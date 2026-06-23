-module(eCas_eunit).

-include("eCas.hrl").
-include_lib("eunit/include/eunit.hrl").

whole_put_test() ->
	setup_tables(players),
	try
		OldRow = #{id => 1, account => <<"neo">>, level => 9, gold => 900, profile => #{}, created_at => <<>>},
		Row = #{id => 1, account => <<"neo">>, level => 10, gold => 1000, profile => #{}, created_at => <<>>},
		ets:insert(players, {1, OldRow, ?cs_clean, 0, 0}),
		ok = eCas:insert(players, 1, Row),
		[Stored] = ets:lookup(players, 1),
		?assertEqual(Row, element(?csDataPos, Stored)),
		?assertEqual(?cs_update, element(?csDirtyStatePos, Stored)),
		?assertEqual([{1, ?cs_update}], ets:lookup(?csDirtyTab(players), 1))
	after
		cleanup(players)
	end.

start_stop_api_test() ->
	stop_all_cache_tables(),
	try
		?assertEqual(ok, eCas:start(fake_db, "127.0.0.1", 0, "user", "pass", "db", [{wFCnt, 2}])),
		?assert(is_map(eCas:stats(players))),
		?assert(is_map(eCas:stats(items))),
		?assertEqual(ok, eCas:flush(items)),
		?assertEqual(ok, eCas:flush()),
		?assertEqual(ok, eCas:flushSync(items)),
		?assertEqual(ok, eCas:flushSync()),
		?assertEqual(ok, eCas:reload(items)),
		?assertEqual(undefined, eCas:reload(items, '$missing_key')),
		?assertEqual(ok, eCas:stop())
	after
		stop_all_cache_tables(),
		cleanup(players),
		cleanup(items),
		cleanup(session_snapshots),
		cleanup(sys_config),
		cleanup(type_showcase)
	end.

generator_api_exports_test() ->
	%% genP/genM 会重写 schema 生成文件，单元测试只确认接口存在，避免污染源码树。
	?assert(erlang:function_exported(eCas, genP, 0)),
	?assert(erlang:function_exported(eCas, genM, 0)).

