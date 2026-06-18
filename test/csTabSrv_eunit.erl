-module(csTabSrv_eunit).

-include("eCas.hrl").
-include_lib("eunit/include/eunit.hrl").

whole_table_load_and_stats_test() ->
	setup_srv(players),
	try
		fake_db:seed(players, [
			#{table_name => players, id => 1, account => <<"neo">>, level => 10, gold => 0, profile => #{}, created_at => <<>>},
			#{table_name => players, id => 2, account => <<"trinity">>, level => 11, gold => 0, profile => #{}, created_at => <<>>}
		]),
		{ok, Pid} = csTabSrv:start_link(players),
		unlink(Pid),
		wait_until(fun() -> ets:info(players, size) =:= 2 end),
		Stats = csTabSrv:stats(players),
		?assertEqual(2, maps:get(cacheSize, Stats)),
		?assertEqual(0, maps:get(dirtyCnt, Stats))
	after
		teardown_srv(players)
	end.

hotdata_loads_keys_only_test() ->
	setup_srv(items),
	try
		fake_db:seed(items, [#{table_name => items, id => 101, player_id => 7, item_type => sword, count => 1, attrs => #{}, updated_at => <<>>}]),
		{ok, Pid} = csTabSrv:start_link(items),
		unlink(Pid),
		wait_until(fun() -> ets:member(?csKeysTab(items), 101) end),
		?assertEqual(0, ets:info(items, size)),
		Stats = csTabSrv:stats(items),
		?assertEqual(1, maps:get(keysCnt, Stats))
	after
		teardown_srv(items)
	end.

start_link2_sends_load_over_message_test() ->
	setup_srv(players),
	try
		Ref = make_ref(),
		fake_db:seed(players, [
			#{table_name => players, id => 11, account => <<"start2">>, level => 1, gold => 0, profile => #{}, created_at => <<>>}
		]),
		{ok, Pid} = csTabSrv:start_link(players, {self(), Ref}),
		unlink(Pid),
		receive
			{eLoadOver, Ref, Pid, players, ok} -> ok
		after 2000 ->
			error(load_over_timeout)
		end,
		?assert(ets:member(players, 11))
	after
		teardown_srv(players)
	end.

flush_sync_writes_dirty_row_test() ->
	setup_srv(items),
	try
		{ok, Pid} = csTabSrv:start_link(items),
		unlink(Pid),
		wait_until(fun() -> ets:info(items, name) =:= items end),
		ets:insert(items, {101, #{table_name => items, id => 101, player_id => 7, item_type => sword, count => 4, attrs => #{a => 1}, updated_at => <<>>}, ?cs_update, 24, erlang:system_time(second)}),
		ets:insert(?csDirtyTab(items), {101, ?cs_update}),
		ok = eCas:flushSync(items),
		wait_until(fun() -> not ets:member(?csDirtyTab(items), 101) end),
		Ops = fake_db:ops(),
		?assert(lists:any(fun({update, items, 101, _Fields, _Row}) -> true; (_) -> false end, Ops))
	after
		teardown_srv(items)
	end.

flush_sync_with_timeout_writes_dirty_row_test() ->
	setup_srv(items),
	try
		{ok, Pid} = csTabSrv:start_link(items),
		unlink(Pid),
		wait_until(fun() -> ets:info(items, name) =:= items end),
		Row = #{table_name => items, id => 111, player_id => 7, item_type => sword, count => 4, attrs => #{}, updated_at => <<>>},
		ets:insert(items, {111, Row, ?cs_update, 8, erlang:system_time(second)}),
		ets:insert(?csDirtyTab(items), {111, ?cs_update}),
		?assertEqual(false, csTabSrv:flush(items, {true, 10000})),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 111))
	after
		teardown_srv(items)
	end.

flush_async_cast_writes_dirty_row_test() ->
	setup_srv(items),
	try
		{ok, Pid} = csTabSrv:start_link(items),
		unlink(Pid),
		wait_until(fun() -> ets:info(items, name) =:= items end),
		Row = #{table_name => items, id => 112, player_id => 7, item_type => sword, count => 4, attrs => #{}, updated_at => <<>>},
		ets:insert(items, {112, Row, ?cs_update, 8, erlang:system_time(second)}),
		ets:insert(?csDirtyTab(items), {112, ?cs_update}),
		?assertEqual(ok, csTabSrv:flush(items, false)),
		wait_until(fun() -> not ets:member(?csDirtyTab(items), 112) end)
	after
		teardown_srv(items)
	end.

save_sync_writes_one_dirty_key_test() ->
	setup_srv(items),
	try
		{ok, Pid} = csTabSrv:start_link(items),
		unlink(Pid),
		wait_until(fun() -> ets:info(items, name) =:= items end),
		Row = #{table_name => items, id => 121, player_id => 7, item_type => sword, count => 5, attrs => #{}, updated_at => <<>>},
		ets:insert(items, {121, Row, ?cs_update, 8, erlang:system_time(second)}),
		ets:insert(?csKeysTab(items), {121}),
		ets:insert(?csDirtyTab(items), {121, ?cs_update}),
		?assertEqual({ok, [{121, ?cs_update}]}, csTabSrv:save(items, 121, true)),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 121)),
		?assertEqual({error, not_change}, csTabSrv:save(items, 121, {true, 10000}))
	after
		teardown_srv(items)
	end.

