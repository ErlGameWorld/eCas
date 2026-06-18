%%%-------------------------------------------------------------------
%%% @doc 每个缓存表对应一个 gen_srv 进程。
%%%
%%% 职责：
%%%   1. 启动时创建对应的 ETS 表（主缓存表、脏 key 表、hotData Keys 表）
%%%   2. 根据 #tbCache{} 配置执行初始化加载（全量或仅加载 keys）
%%%   3. 定时将脏数据落盘到数据库
%%%
%%% 主缓存表统一存储为 {Key, Data, DirtyState, DirtyMask, AccessTime}。
%%% DirtyMask 是字段位掩码，dirty 落盘时传给 DbMod:batchUpdate/1；whole 落盘固定为 0。
%%% 脏 key 表保存 {Key, DirtyType}，DirtyType 决定本次落盘走 insert/update/delete。
%%% 现在同步调用出错了 是没有把脏状态还回去的 具体是因为不知道出错原因  如果还回去了 可能导致死循环 所以现在的策略是 只要出错了 只是打个日志
%%%-------------------------------------------------------------------
-module(csTabSrv).

-behaviour(gen_srv).

-include_lib("stdlib/include/ms_transform.hrl").
-include("eCas.hrl").

%% 批量保存的数量
-define(SaveBatch, 128).

%% API
-export([start_link/1, start_link/2, flush/2, save/3, reload/1, reload/2, stats/1]).

%% gen_srv callbacks
-export([init/1, handleCall/3, handleCast/2, handleInfo/2, handleAfter/2, terminate/2, code_change/3]).

-record(state, {
	table :: atom(),                            %% 表名
	dbMod :: atom(),                            %% eMysql | ePgdb
	config :: #tbCache{},
	saveTimerRef :: reference() | undefined,
	ttlTimerRef :: reference() | undefined
}).

%%% ===================================================================
%%% API
%%% ===================================================================

start_link(Table) ->
	start_link(Table, undefined).

start_link(Table, StartInfo) ->
	gen_srv:start_link({local, Table}, ?MODULE, [Table, StartInfo], []).

%% @doc 立即触发一次异步落盘
flush(Table, true) ->
	gen_srv:call(Table, eFlush, 10000);
flush(Table, {true, TimeOut}) ->
	gen_srv:call(Table, eFlush, TimeOut);
flush(Table, _IsSync) ->
	gen_srv:cast(Table, eFlush).

%% @doc 立即触发一次key落盘
save(Table, Key, true) ->
	gen_srv:call(Table, {eSave, Key}, 10000);
save(Table, Key, {true, TimeOut}) ->
	gen_srv:call(Table, {eSave, Key}, TimeOut);
save(Table, Key, _IsSync) ->
	gen_srv:cast(Table, {eSave, Key}).

%% @doc 全表重新加载（先落盘再清空再从 DB 加载）
reload(Table) ->
	gen_srv:call(Table, eReload, infinity).

%% @doc 重新加载单条记录（从 DB 拉取最新数据，清除脏状态）
reload(Table, Key) ->
	gen_srv:call(Table, {eReload, Key}, 30000).

%% @doc 获取表运行时统计信息
stats(Table) ->
	gen_srv:call(Table, eStats, 5000).

%%% ===================================================================
%%% gen_srv callbacks
%%% ===================================================================

init([Table, StartInfo]) ->
	process_flag(trap_exit, true),
	Config = cacheTabDef:tableCache(Table),
	DbMod = persistent_term:get(?csDbMod),
	createTabEts(Table, Config),
	SaveTimerRef = maybeSaveTimer(Config),
	TtlTimerRef = maybeTtlTimer(Config),
	clearSaveErrors(),
	State = #state{table = Table, dbMod = DbMod, config = Config, saveTimerRef = SaveTimerRef, ttlTimerRef = TtlTimerRef},
	{ok, State, {doAfter, StartInfo}}.

