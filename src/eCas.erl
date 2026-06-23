%%%-------------------------------------------------------------------
%%% @doc eCas 主 API 模块。
%%%
%%% 提供对缓存表与普通 ETS 表的增删改查接口，所有操作均通过 eGLock 加锁保证并发安全。
%%%
%%% 表类型由 cacheTabDef:tableCache/1 区分：
%%%   undefined - 普通 ETS 表（{Key, Data}），仅内存读写，无落盘/回源
%%%   #tbCache{} - 缓存表（{Key, Data, DirtyState, DirtyFields, AccessTime}）
%%%
%%% 缓存读写流程：
%%%   get   - 先查主缓存 ETS；whole 类型没有则返回 undefined；
%%%            hotData 类型则查 Keys ETS，有 key 则从 DB 加载并缓存
%%%   put   - 写入主缓存 ETS，标记为 update（已有记录）
%%%   insert - 写入主缓存 ETS，标记为 new（新记录），等待落盘时 INSERT
%%%   delete - whole 立即删 DB；hotData 删除 Keys 并标记 DirtyTab 为 del，落盘时 DELETE
%%%   flush  - 触发指定表立即落盘（仅缓存表）
%%%
%%% 锁 key 格式: {TableAtom, RecordKey}
%%%-------------------------------------------------------------------
-module(eCas).

-include("eCas.hrl").

-define(csStartedTablesKey, '$csStartedTables').
-define(noneTab, noneTab).

-export([
	start/7,
	stop/0,

	get/2,
	get/3,

	create/2,
	create/3,
	insert/2,
	insert/3,
	delete/2,
	take/2,
	exists/2,

	mget/2,
	mput/2,
	minsert/2,
	mupdate/2,
	mdelete/2,
	txn/3,
	txn/4,

	foldTable/3,
	foldrTable/3,
	foldKey/3,
	foldrKey/3,

	flush/0,
	flush/1,
	flushSync/0,
	flushSync/1,
	reload/1,
	reload/2,
	stats/1,

	genP/0,
	genM/0,
	keysDelete/2,
	dirtyMaskToFields/2,
	diffDirtyMask/5
]).

genP() ->
	genPSchema:gen("./test/schema/postgresql/", dbSchemaDef, cacheTabDef, "./test", "./test", ["./_build/default/lib/ePgdb/include/"]).
genM() ->
	genMSchema:gen("./test/schema/mysql/", dbSchemaDef, cacheTabDef, "./test", "./test", ["./_build/default/lib/eMysql/include/"]).
%%% ===================================================================
%%% start() / start(Opts)
%%%
%%% 手动启动 DB 连接池与缓存表进程。
%%% 表进程按连接池大小分批启动，每批都同步等待 handleAfter 加载完成消息。
%%% ===================================================================
start(DbMod, Host, Port, User, Password, DbName, PoolArgs) ->
	case application:ensure_all_started(eCas) of
		{ok, _Apps} ->
			DefCnt = max(1, erlang:system_info(schedulers) - 1),
			PoolSize = max(1, proplists:get_value(wFCnt, PoolArgs, DefCnt)),
			case DbMod:start(Host, Port, User, Password, DbName, PoolArgs) of
				{ok, _DbPid} ->
					persistent_term:put(?csDbMod, DbMod),
					case startCsTables(getCacheTables(), [], PoolSize, PoolSize) of
						ok ->
							ok;
						{error, Reason} ->
							stop(),
							{error, Reason}
					end;
				{error, Reason} ->
					{error, {db_start_failed, DbMod, Reason}}
			end;
		{error, Reason} ->
			{error, {app_start_failed, eCas, Reason}}
	end.

startCsTables([], [], BatchSize, BatchSize) -> ok;
startCsTables([Table | Tables], TabPidAcc, LeftSize, BatchSize) when LeftSize > 0 ->
	RetRef = make_ref(),
	case eCas_sup:startTable(Table, {self(), RetRef}) of
		{ok, Pid} ->
			MonitorRef = erlang:monitor(process, Pid),
			startCsTables(Tables, [{Pid, Table, MonitorRef} | TabPidAcc], LeftSize - 1, BatchSize);
		Error ->
			{error, {Table, Error}}
	end;
startCsTables(AllTables, TabPidAcc, LeftSize, BatchSize) ->
	receive
		{eLoadOver, _RetRef, RetTabPid, TableName, Result} ->
			{value, {_TabPid, _TabName, MonitorRef}, NewTabPidAcc} = lists:keytake(RetTabPid, 1, TabPidAcc),
			erlang:demonitor(MonitorRef, [flush]),
			case Result of
				ok ->
					startCsTables(AllTables, NewTabPidAcc, LeftSize + 1, BatchSize);
				_ ->
					{error, {TableName, Result}}
			end;
		{'DOWN', MonRef, process, RetTabPid, Reason} ->
			case lists:keytake(RetTabPid, 1, TabPidAcc) of
				{value, {_TabPid, TabName, MonRef}, _NewTabPidAcc} ->
					{error, {table_down, TabName, Reason}};
				_ ->
					startCsTables(AllTables, TabPidAcc, 0, BatchSize)
			end
	end.

%%% ===================================================================
%%% 手动停止缓存表进程并关闭 DB 连接池。
%%% ===================================================================
-spec stop() -> ok | {error, term()}.
stop() ->
	case persistent_term:get(?csDbMod, undefined) of
		undefined ->
			application:stop(eCas);
		DbMod ->
			AppRet = application:stop(eCas),
			DbRet = DbMod:stop(),
			persistent_term:erase(?csDbMod),
			case {AppRet, DbRet} of
				{ok, ok} -> ok;
				{{error, _} = Error, _} -> Error;
				{_, {error, _} = Error} -> Error;
				_ -> ok
			end
	end.

%%% ===================================================================
%%% get(Table, Key) -> Data | undefined
%%%
%%% whole 类型：ETS 中有则返回，无则 undefined（已全量加载）
%%% hotData 类型：ETS 中有则返回；无则查 Keys ETS，
%%%              key 存在则从 DB 加载并缓存；key 不存在则 undefined
%%% ===================================================================
-spec get(atom(), term()) -> {ok, term()} | {error, term()}.
-spec get(atom(), term(), boolean()) -> {ok, term()} | {error, term()}.
get(Table, Key) -> get(Table, Key, true).
get(Table, Key, IsLock) ->
	?CASE(isCacheTable(Table), getCache(Table, Key, IsLock), getPlain(Table, Key, IsLock)).

getPlain(Table, Key, false) ->
	case ets:lookup(Table, Key) of
		[Data] -> {ok, Data};
		[] -> {error, not_found}
	end;
getPlain(Table, Key, _IsLock) ->
	LockKey = {Table, Key},
	try
		true = eGLock:tryLock(LockKey),
		case ets:lookup(Table, Key) of
			[Data] -> {ok, Data};
			[] -> {error, not_found}
		end
	catch C:R:S ->
		error_logger:error_msg("[eCas] get error table=~p key=~p error=~0p~n", [Table, Key, {C, R, S}]),
		{error, {get_error, {C, R, S}}}
	after
		eGLock:releaseLock(LockKey)
	end.

