%%%-------------------------------------------------------------------
%%% @doc 此文件由 genPSchema 自动生成，请勿手动修改。
%%%-------------------------------------------------------------------
-module(dbSchemaDef).

-compile([nowarn_unused_record, nowarn_unused_function]).

-export([getTables/0, tableFields/1, tableInsert/1, tableReplace/1, onReplace/1, tableSchema/1, tablePrimaryKey/1, fieldSchema/2, fieldCodec/2, fieldDefault/2]).

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
	loadFun = undefined,  %% undefined | {M, F, A}  undefined  - 使用通用加载逻辑（全量扫描 DB） {M, F, A}  - 自定义初始化加载函数，调用 M:F(Table, A...) 如果是whole Data就是整条数据 否则就是KeyValue
	flushLimit = 500,     %% non_neg_integer() 每轮落盘条数上限，infinity=全量 每轮 flush 最多处理的脏 key 数，infinity 表示一次性刷完整张状态表
	isOrder = false       %% true 是否为order_set 可能有些表需要保持访问顺序，true 则使用 order_set 作为 ETS 类型，false 则使用 set
}).

tableFields(Table) -> tableFields_(toAtom(Table)).
tableInsert(Table) -> tableInsert_(toAtom(Table)).
tableReplace(Table) -> tableReplace_(toAtom(Table)).
onReplace(Table) -> onReplace_(toAtom(Table)).
tableSchema(Table) -> tableSchema_(toAtom(Table)).
tablePrimaryKey(Table) -> tablePrimaryKey_(toAtom(Table)).
fieldSchema(Table, Field) -> fieldSchema_(toAtom(Table), toAtom(Field)).

getTables() ->
	[
		%pg_cache_schema
		players, items, session_snapshots, sys_config, type_showcase
	].

tableFields_(players) -> [{<<"id">>, 1, undefined, id}, {<<"account">>, 2, undefined, account}, {<<"level">>, 3, undefined, level}, {<<"gold">>, 4, undefined, gold}, {<<"profile">>, 5, json, profile}, {<<"created_at">>, 6, undefined, created_at}];
tableFields_(items) -> [{<<"id">>, 1, undefined, id}, {<<"player_id">>, 2, undefined, player_id}, {<<"item_type">>, 3, atom, item_type}, {<<"count">>, 4, undefined, count}, {<<"attrs">>, 5, json, attrs}, {<<"updated_at">>, 6, undefined, updated_at}];
tableFields_(session_snapshots) -> [{<<"id">>, 2, undefined, id}, {<<"player_id">>, 3, undefined, player_id}, {<<"dirty_flag">>, 4, undefined, dirty_flag}, {<<"online">>, 5, undefined, online}, {<<"payload">>, 6, term_binary, payload}, {<<"heartbeat_at">>, 7, undefined, heartbeat_at}];
tableFields_(sys_config) -> [{<<"key">>, 1, undefined, key}, {<<"value">>, 2, json, value}, {<<"remark">>, 3, undefined, remark}];
tableFields_(type_showcase) -> [{<<"id">>, 1, undefined, id}, {<<"score">>, 2, undefined, score}, {<<"title">>, 3, undefined, title}, {<<"region">>, 4, undefined, region}, {<<"status">>, 5, undefined, status}, {<<"labels">>, 6, undefined, labels}, {<<"login_ip">>, 7, undefined, login_ip}, {<<"payload_text">>, 8, term_str, payload_text}, {<<"event_date">>, 9, undefined, event_date}, {<<"event_time">>, 10, undefined, event_time}];
tableFields_(_) -> [].

tableInsert_(players) -> <<"INSERT INTO \"players\" VALUES ($1, $2, $3, $4, $5, $6)">>;
tableInsert_(items) -> <<"INSERT INTO \"items\" VALUES ($1, $2, $3, $4, $5, $6)">>;
tableInsert_(session_snapshots) -> <<"INSERT INTO \"session_snapshots\" VALUES ($1, $2, $3, $4, $5, $6)">>;
tableInsert_(sys_config) -> <<"INSERT INTO \"sys_config\" VALUES ($1, $2, $3)">>;
tableInsert_(type_showcase) -> <<"INSERT INTO \"type_showcase\" VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)">>;
tableInsert_(_) -> undefined.