save_async_cast_writes_one_dirty_key_test() ->
	setup_srv(items),
	try
		{ok, Pid} = csTabSrv:start_link(items),
		unlink(Pid),
		wait_until(fun() -> ets:info(items, name) =:= items end),
		Row = #{table_name => items, id => 122, player_id => 7, item_type => sword, count => 6, attrs => #{}, updated_at => <<>>},
		ets:insert(items, {122, Row, ?cs_update, 8, erlang:system_time(second)}),
		ets:insert(?csKeysTab(items), {122}),
		ets:insert(?csDirtyTab(items), {122, ?cs_update}),
		?assertEqual(ok, csTabSrv:save(items, 122, false)),
		wait_until(fun() -> not ets:member(?csDirtyTab(items), 122) end)
	after
		teardown_srv(items)
	end.

flush_sync_batch_updates_multiple_dirty_rows_test() ->
	setup_srv(items),
	try
		fake_db:seed(items, [
			#{table_name => items, id => 101, player_id => 7, item_type => sword, count => 1, attrs => #{}, updated_at => <<>>},
			#{table_name => items, id => 102, player_id => 7, item_type => potion, count => 2, attrs => #{}, updated_at => <<>>}
		]),
		{ok, Pid} = csTabSrv:start_link(items),
		unlink(Pid),
		wait_until(fun() ->
			ets:member(?csKeysTab(items), 101) andalso ets:member(?csKeysTab(items), 102)
				   end),
		ets:insert(items, {101, #{table_name => items, id => 101, player_id => 7, item_type => sword, count => 9, attrs => #{}, updated_at => <<>>}, ?cs_update, 8, erlang:system_time(second)}),
		ets:insert(items, {102, #{table_name => items, id => 102, player_id => 7, item_type => potion, count => 8, attrs => #{}, updated_at => <<>>}, ?cs_update, 8, erlang:system_time(second)}),
		ets:insert(?csDirtyTab(items), {101, ?cs_update}),
		ets:insert(?csDirtyTab(items), {102, ?cs_update}),
		ok = eCas:flushSync(items),
		wait_until(fun() ->
			not ets:member(?csDirtyTab(items), 101) andalso not ets:member(?csDirtyTab(items), 102)
				   end),
		Ops = fake_db:ops(),
		?assert(lists:any(fun({update, items, 101, _Fields, _Row}) -> true; (_) -> false end, Ops)),
		?assert(lists:any(fun({update, items, 102, _Fields, _Row}) -> true; (_) -> false end, Ops)),
		{ok, [Row101]} = fake_db:get(items, #{id => 101}),
		{ok, [Row102]} = fake_db:get(items, #{id => 102}),
		?assertEqual(9, maps:get(count, Row101)),
		?assertEqual(8, maps:get(count, Row102))
	after
		teardown_srv(items)
	end.

reload_table_reloads_all_cache_data_test() ->
	setup_srv(players),
	try
		fake_db:seed(players, [
			#{table_name => players, id => 211, account => <<"old">>, level => 1, gold => 0, profile => #{}, created_at => <<>>}
		]),
		{ok, Pid} = csTabSrv:start_link(players),
		unlink(Pid),
		wait_until(fun() -> ets:member(players, 211) end),
		fake_db:reset(),
		fake_db:seed(players, [
			#{table_name => players, id => 212, account => <<"new">>, level => 2, gold => 10, profile => #{}, created_at => <<>>}
		]),
		?assertEqual(ok, csTabSrv:reload(players)),
		?assertEqual([], ets:lookup(players, 211)),
		?assertMatch([{212, #{account := <<"new">>}, ?cs_clean, 0, _}], ets:lookup(players, 212))
	after
		teardown_srv(players)
	end.

flush_sync_deferred_delete_test() ->
	setup_srv(items),
	try
		fake_db:seed(items, [#{table_name => items, id => 201, player_id => 1, item_type => sword, count => 1, attrs => #{}, updated_at => <<>>}]),
		{ok, Pid} = csTabSrv:start_link(items),
		unlink(Pid),
		wait_until(fun() -> ets:member(?csKeysTab(items), 201) end),
		ok = eCas:delete(items, 201),
		wait_until(fun() -> not ets:member(items, 201) end),
		ok = eCas:flushSync(items),
		wait_until(fun() -> not ets:member(?csKeysTab(items), 201) end),
		Ops = fake_db:ops(),
		?assert(lists:any(fun({delete, items, _}) -> true; (_) -> false end, Ops)),
		?assertEqual({ok, []}, fake_db:get(items, #{id => 201}))
	after
		teardown_srv(items)
	end.

flush_sync_delete_failure_restores_dirty_test() ->
	setup_srv(players),
	try
		mute_error_logger(),
		{ok, Pid} = csTabSrv:start_link(players),
		unlink(Pid),
		wait_until(fun() -> ets:info(players, name) =:= players end),
		ets:insert(?csDirtyTab(players), {301, ?cs_del}),
		fake_db:set_fail(delete, fail_delete),
		?assertMatch({error, _}, eCas:flushSync(players)),
		?assertEqual([{301, ?cs_del}], ets:lookup(?csDirtyTab(players), 301))
	after
		unmute_error_logger(),
		teardown_srv(players)
	end.

flush_limit_keeps_remaining_dirty_keys_test() ->
	setup_srv(items),
	try
		{ok, Pid} = csTabSrv:start_link(items),
		unlink(Pid),
		wait_until(fun() -> ets:info(items, name) =:= items end),
		cancel_save_timer(Pid),
		Rows = [#{table_name => items, id => Id, player_id => 7, item_type => sword, count => Id, attrs => #{}, updated_at => <<>>} || Id <- lists:seq(1, 150)],
		[begin
			 ets:insert(items, {maps:get(id, Row), Row, ?cs_update, 8, erlang:system_time(second)}),
			 ets:insert(?csKeysTab(items), {maps:get(id, Row)}),
			 ets:insert(?csDirtyTab(items), {maps:get(id, Row), ?cs_update})
		 end || Row <- Rows],
		?assertEqual({error, flushLimit}, eCas:flushSync(items)),
		?assertEqual(22, ets:info(?csDirtyTab(items), size)),
		ok = eCas:flushSync(items),
		?assertEqual(0, ets:info(?csDirtyTab(items), size))
	after
		teardown_srv(items)
	end.

reload_key_refreshes_cache_test() ->
	setup_srv(players),
	try
		fake_db:seed(players, [#{table_name => players, id => 1, account => <<"old">>, level => 1, gold => 0, profile => #{}, created_at => <<>>}]),
		{ok, Pid} = csTabSrv:start_link(players),
		unlink(Pid),
		wait_until(fun() -> ets:member(players, 1) end),
		fake_db:reset(),
		fake_db:seed(players, [#{table_name => players, id => 1, account => <<"new">>, level => 2, gold => 100, profile => #{}, created_at => <<>>}]),
		Reloaded = csTabSrv:reload(players, 1),
		?assertEqual(#{id => 1, account => <<"new">>, level => 2, gold => 100, profile => #{}, created_at => <<>>}, Reloaded)
	after
		teardown_srv(players)
	end.

reload_key_rejects_dirty_cache_test() ->
	setup_srv(players),
	try
		Old = #{table_name => players, id => 1, account => <<"old">>, level => 1, gold => 0, profile => #{}, created_at => <<>>},
		New = #{id => 1, account => <<"new">>, level => 2, gold => 100, profile => #{}, created_at => <<>>},
		fake_db:seed(players, [Old]),
		{ok, Pid} = csTabSrv:start_link(players),
		unlink(Pid),
		wait_until(fun() -> ets:member(players, 1) end),
		ets:insert(players, {1, New, ?cs_update, 0, erlang:system_time(second)}),
		ets:insert(?csDirtyTab(players), {1, ?cs_update}),
		?assertEqual({error, dirty_conflict}, csTabSrv:reload(players, 1)),
		?assertMatch([{1, New, ?cs_update, 0, _}], ets:lookup(players, 1)),
		?assertEqual([{1, ?cs_update}], ets:lookup(?csDirtyTab(players), 1))
	after
		teardown_srv(players)
	end.

setup_srv(Table) ->
	stop_if_running(Table),
	cleanup_ets(Table),
	application:set_env(eCas, dbModule, fake_db),
	fake_db:reset(),
	persistent_term:put(?csDbMod, fake_db),
	ok.

teardown_srv(Table) ->
	stop_if_running(Table),
	cleanup_ets(Table),
	persistent_term:erase(?csDbMod),
	ok.

cancel_save_timer(Pid) ->
	sys:replace_state(Pid, fun({state, Table, DbMod, Config, SaveTimerRef, TtlTimerRef}) ->
		erlang:cancel_timer(SaveTimerRef, [{async, false}, {info, false}]),
		{state, Table, DbMod, Config, undefined, TtlTimerRef}
	end),
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

cleanup_ets(Table) ->
	maybe_delete(Table),
	case persistent_term:get(?DirtyEtsTag(Table), undefined) of
		undefined -> ok;
		DirtyTab -> try ets:delete(DirtyTab) catch _:_ -> ok end
	end,
	case persistent_term:get(?KeysEtsTag(Table), undefined) of
		undefined -> ok;
		KeysTab -> try ets:delete(KeysTab) catch _:_ -> ok end
	end,
	ok.

maybe_delete(Name) ->
	case ets:info(Name, name) of
		undefined -> ok;
		_ -> ets:delete(Name)
	end.

wait_until(Fun) ->
	wait_until(Fun, 50).

wait_until(Fun, 0) ->
	?assert(Fun());
wait_until(Fun, Left) ->
	case Fun() of
		true -> ok;
		false -> timer:sleep(20), wait_until(Fun, Left - 1)
	end.

mute_error_logger() ->
	error_logger:tty(false).

unmute_error_logger() ->
	error_logger:tty(true).