getCache(Table, Key, false) ->
	case ets:lookup(Table, Key) of
		[CacheValue] ->
			?upAccessTime(Table, Key),
			{ok, ?getCacheData(CacheValue)};
		[] ->
			case cacheTabDef:cacheType(Table) of
				whole -> {error, not_found};
				hotData ->
					case ets:member(?csKeysTab(Table), Key) of
						true -> loadFromDb(Table, Key, false);
						false -> {error, not_found}
					end
			end
	end;
getCache(Table, Key, _IsLock) ->
	LockKey = {Table, Key},
	try
		true = eGLock:tryLock(LockKey),
		case ets:lookup(Table, Key) of
			[CacheValue] ->
				?upAccessTime(Table, Key),
				{ok, ?getCacheData(CacheValue)};
			[] ->
				case cacheTabDef:cacheType(Table) of
					whole -> {error, not_found};
					hotData ->
						case ets:member(?csKeysTab(Table), Key) of
							true -> loadFromDb(Table, Key, true);
							false -> {error, not_found}
						end
				end
		end
	catch C:R:S ->
		error_logger:error_msg("[eCas] get error table=~p key=~p error=~0p~n", [Table, Key, {C, R, S}]),
		{error, {get_error, {C, R, S}}}
	after
		eGLock:releaseLock(LockKey)
	end.

loadFromDb(Table, Key, IsCache) ->
	DbMod = persistent_term:get(?csDbMod),
	[PkField] = cacheTabDef:tablePrimaryKey(Table),
	case DbMod:get(Table, [{PkField, Key}]) of
		{ok, [Data | _]} ->
			KeyValue = cacheTabDef:keyValue(Table, Data),
			IsCache andalso ets:insert(Table, ?cacheValue(KeyValue, Data, ?cs_clean, 0, erlang:monotonic_time(second))),
			{ok, Data};
		{ok, []} ->
			%% DB 中也没有，清理 keys ETS 中的僵尸 key
			IsCache andalso ets:delete(?csKeysTab(Table), Key),
			{error, not_found};
		{error, Reason} ->
			error_logger:error_msg("[eCas] get from db error table=~p key=~p error=~0p~n", [Table, Key, Reason]),
			{error, {load_error, Reason}}
	end.

%%% ===================================================================
%%% put(Table, Key, Data) -> ok
%%%
%%% 将数据写入缓存并标记为 update（用于已存在的记录）。
%%% 不会覆盖已有 new 状态（新记录不能降级为 update）。
%%% ===================================================================
-spec insert(atom(), term()) -> ok | {error, term()}.
-spec insert(atom(), term(), term()) -> ok | {error, term()}.
insert(Table, Data) -> ?CASE(isCacheTable(Table), insert(Table, cacheTabDef:keyValue(Table, Data), Data), {error, not_cache_table}).
insert(Table, Key, Data) ->
	IsCacheTable = isCacheTable(Table),
	LockKey = {Table, Key},
	try
		true = eGLock:tryLock(LockKey),
		?CASE(IsCacheTable, doCacheInsert(Table, Key, Data), doPlainInsert(Table, Key, Data))
	catch
		throw:{error, Reason} ->
			{error, Reason};
		C:R:S ->
			error_logger:error_msg("[eCas] put error table=~p key=~p error=~0p~n", [Table, Key, {C, R, S}]),
			{error, {insert_error, {C, R, S}}}
	after
		eGLock:releaseLock(LockKey)
	end.

getOldCacheStatus(Table, Key, _SaveType) ->
	case cacheTabDef:cacheType(Table) of
		whole ->
			case ets:lookup(Table, Key) of
				[?cacheValue(Key, OldCData, OldCDirtyState, OldCDirtyMask, _AccessTime)] ->
					?OldCacheStatus(OldCData, OldCDirtyState, OldCDirtyMask, false, false);
				[] ->
					?OldCacheStatus(none, ?cs_new, 0, false, true)
			end;
		hotData ->
			case ets:lookup(Table, Key) of
				[?cacheValue(Key, OldCData, OldCDirtyState, OldCDirtyMask, _AccessTime)] ->
					?OldCacheStatus(OldCData, OldCDirtyState, OldCDirtyMask, false, false);
				[] ->
					KeysEts = ?csKeysTab(Table),
					case ets:member(KeysEts, Key) of
						true ->
							?OldCacheStatus(none, ?cs_new, 0, false, true);
						_ ->
							?OldCacheStatus(none, ?cs_new, 0, true, true)

					end
			end
	end.

doCacheInsert(Table, Key, Data) ->
	validateCacheKey(Table, Key, Data),
	SaveType = cacheTabDef:saveType(Table),
	?OldCacheStatus(OldData, OldDirtyState, OldDirtyMask, IsUpKey, IsUpDirty) = getOldCacheStatus(Table, Key, SaveType),
	case SaveType of
		whole ->
			NewDirtyState = ?CASE(OldDirtyState, ?cs_new, ?cs_new, _, ?cs_update),
			ets:insert(Table, ?cacheValue(Key, Data, NewDirtyState, 0, erlang:monotonic_time(second))),
			IsUpKey andalso ets:insert(?csKeysTab(Table), {Key}),
			(IsUpDirty orelse (NewDirtyState /= OldDirtyState)) andalso ets:insert(?csDirtyTab(Table), {Key, NewDirtyState});
		dirty ->
			NewDirtyState = ?CASE(OldDirtyState, ?cs_new, ?cs_new, _, ?cs_update),
			NewDirtyMask = ?CASE(NewDirtyState =:= ?cs_new orelse OldData == none, OldDirtyMask, diffDirtyMask(SaveType, Table, OldData, Data, OldDirtyMask)),
			ets:insert(Table, ?cacheValue(Key, Data, NewDirtyState, NewDirtyMask, erlang:monotonic_time(second))),
			IsUpKey andalso ets:insert(?csKeysTab(Table), {Key}),
			(IsUpDirty orelse (NewDirtyState /= OldDirtyState)) andalso ets:insert(?csDirtyTab(Table), {Key, NewDirtyState})
	end,
	ok.

doPlainInsert(Table, _Key, Data) ->
	ets:insert(Table, Data),
	ok.

%%% ===================================================================
%%% insert(Table, Data) -> ok
%%%
%%% 插入新记录到缓存，标记为 new，落盘时执行 INSERT。
%%% Data 必须包含主键字段（map: #{pk_field => val, ...}，
%%%       record: {TableName, val1, val2, ...}）。
%%% ===================================================================
-spec create(atom(), term()) -> ok | {error, term()}.
-spec create(atom(), term(), term()) -> ok | {error, term()}.
create(Table, Data) -> ?CASE(isCacheTable(Table), create(Table, cacheTabDef:keyValue(Table, Data), Data), {error, not_cache_table}).
create(Table, Key, Data) ->
	IsCacheTable = isCacheTable(Table),
	LockKey = {Table, Key},
	try
		true = eGLock:tryLock(LockKey),
		?CASE(IsCacheTable, doCacheCreate(Table, Key, Data), doPlainCreate(Table, Key, Data))
	catch
		throw:{error, Reason} ->
			{error, Reason};
		C:R:S ->
			error_logger:error_msg("[eCas] insert error table=~p key=~p error=~0p~n", [Table, Key, {C, R, S}]),
			{error, {insert_error, {C, R, S}}}
	after
		eGLock:releaseLock(LockKey)
	end.