tableReplace_(players) -> <<"INSERT INTO \"players\" VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT(id) DO UPDATE SET account = EXCLUDED.account, level = EXCLUDED.level, gold = EXCLUDED.gold, profile = EXCLUDED.profile, created_at = EXCLUDED.created_at ">>;
tableReplace_(items) -> <<"INSERT INTO \"items\" VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT(id) DO UPDATE SET player_id = EXCLUDED.player_id, item_type = EXCLUDED.item_type, count = EXCLUDED.count, attrs = EXCLUDED.attrs, updated_at = EXCLUDED.updated_at ">>;
tableReplace_(session_snapshots) -> <<"INSERT INTO \"session_snapshots\" VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT(id) DO UPDATE SET player_id = EXCLUDED.player_id, dirty_flag = EXCLUDED.dirty_flag, online = EXCLUDED.online, payload = EXCLUDED.payload, heartbeat_at = EXCLUDED.heartbeat_at ">>;
tableReplace_(sys_config) -> <<"INSERT INTO \"sys_config\" VALUES ($1, $2, $3) ON CONFLICT(key) DO UPDATE SET value = EXCLUDED.value, remark = EXCLUDED.remark ">>;
tableReplace_(type_showcase) -> <<"INSERT INTO \"type_showcase\" VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) ON CONFLICT(id) DO UPDATE SET score = EXCLUDED.score, title = EXCLUDED.title, region = EXCLUDED.region, status = EXCLUDED.status, labels = EXCLUDED.labels, login_ip = EXCLUDED.login_ip, payload_text = EXCLUDED.payload_text, event_date = EXCLUDED.event_date, event_time = EXCLUDED.event_time ">>;
tableReplace_(_) -> undefined.

onReplace_(players) -> <<" ON CONFLICT(id) DO UPDATE SET account = EXCLUDED.account, level = EXCLUDED.level, gold = EXCLUDED.gold, profile = EXCLUDED.profile, created_at = EXCLUDED.created_at ">>;
onReplace_(items) -> <<" ON CONFLICT(id) DO UPDATE SET player_id = EXCLUDED.player_id, item_type = EXCLUDED.item_type, count = EXCLUDED.count, attrs = EXCLUDED.attrs, updated_at = EXCLUDED.updated_at ">>;
onReplace_(session_snapshots) -> <<" ON CONFLICT(id) DO UPDATE SET player_id = EXCLUDED.player_id, dirty_flag = EXCLUDED.dirty_flag, online = EXCLUDED.online, payload = EXCLUDED.payload, heartbeat_at = EXCLUDED.heartbeat_at ">>;
onReplace_(sys_config) -> <<" ON CONFLICT(key) DO UPDATE SET value = EXCLUDED.value, remark = EXCLUDED.remark ">>;
onReplace_(type_showcase) -> <<" ON CONFLICT(id) DO UPDATE SET score = EXCLUDED.score, title = EXCLUDED.title, region = EXCLUDED.region, status = EXCLUDED.status, labels = EXCLUDED.labels, login_ip = EXCLUDED.login_ip, payload_text = EXCLUDED.payload_text, event_date = EXCLUDED.event_date, event_time = EXCLUDED.event_time ">>;
onReplace_(_) -> undefined.

tableSchema_(players) ->
	#schema{
		repr = map, comment = "PostgreSQL 玩家主表，全量缓存 + 定时整行落盘",
		fields = [
			#schField{name = id, dbType = bigserial, default = undefined, opts = [primary_key, not_null], codec = undefined, erlType = "integer()", comment = "玩家 ID"},
			#schField{name = account, dbType = {varchar, 64}, default = undefined, opts = [not_null, unique], codec = undefined, erlType = "binary()", comment = "账号"},
			#schField{name = level, dbType = integer, default = 1, opts = [not_null, {default, 1}], codec = undefined, erlType = "integer()", comment = "等级"},
			#schField{name = gold, dbType = bigint, default = 0, opts = [not_null, {default, 0}], codec = undefined, erlType = "integer()", comment = "金币"},
			#schField{name = profile, dbType = jsonb, default = #{}, opts = [{default, <<"{}">>}], codec = json, erlType = "map()", comment = "扩展资料"},
			#schField{name = created_at, dbType = timestamptz, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "创建时间"}
		]
	};
tableSchema_(items) ->
	#schema{
		repr = map, comment = "PostgreSQL 道具表，热数据缓存 + dirty",
		fields = [
			#schField{name = id, dbType = bigserial, default = undefined, opts = [primary_key, not_null], codec = undefined, erlType = "integer()", comment = "道具 ID"},
			#schField{name = player_id, dbType = bigint, default = undefined, opts = [not_null], codec = undefined, erlType = "integer()", comment = "玩家 ID"},
			#schField{name = item_type, dbType = {varchar, 32}, default = undefined, opts = [not_null], codec = atom, erlType = "atom()", comment = "道具类型"},
			#schField{name = count, dbType = integer, default = 1, opts = [not_null, {default, 1}], codec = undefined, erlType = "integer()", comment = "数量"},
			#schField{name = attrs, dbType = jsonb, default = #{}, opts = [{default, <<"{}">>}], codec = json, erlType = "map()", comment = "属性"},
			#schField{name = updated_at, dbType = timestamptz, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "更新时间"}
		]
	};
