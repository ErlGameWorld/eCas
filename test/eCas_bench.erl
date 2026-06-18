-module(eCas_bench).

-include("eCas.hrl").

-export([run/0, run/1]).

run() ->
	run(#{}).

run(Opts) when is_list(Opts) ->
	run(maps:from_list(Opts));
run(Opts) when is_map(Opts) ->
	Iterations = maps:get(iterations, Opts, 10000),
	FlushRows = maps:get(flush_rows, Opts, 500),
	Cases = [
		bench_plain_put_get(Iterations),
		bench_txn_plain(Iterations),
		bench_txn_plain_batch(Iterations),
		bench_txn_hotdata(Iterations),
		bench_txn_hotdata_batch(Iterations),
		bench_flush_dirty(FlushRows)
	],
	print(Cases),
	ok.

bench_plain_put_get(Iterations) ->
	Table = bench_plain_tab,
	setup_plain(Table),
	try
		{ElapsedUs, ok} = timer:tc(fun() ->
			lists:foreach(fun(I) ->
				ok = eCas:insert(Table, I, {bench_row, I, I}),
				{ok, {bench_row, I, I}} = eCas:get(Table, I)
			end, lists:seq(1, Iterations))
		end),
		result(plain_put_get, Iterations * 2, ElapsedUs, #{ets_size => ets:info(Table, size)})
	after
		cleanup(Table)
	end.

bench_txn_plain(Iterations) ->
	Table = bench_txn_plain_tab,
	setup_plain(Table),
	try
		{ElapsedUs, ok} = timer:tc(fun() ->
			lists:foreach(fun(I) ->
				ok = eCas:txn({Table, I, {bench_row, I, 0}}, fun(_Args, _Values) ->
					{alterTab, [{{Table, I}, {bench_row, I, I}}]}
				end, undefined)
			end, lists:seq(1, Iterations))
		end),
		result(txn_plain, Iterations, ElapsedUs, #{ets_size => ets:info(Table, size)})
	after
		cleanup(Table)
	end.

bench_txn_plain_batch(Iterations) ->
	Table = bench_txn_plain_batch_tab,
	setup_plain(Table),
	try
		Keys = [{Table, I, {bench_row, I, 0}} || I <- lists:seq(1, Iterations)],
		{ElapsedUs, ok} = timer:tc(fun() ->
			ok = eCas:txn(Keys, fun(_Args, _Values) ->
				{alterTab, [{{Table, I}, {bench_row, I, I}} || I <- lists:seq(1, Iterations)]}
			end, undefined)
		end),
		result(txn_plain_batch, Iterations, ElapsedUs, #{ets_size => ets:info(Table, size)})
	after
		cleanup(Table)
	end.

bench_txn_hotdata(Iterations) ->
	setup_cache(items),
	try
		Rows = [item_row(Id, 1) || Id <- lists:seq(1, Iterations)],
		[begin
			ets:insert(items, {maps:get(id, Row), Row, ?cs_clean, 0, 0}),
			ets:insert(?csKeysTab(items), {maps:get(id, Row)})
		end || Row <- Rows],
		{ElapsedUs, ok} = timer:tc(fun() ->
			lists:foreach(fun(Id) ->
				NewRow = item_row(Id, 2),
				ok = eCas:txn({items, Id}, fun(_Args, _Values) ->
					{alterTab, [{{items, Id}, NewRow}]}
				end, undefined)
			end, lists:seq(1, Iterations))
		end),
		result(txn_hotdata, Iterations, ElapsedUs, #{
			ets_size => ets:info(items, size),
			dirty_size => ets:info(?csDirtyTab(items), size),
			keys_size => ets:info(?csKeysTab(items), size)
		})
	after
		cleanup(items)
	end.

bench_txn_hotdata_batch(Iterations) ->
	setup_cache(items),
	try
		Rows = [item_row(Id, 1) || Id <- lists:seq(1, Iterations)],
		[begin
			ets:insert(items, {maps:get(id, Row), Row, ?cs_clean, 0, 0}),
			ets:insert(?csKeysTab(items), {maps:get(id, Row)})
		end || Row <- Rows],
		Keys = [{items, Id} || Id <- lists:seq(1, Iterations)],
		{ElapsedUs, ok} = timer:tc(fun() ->
			ok = eCas:txn(Keys, fun(_Args, _Values) ->
				{alterTab, [{{items, Id}, item_row(Id, 3)} || Id <- lists:seq(1, Iterations)]}
			end, undefined)
		end),
		result(txn_hotdata_batch, Iterations, ElapsedUs, #{
			ets_size => ets:info(items, size),
			dirty_size => ets:info(?csDirtyTab(items), size),
			keys_size => ets:info(?csKeysTab(items), size)
		})
	after
		cleanup(items)
	end.

bench_flush_dirty(RowCount) ->
	setup_srv(items),
	try
		{ok, Pid} = csTabSrv:start_link(items),
		unlink(Pid),
		wait_until(fun() -> ets:info(items, name) =:= items end),
		Rows = [maps:put(table_name, items, item_row(Id, Id)) || Id <- lists:seq(1, RowCount)],
		[begin
			ets:insert(items, {maps:get(id, Row), Row, ?cs_update, 8, erlang:system_time(second)}),
			ets:insert(?csKeysTab(items), {maps:get(id, Row)}),
			ets:insert(?csDirtyTab(items), {maps:get(id, Row), ?cs_update})
		end || Row <- Rows],
		{ElapsedUs, Ret} = timer:tc(fun() -> flush_until_done(items) end),
		result(flush_dirty, RowCount, ElapsedUs, #{
			flush_result => Ret,
			dirty_size => ets:info(?csDirtyTab(items), size),
			db_ops => length(fake_db:ops())
		})
	after
		teardown_srv(items)
	end.

flush_until_done(Table) ->
	case eCas:flushSync(Table) of
		ok -> ok;
		{error, flushLimit} -> flush_until_done(Table);
		Other -> Other
	end.

result(Name, Ops, ElapsedUs, Extra) ->
	OpsPerSec =
		case ElapsedUs of
			0 -> Ops;
			_ -> (Ops * 1000000) div ElapsedUs
		end,
	Extra#{
		name => Name,
		ops => Ops,
		elapsed_us => ElapsedUs,
		ops_per_sec => OpsPerSec
	}.

print(Results) ->
	io:format("~nname                 ops      elapsed_us   ops_per_sec   extra~n", []),
	io:format("--------------------  -------  -----------  ------------  ------------------------------~n", []),
	[print_one(Result) || Result <- Results],
	ok.

print_one(#{name := Name, ops := Ops, elapsed_us := ElapsedUs, ops_per_sec := OpsPerSec} = Result) ->
	Extra = maps:without([name, ops, elapsed_us, ops_per_sec], Result),
	io:format("~-20w  ~7w  ~11w  ~12w  ~ts~n", [Name, Ops, ElapsedUs, OpsPerSec, format_extra(Extra)]).

format_extra(Extra) ->
	string:join([io_lib:format("~ts=~0p", [Key, Value]) || {Key, Value} <- lists:sort(maps:to_list(Extra))], " ").

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
	case Fun() of
		true -> ok;
		false -> error(wait_timeout)
	end;
wait_until(Fun, Left) ->
	case Fun() of
		true -> ok;
		false -> timer:sleep(20), wait_until(Fun, Left - 1)
	end.

item_row(Id, Count) ->
	#{id => Id, player_id => 7, item_type => sword, count => Count, attrs => #{}, updated_at => <<>>}.