doCacheCreate(Table, Key, Data) ->
	validateCacheKey(Table, Key, Data),
	case cacheTabDef:cacheType(Table) of
		hotData ->
			case ets:member(?csKeysTab(Table), Key) of
				true ->
					{error, create_failed};
				_ ->
					case ets:insert_new(Table, ?cacheValue(Key, Data, ?cs_new, 0, erlang:monotonic_time(second))) of
						true ->
							ets:insert(?csKeysTab(Table), {Key}),
							ets:insert(?csDirtyTab(Table), {Key, ?cs_new}),
							ok;
						_ ->
							{error, create_failed}
					end
			end;
		whole ->
			case ets:insert_new(Table, ?cacheValue(Key, Data, ?cs_new, 0, erlang:monotonic_time(second))) of
				true ->
					ets:insert(?csDirtyTab(Table), {Key, ?cs_new}),
					ok;
				_ ->
					{error, create_failed}
			end
	end.

doPlainCreate(Table, _Key, Data) ->
	case ets:insert_new(Table, Data) of
		true -> ok;
		_ -> {error, create_failed}
	end.

%%% ===================================================================
%%% delete(Table, Key) -> ok
%%%
%%% 删除记录。hotData / whole 均标记为 del，由 flush 落盘时删库。
%%% ===================================================================
-spec delete(atom(), term()) -> ok | {error, term()}.
delete(Table, Key) ->
	IsCacheTable = isCacheTable(Table),
	LockKey = {Table, Key},
	try
		true = eGLock:tryLock(LockKey),
		?CASE(IsCacheTable, doCacheDelete(Table, Key), doPlainDelete(Table, Key))
	catch C:R:S ->
		error_logger:error_msg("[eCas] delete error table=~p key=~p error=~0p~n", [Table, Key, {C, R, S}]),
		{error, {delete_error, {C, R, S}}}
	after
		eGLock:releaseLock(LockKey)
	end.

%%% ===================================================================
%%% delete_return(Table, Key) -> {ok, Data} | {error, Reason}
%%%
%%% 删除记录并返回被删除的数据。
%%% whole 直接读取主缓存 ETS；hotData 主缓存未命中时，若 Keys ETS 有 key，
%%% 则先从 DB 加载数据用于返回，再按 delete/2 语义删除。
%%% ===================================================================
-spec take(atom(), term()) -> {ok, term()} | {error, term()}.
take(Table, Key) ->
	IsCacheTable = isCacheTable(Table),
	LockKey = {Table, Key},
	try
		true = eGLock:tryLock(LockKey),
		case IsCacheTable of
			false ->
				case ets:lookup(Table, Key) of
					[Data] ->
						ets:delete(Table, Key),
						{ok, Data};
					[] ->
						{error, not_found}
				end;
			_ ->
				Ret =
					case cacheTabDef:cacheType(Table) of
						whole ->
							case ets:lookup(Table, Key) of
								[CacheValue] -> {ok, ?getCacheData(CacheValue)};
								[] -> {error, not_found}
							end;
						hotData ->
							case ets:lookup(Table, Key) of
								[CacheValue] ->
									{ok, ?getCacheData(CacheValue)};
								[] ->
									case ets:member(?csKeysTab(Table), Key) of
										true -> loadFromDb(Table, Key, false);
										false -> {error, not_found}
									end
							end
					end,
				case Ret of
					{ok, Data} ->
						case doCacheDelete(Table, Key) of
							ok -> {ok, Data};
							{error, Reason} -> {error, Reason}
						end;
					Error ->
						Error
				end
		end
	catch C:R:S ->
		error_logger:error_msg("[eCas] delete_return error table=~p key=~p error=~0p~n", [Table, Key, {C, R, S}]),
		{error, {delete_return_error, {C, R, S}}}
	after
		eGLock:releaseLock(LockKey)
	end.

doPlainDelete(Table, Key) ->
	ets:delete(Table, Key),
	ok.

doCacheDelete(Table, Key) ->
	DirtyTab = ?csDirtyTab(Table),
	DirtyState = case ets:lookup(DirtyTab, Key) of
		[{Key, Type}] -> Type;
		[] -> ?cs_clean
	end,

	WasNew = DirtyState =:= ?cs_new,
	case cacheTabDef:cacheType(Table) of
		hotData ->
			KeysTab = ?csKeysTab(Table),
			HasTarget = ets:member(KeysTab, Key),
			?CASE(HasTarget andalso not WasNew, ets:insert(DirtyTab, {Key, ?cs_del}), ets:delete(DirtyTab, Key)),
			ets:delete(KeysTab, Key),
			ets:delete(Table, Key);
		_ ->
			HasTarget = ets:member(Table, Key),
			?CASE(HasTarget andalso not WasNew, ets:insert(DirtyTab, {Key, ?cs_del}), ets:delete(DirtyTab, Key)),
			ets:delete(Table, Key)
	end,
	ok.

%%% ===================================================================
%%% exists(Table, Key) -> boolean()
%%%
%%% 仅检查缓存 ETS 是否存在指定 Key，不触发 DB 回源。
%%% whole  类型下等价于「记录是否存在」。
%%% hotData 类型下查 Keys ETS，只要 Key 在 DB 里存在即返回 true（
%%%   无论是否已加载到主缓存）。
%%% 比 get/2 /= undefined 效率高很多，无锁开销。
%%% ===================================================================
-spec exists(atom(), term()) -> boolean().
exists(Table, Key) ->
	case ets:member(Table, Key) of
		true -> true;
		_ ->
			case cacheTabDef:cacheType(Table) of
				hotData ->
					ets:member(?csKeysTab(Table), Key);
				_ ->
					false
			end
	end.

%%% ===================================================================
%%% foldTable/3 - 遍历表（缓存表与普通 ETS 表统一取业务 Data）
%%% ===================================================================
-spec foldTable(atom(), term(), fun((term(), term()) -> term())) -> term().
foldTable(Table, InitAcc, Fun) when is_function(Fun, 2) ->
	case cacheTabDef:cacheType(Table) of
		hotData ->
			ets:foldl(fun({Key}, Acc) ->
				case get(Table, Key, true) of
					{ok, Data} ->
						Fun(Data, Acc);
					{error, not_found} ->
						Acc;
					{error, Reason} ->
						error({fold_load_failed, Table, Key, Reason})
				end
			end, InitAcc, ?csKeysTab(Table));
		undefined ->
			ets:foldl(Fun, InitAcc, Table);
		_ ->
			ets:foldl(fun(CacheValue, Acc) -> Fun(?getCacheData(CacheValue), Acc) end, InitAcc, Table)
	end.

-spec foldrTable(atom(), term(), fun((term(), term()) -> term())) -> term().
foldrTable(Table, InitAcc, Fun) when is_function(Fun, 2) ->
	case cacheTabDef:cacheType(Table) of
		hotData ->
			ets:foldr(fun({Key}, Acc) ->
				case get(Table, Key, true) of
					{ok, Data} ->
						Fun(Data, Acc);
					{error, not_found} ->
						Acc;
					{error, Reason} ->
						error({fold_load_failed, Table, Key, Reason})
				end
			end, InitAcc, ?csKeysTab(Table));
		undefined ->
			ets:foldr(Fun, InitAcc, Table);
		_ ->
			ets:foldr(fun(CacheValue, Acc) -> Fun(?getCacheData(CacheValue), Acc) end, InitAcc, Table)
	end.

