-module(fake_db).

-export([
	start/6, stop/0,
	get/2, delete/2,
	batchInsert/2, batchUpdate/1, batchUpdate/2, batchDelByKey/3,
	foreachRows/4, foreachRows/5,
	schema/1, schemas/0,
	reset/0, seed/2, ops/0, set_fail/2, clear_fail/1
]).

-define(ROWS_TAB, fake_db_rows).
-define(OPS_TAB, fake_db_ops).
-define(FLAGS_TAB, fake_db_flags).

start(_Host, _Port, _User, _Password, _DbName, _PoolArgs) ->
	ensure_tabs(),
	{ok, self()}.

stop() ->
	ok.

reset() ->
	ensure_tabs(),
	ets:delete_all_objects(?ROWS_TAB),
	ets:delete_all_objects(?OPS_TAB),
	ets:delete_all_objects(?FLAGS_TAB),
	ok.

seed(Table, Rows) when is_list(Rows) ->
	ensure_tabs(),
	[begin
		 Table = maps:get(table_name, Row),
		 store_db_row(Row)
	 end || Row <- Rows],
	ok.

ops() ->
	ensure_tabs(),
	[Op || {_Id, Op} <- lists:sort(ets:tab2list(?OPS_TAB))].

set_fail(Operation, Reason) ->
	ensure_tabs(),
	ets:insert(?FLAGS_TAB, {Operation, Reason}),
	ok.

clear_fail(Operation) ->
	ensure_tabs(),
	ets:delete(?FLAGS_TAB, Operation),
	ok.

get(Table, Filter) when is_list(Filter) ->
	get(Table, maps:from_list(Filter));
get(Table, Filter) when is_map(Filter) ->
	{ok, matched_rows(Table, Filter)}.

delete(Table, Filter) when is_list(Filter) ->
	delete(Table, maps:from_list(Filter));
delete(Table, Filter) when is_map(Filter) ->
	case lookup_fail(delete) of
		undefined ->
			Rows = matched_rows(Table, Filter),
			[ets:delete(?ROWS_TAB, {Table, row_key(Table, Row)}) || Row <- Rows],
			log({delete, Table, Filter}),
			{ok, length(Rows)};
		Reason ->
			{error, Reason}
	end.

batchInsert(DbRows, _Overwrite) when is_list(DbRows) ->
	case lookup_fail(batchInsert) of
		undefined ->
			[store_db_row(DbData) || DbData <- DbRows],
			ok;
		Reason ->
			{error, Reason}
	end.

batchDelByKey(_Table, _KeyField, []) ->
	{ok, 0};
batchDelByKey(Table, KeyField, Keys) ->
	case lookup_fail(batchDelByKey) of
		undefined ->
			case lookup_fail(delete) of
				undefined ->
					Deleted =
						lists:sum([
							begin
								Filter = #{KeyField => Key},
								{ok, N} = delete(Table, Filter),
								N
							end || Key <- Keys
						]),
					{ok, Deleted};
				Reason ->
					{error, Reason}
			end;
		Reason ->
			{error, Reason}
	end.

batchUpdate(Updates) when is_list(Updates) ->
	case lookup_fail(batchUpdate) of
		undefined ->
			do_batch_update(Updates);
		Reason ->
			{error, Reason}
	end.

batchUpdate(_Conn, Updates) ->
	batchUpdate(Updates).

do_batch_update(Updates) ->
	lists:foreach(fun({DbData, MaskOrFields, Where}) ->
		Fields = fields_from_mask_or_list(DbData, MaskOrFields),
		case Fields of
			[] ->
				ok;
			_ ->
				Table = maps:get(table_name, DbData),
				{KeyField, Key} = hd(Where),
				update_row(Table, KeyField, Key, maps:remove(table_name, DbData), Fields)
		end
				  end, Updates),
	ok.

