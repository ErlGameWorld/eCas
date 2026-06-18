%%%-------------------------------------------------------------------
%%% @doc 此文件由 genPSchema 自动生成，请勿手动修改。
%%%-------------------------------------------------------------------
-module(cacheTabDef).

-compile([nowarn_unused_record, nowarn_unused_function]).

-export([getCaches/0, tableCache/1, tableFields/1, tablePrimaryKey/1, cacheType/1, saveType/1, keyValue/2, dirtyIndex/1]).

-record(schema, {
	repr = map,          %% record | map - Erlang 端数据表示方式
	comment = "",        %% string()|binary() - 表注释
	tbCache = undefined, %% undefined | #tbCache{}  缓存配置
	fields = []          %% [#schField{}]
}).

-record(schField, {
	name,                %% atom()     - 字段名
	dbType,              %% term()     - 数据库类型: integer | {varchar, 64} | jsonb | ...
	default = undefined, %% term()     - 默认值, undefined 表示无默认值
	opts = [],           %% [term()]   - 约束: [primary_key, not_null, unique, ...]
	codec = undefined,   %% undefined | json | term_str | term_binary | atom - 编解码策略
	erlType = "",        %% string()   - Erlang 类型声明字符串, "" 则从 dbType 推导
	comment = ""         %% string()|binary() - 注释 (同时用于代码和数据库)
}).

-record(tbCache, {
	type = whole,         %% whole | hotData  whole- 全表缓存，启动时将整张表数据加载到 ETS  热数据缓存，仅缓存被访问过的数据，同时维护全量 keys ETS
	ttl = 0,              %% non_neg_integer() hotData 缓存 TTL（秒），0=永不淘汰
	saveMode = 300,       %% pos_integer() 如果需要立即存库的表 就把时间配置短一点 (单位毫秒)
	saveType = whole,     %% whole | dirty whole落盘时写入整行数据（使用 upsert） dirty 落盘时仅写入脏字段（需配合 eCas:update/3 使用）
	loadFun = undefined,  %% undefined | {M, F, A}  undefined  -  {M, F, A}  - 自定义初始化加载时对对每条数据执行的函数，调用 M:F(Data, A...) 如果是whole Data就是整条数据 否则就是KeyValue
	flushLimit = 500,     %% non_neg_integer() 每轮落盘条数上限，infinity=全量 每轮 flush 最多处理的脏 key 数，infinity 表示一次性刷完整张状态表
	isOrder = false       %% true 是否为order_set 可能有些表需要保持访问顺序，true 则使用 order_set 作为 ETS 类型，false 则使用 set
}).

tableCache(Table) -> tableCache_(toAtom(Table)).
tableFields(Table) -> tableFields_(toAtom(Table)).
tablePrimaryKey(Table) -> tablePrimaryKey_(toAtom(Table)).
cacheType(Table) -> cacheType_(toAtom(Table)).
saveType(Table) -> saveType_(toAtom(Table)).
keyValue(Table, Data) -> keyValue_(toAtom(Table), Data).
dirtyIndex(Table) -> dirtyIndex_(toAtom(Table)).

getCaches() ->
	[
		%pg_cache_schema
		players, items, session_snapshots, sys_config, type_showcase
	].

tableCache_(players) -> #tbCache{type = whole, ttl = 0, saveMode = 300, saveType = whole, loadFun = undefined, flushLimit = 200, isOrder = false};
tableCache_(items) -> #tbCache{type = hotData, ttl = 1800, saveMode = 1, saveType = dirty, loadFun = undefined, flushLimit = 100, isOrder = false};
tableCache_(session_snapshots) -> #tbCache{type = hotData, ttl = 60, saveMode = 1, saveType = whole, loadFun = {schema_test_loader, load_session_snapshots, [postgresql]}, flushLimit = 20, isOrder = false};
tableCache_(sys_config) -> #tbCache{type = whole, ttl = 0, saveMode = 86400, saveType = whole, loadFun = undefined, flushLimit = infinity, isOrder = false};
tableCache_(type_showcase) -> #tbCache{type = whole, ttl = 0, saveMode = 15, saveType = whole, loadFun = undefined, flushLimit = 10, isOrder = false};
tableCache_(_) -> undefined.

tableFields_(players) -> [{1, 1, id}, {2, 2, account}, {3, 4, level}, {4, 8, gold}, {5, 16, profile}, {6, 32, created_at}];
tableFields_(items) -> [{1, 1, id}, {2, 2, player_id}, {3, 4, item_type}, {4, 8, count}, {5, 16, attrs}, {6, 32, updated_at}];
tableFields_(session_snapshots) -> [{2, 2, id}, {3, 4, player_id}, {4, 8, dirty_flag}, {5, 16, online}, {6, 32, payload}, {7, 64, heartbeat_at}];
tableFields_(sys_config) -> [{1, 1, key}, {2, 2, value}, {3, 4, remark}];
tableFields_(type_showcase) -> [{1, 1, id}, {2, 2, score}, {3, 4, title}, {4, 8, region}, {5, 16, status}, {6, 32, labels}, {7, 64, login_ip}, {8, 128, payload_text}, {9, 256, event_date}, {10, 512, event_time}];
tableFields_(_) -> [].

tablePrimaryKey_(players) -> [id];
tablePrimaryKey_(items) -> [id];
tablePrimaryKey_(session_snapshots) -> [id];
tablePrimaryKey_(sys_config) -> [key];
tablePrimaryKey_(type_showcase) -> [id];
tablePrimaryKey_(_) -> [].

cacheType_(players) -> whole;
cacheType_(items) -> hotData;
cacheType_(session_snapshots) -> hotData;
cacheType_(sys_config) -> whole;
cacheType_(type_showcase) -> whole;
cacheType_(_) -> undefined.

saveType_(players) -> whole;
saveType_(items) -> dirty;
saveType_(session_snapshots) -> whole;
saveType_(sys_config) -> whole;
saveType_(type_showcase) -> whole;
saveType_(_) -> undefined.

keyValue_(players, Data) -> maps:get(id, Data);
keyValue_(items, Data) -> maps:get(id, Data);
keyValue_(session_snapshots, Data) -> element(2, Data);
keyValue_(sys_config, Data) -> maps:get(key, Data);
keyValue_(type_showcase, Data) -> maps:get(id, Data);
keyValue_(_, _) -> undefined.

dirtyIndex_(players) -> 0;
dirtyIndex_(items) -> 0;
dirtyIndex_(session_snapshots) -> 4;
dirtyIndex_(sys_config) -> 0;
dirtyIndex_(type_showcase) -> 0;
dirtyIndex_(_) -> 0.

toAtom(Value) when is_atom(Value) -> Value;
toAtom(Value) when is_binary(Value) -> binary_to_atom(Value, utf8);
toAtom(Value) when is_list(Value) -> list_to_atom(Value).