tableSchema_(session_snapshots) ->
	#schema{
		repr = record, comment = "PostgreSQL 会话快照，热数据缓存 + 自定义 loadFun",
		fields = [
			#schField{name = id, dbType = bigserial, default = undefined, opts = [primary_key, not_null], codec = undefined, erlType = "integer()", comment = "快照 ID"},
			#schField{name = player_id, dbType = bigint, default = undefined, opts = [not_null], codec = undefined, erlType = "integer()", comment = "玩家 ID"},
			#schField{name = dirty_flag, dbType = smallint, default = 0, opts = [{default, 0}], codec = undefined, erlType = "integer()", comment = "脏标记"},
			#schField{name = online, dbType = boolean, default = false, opts = [{default, false}], codec = undefined, erlType = "boolean()", comment = "在线状态"},
			#schField{name = payload, dbType = bytea, default = undefined, opts = [], codec = term_binary, erlType = "term()", comment = "快照内容"},
			#schField{name = heartbeat_at, dbType = timestamp, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "心跳时间"}
		]
	};
tableSchema_(sys_config) ->
	#schema{
		repr = map, comment = "PostgreSQL 系统配置，只读缓存",
		fields = [
			#schField{name = key, dbType = {varchar, 128}, default = undefined, opts = [primary_key, not_null], codec = undefined, erlType = "binary()", comment = "配置键"},
			#schField{name = value, dbType = jsonb, default = #{}, opts = [{default, <<"{}">>}], codec = json, erlType = "term()", comment = "配置值"},
			#schField{name = remark, dbType = {varchar, 256}, default = <<>>, opts = [{default, <<>>}], codec = undefined, erlType = "binary()", comment = "备注"}
		]
	};
tableSchema_(type_showcase) ->
	#schema{
		repr = map, comment = "PostgreSQL 类型覆盖样例",
		fields = [
			#schField{name = id, dbType = uuid, default = undefined, opts = [primary_key], codec = undefined, erlType = "binary()", comment = "主键"},
			#schField{name = score, dbType = {numeric, 10, 2}, default = 0, opts = [{default, 0}], codec = undefined, erlType = "number()", comment = "积分"},
			#schField{name = title, dbType = text, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "标题"},
			#schField{name = region, dbType = {char, 8}, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "区服代码"},
			#schField{name = status, dbType = {enum, binary}, default = <<"active">>, opts = [{default, <<"active">>}], codec = undefined, erlType = "binary()", comment = "状态"},
			#schField{name = labels, dbType = {array, {varchar, 32}}, default = undefined, opts = [], codec = undefined, erlType = "[binary()]", comment = "标签数组"},
			#schField{name = login_ip, dbType = inet, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "登录 IP"},
			#schField{name = payload_text, dbType = text, default = undefined, opts = [], codec = term_str, erlType = "term()", comment = "可读结构体"},
			#schField{name = event_date, dbType = date, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "事件日期"},
			#schField{name = event_time, dbType = time, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "事件时间"}
		]
	};
tableSchema_(_) -> undefined.

tablePrimaryKey_(players) -> [id];
tablePrimaryKey_(items) -> [id];
tablePrimaryKey_(session_snapshots) -> [id];
tablePrimaryKey_(sys_config) -> [key];
tablePrimaryKey_(type_showcase) -> [id];
tablePrimaryKey_(_) -> [].