handleAfter({RetPid, RetRef}, #state{table = Table, dbMod = DbMod, config = Config} = State) ->
	Result = loadInitData(Table, DbMod, Config),
	RetPid ! {eLoadOver, RetRef, self(), Table, Result},
	case Result of
		ok -> {noreply, State};
		{error, Reason} -> {stop, {init_load_failed, Reason}, State}
	end;
handleAfter(_StartInfo, #state{table = Table, dbMod = DbMod, config = Config} = State) ->
	case loadInitData(Table, DbMod, Config) of
		ok -> {noreply, State};
		{error, Reason} -> {stop, {init_load_failed, Reason}, State}
	end.

handleCall(eFlush, #state{table = Table, dbMod = DbMod, config = Config} = State, _From) ->
	{reply, flushDirtyData(Table, DbMod, Config), State};
handleCall({eSave, Key}, #state{table = Table, dbMod = DbMod, config = Config} = State, _From) ->
	{reply, saveOneKey(Table, Key, DbMod, Config), State};
handleCall(eReload, #state{table = Table, dbMod = DbMod, config = Config} = State, _From) ->
	Result = reloadTable(Table, DbMod, Config),
	{reply, Result, State};
handleCall({eReload, Key}, #state{table = Table, dbMod = DbMod, config = Config} = State, _From) ->
	LockKey = {Table, Key},
	Result = try
				 true = eGLock:tryLock(LockKey),
				 reloadKey(Table, Key, DbMod, Config)
			 catch
				 C:R:S ->
					 error_logger:error_msg("[csTabSrv] op=reload_key_lock table=~p key=~p reason=~0p~n", [Table, Key, {C, R, S}]),
					 {error, {LockKey, {C, R, S}}}
			 after
				 eGLock:releaseLock(LockKey)
			 end,
	{reply, Result, State};
handleCall(eStats, #state{table = Table, dbMod = DbMod, config = Config} = State, _From) ->
	{reply, collectStats(Table, DbMod, Config), State};
handleCall(_Request, State, _From) ->
	{reply, ok, State}.

handleCast(eFlush, #state{table = Table, dbMod = DbMod, config = Config} = State) ->
	flushDirtyData(Table, DbMod, Config),
	{noreply, State};
handleCast({eSave, Key}, #state{table = Table, dbMod = DbMod, config = Config} = State) ->
	saveOneKey(Table, Key, DbMod, Config),
	{noreply, State};
handleCast(_Msg, State) ->
	{noreply, State}.

handleInfo({timeout, SaveTimerRef, eSaveTimer}, #state{table = Table, dbMod = DbMod, config = Config, saveTimerRef = SaveTimerRef} = State) ->
	flushDirtyData(Table, DbMod, Config),
	NewRef = maybeSaveTimer(Config),
	{noreply, State#state{saveTimerRef = NewRef}};

handleInfo({timeout, TtlTimerRef, eTtlTimer}, #state{table = Table, config = Config, ttlTimerRef = TtlTimerRef} = State) ->
	NowSec = erlang:monotonic_time(second),
	evictExpired(Table, NowSec, Config),
	NewRef = maybeTtlTimer(Config),
	{noreply, State#state{ttlTimerRef = NewRef}};

handleInfo(_Info, State) ->
	{noreply, State}.

terminate(_Reason, #state{table = Table, dbMod = DbMod, config = Config}) ->
	%% 进程退出时尽量刷完所有脏数据，最多重试 3 次，每次失败后 saveErrors 会回退到 StatusEts 供下一轮扫描。
	LConfig = Config#tbCache{flushLimit = infinity},
	maybe
		{error, _} ?= flushDirtyData(Table, DbMod, LConfig),
		{error, _} ?= flushDirtyData(Table, DbMod, LConfig),
		{error, Reason} ?= flushDirtyData(Table, DbMod, LConfig),
		error_logger:error_msg("[csTabSrv] op=terminate_flush_failed table=~p reason=~0p~n", [Table, Reason])
	end,
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%% ===================================================================
%%% ETS 初始化
%%% ===================================================================
createTabEts(Table, #tbCache{type = Type, isOrder = IsOrder}) ->
	case IsOrder of
		true ->
			%% 主缓存表：统一存储为 {Key, Data, DirtyState, DirtyMask, AccessTime}
			%% keypos=1 指向 Key，后 4 个槽位是缓存层内部元数据。
			ets:new(Table, [named_table, ?CASE(Type == whole, ordered_set, set), public, {read_concurrency, true}, {write_concurrency, true}]),
			%% 脏表：待落盘 key，格式 {Key, DirtyType}；Keys 表为 {Key}
			persistent_term:put(?DirtyEtsTag(Table), ets:new(undefined, [set, public, {write_concurrency, true}])),
			%% hotData 类型需要 Keys 表
			Type == hotData andalso persistent_term:put(?KeysEtsTag(Table), ets:new(undefined, [ordered_set, public, {write_concurrency, true}])),
			ok;
		_ ->
			%% 主缓存表：统一存储为 {Key, Data, DirtyState, DirtyMask, AccessTime}
			%% keypos=1 指向 Key，后 4 个槽位是缓存层内部元数据。
			ets:new(Table, [named_table, set, public, {read_concurrency, true}, {write_concurrency, true}]),
			%% 脏表：待落盘 key，格式 {Key, DirtyType}；Keys 表为 {Key}
			persistent_term:put(?DirtyEtsTag(Table), ets:new(undefined, [set, public, {write_concurrency, true}])),
			%% hotData 类型需要 Keys 表
			Type == hotData andalso persistent_term:put(?KeysEtsTag(Table), ets:new(undefined, [set, public, {write_concurrency, true}])),
			ok
	end.

%%% ===================================================================
%%% 初始化数据加载
%%% ===================================================================
loadInitData(Table, DbMod, #tbCache{type = Type, loadFun = LoadFun}) ->
	case Type of
		whole ->    %% 全表加载到主缓存 ETS
			doLoadWholeData(Table, DbMod, LoadFun);
		hotData ->  %% 仅加载所有 keys 到 Keys ETS  注意 对于Keys ETS 的key的操作 需要在锁 {Table, Key}里面操作 这个table 是表名
			doLoadAllKeys(Table, DbMod, LoadFun)
	end.

doLoadWholeData(Table, DbMod, LoadFun) ->
	Fun = fun(Data) ->
		KeyValue = cacheTabDef:keyValue(Table, Data),
		LockKey = {Table, KeyValue},
		try
			true = eGLock:tryLock(LockKey),
			ets:insert(Table, ?cacheValue(KeyValue, Data, ?cs_clean, 0, erlang:monotonic_time(second))),
			runLoadFun(Table, Data, LoadFun)
		catch C:R:S ->
			error_logger:error_msg("[csTabSrv] op=load_whole_row table=~p key=~p reason=~0p~n", [Table, KeyValue, {C, R, S}]),
			{error, {LockKey, {C, R, S}}}
		after
			eGLock:releaseLock(LockKey)
		end
		  end,
	try DbMod:foreachRows(Table, [], 500, [], Fun) of
		ok ->
			ok;
		{error, Err} ->
			error_logger:error_msg("[csTabSrv] op=load_whole_table table=~p reason=~0p~n", [Table, Err]),
			{error, Err}
	catch C:R:S ->
		error_logger:error_msg("[csTabSrv] op=load_whole_table table=~p reason=~0p~n", [Table, {C, R, S}]),
		{error, {C, R, S}}
	end.

%% hotData Keys ETS：{Key}，需在锁 {Table, Key} 内操作
doLoadAllKeys(Table, DbMod, LoadFun) ->
	[PKeyField] = PKeyFields = cacheTabDef:tablePrimaryKey(Table),
	Fun = fun(KeyValueMap) ->
		KeyValue = maps:get(PKeyField, KeyValueMap),
		LockKey = {Table, KeyValue},
		try
			true = eGLock:tryLock(LockKey),
			ets:insert(?csKeysTab(Table), {KeyValue}),
			runLoadFun(Table, KeyValue, LoadFun)
		catch C:R:S ->
			error_logger:error_msg("[csTabSrv] op=load_hot_key table=~p key=~p reason=~0p~n", [Table, KeyValue, {C, R, S}]),
			{error, {LockKey, {C, R, S}}}
		after
			eGLock:releaseLock(LockKey)
		end
		  end,
	Opts = [{fields, PKeyFields}],
	try DbMod:foreachRows(Table, [], 500, Opts, Fun) of
		ok ->
			ok;
		{error, Err} ->
			error_logger:error_msg("[csTabSrv] op=load_hot_keys table=~p reason=~0p~n", [Table, Err]),
			{error, Err}
	catch C:R:S ->
		error_logger:error_msg("[csTabSrv] op=load_hot_keys table=~p reason=~0p~n", [Table, {C, R, S}]),
		{error, {C, R, S}}
	end.

runLoadFun(Table, Data, LoadFun) ->
	case LoadFun of
		{M, F, A} ->
			try apply(M, F, [Data | A])
			catch C:R:S ->
				error_logger:error_msg("[csTabSrv] op=load_callback table=~p data=~0p callback=~p reason=~0p~n", [Table, Data, {M, F, A}, {C, R, S}])
			end;
		_ ->
			ignore
	end.

%%% ===================================================================
%%% 脏数据落盘
%%% ===================================================================
-spec flushDirtyData(atom(), atom(), #tbCache{}) -> false | flushLimit | {error, term()}.
flushDirtyData(Table, DbMod, #tbCache{flushLimit = FlushLimit, saveType = SaveType}) ->
	StatusEts = ?csDirtyTab(Table),
	KeysEts = ?csKeysTab(Table),
	ets:info(StatusEts, size) > 0 andalso
		begin
			ets:safe_fixtable(StatusEts, true),
			try
				case ets:match_object(StatusEts, '_', ?SaveBatch) of
					'$end_of_table' ->
						false;
					{KeyList, NextKey} ->
						[PkField] = cacheTabDef:tablePrimaryKey(Table),
						{Ret, SaveCnt} = doSaveData(SaveType, KeyList, Table, DbMod, StatusEts, KeysEts, PkField, FlushLimit, false, 0),
						continueNext(SaveType, NextKey, Table, DbMod, StatusEts, KeysEts, PkField, FlushLimit, Ret, SaveCnt)
				end
			after
				ets:safe_fixtable(StatusEts, false)
			end
		end.

continueNext(SaveType, NextKey, Table, DbMod, StatusEts, KeysEts, PkField, FlushLimit, Ret, SaveCnt) ->
	case SaveCnt < FlushLimit andalso ets:match_object(NextKey) of
		'$end_of_table' ->
			Ret;
		{KeyList, NewNextKey} ->
			{NRet, NSaveCnt} = doSaveData(SaveType, KeyList, Table, DbMod, StatusEts, KeysEts, PkField, FlushLimit, Ret, SaveCnt),
			continueNext(SaveType, NewNextKey, Table, DbMod, StatusEts, KeysEts, PkField, FlushLimit, NRet, NSaveCnt);
		_ ->
			?CASE(Ret == false, flushLimit, Ret)
	end.

doSaveData(whole, DirtyKeys, Table, DbMod, StatusEts, _KeysEts, PkField, _FlushLimit, Ret, SaveCnt) ->
	clearSaveErrors(),
	{DataList, DelKeys, InsertRetryItems, DelRetryItems, FailCnt} = collWholeFlushItems(DirtyKeys, Table, StatusEts, [], [], [], [], 0),
	
	doDbBatch(Table, DelRetryItems, DbMod, batchDelByKey, [Table, PkField, DelKeys]),
	doDbBatch(Table, InsertRetryItems, DbMod, batchInsert, [DataList, true]),
	
	SaveErrors = clearSaveErrors(),
	SaveErrors /= [] andalso restoreSaveErrors(Table, StatusEts, SaveErrors),
	NSaveCnt = SaveCnt + length(DirtyKeys) - FailCnt,
	{mergeSaveRet(Ret, SaveErrors), NSaveCnt};
doSaveData(_SaveType, DirtyKeys, Table, DbMod, StatusEts, KeysEts, PkField, _FlushLimit, Ret, SaveCnt) ->
	clearSaveErrors(),
	{Inserts, Updates, DelKeys, InsRetryItems, UpdRetryItems, DelRetryItems, FailCnt} = collDirtyFlushItems(DirtyKeys, Table, PkField, StatusEts, KeysEts, [], [], [], [], [], [], 0),
	
	doDbBatch(Table, InsRetryItems, DbMod, batchInsert, [Inserts, true]),
	doDbBatch(Table, DelRetryItems, DbMod, batchDelByKey, [Table, PkField, DelKeys]),
	doDbBatch(Table, UpdRetryItems, DbMod, batchUpdate, [Updates]),
	
	SaveErrors = clearSaveErrors(),
	SaveErrors /= [] andalso restoreSaveErrors(Table, StatusEts, SaveErrors),
	NSaveCnt = SaveCnt + length(DirtyKeys) - FailCnt,
	{mergeSaveRet(Ret, SaveErrors), NSaveCnt}.

collWholeFlushItems([], _Table, _StatusEts, DataAcc, DelAcc, InsRetryAcc, DelRetryAcc, FailCnt) ->
	{DataAcc, DelAcc, InsRetryAcc, DelRetryAcc, FailCnt};
collWholeFlushItems([{OneKey, DirtyType} | DirtyKeys], Table, StatusEts, DataAcc, DelAcc, InsRetryAcc, DelRetryAcc, FailCnt) ->
	case lockWholeFlushItem(OneKey, DirtyType, Table, StatusEts) of
		{delete, RetryItem} ->
			collWholeFlushItems(DirtyKeys, Table, StatusEts, DataAcc, [OneKey | DelAcc], InsRetryAcc, [RetryItem | DelRetryAcc], FailCnt);
		{ok, Data, RetryItem} ->
			collWholeFlushItems(DirtyKeys, Table, StatusEts, [Data | DataAcc], DelAcc, [RetryItem | InsRetryAcc], DelRetryAcc, FailCnt);
		{error, deal_error} ->
			collWholeFlushItems(DirtyKeys, Table, StatusEts, DataAcc, DelAcc, InsRetryAcc, DelRetryAcc, FailCnt + 1)
	end.

lockWholeFlushItem(OneKey, DirtyType, Table, StatusEts) ->
	LockKey = {Table, OneKey},
	try
		true = eGLock:tryLock(LockKey),
		ets:delete(StatusEts, OneKey),
		case ets:lookup(Table, OneKey) of
			[?cacheValue(_Key, Data, _DirtyState, DirtyMask, _AccessTime)] ->
				%% flush 落盘期间把 AccessTime 略往后推，避免 TTL 扫描误淘汰正在落盘的 clean 行
				ets:update_element(Table, OneKey, [{?csDirtyStatePos, ?cs_clean}, {?csAccessTimePos, erlang:monotonic_time(second) + 3}]),
				{ok, Data, ?retryItem(upsert, OneKey, DirtyType, DirtyMask)};
			_ ->
				{delete, ?retryItem(delete, OneKey, DirtyType, 0)}
		end
	catch C:R:S ->
		error_logger:error_msg("[csTabSrv] op=flush_whole_lock table=~p key=~p reason=~0p~n", [Table, OneKey, {C, R, S}]),
		{error, deal_error}
	after
		eGLock:releaseLock(LockKey)
	end.

collDirtyFlushItems([], _Table, _PkField, _StatusEts, _KeysEts, InsAcc, UpdAcc, DelAcc, InsRetryAcc, UpRetryAcc, DelRetryAcc, FailCnt) ->
	{InsAcc, UpdAcc, DelAcc, InsRetryAcc, UpRetryAcc, DelRetryAcc, FailCnt};
collDirtyFlushItems([{OneKey, DirtyType} | DirtyKeys], Table, PkField, StatusEts, KeysEts, InsAcc, UpdAcc, DelAcc, InsRetryAcc, UpRetryAcc, DelRetryAcc, FailCnt) ->
	case lockDirtyFlushItem(OneKey, DirtyType, Table, PkField, StatusEts, KeysEts) of
		{insert, Data, RetryItem} ->
			collDirtyFlushItems(DirtyKeys, Table, PkField, StatusEts, KeysEts, [Data | InsAcc], UpdAcc, DelAcc, [RetryItem | InsRetryAcc], UpRetryAcc, DelRetryAcc, FailCnt);
		{update, UpDataInfo, RetryItem} ->
			collDirtyFlushItems(DirtyKeys, Table, PkField, StatusEts, KeysEts, InsAcc, [UpDataInfo | UpdAcc], DelAcc, InsRetryAcc, [RetryItem | UpRetryAcc], DelRetryAcc, FailCnt);
		{delete, RetryItem} ->
			collDirtyFlushItems(DirtyKeys, Table, PkField, StatusEts, KeysEts, InsAcc, UpdAcc, [OneKey | DelAcc], InsRetryAcc, UpRetryAcc, [RetryItem | DelRetryAcc], FailCnt);
		skipped ->
			collDirtyFlushItems(DirtyKeys, Table, PkField, StatusEts, KeysEts, InsAcc, UpdAcc, DelAcc, InsRetryAcc, UpRetryAcc, DelRetryAcc, FailCnt + 1);
		Error ->
			error_logger:error_msg("[csTabSrv] op=flockDirtyFlushItem table=~p key=~p lock_key=~p reason=~0p~n", [Table, OneKey, Error]),
			collDirtyFlushItems(DirtyKeys, Table, PkField, StatusEts, KeysEts, InsAcc, UpdAcc, DelAcc, InsRetryAcc, UpRetryAcc, DelRetryAcc, FailCnt + 1)
	end.

lockDirtyFlushItem(OneKey, DirtyType, Table, PkField, StatusEts, _KeysEts) ->
	LockKey = {Table, OneKey},
	try
		true = eGLock:tryLock(LockKey),
		ets:delete(StatusEts, OneKey),
		case ets:lookup(Table, OneKey) of
			[] ->
				case DirtyType of
					?cs_del ->
						{delete, ?retryItem(delete, OneKey, DirtyType, 0)};
					?cs_new ->
						%% 新增但主缓存已不存在，说明最终没有需要落库的行。
						skipped;
					?cs_update ->
						skipped;
					?cs_clean ->
						skipped
				end;
			[?cacheValue(_Key, Data, _DirtyState, DirtyMask, _AccessTime)] ->
				%% flush 落盘期间把 AccessTime 略往后推，避免 TTL 扫描误淘汰正在落盘的 clean 行
				ets:update_element(Table, OneKey, [{?csDirtyStatePos, ?cs_clean}, {?csAccessTimePos, erlang:monotonic_time(second) + 3}]),
				case DirtyType of
					?cs_update ->
						{update, {Data, DirtyMask, [{PkField, OneKey}]}, ?retryItem(update, OneKey, DirtyType, DirtyMask)};
					?cs_new ->
						{insert, Data, ?retryItem(insert, OneKey, DirtyType, DirtyMask)};
					?cs_del ->
						%% 删除后又写回了缓存，最终事实是行存在，用 upsert 保底。 正确性的情况下不会来这个分支
						{insert, Data, ?retryItem(insert, OneKey, DirtyType, DirtyMask)};
					?cs_clean ->
						%% 正确性的情况下不会来这个分支
						{insert, Data, ?retryItem(insert, OneKey, DirtyType, DirtyMask)}
				end
		end
	catch
		C:R:S ->
			{error, {C, R, S}}
	after
		eGLock:releaseLock(LockKey)
	end.

%%% ===================================================================
%%% 重新加载
%%% ===================================================================
saveOneKey(Table, Key, DbMod, #tbCache{flushLimit = FlushLimit, saveType = SaveType}) ->
	%% 注：FlushLimit 是单轮 flush 最多处理的脏 key 数，用于"分页落盘"避免单次事务过大。
	%% 本函数只对单个 Key 落盘，永远只处理 1 条，所以 FlushLimit 在 doSaveData 内部被忽略（见 _FlushLimit）。
	%% 保留参数是为了让 doSaveData/10 的签名统一，单 key 路径与批量路径走相同的批处理框架。
	StatusEts = ?csDirtyTab(Table),
	KeysEts = ?csKeysTab(Table),
	case ets:lookup(StatusEts, Key) of
		[] ->
			{error, not_change};
		KeyList ->
			[PkField] = cacheTabDef:tablePrimaryKey(Table),
			case doSaveData(SaveType, KeyList, Table, DbMod, StatusEts, KeysEts, PkField, FlushLimit, false, 0) of
				{{error, _} = Error, _SaveCnt} -> Error;
				_ -> {ok, KeyList}
			end
	end.

reloadTable(Table, DbMod, Config) ->
	case flushDirtyData(Table, DbMod, Config#tbCache{flushLimit = infinity}) of
		false ->
			ets:delete_all_objects(Table),
			ets:delete_all_objects(?csDirtyTab(Table)),
			Config#tbCache.type == hotData andalso ets:delete_all_objects(?csKeysTab(Table)),
			loadInitData(Table, DbMod, Config);
		Other ->
			{error, {flush_before_reload_failed, Other}}
	end.

reloadKey(Table, Key, DbMod, Config) ->
	case ets:lookup(?csDirtyTab(Table), Key) of
		[] ->
			doReloadKey(Table, Key, DbMod, Config);
		[_Dirty] ->
			{error, dirty_conflict}
	end.

doReloadKey(Table, Key, DbMod, Config) ->
	[PkField] = cacheTabDef:tablePrimaryKey(Table),
	try DbMod:get(Table, [{PkField, Key}]) of
		{ok, [Row | _]} ->
			ets:insert(Table, ?cacheValue(Key, Row, ?cs_clean, 0, erlang:monotonic_time(second))),
			ets:delete(?csDirtyTab(Table), Key),
			Config#tbCache.type == hotData andalso ets:insert(?csKeysTab(Table), {Key}),
			Row;
		{ok, []} ->
			ets:delete(Table, Key),
			ets:delete(?csDirtyTab(Table), Key),
			Config#tbCache.type == hotData andalso ets:delete(?csKeysTab(Table), Key),
			undefined;
		{error, Reason} ->
			error_logger:error_msg("[csTabSrv] op=reload_key_db table=~p key=~p reason=~0p~n", [Table, Key, Reason]),
			{error, Reason}
	catch C:R:S ->
		error_logger:error_msg("[csTabSrv] op=reload_key_db_exception table=~p key=~p reason=~0p~n", [Table, Key, {C, R, S}]),
		{error, {C, R, S}}
	end.

%%% ===================================================================
%%% 运行时统计
%%% ===================================================================

collectStats(Table, DbMod, Config) ->
	DirtyTab = ?csDirtyTab(Table),
	KeysTab = ?csKeysTab(Table),
	
	CacheSize = ets:info(Table, size),
	DirtyCount = ets:info(DirtyTab, size),
	KeysCount = ?CASE(KeysTab, undefined, 0, _, ets:info(KeysTab, size)),
	
	{NewCnt, UpCnt, DelCnt} = collDirtyCnt(DirtyTab),
	
	CacheMem = ets:info(Table, memory),
	DirtyMem = ets:info(DirtyTab, memory),
	KeysMem = ?CASE(KeysTab, undefined, 0, _, ets:info(KeysTab, memory)),
	TotalMem = CacheMem + DirtyMem + KeysMem,
	
	LoadFun = Config#tbCache.loadFun,
	Schema = DbMod:schema(Table),
	
	#{
		%% --- 基础标识 ---
		table => Table,
		
		%% --- 行数 ---
		cacheSize => CacheSize,
		dirtyCnt => DirtyCount,
		keysCnt => KeysCount,
		newCnt => NewCnt,
		updateCnt => UpCnt,
		delCnt => DelCnt,
		
		cacheMem => CacheMem,
		dirtyMem => DirtyMem,
		keysMem => KeysMem,
		totalMem => TotalMem,
		
		%% --- 缓存配置 ---
		cacheType => Config#tbCache.type,
		saveMode => Config#tbCache.saveMode,
		saveType => Config#tbCache.saveType,
		ttl => Config#tbCache.ttl,
		flushLimit => Config#tbCache.flushLimit,
		isOrder => Config#tbCache.isOrder,
		loadFun => LoadFun,
		
		%% 表的格式
		schema => Schema,
		%% --- 抽样数据，便于调试 ---
		sampleKey => sampleKey(Table),
		sampleValue => sampleValue(Table)
	}.

%%% ===================================================================
%%% TTL 淘汰（仅 hotData + ttl > 0 生效）
%%% ===================================================================
evictExpired(Table, NowSec, #tbCache{ttl = TTL, type = Type}) ->
	%% TTL 定时器已经带随机抖动，这里只校验距离上次扫描至少过了一个 TTL。
	case TTL > 0 andalso Type /= whole of
		true ->
			ExpiredTime = NowSec - TTL,
			Ms = ets:fun2ms(fun(?cacheValue(Key, _Data, DirtyState, _DirtyMask, AccessTime)) when AccessTime < ExpiredTime andalso DirtyState == ?cs_clean -> Key end),
			case ets:select(Table, Ms, 128) of
				'$end_of_table' ->
					ok;
				{ExpiredKeys, NextKey} ->
					clearCache(Table, ExpiredKeys, ExpiredTime),
					selectNext(Table, NextKey, ExpiredTime)
			end;
		_ ->
			ignore
	end.

selectNext(Table, NextKey, ExpiredTime) ->
	case ets:select(NextKey) of
		'$end_of_table' ->
			ok;
		{ExpiredKeys, NewNextKey} ->
			clearCache(Table, ExpiredKeys, ExpiredTime),
			selectNext(Table, NewNextKey, ExpiredTime)
	end.

clearCache(Table, ExpiredKeys, ExpiredTime) ->
	[
		begin
			LockKey = {Table, OneKey},
			try
				true = eGLock:tryLock(LockKey),
				case ets:lookup(Table, OneKey) of
					[?cacheValue(_Key, _Data, DirtyState, _DirtyMask, AccessTime)] when AccessTime < ExpiredTime andalso DirtyState == ?cs_clean ->
						ets:delete(Table, OneKey);
					_ ->
						ignore
				end
			catch C:R:S ->
				error_logger:error_msg("[csTabSrv] op=ttl_evict table=~p key=~p reason=~0p~n", [Table, OneKey, {C, R, S}]),
				ok
			after
				eGLock:releaseLock(LockKey)
			end
		end || OneKey <- ExpiredKeys
	],
	ok.

%%% ===================================================================
%%% 落盘失败补偿
%%% ===================================================================
doDbBatch(Table, RetryItems, DdMod, DbFun, DdArgs) ->
	RetryItems /= [] andalso try apply(DdMod, DbFun, DdArgs) of
								 ok ->
									 ok;
								 {ok, _Cnt} ->
									 ok;
								 {error, Reason} ->
									 recordSaveError(Table, DbFun, RetryItems, Reason);
								 Other ->
									 recordSaveError(Table, DbFun, RetryItems, {unexpected_return, Other})
							 catch C:R:S ->
		recordSaveError(Table, DbFun, RetryItems, {C, R, S})
							 end.

recordSaveError(Table, Op, RetryItems, Reason) ->
	addSaveError(RetryItems),
	error_logger:error_msg("[csTabSrv] op=~p table=~p items=~0p reason=~0p~n", [Op, Table, RetryItems, Reason]),
	ok.

restoreSaveErrors(Table, StatusEts, SaveErrors) ->
	[restoreRetryItem(Table, StatusEts, RetryItem) || BatchSaveError <- SaveErrors, RetryItem <- BatchSaveError],
	ok.

restoreRetryItem(Table, StatusEts, ?retryItem(OpType, Key, DirtyType, DirtyMask)) ->
	LockKey = {Table, Key},
	try
		true = eGLock:tryLock(LockKey),
		mergeRetryItem(Table, StatusEts, OpType, Key, DirtyType, DirtyMask)
	catch C:R:S ->
		error_logger:error_msg("[csTabSrv] op=restore_save_error table=~p key=~p reason=~0p~n", [Table, Key, {C, R, S}]),
		ok
	after
		eGLock:releaseLock(LockKey)
	end.

mergeRetryItem(Table, StatusEts, Op, Key, DirtyType, DirtyMask) ->
	RetryDirtyType = retryDirtyType(Op, DirtyType),
	case ets:lookup(Table, Key) of
		[?cacheValue(_Key, _Data, CurrentDirtyState, CurrentDirtyMask, _AccessTime)] ->
			NewDirtyType = mergeDirtyType(CurrentDirtyState, RetryDirtyType),
			NewDirtyMask = CurrentDirtyMask bor DirtyMask,
			ets:insert(StatusEts, {Key, NewDirtyType}),
			ets:update_element(Table, Key, [{?csDirtyStatePos, NewDirtyType}, {?csDirtyMask, NewDirtyMask}]);
		[] ->
			restoreMissingRetry(Table, StatusEts, Key, Op, RetryDirtyType)
	end.

retryDirtyType(delete, _DirtyType) ->
	?cs_del;
retryDirtyType(_Op, ?cs_clean) ->
	?cs_update;
retryDirtyType(_Op, DirtyType) ->
	DirtyType.

restoreMissingRetry(Table, StatusEts, Key, delete, RetryDirtyType) ->
	KeysTab = ?csKeysTab(Table),
	case KeysTab =/= undefined andalso ets:member(KeysTab, Key) of
		true ->
			%% Keys ETS 中仍有该 key，说明行在 DB 中实际存在（主缓存仅被 TTL 淘汰）。
			%% delete 失败不能将状态回退为 del，否则下次 flush 会误删 DB 有效行。
			ok;
		false when RetryDirtyType =:= ?cs_del ->
			ets:insert(StatusEts, {Key, RetryDirtyType});
		false ->
			ok
	end;
restoreMissingRetry(_Table, StatusEts, Key, _Op, _RetryDirtyType) ->
	%% 当前事实已经没有缓存行，insert/update 失败不应复活旧数据；
	%% 如果期间发生了 delete，dirty ETS 中会已有 del 状态。
	case ets:lookup(StatusEts, Key) of
		[] -> ok;
		_ -> ok
	end.

mergeDirtyType(?cs_new, _) -> ?cs_new;
mergeDirtyType(_, ?cs_new) -> ?cs_new;
mergeDirtyType(_, _) -> ?cs_update.

mergeSaveRet(Ret, SaveErrors) ->
	?CASE(SaveErrors == [], Ret, {error, SaveErrors}).

%% 调度定时器
maybeSaveTimer(#tbCache{saveMode = IntervalSec}) ->
	IntervalSec > 0 andalso erlang:start_timer(IntervalSec, self(), eSaveTimer).

maybeTtlTimer(#tbCache{type = Type, ttl = TTL}) ->
	case Type == hotData andalso TTL > 0 of
		true ->
			erlang:start_timer((TTL + rand:uniform(TTL)) * 1000, self(), eTtlTimer);
		_ ->
			undefined
	end.

%% 存库失败临时保存的状态回退数据，进程内存储，格式 [{OpType, Key, DirtyType, DirtyMask}]
addSaveError(ErrorData) ->
	put(saveError, [ErrorData | get(saveError)]).


clearSaveErrors() ->
	put(saveError, []).

%%% 统计 Dirty ETS 中 new / update / del 各有多少条
collDirtyCnt(DirtyTab) ->
	ets:foldl(fun({_K, DirtyType}, {NewCnt, UpCnt, DelCnt}) ->
		case DirtyType of
			?cs_new -> {NewCnt + 1, UpCnt, DelCnt};
			?cs_update -> {NewCnt, UpCnt + 1, DelCnt};
			?cs_del -> {NewCnt, UpCnt, DelCnt + 1};
			_ -> {NewCnt, UpCnt, DelCnt}
		end end, {0, 0, 0}, DirtyTab).

%%% 抽样第一条 cache row 的 key（用于调试）
sampleKey(Table) ->
	case ets:first(Table) of
		'$end_of_table' -> undefined;
		'$empty_table' -> undefined;
		K -> K
	end.

%%% 抽样第一条 cache row 的 data（不复制 tuple，避免大 record 撑爆 stats 输出）
sampleValue(Table) ->
	case ets:first(Table) of
		'$end_of_table' -> undefined;
		'$empty_table' -> undefined;
		K ->
			case ets:lookup(Table, K) of
				[] -> undefined;
				[Row] -> element(?csDataPos, Row)
			end
	end.