-module(field_diff_bench).

-include_lib("eunit/include/eunit.hrl").

-export([
	run/0,
	run/1,
	run_baseline/0,
	run_baseline/1,
	run_ecas/0,
	run_ecas/1,
	run_case/3,
	diff_tuple_fields/2,
	diff_map_fields/2,
	diff_map_fields/3
]).

-define(DEFAULT_SIZES, [8, 16, 32, 64, 128, 256]).
-define(DEFAULT_ITERATIONS, 20000).
-define(DEFAULT_MAX_CHANGE_COUNT, 8).

run() ->
	run(#{}).

run(Opts) when is_list(Opts) ->
	run(maps:from_list(Opts));
run(Opts) when is_map(Opts) ->
	#{
		baseline => run_baseline(Opts),
		ecas => run_ecas(Opts)
	}.

run_baseline() ->
	run_baseline(#{}).

run_baseline(Opts) when is_list(Opts) ->
	run_baseline(maps:from_list(Opts));
run_baseline(Opts) when is_map(Opts) ->
	seed_rand(),
	Sizes = maps:get(sizes, Opts, ?DEFAULT_SIZES),
	Iterations = maps:get(iterations, Opts, ?DEFAULT_ITERATIONS),
	io:format("baseline field diff benchmark: iterations=~w opts=~w~n", [Iterations, Opts]),
	Results = [run_case(Size, Iterations, Opts) || Size <- Sizes],
	print_summary(Results),
	Results.

run_ecas() ->
	run_ecas(#{}).

run_ecas(Opts) when is_list(Opts) ->
	run_ecas(maps:from_list(Opts));
run_ecas(Opts) when is_map(Opts) ->
	seed_rand(),
	Iterations = maps:get(iterations, Opts, ?DEFAULT_ITERATIONS),
	io:format("eCas diffDirtyMask benchmark: iterations=~w opts=~w~n", [Iterations, Opts]),
	Results = [
		run_ecas_case(ecas_items_map, Iterations, Opts),
		run_ecas_case(ecas_session_tuple, Iterations, Opts)
	],
	print_ecas_summary(Results),
	Results.

run_case(Size, Iterations, Opts) when is_integer(Size), Size > 0 ->
	Verify = maps:get(verify, Opts, true),
	TupleBase = build_tuple(Size),
	MapBase = build_map(Size),
	MapKeys = lists:seq(1, Size),
	#{
		size => Size,
		tuple => benchmark(tuple, TupleBase, Size, Iterations, Verify, Opts),
		map => benchmark(map, {MapKeys, MapBase}, Size, Iterations, Verify, Opts)
	}.

benchmark(tuple, Base, Size, Iterations, Verify, Opts) ->
	WallStartNs = erlang:monotonic_time(nanosecond),
	{DiffNs, ChangedTotal} = bench_loop(tuple, Base, Size, Iterations, Verify, Opts, 1, 0, 0),
	build_bench_result(Iterations, DiffNs, erlang:monotonic_time(nanosecond) - WallStartNs, ChangedTotal);
benchmark(map, {MapKeys, Base}, Size, Iterations, Verify, Opts) ->
	WallStartNs = erlang:monotonic_time(nanosecond),
	{DiffNs, ChangedTotal} = bench_loop(map, {MapKeys, Base}, Size, Iterations, Verify, Opts, 1, 0, 0),
	build_bench_result(Iterations, DiffNs, erlang:monotonic_time(nanosecond) - WallStartNs, ChangedTotal).

run_ecas_case(ecas_items_map, Iterations, Opts) ->
	Base = items_map_base(),
	Fields = [id, player_id, item_type, count, attrs, updated_at],
	benchmark_ecas(ecas_items_map, items, Base, Fields, Iterations, Opts);
run_ecas_case(ecas_session_tuple, Iterations, Opts) ->
	Base = session_tuple_base(),
	Fields = [id, player_id, dirty_flag, online, payload, heartbeat_at],
	benchmark_ecas(ecas_session_tuple, session_snapshots, Base, Fields, Iterations, Opts).

benchmark_ecas(Name, Table, Base, Fields, Iterations, Opts) ->
	Verify = maps:get(verify, Opts, true),
	WallStartNs = erlang:monotonic_time(nanosecond),
	{DiffNs, ChangedTotal} = ecas_bench_loop(Table, Base, Fields, Iterations, Verify, Opts, 1, 0, 0),
	build_ecas_bench_result(Name, Table, Iterations, DiffNs, erlang:monotonic_time(nanosecond) - WallStartNs, ChangedTotal).

build_ecas_bench_result(Name, Table, Iterations, DiffNs, WallNs, ChangedTotal) ->
	Base = build_bench_result(Iterations, DiffNs, WallNs, ChangedTotal),
	Base#{name => Name, table => Table}.

build_bench_result(Iterations, DiffNs, WallNs, ChangedTotal) ->
	SafeIterations = max(1, Iterations),
	#{
		iterations => Iterations,
		diff_total_us => erlang:convert_time_unit(DiffNs, nanosecond, microsecond),
		wall_total_us => erlang:convert_time_unit(WallNs, nanosecond, microsecond),
		avg_diff_ns => DiffNs div SafeIterations,
		avg_wall_ns => WallNs div SafeIterations,
		avg_changed_fields => ChangedTotal / SafeIterations
	}.