hotdata_get_loads_from_db_test() ->
	setup_tables(items),
	try
		fake_db:seed(items, [#{table_name => items, id => 101, player_id => 7, item_type => sword, count => 2, attrs => #{}, updated_at => <<>>}]),
		ets:insert(?csKeysTab(items), {101}),
		{ok, Row} = eCas:get(items, 101),
		?assertEqual(#{id => 101, player_id => 7, item_type => sword, count => 2, attrs => #{}, updated_at => <<>>}, Row),
		?assert(ets:member(items, 101))
	after
		cleanup(items)
	end.

get3_without_lock_reads_plain_and_cache_test() ->
	Plain = plain_get3_tab,
	cleanup(Plain),
	ets:new(Plain, [named_table, set, public, {keypos, 2}]),
	setup_tables(players),
	try
		PlainRow = {plain_row, 1, <<"plain">>},
		Player = #{id => 11, account => <<"get3">>, level => 1, gold => 0, profile => #{}, created_at => <<>>},
		ets:insert(Plain, PlainRow),
		ets:insert(players, {11, Player, ?cs_clean, 0, 0}),
		?assertEqual({ok, PlainRow}, eCas:get(Plain, 1, false)),
		?assertEqual({ok, Player}, eCas:get(players, 11, false))
	after
		cleanup(Plain),
		cleanup(players)
	end.

create2_and_put2_cache_api_test() ->
	setup_tables(players),
	try
		Row1 = #{id => 21, account => <<"create2">>, level => 1, gold => 0, profile => #{}, created_at => <<>>},
		Row2 = Row1#{level => 2},
		?assertEqual(ok, eCas:create(players, Row1)),
		?assertMatch([{21, Row1, ?cs_new, 0, _}], ets:lookup(players, 21)),
		?assertEqual(ok, eCas:insert(players, Row2)),
		?assertMatch([{21, Row2, ?cs_new, 0, _}], ets:lookup(players, 21))
	after
		cleanup(players)
	end.

insert_key_mismatch_returns_flat_error_test() ->
	setup_tables(players),
	try
		Row = #{id => 99, account => <<"mismatch">>, level => 1, gold => 0, profile => #{}, created_at => <<>>},
		?assertEqual({error, {key_mismatch, players, 100, 99}}, eCas:insert(players, 100, Row))
	after
		cleanup(players)
	end.

update_dirty_tracks_fields_test() ->
	setup_tables(items),
	try
		ets:insert(items, {101, #{id => 101, player_id => 7, item_type => sword, count => 1, attrs => #{}, updated_at => <<>>}, ?cs_clean, 0, 0}),
		ets:insert(?csKeysTab(items), {101}),
		ok = eCas:mupdate(items, [{101, #{count => 5, attrs => #{a => 1}}}]),
		[Stored] = ets:lookup(items, 101),
		?assertEqual(?cs_update, element(?csDirtyStatePos, Stored)),
		DirtyMask = element(?csDirtyMask, Stored),
		?assert(DirtyMask band 8 =:= 8),
		?assert(DirtyMask band 16 =:= 16),
		?assert(DirtyMask band bnot(8 bor 16) =:= 0),
		?assertEqual([{101, ?cs_update}], ets:lookup(?csDirtyTab(items), 101))
	after
		cleanup(items)
	end.

take_api_plain_whole_and_hotdata_test() ->
	Plain = plain_take_tab,
	cleanup(Plain),
	ets:new(Plain, [named_table, set, public, {keypos, 2}]),
	setup_tables(players),
	setup_tables(items),
	try
		PlainRow = {plain_row, 1, <<"take">>},
		Player = #{id => 31, account => <<"take">>, level => 1, gold => 0, profile => #{}, created_at => <<>>},
		Item = #{id => 32, player_id => 7, item_type => sword, count => 1, attrs => #{}, updated_at => <<>>},
		ets:insert(Plain, PlainRow),
		ets:insert(players, {31, Player, ?cs_clean, 0, 0}),
		ets:insert(?csKeysTab(items), {32}),
		fake_db:seed(items, [maps:put(table_name, items, Item)]),
		?assertEqual({ok, PlainRow}, eCas:take(Plain, 1)),
		?assertEqual([], ets:lookup(Plain, 1)),
		?assertEqual({ok, Player}, eCas:take(players, 31)),
		?assertEqual([{31, ?cs_del}], ets:lookup(?csDirtyTab(players), 31)),
		?assertEqual({ok, Item}, eCas:take(items, 32)),
		?assertEqual([], ets:lookup(?csKeysTab(items), 32)),
		?assertEqual([{32, ?cs_del}], ets:lookup(?csDirtyTab(items), 32))
	after
		cleanup(Plain),
		cleanup(players),
		cleanup(items)
	end.

hotdata_delete_defers_db_until_flush_test() ->
	setup_tables(items),
	try
		fake_db:seed(items, [#{table_name => items, id => 301, player_id => 1, item_type => sword, count => 1, attrs => #{}, updated_at => <<>>}]),
		ets:insert(?csKeysTab(items), {301}),
		ok = eCas:delete(items, 301),
		?assertEqual(false, ets:member(?csKeysTab(items), 301)),
		?assertEqual([{301, ?cs_del}], ets:lookup(?csDirtyTab(items), 301)),
		OpsBefore = fake_db:ops(),
		?assertEqual(false, lists:any(fun({delete, items, _}) -> true; (_) -> false end, OpsBefore))
	after
		cleanup(items)
	end.

mget_mput_and_mdelete_plain_api_test() ->
	Table = plain_batch_tab,
	cleanup(Table),
	ets:new(Table, [named_table, set, public, {keypos, 2}]),
	try
		?assertEqual(ok, eCas:mput(Table, [{1, {plain_row, 1, <<"a">>}}, {2, {plain_row, 2, <<"b">>}}])),
		?assertEqual([{1, {ok, {plain_row, 1, <<"a">>}}}, {2, {ok, {plain_row, 2, <<"b">>}}}, {3, {error, not_found}}], eCas:mget(Table, [1, 2, 3])),
		?assertEqual(ok, eCas:mdelete(Table, [1, 2])),
		?assertEqual([{1, {error, not_found}}, {2, {error, not_found}}], eCas:mget(Table, [1, 2]))
	after
		cleanup(Table)
	end.

minsert_mupdate_mdelete_cache_api_test() ->
	setup_tables(items),
	try
		Row1 = #{id => 41, player_id => 7, item_type => sword, count => 1, attrs => #{}, updated_at => <<>>},
		Row2 = #{id => 42, player_id => 7, item_type => potion, count => 2, attrs => #{}, updated_at => <<>>},
		?assertEqual(ok, eCas:minsert(items, [Row1, Row2])),
		?assertMatch([{41, Row1, ?cs_new, 0, _}], ets:lookup(items, 41)),
		?assertMatch([{42, Row2, ?cs_new, 0, _}], ets:lookup(items, 42)),
		?assertEqual(ok, eCas:mupdate(items, [{41, #{count => 5}}, {42, [{attrs, #{gem => 1}}]}])),
		?assertEqual(ok, eCas:mdelete(items, [41, 42])),
		?assertEqual([], ets:lookup(items, 41)),
		?assertEqual([], ets:lookup(items, 42)),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 41)),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 42))
	after
		cleanup(items)
	end.

fold_table_and_key_apis_test() ->
	Plain = plain_fold_tab,
	cleanup(Plain),
	ets:new(Plain, [named_table, set, public, {keypos, 2}]),
	setup_tables(players),
	setup_tables(items),
	try
		P1 = {plain_row, 1, <<"a">>},
		P2 = {plain_row, 2, <<"b">>},
		Player1 = #{id => 61, account => <<"p1">>, level => 1, gold => 0, profile => #{}, created_at => <<>>},
		Player2 = #{id => 62, account => <<"p2">>, level => 2, gold => 0, profile => #{}, created_at => <<>>},
		Item = #{id => 63, player_id => 7, item_type => sword, count => 1, attrs => #{}, updated_at => <<>>},
		ets:insert(Plain, P1),
		ets:insert(Plain, P2),
		ets:insert(players, {61, Player1, ?cs_clean, 0, 0}),
		ets:insert(players, {62, Player2, ?cs_clean, 0, 0}),
		ets:insert(?csKeysTab(items), {63}),
		fake_db:seed(items, [maps:put(table_name, items, Item)]),
		?assertEqual([P1, P2], lists:sort(eCas:foldTable(Plain, [], fun(Data, Acc) -> [Data | Acc] end))),
		?assertEqual([Player1, Player2], lists:sort(eCas:foldrTable(players, [], fun(Data, Acc) -> [Data | Acc] end))),
		?assertEqual([1, 2], lists:sort(eCas:foldKey(Plain, [], fun(Key, Acc) -> [Key | Acc] end))),
		?assertEqual([61, 62], lists:sort(eCas:foldrKey(players, [], fun(Key, Acc) -> [Key | Acc] end))),
		?assertEqual([Item], eCas:foldTable(items, [], fun(Data, Acc) -> [Data | Acc] end)),
		?assertEqual([63], eCas:foldKey(items, [], fun(Key, Acc) -> [Key | Acc] end))
	after
		cleanup(Plain),
		cleanup(players),
		cleanup(items)
	end.

reload_stats_flush_and_helper_apis_test() ->
	Plain = plain_misc_api_tab,
	cleanup(Plain),
	ets:new(Plain, [named_table, set, public, {keypos, 2}]),
	setup_tables(items),
	try
		Row = #{id => 71, player_id => 7, item_type => sword, count => 1, attrs => #{}, updated_at => <<>>},
		ets:insert(Plain, {plain_row, 1, <<"a">>}),
		ets:insert(?csKeysTab(items), {71}),
		fake_db:seed(items, [maps:put(table_name, items, Row)]),
		?assertEqual(#{type => plain, size => 1}, eCas:stats(Plain)),
		?assertEqual({ok, {plain_row, 1, <<"a">>}}, eCas:reload(Plain, 1)),
		?assertEqual(ok, eCas:reload(Plain)),
		?assertEqual(ok, eCas:keysDelete(items, 71)),
		?assertEqual(false, ets:member(?csKeysTab(items), 71)),
		?assertEqual([count, attrs], eCas:dirtyMaskToFields(items, 8 bor 16)),
		?assertEqual(ok, eCas:flush()),
		?assertEqual({error, not_cache_table}, eCas:flush(Plain)),
		?assertMatch({error, _}, eCas:flushSync()),
		?assertEqual({error, not_cache_table}, eCas:flushSync(Plain))
	after
		cleanup(Plain),
		cleanup(items)
	end.

fake_db_batch_update_test() ->
	fake_db:reset(),
	P1 = #{table_name => players, id => 1, account => <<"a">>, level => 1, gold => 10, profile => #{}, created_at => <<>>},
	P2 = #{table_name => players, id => 2, account => <<"b">>, level => 1, gold => 20, profile => #{}, created_at => <<>>},
	ok = fake_db:batchInsert([P1, P2], true),
	ok = fake_db:batchUpdate([
		{#{table_name => players, id => 1, level => 11, gold => 110}, [level, gold], [{id, 1}]},
		{#{table_name => players, id => 2, level => 22, gold => 220}, [level, gold], [{id, 2}]}
	]),
	{ok, [Row1]} = fake_db:get(players, #{id => 1}),
	{ok, [Row2]} = fake_db:get(players, #{id => 2}),
	?assertEqual(11, maps:get(level, Row1)),
	?assertEqual(110, maps:get(gold, Row1)),
	?assertEqual(22, maps:get(level, Row2)),
	?assertEqual(220, maps:get(gold, Row2)).

insert_then_delete_new_row_skips_db_delete_test() ->
	setup_tables(players),
	try
		ok = eCas:create(players, #{id => 3, account => <<"new">>, level => 1, gold => 0, profile => #{}, created_at => <<>>}),
		ok = eCas:delete(players, 3),
		Ops = fake_db:ops(),
		?assertEqual(false, lists:any(fun({delete, players, _}) -> true; (_) -> false end, Ops))
	after
		cleanup(players)
	end.

txn_whole_delete_defers_db_until_flush_test() ->
	setup_tables(players),
	try
		Row = #{id => 9, account => <<"rollback">>, level => 1, gold => 0, profile => #{}, created_at => <<>>},
		fake_db:seed(players, [maps:put(table_name, players, Row)]),
		ets:insert(players, {9, Row, ?cs_clean, 0, 0}),
		fake_db:set_fail(delete, fail_delete),
		ok = eCas:txn([{players, 9}], fun(_Args, _Values) ->
			{alterTab, [{{players, 9}, del}]}
		end, undefined),
		?assertEqual([], ets:lookup(players, 9)),
		?assertEqual([{9, ?cs_del}], ets:lookup(?csDirtyTab(players), 9)),
		?assertEqual(false, lists:any(fun({delete, players, _}) -> true; (_) -> false end, fake_db:ops())),
		?assertMatch({error, _}, eCas:flushSync(players)),
		?assertEqual([{9, ?cs_del}], ets:lookup(?csDirtyTab(players), 9))
	after
		cleanup(players)
	end.

plain_ets_crud_test() ->
	Table = plain_test_tab,
	cleanup(Table),
	ets:new(Table, [named_table, set, public, {keypos, 2}]),
	try
		ok = eCas:insert(Table, 1, {plain_row, 1, <<"a">>}),
		?assertEqual({ok, {plain_row, 1, <<"a">>}}, eCas:get(Table, 1)),
		?assert(eCas:exists(Table, 1)),
		ok = eCas:delete(Table, 1),
		?assertEqual({error, not_found}, eCas:get(Table, 1)),
		ok = eCas:create(Table, 2, {plain_row, 2, <<"new">>}),
		?assertEqual({error, create_failed}, eCas:create(Table, 2, {plain_row, 2, <<"dup">>})),
		?assertEqual({error, not_cache_table}, eCas:minsert(Table, [{plain_row, 3, <<"implicit">>}]))
	after
		cleanup(Table)
	end.

setup_tables(Table) ->
	cleanup(Table),
	application:set_env(eCas, dbModule, fake_db),
	fake_db:reset(),
	persistent_term:put(?csDbMod, fake_db),
	ets:new(Table, [named_table, set, public]),
	DirtyTab = ets:new(undefined, [set, public]),
	persistent_term:put(?DirtyEtsTag(Table), DirtyTab),
	case cacheTabDef:tableCache(Table) of
		#tbCache{type = hotData} ->
			KeysTab = ets:new(undefined, [set, public]),
			persistent_term:put(?KeysEtsTag(Table), KeysTab);
		_ -> ok
	end,
	Table.

cleanup(Table) ->
	maybe_delete(Table),
	case persistent_term:get(?DirtyEtsTag(Table), undefined) of
		undefined -> ok;
		DirtyTab -> try ets:delete(DirtyTab) catch _:_ -> ok end
	end,
	case persistent_term:get(?KeysEtsTag(Table), undefined) of
		undefined -> ok;
		KeysTab -> try ets:delete(KeysTab) catch _:_ -> ok end
	end,
	persistent_term:erase(?csDbMod),
	persistent_term:erase(?DirtyEtsTag(Table)),
	persistent_term:erase(?KeysEtsTag(Table)),
	ok.

maybe_delete(Name) ->
	case ets:info(Name, name) of
		undefined -> ok;
		_ -> ets:delete(Name)
	end.

stop_all_cache_tables() ->
	[stop_if_running(Table) || Table <- cacheTabDef:getCaches()],
	ok.

stop_if_running(Table) ->
	case whereis(Table) of
		undefined -> ok;
		Pid ->
			MRef = erlang:monitor(process, Pid),
			exit(Pid, kill),
			receive
				{'DOWN', MRef, process, Pid, _} -> ok
			after 2000 ->
				erlang:demonitor(MRef, [flush]),
				ok
			end
	end.