-spec foldKey(atom(), term(), fun((term(), term()) -> term())) -> term().
foldKey(Table, InitAcc, Fun) when is_function(Fun, 2) ->
	case cacheTabDef:cacheType(Table) of
		hotData ->
			ets:foldl(fun({Key}, Acc) -> Fun(Key, Acc) end, InitAcc, ?csKeysTab(Table));
		undefined ->
			KeyPos = ets:info(Table, keypos),
			ets:foldl(fun(Data, Acc) -> Fun(element(KeyPos, Data), Acc) end, InitAcc, Table);
		_ ->
			ets:foldl(fun(CacheValue, Acc) -> Fun(cacheTabDef:keyValue(Table, ?getCacheData(CacheValue)), Acc) end, InitAcc, Table)
	end.

-spec foldrKey(atom(), term(), fun((term(), term()) -> term())) -> term().
foldrKey(Table, InitAcc, Fun) when is_function(Fun, 2) ->
	case cacheTabDef:cacheType(Table) of
		hotData ->
			ets:foldr(fun({Key}, Acc) -> Fun(Key, Acc) end, InitAcc, ?csKeysTab(Table));
		undefined ->
			KeyPos = ets:info(Table, keypos),
			ets:foldr(fun(Data, Acc) -> Fun(element(KeyPos, Data), Acc) end, InitAcc, Table);
		_ ->
			ets:foldr(fun(CacheValue, Acc) -> Fun(cacheTabDef:keyValue(Table, ?getCacheData(CacheValue)), Acc) end, InitAcc, Table)
	end.

%%% ===================================================================
%%% flush() -> ok
%%%
%%% 触发所有缓存表立即落盘（异步）。
%%% ===================================================================
-spec flush() -> ok.
flush() ->
	[csTabSrv:flush(Table, false) || Table <- getCacheTables()],
	ok.

%%% ===================================================================
%%% flush(Table) -> ok
%%%
%%% 触发指定表立即落盘（异步，发送 cast 给对应进程）。
%%% ===================================================================
-spec flush(atom()) -> ok | {error, not_cache_table}.
flush(Table) ->
	case isCacheTable(Table) of
		true -> csTabSrv:flush(Table, false), ok;
		false -> {error, not_cache_table}
	end.

%%% ===================================================================
%%% flushSync() -> ok
%%%
%%% 同步落盘所有缓存表。
%%% ===================================================================
-spec flushSync() -> ok | {error, [{atom(), term()}]}.
flushSync() ->
	Results = [{Table, flushSync(Table)} || Table <- getCacheTables()],
	case [{Table, Reason} || {Table, {error, Reason}} <- Results] of
		[] -> ok;
		Errors -> {error, Errors}
	end.

%%% ===================================================================
%%% flushSync(Table) -> ok
%%%
%%% 同步落盘：阻塞调用直到本次落盘完成。
%%% ===================================================================
-spec flushSync(atom()) -> ok | {error, term()}.
flushSync(Table) ->
	case isCacheTable(Table) of
		false ->
			{error, not_cache_table};
		true ->
			try normalizeFlushRet(csTabSrv:flush(Table, true))
			catch
				exit:Reason -> {error, {flush_exit, Reason}};
				C:R:S -> {error, {flush_error, {C, R, S}}}
			end
	end.

normalizeFlushRet(false) -> ok;
normalizeFlushRet(ok) -> ok;
normalizeFlushRet(flushLimit) -> {error, flushLimit};
normalizeFlushRet({error, _Reason} = Error) -> Error;
normalizeFlushRet(Other) -> {error, {unexpected_flush_result, Other}}.

%%% ===================================================================
%%% reload(Table) -> ok
%%%
%%% 全表重新加载：先把当前脏数据落盘，然后清空缓存并重新从 DB 加载。
%%% 用于表数据被外部直接修改后强制同步。
%%% ===================================================================
-spec reload(atom()) -> term().
reload(Table) ->
	case isCacheTable(Table) of
		true -> csTabSrv:reload(Table);
		false -> ok
	end.

%%% ===================================================================
%%% reload(Table, Key) -> Data | undefined | {error, Reason}
%%%
%%% 单条记录重载：从 DB 拉取最新数据覆盖缓存，清除脏状态。
%%% 用于处理数据冲突或强制同步单条记录。
%%% ===================================================================
-spec reload(atom(), term()) -> term() | {error, term()}.
reload(Table, Key) ->
	case isCacheTable(Table) of
		true -> csTabSrv:reload(Table, Key);
		false -> get(Table, Key)
	end.

%%% ===================================================================
%%% stats(Table) -> map()
%%%
%%% 获取指定表的运行时统计信息：缓存条数、脏记录数、配置参数等。
%%% ===================================================================
-spec stats(atom()) -> map().
stats(Table) ->
	case isCacheTable(Table) of
		true -> csTabSrv:stats(Table);
		false -> #{type => plain, size => ets:info(Table, size)}
	end.

%%% ===================================================================
%%% 批量 API
%%% ===================================================================
-spec mget(atom(), [term()]) -> [{term(), {ok, term()} | {error, term()}}].
mget(Table, Keys) ->
	[{Key, get(Table, Key)} || Key <- Keys].

%%% ===================================================================
%%% mput(Table, Entries) -> ok
%%%
%%% 批量覆写缓存中的完整记录，使用一次事务批量加锁以降低锁开销。
%%% Entries :: [{Key, Data}]
%%% ===================================================================
-spec mput(atom(), [{term(), term()}]) -> ok | {error, term()}.
mput(_Table, []) ->
	ok;
mput(Table, Entries) ->
	TxnKeys = [{Table, Key} || {Key, _Data} <- Entries],
	AlterTab = [{{Table, Key}, Data} || {Key, Data} <- Entries],
	txn(TxnKeys, fun(InAlterTab, _TxnValues) ->
		{alterTab, InAlterTab}
	end, AlterTab).

%%% ===================================================================
%%% txn(KeyOrKeys, Fun, Args, TimeOut) -> Result
%%%
%%% 开启多表、多记录跨行事务（接口形态与 eGLock:txn/4 对齐）。
%%% 使用 eGLock:tryLock/releaseLock 加锁，并由 eCas 自己维护缓存表
%%% 主表、Keys ETS、Dirty ETS 的提交顺序（含 dirtyMask 维护）。
%%%
%%% KeyOrKeys：单个 TxnKey 或 TxnKey 列表
%%%   {?noneTab, JustKey} | {?noneTab, JustKey, DefValue}
%%%   {EtsTab, TabKey}    | {EtsTab, TabKey, DefValue}
%%%   其中 EtsTab 可以是缓存 table，也可以是普通 ets 表
%%%
%%% Fun 接收参数：
%%%   Fun(Args, [{{Table, Key}, Data | Default | undefined}])
%%%
%%% Fun 返回值：
%%%   {alterTab, AlterTab}
%%%   {alterTab, Ret, AlterTab}
%%%   Ret
%%%
%%% AlterTab:
%%%   {{Table, Key}, Data}      - put/update，要求 key 已在 TxnKeys 中锁定
%%%   {{Table, Key}, new, Data} - create/insert_new，不要求 key 已存在
%%%   {{Table, Key}, del}       - delete，要求 key 已在 TxnKeys 中锁定
%%%
%%% 提交 alterTab 时自动维护脏表、dirtyMask、Keys ETS；
%%% 提交中途失败会回退本次事务的所有 ETS 修改（包括新增和删除）。
%%% ===================================================================
-spec txn(term() | [term()], fun((term(), list()) -> term()), term()) -> term().
txn(KeyOrKeys, Fun, Args) ->
	txn(KeyOrKeys, Fun, Args, ?casTimeOut).