bench_loop(_Type, _Base, _Size, 0, _Verify, _Opts, _Salt, DiffNsAcc, ChangedAcc) ->
	{DiffNsAcc, ChangedAcc};
bench_loop(tuple, Base, Size, Left, Verify, Opts, Salt, DiffNsAcc, ChangedAcc) ->
	ChangeCount = pick_change_count(Size, Opts),
	Positions = random_positions(Size, ChangeCount),
	NewTuple = mutate_tuple(Base, Positions, Salt),
	StartNs = erlang:monotonic_time(nanosecond),
	Changed = diff_tuple_fields(Base, NewTuple),
	EndNs = erlang:monotonic_time(nanosecond),
	maybe_verify(Verify, Positions, Changed, tuple),
	bench_loop(tuple, Base, Size, Left - 1, Verify, Opts, Salt + 1,
		DiffNsAcc + (EndNs - StartNs), ChangedAcc + length(Changed));
bench_loop(map, {MapKeys, Base}, Size, Left, Verify, Opts, Salt, DiffNsAcc, ChangedAcc) ->
	ChangeCount = pick_change_count(Size, Opts),
	Positions = random_positions(Size, ChangeCount),
	NewMap = mutate_map(Base, Positions, Salt),
	StartNs = erlang:monotonic_time(nanosecond),
	Changed = diff_map_fields(MapKeys, Base, NewMap),
	EndNs = erlang:monotonic_time(nanosecond),
	maybe_verify(Verify, Positions, Changed, map),
	bench_loop(map, {MapKeys, Base}, Size, Left - 1, Verify, Opts, Salt + 1,
		DiffNsAcc + (EndNs - StartNs), ChangedAcc + length(Changed)).

ecas_bench_loop(_Table, _Base, _Fields, 0, _Verify, _Opts, _Salt, DiffNsAcc, ChangedAcc) ->
	{DiffNsAcc, ChangedAcc};
ecas_bench_loop(Table, Base, Fields, Left, Verify, Opts, Salt, DiffNsAcc, ChangedAcc) ->
	ChangeCount = pick_change_count(length(Fields), Opts),
	Positions = random_positions(length(Fields), ChangeCount),
	ChangedFields = [lists:nth(Pos, Fields) || Pos <- Positions],
	NewData = mutate_ecas_data(Base, ChangedFields, Salt),
	ExpectedMask = fields_to_mask(Table, ChangedFields),
	StartNs = erlang:monotonic_time(nanosecond),
	Mask = eCas:diffDirtyMask(dirty, Table, Base, NewData, 0),
	EndNs = erlang:monotonic_time(nanosecond),
	maybe_verify_mask(Verify, Table, ExpectedMask, Mask),
	ecas_bench_loop(Table, Base, Fields, Left - 1, Verify, Opts, Salt + 1,
		DiffNsAcc + (EndNs - StartNs), ChangedAcc + length(ChangedFields)).