update_row(Table, PkField, Key, DbData, DirtyFields) ->
	Row0 = case ets:lookup(?ROWS_TAB, {Table, Key}) of
			   [{{_, _}, Existing}] -> Existing;
			   [] -> #{PkField => Key}
		   end,
	Row1 = lists:foldl(fun(Field, Acc) ->
		case maps:find(Field, DbData) of
			{ok, Value} -> Acc#{Field => Value};
			error -> Acc
		end
					   end, Row0, DirtyFields),
	ets:insert(?ROWS_TAB, {{Table, Key}, Row1}),
	log({update, Table, Key, DirtyFields, Row1}),
	ok.

fields_from_mask_or_list(_DbData, Fields) when is_list(Fields) ->
	Fields;
fields_from_mask_or_list(DbData, Mask) when is_integer(Mask) ->
	Table = maps:get(table_name, DbData),
	eCas:dirtyMaskToFields(Table, Mask).

foreachRows(Table, Filter, _PageSize, Fun) ->
	lists:foreach(Fun, matched_rows(Table, Filter)),
	ok.

foreachRows(Table, Filter, _PageSize, Opts, Fun) ->
	case is_function(Opts, 1) andalso is_list(Fun) of
		true ->
			foreachRows(Table, Filter, _PageSize, Fun, Opts);
		false ->
			do_foreach_rows(Table, Filter, Opts, Fun)
	end.

%% 与 eMysql/ePgdb 对齐：供 csTabSrv:stats/1 等调用方读取表 schema 描述
%% fake_db 是测试替身，这里直接转发到 dbSchemaDef（与真实驱动一致），
%% 这样上层（csTabSrv 统计、调试输出等）就不必为 fake_db 走特殊分支。
schema(Table) ->
	dbSchemaDef:tableSchema(Table).

schemas() ->
	[dbSchemaDef:tableSchema(Table) || Table <- dbSchemaDef:getTables()].

do_foreach_rows(Table, Filter, Opts, Fun) ->
	Fields = proplists:get_value(fields, Opts, undefined),
	Rows = matched_rows(Table, Filter),
	Projected = case Fields of
					undefined -> Rows;
					_ -> [maps:with(Fields, Row) || Row <- Rows]
				end,
	lists:foreach(Fun, Projected),
	ok.

ensure_tabs() ->
	ensure_tab(?ROWS_TAB),
	ensure_tab(?OPS_TAB),
	ensure_tab(?FLAGS_TAB),
	ok.

ensure_tab(Name) ->
	case ets:info(Name, name) of
		undefined -> ets:new(Name, [named_table, ordered_set, public]);
		_ -> Name
	end.

matched_rows(Table, Filter) ->
	[Row || {{StoredTable, _Key}, Row} <- ets:tab2list(?ROWS_TAB),
		StoredTable =:= Table,
		match_filter(Row, Filter)].

match_filter(_Row, []) ->
	true;
match_filter(_Row, Filter) when map_size(Filter) =:= 0 ->
	true;
match_filter(Row, Filter) ->
	lists:all(fun({Field, Value}) -> maps:get(Field, Row, '$missing') =:= Value end,
		maps:to_list(Filter)).

store_db_row(DbData) ->
	Table = maps:get(table_name, DbData),
	Row = maps:remove(table_name, DbData),
	Key = row_key(Table, Row),
	ets:insert(?ROWS_TAB, {{Table, Key}, Row}),
	log({upsert, Table, Key, Row}).

row_key(Table, Row) ->
	[PkField] = cacheTabDef:tablePrimaryKey(Table),
	maps:get(PkField, Row).

log(Op) ->
	Id = erlang:unique_integer([monotonic, positive]),
	ets:insert(?OPS_TAB, {Id, Op}),
	ok.

lookup_fail(Operation) ->
	case ets:lookup(?FLAGS_TAB, Operation) of
		[{_, Reason}] -> Reason;
		[] -> undefined
	end.