-spec txn(term() | [term()], fun((term(), list()) -> term()), term(), integer() | infinity) -> term().
txn(TxnKeys, Fun, Args, TimeOut) when is_function(Fun, 2) ->
	TxnKeyList = ?CASE(is_list(TxnKeys), TxnKeys, [TxnKeys]),
	TxnKeyIxs = eGLock:getKeyIxAndMaps(TxnKeyList, []),
	case eGLock:tryLock(TxnKeyIxs, TimeOut) of
		true ->
			try
				{TxnValues, OldStatusList} = buildTxnValues(TxnKeyList, [], []),
				case Fun(Args, TxnValues) of
					{alterTab, AlterTab} ->
						case commitTxnAlter(TxnKeyList, AlterTab, OldStatusList) of
							ok -> ok;
							Error -> Error
						end;
					{alterTab, Ret, AlterTab} ->
						case commitTxnAlter(TxnKeyList, AlterTab, OldStatusList) of
							ok -> Ret;
							Error -> Error
						end;
					Other ->
						Other
				end
			catch
				throw:Throw ->
					Throw;
				C:R:S ->
					error_logger:error_msg("[eCas] txn error keys=~p error=~0p~n", [TxnKeys, {C, R, S}]),
					{error, {txn_error, {C, R, S}}}
			after
				eGLock:releaseLock(TxnKeyIxs)
			end;
		lockTimeout ->
			{error, {lock_timeout, TxnKeys}};
		Other ->
			{error, {lock_failed, Other, TxnKeys}}
	end.

buildTxnValues([], ValueAcc, StatusAcc) ->
	{lists:reverse(ValueAcc), StatusAcc};
buildTxnValues([TxnKey | TxnKeys], ValueAcc, StatusAcc) ->
	case TxnKey of
		{EtsTab, TabKey} ->
			txnValueStatus(EtsTab, TabKey, undefined, TxnKeys, ValueAcc, StatusAcc);
		{EtsTab, TabKey, DefValue} ->
			txnValueStatus(EtsTab, TabKey, DefValue, TxnKeys, ValueAcc, StatusAcc)
	end.

txnValueStatus(?noneTab, Key, DefValue, TxnKeys, ValueAcc, StatusAcc) ->
	Value = txnDefValue(DefValue),
	Status = ?RbCacheStatus({?noneTab, Key}, ?noneTab, undefined, ?cs_clean, 0, false, false, false, false),
	buildTxnValues(TxnKeys, [{{?noneTab, Key}, Value} | ValueAcc], [Status | StatusAcc]);
txnValueStatus(EtsTab, Key, DefValue, TxnKeys, ValueAcc, StatusAcc) ->
	case cacheTabDef:cacheType(EtsTab) of
		undefined ->
			case ets:lookup(EtsTab, Key) of
				[Value] ->
					Status = ?RbCacheStatus({EtsTab, Key}, etsTab, Value, ?cs_clean, 0, false, false, false, false),
					buildTxnValues(TxnKeys, [{{EtsTab, Key}, Value} | ValueAcc], [Status | StatusAcc]);
				_ ->
					Status = ?RbCacheStatus({EtsTab, Key}, etsTab, undefined, ?cs_clean, 0, false, false, false, false),
					buildTxnValues(TxnKeys, [{{EtsTab, Key}, txnDefValue(DefValue)} | ValueAcc], [Status | StatusAcc])
			end;
		hotData ->
			case ets:lookup(EtsTab, Key) of
				[?cacheValue(Key, Data, DirtyState, DirtyMask, _AccessTime) = CacheValue] ->
					?upAccessTime(EtsTab, Key),
					HasKey = ets:member(?csKeysTab(EtsTab), Key),
					HasDirty = ets:member(?csDirtyTab(EtsTab), Key),
					IsUpKey = not HasKey,
					IsUpDirty = not HasDirty,
					Status = ?RbCacheStatus({EtsTab, Key}, hotData, CacheValue, DirtyState, DirtyMask, IsUpKey, IsUpDirty, HasKey, HasDirty),
					buildTxnValues(TxnKeys, [{{EtsTab, Key}, Data} | ValueAcc], [Status | StatusAcc]);
				_ ->
					case ets:member(?csKeysTab(EtsTab), Key) of
						true ->
							case loadFromDb(EtsTab, Key, true) of
								{ok, _Data} ->
									[?cacheValue(Key, Data, DirtyState, DirtyMask, _AccessTime) = CacheValue] = ets:lookup(EtsTab, Key),
									HasDirty = ets:member(?csDirtyTab(EtsTab), Key),
									IsUpDirty = not HasDirty,
									Status = ?RbCacheStatus({EtsTab, Key}, hotData, CacheValue, DirtyState, DirtyMask, false, IsUpDirty, true, HasDirty),
									buildTxnValues(TxnKeys, [{{EtsTab, Key}, Data} | ValueAcc], [Status | StatusAcc]);
								{error, not_found} ->
									{HasDirty, DirtyState} = getOldDirty(EtsTab, Key),
									Status = ?RbCacheStatus({EtsTab, Key}, hotData, undefined, DirtyState, 0, true, true, true, HasDirty),
									buildTxnValues(TxnKeys, [{{EtsTab, Key}, txnCacheDefValue(EtsTab, Key, DefValue)} | ValueAcc], [Status | StatusAcc]);
								{error, Reason} ->
									throw({error, {txn_load_failed, EtsTab, Key, Reason}})
							end;
						_ ->
							HasKey = false,
							{HasDirty, DirtyState} = getOldDirty(EtsTab, Key),
							Status = ?RbCacheStatus({EtsTab, Key}, hotData, undefined, DirtyState, 0, true, true, HasKey, HasDirty),
							buildTxnValues(TxnKeys, [{{EtsTab, Key}, txnCacheDefValue(EtsTab, Key, DefValue)} | ValueAcc], [Status | StatusAcc])
					end
			end;
		whole ->
			case ets:lookup(EtsTab, Key) of
				[?cacheValue(Key, Data, DirtyState, DirtyMask, _AccessTime) = CacheValue] ->
					HasDirty = ets:member(?csDirtyTab(EtsTab), Key),
					IsUpDirty = not HasDirty,
					Status = ?RbCacheStatus({EtsTab, Key}, whole, CacheValue, DirtyState, DirtyMask, false, IsUpDirty, true, HasDirty),
					buildTxnValues(TxnKeys, [{{EtsTab, Key}, Data} | ValueAcc], [Status | StatusAcc]);
				_ ->
					{HasDirty, DirtyState} = getOldDirty(EtsTab, Key),
					Status = ?RbCacheStatus({EtsTab, Key}, whole, undefined, DirtyState, 0, false, not HasDirty, false, HasDirty),
					buildTxnValues(TxnKeys, [{{EtsTab, Key}, txnCacheDefValue(EtsTab, Key, DefValue)} | ValueAcc], [Status | StatusAcc])
			end
	end.