build_tuple(Size) ->
	list_to_tuple(lists:seq(1, Size)).

build_map(Size) ->
	maps:from_list([{Index, Index} || Index <- lists:seq(1, Size)]).

items_map_base() ->
	#{id => 1, player_id => 7, item_type => sword, count => 1, attrs => #{}, updated_at => <<>>}.

session_tuple_base() ->
	{session_snapshots, 1, 7, 0, false, #{}, <<>>}.

mutate_tuple(Base, Positions, Salt) ->
	lists:foldl(fun(Pos, Acc) ->
		setelement(Pos, Acc, new_value(Pos, Salt))
				end, Base, Positions).

mutate_map(Base, Positions, Salt) ->
	lists:foldl(fun(Pos, Acc) ->
		Acc#{Pos => new_value(Pos, Salt)}
				end, Base, Positions).

mutate_ecas_data(Base, Fields, Salt) when is_map(Base) ->
	lists:foldl(fun(Field, Acc) ->
		Acc#{Field => new_value(erlang:phash2(Field, 1000), Salt)}
				end, Base, Fields);
mutate_ecas_data(Base, Fields, Salt) when is_tuple(Base) ->
	lists:foldl(fun(Field, Acc) ->
		{Index, _BitValue, Field} = lists:keyfind(Field, 3, cacheTabDef:tableFields(session_snapshots)),
		setelement(Index, Acc, new_value(Index, Salt))
				end, Base, Fields).

diff_tuple_fields(OldTuple, NewTuple) when tuple_size(OldTuple) =:= tuple_size(NewTuple) ->
	diff_tuple_fields(1, tuple_size(OldTuple), OldTuple, NewTuple, []).

diff_tuple_fields(Index, Size, _OldTuple, _NewTuple, Acc) when Index > Size ->
	lists:reverse(Acc);
diff_tuple_fields(Index, Size, OldTuple, NewTuple, Acc) ->
	NextAcc =
		case element(Index, OldTuple) =:= element(Index, NewTuple) of
			true -> Acc;
			false -> [Index | Acc]
		end,
	diff_tuple_fields(Index + 1, Size, OldTuple, NewTuple, NextAcc).

diff_map_fields(OldMap, NewMap) ->
	diff_map_fields(maps:keys(OldMap), OldMap, NewMap).

diff_map_fields(Keys, OldMap, NewMap) ->
	[Key || Key <- Keys, maps:get(Key, OldMap, '$missing') =/= maps:get(Key, NewMap, '$missing')].

pick_change_count(Size, Opts) ->
	case maps:get(change_count, Opts, random) of
		random ->
			MaxChangeCount = min(Size, maps:get(max_change_count, Opts, ?DEFAULT_MAX_CHANGE_COUNT)),
			rand:uniform(max(1, MaxChangeCount));
		Count when is_integer(Count), Count > 0 ->
			min(Size, Count)
	end.

random_positions(Size, Count) ->
	random_positions(Size, Count, #{}).

random_positions(_Size, Count, Acc) when map_size(Acc) >= Count ->
	lists:sort(maps:keys(Acc));
random_positions(Size, Count, Acc) ->
	Position = rand:uniform(Size),
	random_positions(Size, Count, Acc#{Position => true}).

new_value(Pos, Salt) ->
	Pos + (Salt bsl 10).

maybe_verify(false, _Expected, _Actual, _Type) ->
	ok;
maybe_verify(true, Expected, Actual, Type) ->
	case Expected =:= Actual of
		true -> ok;
		false -> erlang:error({diff_result_mismatch, Type, Expected, Actual})
	end.

maybe_verify_mask(false, _Table, _ExpectedMask, _ActualMask) ->
	ok;
maybe_verify_mask(true, Table, ExpectedMask, ActualMask) ->
	case ExpectedMask =:= ActualMask of
		true -> ok;
		false ->
			erlang:error({ecas_diff_mask_mismatch, Table, ExpectedMask, ActualMask,
				eCas:dirtyMaskToFields(Table, ExpectedMask), eCas:dirtyMaskToFields(Table, ActualMask)})
	end.

fields_to_mask(Table, Fields) ->
	lists:foldl(fun(Field, MaskAcc) ->
		{_Index, BitValue, Field} = lists:keyfind(Field, 3, cacheTabDef:tableFields(Table)),
		MaskAcc bor BitValue
				end, 0, Fields).

seed_rand() ->
	rand:seed(exsplus, {
		erlang:phash2(node()),
		erlang:unique_integer([positive]),
		erlang:phash2(erlang:monotonic_time())
	}).

print_summary(Results) ->
	io:format("diff_us = only diff function time; total_us = full benchmark loop time~n", []),
	io:format("~nsize | implementation | diff_us   | total_us  | avg_diff_ns | avg_total_ns | avg_changed~n", []),
	io:format("-----+----------------+-----------+-----------+-------------+--------------+------------~n", []),
	lists:foreach(fun print_result/1, Results).

print_result(#{size := Size, tuple := TupleResult, map := MapResult}) ->
	print_line(Size, baseline_tuple, TupleResult),
	print_line(Size, baseline_map, MapResult).

print_line(Size, Type, Result) ->
	io:format("~4w | ~-14w | ~9w | ~9w | ~11w | ~12w | ~10.2f~n", [
		Size,
		Type,
		maps:get(diff_total_us, Result),
		maps:get(wall_total_us, Result),
		maps:get(avg_diff_ns, Result),
		maps:get(avg_wall_ns, Result),
		maps:get(avg_changed_fields, Result)
	]).

print_ecas_summary(Results) ->
	io:format("~neCas diffDirtyMask benchmark (actual eCas implementation)~n", []),
	io:format("diff_us = only eCas:diffDirtyMask/5 time; total_us = full benchmark loop time~n", []),
	io:format("implementation     | table             | diff_us   | total_us  | avg_diff_ns | avg_total_ns | avg_changed~n", []),
	io:format("-------------------+-------------------+-----------+-----------+-------------+--------------+------------~n", []),
	lists:foreach(fun print_ecas_result/1, Results).

print_ecas_result(Result) ->
	io:format("~-18w | ~-17w | ~9w | ~9w | ~11w | ~12w | ~10.2f~n", [
		maps:get(name, Result),
		maps:get(table, Result),
		maps:get(diff_total_us, Result),
		maps:get(wall_total_us, Result),
		maps:get(avg_diff_ns, Result),
		maps:get(avg_wall_ns, Result),
		maps:get(avg_changed_fields, Result)
	]).

ecas_diff_dirty_mask_map_test() ->
	Old = items_map_base(),
	New = Old#{count => 5, attrs => #{gem => 1}},
	Mask = eCas:diffDirtyMask(dirty, items, Old, New, 0),
	?assertEqual(8 bor 16, Mask),
	?assertEqual([count, attrs], eCas:dirtyMaskToFields(items, Mask)).

ecas_diff_dirty_mask_tuple_test() ->
	Old = session_tuple_base(),
	New = setelement(6, setelement(4, Old, 1), #{payload => changed}),
	Mask = eCas:diffDirtyMask(dirty, session_snapshots, Old, New, 0),
	?assertEqual(8 bor 32, Mask),
	?assertEqual([dirty_flag, payload], eCas:dirtyMaskToFields(session_snapshots, Mask)).

ecas_diff_dirty_mask_preserves_old_mask_test() ->
	Old = items_map_base(),
	New = Old#{attrs => #{gem => 1}},
	Mask = eCas:diffDirtyMask(dirty, items, Old, New, 8),
	?assertEqual(8 bor 16, Mask),
	?assertEqual([count, attrs], eCas:dirtyMaskToFields(items, Mask)).
