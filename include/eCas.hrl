%%%-------------------------------------------------------------------
%%% @doc eCas 公共头文件
%%%-------------------------------------------------------------------
-ifndef(ECSSTORE_HRL).
-define(ECSSTORE_HRL, true).

%% 三目元算符
-define(CASE(Cond, Then, That), case Cond of true -> Then; _ -> That end).
-define(CASE(Expr, Expect, Then, ExprRet, That), case Expr of Expect -> Then; ExprRet -> That end).

-record(tbCache, {
	type = whole,         %% whole | hotData  whole- 全表缓存，启动时将整张表数据加载到 ETS  热数据缓存，仅缓存被访问过的数据，同时维护全量 keys ETS
	ttl = 0,              %% non_neg_integer() hotData 缓存 TTL（秒），0=永不淘汰
	saveMode = 300,       %% pos_integer() 如果需要立即存库的表 就把时间配置短一点 (单位毫秒)
	saveType = whole,     %% whole | dirty whole落盘时写入整行数据（使用 upsert） dirty 落盘时仅写入脏字段（需配合 eCas:update/3 使用）
	loadFun = undefined,  %% undefined | {M, F, A}  undefined  -  {M, F, A}  - 自定义初始化加载时对对每条数据执行的函数，调用 M:F(Data, A...) 如果是whole Data就是整条数据 否则就是KeyValue
	flushLimit = 500,     %% non_neg_integer() 每轮落盘条数上限，infinity=全量 每轮 flush 最多处理的脏 key 数，infinity 表示一次性刷完整张状态表
	isOrder = false       %% true 是否为order_set 可能有些表需要保持访问顺序，true 则使用 order_set 作为 ETS 类型，false 则使用 set
}).

%% 默认超时时间单位:Ms
-define(casTimeOut, 5000).

%%% ===================================================================
%%% 内部状态标记（存储在 Status ETS 中）
%%% ===================================================================
-define(cs_clean, clean).   %% 主缓存行：已落盘/无脏数据
-define(cs_new, new).       %% 主缓存行 / Keys ETS：新增，落盘 INSERT
-define(cs_del, del).       %% Keys ETS：待删除，落盘 DELETE
-define(cs_update, update). %% 主缓存行 / Keys ETS：已存在或待 UPDATE

%%% ===================================================================
%%% Persistent Term 键
%%% ===================================================================
-define(csDbMod, '$csDbMod').  %% 当前 DB 驱动模块 (eMysql | ePgdb)

%%% ===================================================================
%%% ETS 表名辅助宏
%%% ===================================================================
-define(DirtyEtsTag(Table), {csDirtyEts, Table}).
-define(KeysEtsTag(Table), {csKeysEts, Table}).

-define(csDirtyTab(Table), persistent_term:get(?DirtyEtsTag(Table), undefined)).  %% 脏 key 表，保存 {Key, DirtyType}，供落盘扫描
-define(csKeysTab(Table), persistent_term:get(?KeysEtsTag(Table), undefined)).  %% hotData Keys 表：{Key}，只表示 DB/逻辑层存在该 key

%%% 主缓存表统一存储格式：
%%%   {Key, Data, DirtyState, DirtyFields, AccessTime}
%%%   Key         - 主键值，作为 ETS key
%%%   Data        - 业务数据（map 或 record tuple）
%%%   DirtyState  - clean | new | update，表示当前行的持久化状态
%%%   DirtyMask   - integer() bitmask，dirty 模式下记录本行脏字段位掩码；位 N(0‑based) 对应 cacheTabDef:tableFields 中第 N+1 字段；whole 模式固定为 0
%%%   AccessTime  - 最后访问时间戳（秒）；hotData + ttl 用它做淘汰判断
-define(csDataPos, 2).
-define(csDirtyStatePos, 3).
-define(csDirtyMask, 4).
-define(csAccessTimePos, 5).

-define(cacheValue(Key, Data, DirtyState, DirtyMask, AccessTime), {Key, Data, DirtyState, DirtyMask, AccessTime}).
-define(upAccessTime(Table, Key), ets:update_element(Table, Key, {?csAccessTimePos, erlang:monotonic_time(second)})).
-define(getCacheData(Data), element(?csDataPos, Data)).
-define(getDirtyState(Data), element(?csDirtyStatePos, Data)).
-define(getDirtyMask(Data), element(?csDirtyMask, Data)).

%% 老的缓数据状态OldData , OldDirtyState, OldDirtyMask, IsUpKey 是否需要插入key 为true 说明keyEts没有数据 IsUpDirty 是否要更新dirtyEts 为true 说明dirtyets没有数据
-define(OldCacheStatus(OldData, OldDirtyState, OldDirtyMask, IsUpKey, IsUpDirty), {OldData, OldDirtyState, OldDirtyMask, IsUpKey, IsUpDirty}).

%%  回滚数据和老的缓数据状态ValueKey = {EtsTab, Key}, TabType = noneTab | etsTab | whole | hotData, OldData , OldDirtyState, OldDirtyMask, IsUpKey 是否需要插入key 为true 说明keyEts没有数据 IsUpDirty 是否要更新dirtyEts 为true 说明dirtyets没有数据 IsHasKey 是否有key 为true 说明keyEts有数据 IsHasDirty 是否有dirty为true 说明dirtyets有数据
-define(RbCacheStatus(ValueKey, TabType, OldData, OldDirtyState, OldDirtyMask, IsUpKey, IsUpDirty, IsHasKey, IsHasDirty), {ValueKey, TabType, OldData, OldDirtyState, OldDirtyMask, IsUpKey, IsUpDirty, IsHasKey, IsHasDirty}).

-define(retryItem(OpType, Key, DirtyType, DirtyMask), {OpType, Key, DirtyType, DirtyMask}).

-endif.