txnDefValue(undefined) -> undefined;
txnDefValue({DefFun, Args}) when is_function(DefFun) -> erlang:apply(DefFun, Args);
txnDefValue(DefValue) -> DefValue.

txnCacheDefValue(_Table, _Key, undefined) ->
	undefined;
txnCacheDefValue(Table, Key, DefValue) ->
	case txnDefValue(DefValue) of
		undefined -> undefined;
		Data ->
			validateTxnCacheKey(Table, Key, Data),
			Data
	end.

getOldDirty(Table, Key) ->
	case ets:lookup(?csDirtyTab(Table), Key) of
		[{Key, OldDirtyState}] -> {true, OldDirtyState};
		_ -> {false, ?cs_new}
	end.

commitTxnAlter(TxnKeys, AlterTab, OldStatusList) ->
	validateTxnAlters(TxnKeys, AlterTab, OldStatusList),
	initAlterState(),
	try
		commitTxnAlters(AlterTab, OldStatusList),
		clearAlterState()
	catch
		throw:{error, Reason}:_S ->
			AlterCnt = clearAlterCnt(),
			NewDirtyList = clearTxnNewDirty(),
			rollbackTxnAlters(AlterTab, OldStatusList, AlterCnt, NewDirtyList),
			{error, Reason};
		C:R:S ->
			AlterCnt = clearAlterCnt(),
			NewDirtyList = clearTxnNewDirty(),
			RollbackRet = rollbackTxnAlters(AlterTab, OldStatusList, AlterCnt, NewDirtyList),
			{error, {txn_commit_failed, {C, R, S}, RollbackRet}}
	end.

validateTxnAlters(_TxnKeys, [], _OldStatusList) ->
	ok;
validateTxnAlters(TxnKeys, [Alter | AlterTab], OldStatusList) ->
	validateTxnAlter(TxnKeys, Alter, OldStatusList),
	validateTxnAlters(TxnKeys, AlterTab, OldStatusList).

validateTxnAlter(_TxnKeys, {{?noneTab, _Key}, _Value}, _OldStatusList) ->
	ok;
%% new 是 create 语义，允许提交未预读/未预锁的 key；put/delete 必须来自 OldStatusList。
validateTxnAlter(_TxnKeys, {{_Table, _Key}, new, _Value}, _OldStatusList) ->
	ok;
validateTxnAlter(_TxnKeys, {{Table, Key}, _Value}, OldStatusList) ->
	case lists:keyfind({Table, Key}, 1, OldStatusList) of
		false -> throw({error, {txn_alter_key_not_locked, {Table, Key}}});
		_ -> ok
	end.

commitTxnAlters([], _OldStatusList) ->
	ok;
commitTxnAlters([Alter | AlterTab], OldStatusList) ->
	addAlterCnt(),
	case Alter of
		{{?noneTab, _Key}, _Value} ->
			ok;
		{{?noneTab, _Key}, new, _Value} ->
			ok;
		{{Table, Key}, del} ->
			applyTxnDelete(Table, Key);
		{{Table, Key}, new, Value} ->
			applyTxnCreate(Table, Key, Value);
		{{Table, Key}, Value} ->
			applyTxnPut(Table, Key, Value, OldStatusList)
	end,
	commitTxnAlters(AlterTab, OldStatusList).

validatePlainKey(Table, Key, Value) ->
	case plainDataKey(Table, Value) of
		{ok, Key} -> ok;
		{ok, DataKey} -> throw({error, {key_mismatch, Table, Key, DataKey}});
		{error, Reason} -> throw({error, Reason})
	end.

validateTxnCacheKey(Table, Key, Data) ->
	case cacheTabDef:keyValue(Table, Data) of
		Key -> ok;
		DataKey -> throw({error, {key_mismatch, Table, Key, DataKey}})
	end.

applyTxnCreate(Table, Key, Value) ->
	case cacheTabDef:cacheType(Table) of
		undefined ->
			validatePlainKey(Table, Key, Value),
			case ets:insert_new(Table, Value) of
				true ->
					addTxnNewDirty(Table, Key),
					ok;
				false -> throw({error, {create_failed, Table, Key}})
			end;
		hotData ->
			validateTxnCacheKey(Table, Key, Value),
			case ets:member(?csKeysTab(Table), Key) of
				true ->
					throw({error, {create_failed, Table, Key}});
				false ->
					CacheValue = ?cacheValue(Key, Value, ?cs_new, 0, erlang:monotonic_time(second)),
					case ets:insert_new(Table, CacheValue) of
						true ->
							addTxnNewDirty(Table, Key),
							ets:insert(?csKeysTab(Table), {Key}),
							ets:insert(?csDirtyTab(Table), {Key, ?cs_new}),
							ok;
						false ->
							throw({error, {create_failed, Table, Key}})
					end
			end;
		whole ->
			validateTxnCacheKey(Table, Key, Value),
			CacheValue = ?cacheValue(Key, Value, ?cs_new, 0, erlang:monotonic_time(second)),
			case ets:insert_new(Table, CacheValue) of
				true ->
					addTxnNewDirty(Table, Key),
					ets:insert(?csDirtyTab(Table), {Key, ?cs_new}),
					ok;
				false ->
					throw({error, {create_failed, Table, Key}})
			end
	end,
	ok.

applyTxnDelete(Table, Key) ->
	case cacheTabDef:cacheType(Table) of
		undefined ->
			ets:delete(Table, Key);
		hotData ->
			HasTarget = ets:member(?csKeysTab(Table), Key),
			case ets:lookup(?csDirtyTab(Table), Key) of
				[{Key, ?cs_new}] ->
					ets:delete(?csDirtyTab(Table), Key);
				_ ->
					HasTarget andalso ets:insert(?csDirtyTab(Table), {Key, ?cs_del})
			end,
			ets:delete(?csKeysTab(Table), Key),
			ets:delete(Table, Key);
		whole ->
			HasTarget = ets:member(Table, Key),
			case ets:lookup(?csDirtyTab(Table), Key) of
				[{Key, ?cs_new}] -> ets:delete(?csDirtyTab(Table), Key);
				_ ->
					HasTarget andalso ets:insert(?csDirtyTab(Table), {Key, ?cs_del})
			end,
			ets:delete(Table, Key)
	end,
	ok.