fieldSchema_(players, id) -> #schField{name = id, dbType = bigserial, default = undefined, opts = [primary_key, not_null], codec = undefined, erlType = "integer()", comment = "玩家 ID"};
fieldSchema_(players, account) -> #schField{name = account, dbType = {varchar, 64}, default = undefined, opts = [not_null, unique], codec = undefined, erlType = "binary()", comment = "账号"};
fieldSchema_(players, level) -> #schField{name = level, dbType = integer, default = 1, opts = [not_null, {default, 1}], codec = undefined, erlType = "integer()", comment = "等级"};
fieldSchema_(players, gold) -> #schField{name = gold, dbType = bigint, default = 0, opts = [not_null, {default, 0}], codec = undefined, erlType = "integer()", comment = "金币"};
fieldSchema_(players, profile) -> #schField{name = profile, dbType = jsonb, default = #{}, opts = [{default, <<"{}">>}], codec = json, erlType = "map()", comment = "扩展资料"};
fieldSchema_(players, created_at) -> #schField{name = created_at, dbType = timestamptz, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "创建时间"};
fieldSchema_(items, id) -> #schField{name = id, dbType = bigserial, default = undefined, opts = [primary_key, not_null], codec = undefined, erlType = "integer()", comment = "道具 ID"};
fieldSchema_(items, player_id) -> #schField{name = player_id, dbType = bigint, default = undefined, opts = [not_null], codec = undefined, erlType = "integer()", comment = "玩家 ID"};
fieldSchema_(items, item_type) -> #schField{name = item_type, dbType = {varchar, 32}, default = undefined, opts = [not_null], codec = atom, erlType = "atom()", comment = "道具类型"};
fieldSchema_(items, count) -> #schField{name = count, dbType = integer, default = 1, opts = [not_null, {default, 1}], codec = undefined, erlType = "integer()", comment = "数量"};
fieldSchema_(items, attrs) -> #schField{name = attrs, dbType = jsonb, default = #{}, opts = [{default, <<"{}">>}], codec = json, erlType = "map()", comment = "属性"};
fieldSchema_(items, updated_at) -> #schField{name = updated_at, dbType = timestamptz, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "更新时间"};
fieldSchema_(session_snapshots, id) -> #schField{name = id, dbType = bigserial, default = undefined, opts = [primary_key, not_null], codec = undefined, erlType = "integer()", comment = "快照 ID"};
fieldSchema_(session_snapshots, player_id) -> #schField{name = player_id, dbType = bigint, default = undefined, opts = [not_null], codec = undefined, erlType = "integer()", comment = "玩家 ID"};
fieldSchema_(session_snapshots, dirty_flag) -> #schField{name = dirty_flag, dbType = smallint, default = 0, opts = [{default, 0}], codec = undefined, erlType = "integer()", comment = "脏标记"};
fieldSchema_(session_snapshots, online) -> #schField{name = online, dbType = boolean, default = false, opts = [{default, false}], codec = undefined, erlType = "boolean()", comment = "在线状态"};
fieldSchema_(session_snapshots, payload) -> #schField{name = payload, dbType = bytea, default = undefined, opts = [], codec = term_binary, erlType = "term()", comment = "快照内容"};
fieldSchema_(session_snapshots, heartbeat_at) -> #schField{name = heartbeat_at, dbType = timestamp, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "心跳时间"};
fieldSchema_(sys_config, key) -> #schField{name = key, dbType = {varchar, 128}, default = undefined, opts = [primary_key, not_null], codec = undefined, erlType = "binary()", comment = "配置键"};
fieldSchema_(sys_config, value) -> #schField{name = value, dbType = jsonb, default = #{}, opts = [{default, <<"{}">>}], codec = json, erlType = "term()", comment = "配置值"};
fieldSchema_(sys_config, remark) -> #schField{name = remark, dbType = {varchar, 256}, default = <<>>, opts = [{default, <<>>}], codec = undefined, erlType = "binary()", comment = "备注"};
fieldSchema_(type_showcase, id) -> #schField{name = id, dbType = uuid, default = undefined, opts = [primary_key], codec = undefined, erlType = "binary()", comment = "主键"};
fieldSchema_(type_showcase, score) -> #schField{name = score, dbType = {numeric, 10, 2}, default = 0, opts = [{default, 0}], codec = undefined, erlType = "number()", comment = "积分"};
fieldSchema_(type_showcase, title) -> #schField{name = title, dbType = text, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "标题"};
fieldSchema_(type_showcase, region) -> #schField{name = region, dbType = {char, 8}, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "区服代码"};
fieldSchema_(type_showcase, status) -> #schField{name = status, dbType = {enum, binary}, default = <<"active">>, opts = [{default, <<"active">>}], codec = undefined, erlType = "binary()", comment = "状态"};
fieldSchema_(type_showcase, labels) -> #schField{name = labels, dbType = {array, {varchar, 32}}, default = undefined, opts = [], codec = undefined, erlType = "[binary()]", comment = "标签数组"};
fieldSchema_(type_showcase, login_ip) -> #schField{name = login_ip, dbType = inet, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "登录 IP"};
fieldSchema_(type_showcase, payload_text) -> #schField{name = payload_text, dbType = text, default = undefined, opts = [], codec = term_str, erlType = "term()", comment = "可读结构体"};
fieldSchema_(type_showcase, event_date) -> #schField{name = event_date, dbType = date, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "事件日期"};
fieldSchema_(type_showcase, event_time) -> #schField{name = event_time, dbType = time, default = undefined, opts = [], codec = undefined, erlType = "binary()", comment = "事件时间"};
fieldSchema_(_, _) -> undefined.

fieldCodec(Table, Field) ->
	case fieldSchema_(toAtom(Table), toAtom(Field)) of
		#schField{codec = Codec} -> Codec;
		_ -> undefined
	end.

fieldDefault(Table, Field) ->
	case fieldSchema_(toAtom(Table), toAtom(Field)) of
		#schField{default = Default} -> Default;
		_ -> undefined
	end.

toAtom(Value) when is_atom(Value) -> Value;
toAtom(Value) when is_binary(Value) -> binary_to_atom(Value, utf8);
toAtom(Value) when is_list(Value) -> list_to_atom(Value).

