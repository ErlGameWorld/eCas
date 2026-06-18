%%%-------------------------------------------------------------------
%%% @doc PostgreSQL schema 与 tbCache 覆盖样例。
%%%-------------------------------------------------------------------
-module(pg_cache_schema).

-include_lib("ePgdb/include/pgdbSchema.hrl").

-export([players/0, items/0, session_snapshots/0, sys_config/0, type_showcase/0]).

players() ->
	#schema{
		repr = map,
		comment = "PostgreSQL 玩家主表，全量缓存 + 定时整行落盘",
		tbCache = #tbCache{type = whole, saveMode = 300, saveType = whole, loadFun = undefined, flushLimit = 200},
		fields = [
			#schField{name = id, dbType = ?pg_bigserial, opts = [?pg_primary_key, ?pg_not_null], erlType = "integer()", comment = "玩家 ID"},
			#schField{name = account, dbType = ?pg_varchar(64), opts = [?pg_not_null, ?pg_unique], erlType = "binary()", comment = "账号"},
			#schField{name = level, dbType = ?pg_integer, default = 1, opts = [?pg_not_null, ?pg_default(1)], erlType = "integer()", comment = "等级"},
			#schField{name = gold, dbType = ?pg_bigint, default = 0, opts = [?pg_not_null, ?pg_default(0)], erlType = "integer()", comment = "金币"},
			#schField{name = profile, dbType = ?pg_jsonb, default = #{}, codec = ?codec_json, erlType = "map()", comment = "扩展资料"},
			#schField{name = created_at, dbType = ?pg_timestamptz, erlType = "binary()", comment = "创建时间"}
		]
	}.

items() ->
	#schema{
		repr = map,
		comment = "PostgreSQL 道具表，热数据缓存 + dirty",
		tbCache = #tbCache{type = hotData, ttl = 1800, saveMode = 1, saveType = dirty, loadFun = undefined, flushLimit = 100},
		fields = [
			#schField{name = id, dbType = ?pg_bigserial, opts = [?pg_primary_key, ?pg_not_null], comment = "道具 ID"},
			#schField{name = player_id, dbType = ?pg_bigint, opts = [?pg_not_null, ?pg_index], comment = "玩家 ID"},
			#schField{name = item_type, dbType = ?pg_varchar(32), opts = [?pg_not_null], codec = ?codec_atom, erlType = "atom()", comment = "道具类型"},
			#schField{name = count, dbType = ?pg_integer, default = 1, opts = [?pg_not_null, ?pg_default(1)], comment = "数量"},
			#schField{name = attrs, dbType = ?pg_jsonb, default = #{}, codec = ?codec_json, comment = "属性"},
			#schField{name = updated_at, dbType = ?pg_timestamptz, comment = "更新时间"}
		]
	}.

session_snapshots() ->
	#schema{
		repr = record,
		comment = "PostgreSQL 会话快照，热数据缓存 + 自定义 loadFun",
		tbCache = #tbCache{type = hotData, ttl = 60, saveMode = 1, saveType = whole, loadFun = {schema_test_loader, load_session_snapshots, [postgresql]}, flushLimit = 20},
		fields = [
			#schField{name = id, dbType = ?pg_bigserial, opts = [?pg_primary_key, ?pg_not_null], comment = "快照 ID"},
			#schField{name = player_id, dbType = ?pg_bigint, opts = [?pg_not_null, ?pg_index], comment = "玩家 ID"},
			#schField{name = dirty_flag, dbType = ?pg_smallint, default = 0, opts = [?pg_default(0)], comment = "脏标记"},
			#schField{name = online, dbType = ?pg_boolean, default = false, opts = [?pg_default(false)], erlType = "boolean()", comment = "在线状态"},
			#schField{name = payload, dbType = ?pg_bytea, codec = ?codec_term_binary, erlType = "term()", comment = "快照内容"},
			#schField{name = heartbeat_at, dbType = ?pg_timestamp, comment = "心跳时间"}
		]
	}.

sys_config() ->
	#schema{
		repr = map,
		comment = "PostgreSQL 系统配置，只读缓存",
		tbCache = #tbCache{type = whole, saveMode = 86400, saveType = whole, loadFun = undefined, flushLimit = infinity},
		fields = [
			#schField{name = key, dbType = ?pg_varchar(128), opts = [?pg_primary_key, ?pg_not_null], comment = "配置键"},
			#schField{name = value, dbType = ?pg_jsonb, default = #{}, codec = ?codec_json, erlType = "term()", comment = "配置值"},
			#schField{name = remark, dbType = ?pg_varchar(256), default = <<>>, opts = [?pg_default(<<>>)], comment = "备注"}
		]
	}.

type_showcase() ->
	#schema{
		repr = map,
		comment = "PostgreSQL 类型覆盖样例",
		tbCache = #tbCache{type = whole, saveMode = 15, saveType = whole, loadFun = undefined, flushLimit = 10},
		fields = [
			#schField{name = id, dbType = ?pg_uuid, opts = [?pg_primary_key], comment = "主键"},
			#schField{name = score, dbType = ?pg_numeric(10, 2), default = 0, opts = [?pg_default(0)], erlType = "number()", comment = "积分"},
			#schField{name = title, dbType = ?pg_text, comment = "标题"},
			#schField{name = region, dbType = ?pg_char(8), comment = "区服代码"},
			#schField{name = status, dbType = ?pg_enum_binary, default = <<"active">>, opts = [?pg_default(<<"active">>)], comment = "状态"},
			#schField{name = labels, dbType = ?pg_array(?pg_varchar(32)), erlType = "[binary()]", comment = "标签数组"},
			#schField{name = login_ip, dbType = ?pg_inet, comment = "登录 IP"},
			#schField{name = payload_text, dbType = ?pg_text, codec = ?codec_term_str, erlType = "term()", comment = "可读结构体"},
			#schField{name = event_date, dbType = ?pg_date, comment = "事件日期"},
			#schField{name = event_time, dbType = ?pg_time, comment = "事件时间"}
		]
	}.