applyTxnPut(Table, Key, Value, OldStatusList) ->
	case cacheTabDef:cacheType(Table) of
		undefined ->
			validatePlainKey(Table, Key, Value),
			ets:insert(Table, Value),
			ok;
		_ ->
			validateTxnCacheKey(Table, Key, Value),
			SaveType = cacheTabDef:saveType(Table),
			OldStatus = lists:keyfind({Table, Key}, 1, OldStatusList),
			?RbCacheStatus(_ValueKey, _TabType, OldCacheValue, OldDirtyState, OldDirtyMask, IsUpKey, IsUpDirty, _HasKey, _HasDirty) = OldStatus,

			OldData = case OldCacheValue of
				undefined -> none;
				_ -> ?getCacheData(OldCacheValue)
			end,
			NewDirtyState = ?CASE(OldDirtyState, ?cs_new, ?cs_new, _, ?cs_update),
			NewDirtyMask = ?CASE(SaveType == whole orelse NewDirtyState =:= ?cs_new orelse OldData == none, OldDirtyMask, diffDirtyMask(SaveType, Table, OldData, Value, OldDirtyMask)),
			ets:insert(Table, ?cacheValue(Key, Value, NewDirtyState, NewDirtyMask, erlang:monotonic_time(second))),
			IsUpKey andalso ets:insert(?csKeysTab(Table), {Key}),
			(IsUpDirty orelse (NewDirtyState /= OldDirtyState)) andalso ets:insert(?csDirtyTab(Table), {Key, NewDirtyState})
	end,
	ok.

rollbackTxnAlters(AlterTab, OldStatusList, AlterCnt, NewDirtyList) ->
	RollbackAlters = lists:reverse(lists:sublist(AlterTab, AlterCnt)),
	lists:foldl(fun(Alter, Acc) ->
		try
			rollbackTxnAlter(Alter, OldStatusList, NewDirtyList),
			Acc
		catch C:R:S ->
			error_logger:error_msg("[eCas] txn rollback alter error alter=~p error=~0p~n", [Alter, {C, R, S}]),
			?CASE(Acc =:= ok, {error, [{Alter, {C, R, S}}]}, {error, [{Alter, {C, R, S}} | element(2, Acc)]})
		end
	end, ok, RollbackAlters).

rollbackTxnAlter({{?noneTab, _Key}, _Value}, _OldStatusList, _NewDirtyList) ->
	ok;
rollbackTxnAlter({{?noneTab, _Key}, new, _Value}, _OldStatusList, _NewDirtyList) ->
	ok;
rollbackTxnAlter({{Table, Key}, new, _Value}, _OldStatusList, NewDirtyList) ->
	rollbackTxnCreate(Table, Key, NewDirtyList);
rollbackTxnAlter({TxnKey, del}, OldStatusList, _NewDirtyList) ->
	rollbackTxnStatus(lists:keyfind(TxnKey, 1, OldStatusList));
rollbackTxnAlter({TxnKey, _Value}, OldStatusList, _NewDirtyList) ->
	rollbackTxnStatus(lists:keyfind(TxnKey, 1, OldStatusList)).

rollbackTxnCreate(Table, Key, NewDirtyList) ->
	case lists:keyfind({Table, Key}, 1, NewDirtyList) of
		false ->
			ok;
		{{_Table, _Key}, plain} ->
			ets:delete(Table, Key);
		{{_Table, _Key}, OldDirty} ->
			case cacheTabDef:cacheType(Table) of
				hotData ->
					rollbackTxnCreateDirty(Table, Key, OldDirty),
					ets:delete(?csKeysTab(Table), Key),
					ets:delete(Table, Key);
				whole ->
					rollbackTxnCreateDirty(Table, Key, OldDirty),
					ets:delete(Table, Key)
			end,
			ok
	end.

rollbackTxnCreateDirty(Table, Key, none) ->
	ets:delete(?csDirtyTab(Table), Key);
rollbackTxnCreateDirty(Table, Key, {dirty, OldDirtyState}) ->
	ets:insert(?csDirtyTab(Table), {Key, OldDirtyState}),
	ok.

rollbackTxnStatus(?RbCacheStatus({_Table, _Key}, ?noneTab, _OldRow, _OldDirtyState, _OldDirtyMask, _IsUpKey, _IsUpDirty, _HasKey, _HasDirty)) ->
	ok;
rollbackTxnStatus(?RbCacheStatus({Table, Key}, etsTab, OldRow, _OldDirtyState, _OldDirtyMask, _IsUpKey, _IsUpDirty, _HasKey, _HasDirty)) ->
	rollbackMainRow(Table, Key, OldRow);
rollbackTxnStatus(?RbCacheStatus({Table, Key}, whole, OldRow, OldDirtyState, _OldDirtyMask, _IsUpKey, _IsUpDirty, _HasKey, HasDirty)) ->
	rollbackDirtyRow(Table, Key, OldDirtyState, HasDirty),
	rollbackMainRow(Table, Key, OldRow);
rollbackTxnStatus(?RbCacheStatus({Table, Key}, hotData, OldRow, OldDirtyState, _OldDirtyMask, _IsUpKey, _IsUpDirty, HasKey, HasDirty)) ->
	rollbackDirtyRow(Table, Key, OldDirtyState, HasDirty),
	rollbackKeysRow(Table, Key, HasKey),
	rollbackMainRow(Table, Key, OldRow).

rollbackMainRow(Table, Key, undefined) ->
	ets:delete(Table, Key);
rollbackMainRow(Table, _Key, OldRow) ->
	ets:insert(Table, OldRow).

rollbackKeysRow(Table, Key, HasKey) ->
	KeysTab = ?csKeysTab(Table),
	?CASE(HasKey, ets:insert(KeysTab, {Key}), ets:delete(KeysTab, Key)),
	ok.

rollbackDirtyRow(Table, Key, OldDirtyState, HasDirty) ->
	DirtyTab = ?csDirtyTab(Table),
	?CASE(HasDirty, ets:insert(DirtyTab, {Key, OldDirtyState}), ets:delete(DirtyTab, Key)),
	ok.

%%% ===================================================================
%%% minsert(Table, DataList) -> ok
%%%
%%% 批量插入新记录到缓存。
%%% ===================================================================
-spec minsert(atom(), [term()]) -> ok | {error, term()}.
minsert(_Table, []) ->
	ok;
minsert(Table, DataList) ->
	case isCacheTable(Table) of
		true ->
			TxnKeys = [{Table, cacheTabDef:keyValue(Table, Data)} || Data <- DataList],
			txn(TxnKeys, fun(InDataList, TxnValues) ->
				{Errors, Alters} = lists:foldl(fun(Data, {ErrAcc, AlterAcc}) ->
					Key = cacheTabDef:keyValue(Table, Data),
					case lists:keyfind({Table, Key}, 1, TxnValues) of
						{{Table, Key}, undefined} ->
							{ErrAcc, [{{Table, Key}, new, Data} | AlterAcc]};
						_ ->
							{[{Key, create_failed} | ErrAcc], AlterAcc}
					end
				end, {[], []}, InDataList),
				Ret = ?CASE(Errors, [], ok, _, {error, lists:reverse(Errors)}),
				{alterTab, Ret, lists:reverse(Alters)}
			end, DataList);
		false ->
			{error, not_cache_table}
	end.

