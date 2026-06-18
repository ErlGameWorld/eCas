-module(eCas_perf_eunit).

-include("eCas.hrl").
-include_lib("eunit/include/eunit.hrl").

plain_put_get_perf_smoke_test() ->
	Table = perf_plain_tab,
	setup_plain(Table),
	try
		Ops = 1000,
		{ElapsedUs, ok} = timer:tc(fun() ->
			lists:foreach(fun(I) ->
				ok = eCas:insert(Table, I, {perf_row, I, I}),
				{ok, {perf_row, I, I}} = eCas:get(Table, I)
			end, lists:seq(1, Ops))
		end),
		print_perf(plain_put_get, Ops * 2, ElapsedUs),
		?assert(ElapsedUs < 5000000)
	after
		cleanup(Table)
	end.

txn_hotdata_update_perf_smoke_test() ->
	setup_cache(items),
	try
		Rows = [item_row(Id, 1) || Id <- lists:seq(1, 300)],
		[begin
			ets:insert(items, {maps:get(id, Row), Row, ?cs_clean, 0, 0}),
			ets:insert(?csKeysTab(items), {maps:get(id, Row)})
		end || Row <- Rows],
		Ops = 300,
		{ElapsedUs, ok} = timer:tc(fun() ->
			lists:foreach(fun(Id) ->
				NewRow = item_row(Id, 2),
				ok = eCas:txn({items, Id}, fun(_Args, _Values) ->
					{alterTab, [{{items, Id}, NewRow}]}
				end, undefined)
			end, lists:seq(1, Ops))
		end),
		print_perf(txn_hotdata_update, Ops, ElapsedUs, #{dirty_size => ets:info(?csDirtyTab(items), size)}),
		?assert(ElapsedUs < 5000000),
		?assertEqual(300, ets:info(?csDirtyTab(items), size))
	after
		cleanup(items)
	end.

txn_hotdata_batch_update_perf_smoke_test() ->
	setup_cache(items),
	try
		Ops = 300,
		Rows = [item_row(Id, 1) || Id <- lists:seq(1, Ops)],
		[begin
			ets:insert(items, {maps:get(id, Row), Row, ?cs_clean, 0, 0}),
			ets:insert(?csKeysTab(items), {maps:get(id, Row)})
		end || Row <- Rows],
		Keys = [{items, Id} || Id <- lists:seq(1, Ops)],
		{ElapsedUs, ok} = timer:tc(fun() ->
			ok = eCas:txn(Keys, fun(_Args, _Values) ->
				Alters = [{{items, Id}, item_row(Id, 3)} || Id <- lists:seq(1, Ops)],
				{alterTab, Alters}
			end, undefined)
		end),
		print_perf(txn_hotdata_batch_update, Ops, ElapsedUs, #{
			cache_size => ets:info(items, size),
			dirty_size => ets:info(?csDirtyTab(items), size)
		}),
		?assert(ElapsedUs < 5000000),
		?assertEqual(Ops, ets:info(?csDirtyTab(items), size)),
		?assertEqual(Ops, ets:info(items, size))
	after
		cleanup(items)
	end.

txn_plain_batch_insert_perf_smoke_test() ->
	Table = perf_plain_txn_batch_tab,
	setup_plain(Table),
	try
		Ops = 500,
		Keys = [{Table, Id, {perf_row, Id, 0}} || Id <- lists:seq(1, Ops)],
		{ElapsedUs, ok} = timer:tc(fun() ->
			ok = eCas:txn(Keys, fun(_Args, _Values) ->
				Alters = [{{Table, Id}, {perf_row, Id, Id}} || Id <- lists:seq(1, Ops)],
				{alterTab, Alters}
			end, undefined)
		end),
		print_perf(txn_plain_batch_insert, Ops, ElapsedUs, #{ets_size => ets:info(Table, size)}),
		?assert(ElapsedUs < 5000000),
		?assertEqual(Ops, ets:info(Table, size))
	after
		cleanup(Table)
	end.

flush_dirty_perf_smoke_test() ->
	setup_srv(items),
	try
		{ok, Pid} = csTabSrv:start_link(items),
		unlink(Pid),
		wait_until(fun() -> ets:info(items, name) =:= items end),
		Rows = [maps:put(table_name, items, item_row(Id, Id)) || Id <- lists:seq(1, 80)],
		[begin
			ets:insert(items, {maps:get(id, Row), Row, ?cs_update, 8, erlang:system_time(second)}),
			ets:insert(?csKeysTab(items), {maps:get(id, Row)}),
			ets:insert(?csDirtyTab(items), {maps:get(id, Row), ?cs_update})
		end || Row <- Rows],
		Ops = length(Rows),
		{ElapsedUs, ok} = timer:tc(fun() ->
			ok = eCas:flushSync(items)
		end),
		print_perf(flush_dirty, Ops, ElapsedUs, #{db_ops => length(fake_db:ops())}),
		?assert(ElapsedUs < 5000000),
		?assertEqual(0, ets:info(?csDirtyTab(items), size))
	after
		teardown_srv(items)
	end.

setup_plain(Table) ->
	cleanup(Table),
	ets:new(Table, [named_table, set, public, {keypos, 2}]),
	Table.

setup_cache(Table) ->
	cleanup(Table),
	fake_db:reset(),
	persistent_term:put(?csDbMod, fake_db),
	ets:new(Table, [named_table, set, public]),
	DirtyTab = ets:new(undefined, [set, public]),
	persistent_term:put(?DirtyEtsTag(Table), DirtyTab),
	case cacheTabDef:tableCache(Table) of
		#tbCache{type = hotData} ->
			KeysTab = ets:new(undefined, [set, public]),
			persistent_term:put(?KeysEtsTag(Table), KeysTab);
		_ ->
			ok
	end,
	Table.

setup_srv(Table) ->
	stop_if_running(Table),
	cleanup(Table),
	fake_db:reset(),
	persistent_term:put(?csDbMod, fake_db),
	ok.

teardown_srv(Table) ->
	stop_if_running(Table),
	cleanup(Table),
	ok.

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

wait_until(Fun) ->
	wait_until(Fun, 50).

wait_until(Fun, 0) ->
	?assert(Fun());
wait_until(Fun, Left) ->
	case Fun() of
		true -> ok;
		false -> timer:sleep(20), wait_until(Fun, Left - 1)
	end.

item_row(Id, Count) ->
	#{id => Id, player_id => 7, item_type => sword, count => Count, attrs => #{}, updated_at => <<>>}.

print_perf(Name, Ops, ElapsedUs) ->
	print_perf(Name, Ops, ElapsedUs, #{}).

print_perf(Name, Ops, ElapsedUs, Extra) ->
	OpsPerSec =
		case ElapsedUs of
			0 -> Ops;
			_ -> (Ops * 1000000) div ElapsedUs
		end,
	io:format(
		standard_error,
		"~n[perf] ~p ops=~p elapsed_us=~p ops_per_sec=~p extra=~p~n",
		[Name, Ops, ElapsedUs, OpsPerSec, Extra]
	).