%%% ===================================================================
%%% mupdate(Table, ChangesList) -> ok | {error, [{Key, not_found}]}
%%%
%%% 批量局部更新缓存中的若干字段，使用一次事务批量加锁执行。
%%% ChangesList :: [{Key, #{FieldAtom => NewValue} | [{FieldAtom, NewValue}]}]
%%% ===================================================================
-spec mupdate(atom(), [{term(), map() | [{atom(), term()}]}]) -> ok | {error, [{term(), term()}]}.
mupdate(_Table, []) ->
	ok;
mupdate(Table, ChangesList) ->
	?CASE(isCacheTable(Table),
		begin
			TxnKeys = [{Table, Key} || {Key, _Changes} <- ChangesList],
			txn(TxnKeys, fun(InChangesList, TxnValues) ->
				{Errors, Alters} = lists:foldl(fun({{_Table, Key}, Value}, {ErrAcc, AlterAcc}) ->
					Changes = proplists:get_value(Key, InChangesList),
					case txnUpdateData(Table, Key, Value) of
						{ok, Data} ->
							NewData = applyChanges(Table, Data, Changes),
							{ErrAcc, [{{Table, Key}, NewData} | AlterAcc]};
						{error, Reason} ->
							{[{Key, Reason} | ErrAcc], AlterAcc}
					end
				end, {[], []}, TxnValues),
				Ret = ?CASE(Errors, [], ok, _, {error, lists:reverse(Errors)}),
				{alterTab, Ret, lists:reverse(Alters)}
			end, ChangesList)
		end,
		{error, not_cache_table}).

txnUpdateData(Table, _Key, Value) ->
	case {isCacheTable(Table), Value} of
		{_, undefined} -> {error, not_found};
		{true, Data} -> {ok, Data};
		{false, Data} -> {ok, Data}
	end.

%%% ===================================================================
%%% mdelete(Table, Keys) -> ok
%%%
%%% 批量删除多条缓存记录（cs_new 状态的记录跳过 DB 删除）。
%%% ===================================================================
-spec mdelete(atom(), [term()]) -> ok | {error, term()}.
mdelete(_Table, []) ->
	ok;
mdelete(Table, Keys) ->
	TxnKeys = [{Table, Key} || Key <- lists:usort(Keys)],
	AlterTab = [{{Table, Key}, del} || Key <- lists:usort(Keys)],
	txn(TxnKeys, fun(InAlterTab, _TxnValues) ->
		{alterTab, InAlterTab}
	end, AlterTab).

%%% ===================================================================
%%% 内部工具函数
%%% ===================================================================

isCacheTable(Table) ->
	cacheTabDef:cacheType(Table) =/= undefined.

plainDataKey(Table, Data) when is_tuple(Data) ->
	KeyPos = ets:info(Table, keypos),
	case is_integer(KeyPos) andalso tuple_size(Data) >= KeyPos of
		true -> {ok, element(KeyPos, Data)};
		false -> {error, {bad_plain_data_key, Table, Data}}
	end;
plainDataKey(Table, Data) ->
	{error, {bad_plain_data_key, Table, Data}}.

%% 将 Changes 应用到缓存数据
applyChanges(_Table, Data, Changes) when is_map(Data), is_map(Changes) ->
	maps:merge(Data, Changes);
applyChanges(_Table, Data, Changes) when is_map(Data), is_list(Changes) ->
	maps:merge(Data, maps:from_list(Changes));
applyChanges(Table, Data, Changes) when is_tuple(Data) ->
	%% record 类型：逐字段更新
	Fields = dbSchemaDef:tableFields(Table),
	ChangeMap = toMap(Changes),
	maps:fold(fun(FieldAtom, NewVal, Acc) ->
		FieldBin = atom_to_binary(FieldAtom, utf8),
		case lists:keyfind(FieldBin, 1, Fields) of
			{_, Index, _, _} -> setelement(Index, Acc, NewVal);
			false -> throw({error, {unknown_field, FieldAtom, Table}})
		end
	end, Data, ChangeMap).

toMap(M) when is_map(M) -> M;
toMap(L) when is_list(L) -> maps:from_list(L).

%%% ===================================================================
%%% 脏字段掩码工具函数
%%% DirtyFields = integer() bitmask，位 N (0‑based) 对应 tableFields 中第 N+1 字段
%%% ===================================================================

validateCacheKey(Table, Key, Data) ->
	case cacheTabDef:keyValue(Table, Data) of
		Key -> ok;
		DataKey -> throw({error, {key_mismatch, Table, Key, DataKey}})
	end.

dirtyMaskToFields(Table, Mask) when is_integer(Mask) ->
	[Field || {_Index, BitValue, Field} <- cacheTabDef:tableFields(Table), Mask band BitValue =/= 0].

diffDirtyMask(_SaveType, Table, OldData, NewData, OldMask) ->
	?CASE(is_tuple(NewData), diffRecordMask(cacheTabDef:tableFields(Table), OldData, NewData, OldMask), diffMapMask(cacheTabDef:tableFields(Table), OldData, NewData, OldMask)).

diffMapMask([], _OldMap, _NewMap, MaskAcc) -> MaskAcc;
diffMapMask([{_Index, BitValue, Field} | Fields], OldMap, NewMap, MaskAcc) ->
	case MaskAcc band BitValue =/= 0 orelse maps:get(Field, OldMap, '$missing') =:= maps:get(Field, NewMap, '$missing') of
		true -> diffMapMask(Fields, OldMap, NewMap, MaskAcc);
		false -> diffMapMask(Fields, OldMap, NewMap, MaskAcc bor BitValue)
	end.

diffRecordMask([], _OldMap, _NewMap, MaskAcc) -> MaskAcc;
diffRecordMask([{Index, BitValue, _Field} | Fields], OldRecord, NewRecord, MaskAcc) ->
	case MaskAcc band BitValue =/= 0 orelse element(Index, OldRecord) =:= element(Index, NewRecord) of
		true -> diffRecordMask(Fields, OldRecord, NewRecord, MaskAcc);
		false -> diffRecordMask(Fields, OldRecord, NewRecord, MaskAcc bor BitValue)
	end.

%%% ===================================================================
%%% hotData Keys ETS：{Key}，只表示 DB/逻辑层存在该 key；脏类型由 csDirtyTab 保存。
%%% ===================================================================

keysDelete(Table, Key) ->
	case cacheTabDef:cacheType(Table) of
		hotData ->
			ets:delete(?csKeysTab(Table), Key),
			ok;
		_ ->
			ok
	end.

getCacheTables() ->
	FilterFun = persistent_term:get('$filterFun', undefined),
	[OneTable || OneTable <- cacheTabDef:getCaches(), filterTable(FilterFun, OneTable)].

filterTable({M, F}, Table) -> M:F(Table);
filterTable(_, _Table) -> true.

initAlterState() ->
	put('$alterCnt', 0),
	put('$txnNewDirty', []).

clearAlterState() ->
	erase('$alterCnt'),
	erase('$txnNewDirty'),
	ok.

addAlterCnt() ->
	put('$alterCnt', get('$alterCnt') + 1).

clearAlterCnt() ->
	erase('$alterCnt').

addTxnNewDirty(Table, Key) ->
	case cacheTabDef:cacheType(Table) of
		undefined ->
			put('$txnNewDirty', [{{Table, Key}, plain} | get('$txnNewDirty')]);
		_ ->
			case ets:lookup(?csDirtyTab(Table), Key) of
				[{Key, DirtyState}] ->
					put('$txnNewDirty', [{{Table, Key}, {dirty, DirtyState}} | get('$txnNewDirty')]);
				[] ->
					put('$txnNewDirty', [{{Table, Key}, none} | get('$txnNewDirty')])
			end
	end.

clearTxnNewDirty() ->
	erase('$txnNewDirty').