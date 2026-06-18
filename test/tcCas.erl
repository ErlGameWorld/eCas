-module(tcCas).

-export([
	tcall/0,
	tcall/1,
	tlock/0,
	tlock/1,
	ttxn2/0,
	ttxn4/0,
	ttxn8/0,
	ttxn16/0,
	ttxn32/0,
	ttxn64/0,
	ttxn128/0,
	setup/0,
	prepare/1,
	cleanup/0
]).

-include("eCas.hrl").

-define(TABLE, session_snapshots).
-define(DEFAULT_LOOP, 10000).
-define(KEY_COUNTS, [2, 4, 8, 16, 32, 64, 128]).
-define(PROCESS_COUNTS, [2, 4, 8, 16, 32, 64, 128, 256, 512]).

tcall() ->
	tcall(false).

tcall(IsFile) ->
	setup(),
	{{Y, M, D}, {H, Mi, _}} = calendar:local_time(),
	FileName = lists:flatten(io_lib:format("tcCas_txn_~4..0B~2..0B~2..0B_~2..0B~2..0B.txt", [Y, M, D, H, Mi])),
	IsFile andalso utTc:toFile(FileName),
	try
		tlock(),
		[tlock(ProcCnt) || ProcCnt <- ?PROCESS_COUNTS],
		ok
	after
		IsFile andalso utTc:toShell(),
		cleanup()
	end.

tlock() ->
	io:format("~n========== eCas txn hotData lock tests ==========~n"),
	run_single(?DEFAULT_LOOP, ttxn2, 2),
	run_single(?DEFAULT_LOOP, ttxn4, 4),
	run_single(?DEFAULT_LOOP, ttxn8, 8),
	run_single(?DEFAULT_LOOP, ttxn16, 16),
	run_single(?DEFAULT_LOOP, ttxn32, 32),
	run_single(?DEFAULT_LOOP, ttxn64, 64),
	run_single(?DEFAULT_LOOP, ttxn128, 128),
	ok.

tlock(ProcCnt) ->
	io:format("~n========== eCas txn hotData lock tests ProcCnt=~p ==========~n", [ProcCnt]),
	run_multi(ProcCnt, ?DEFAULT_LOOP, ttxn2, 2),
	run_multi(ProcCnt, ?DEFAULT_LOOP, ttxn4, 4),
	run_multi(ProcCnt, ?DEFAULT_LOOP, ttxn8, 8),
	run_multi(ProcCnt, ?DEFAULT_LOOP, ttxn16, 16),
	run_multi(ProcCnt, ?DEFAULT_LOOP, ttxn32, 32),
	run_multi(ProcCnt, ?DEFAULT_LOOP, ttxn64, 64),
	run_multi(ProcCnt, ?DEFAULT_LOOP, ttxn128, 128),
	ok.

run_single(LoopTime, Fun, KeyCnt) ->
	prepare(KeyCnt),
	utTc:tc(LoopTime, ?MODULE, Fun, []).

run_multi(ProcCnt, LoopTime, Fun, KeyCnt) ->
	prepare(KeyCnt),
	utTc:tc(ProcCnt, LoopTime, ?MODULE, Fun, []).

ttxn2() ->
	Keys = [{?TABLE, 1}, {?TABLE, 2}],
	ok = eCas:txn(Keys, fun txn_update/2, [], infinity).

ttxn4() ->
	Keys = [{?TABLE, 1}, {?TABLE, 2}, {?TABLE, 3}, {?TABLE, 4}],
	ok = eCas:txn(Keys, fun txn_update/2, [], infinity).

ttxn8() ->
	Keys = [
		{?TABLE, 1}, {?TABLE, 2}, {?TABLE, 3}, {?TABLE, 4},
		{?TABLE, 5}, {?TABLE, 6}, {?TABLE, 7}, {?TABLE, 8}
	],
	ok = eCas:txn(Keys, fun txn_update/2, [], infinity).

ttxn16() ->
	Keys = [
		{?TABLE, 1}, {?TABLE, 2}, {?TABLE, 3}, {?TABLE, 4},
		{?TABLE, 5}, {?TABLE, 6}, {?TABLE, 7}, {?TABLE, 8},
		{?TABLE, 9}, {?TABLE, 10}, {?TABLE, 11}, {?TABLE, 12},
		{?TABLE, 13}, {?TABLE, 14}, {?TABLE, 15}, {?TABLE, 16}
	],
	ok = eCas:txn(Keys, fun txn_update/2, [], infinity).

ttxn32() ->
	Keys = [
		{?TABLE, 1}, {?TABLE, 2}, {?TABLE, 3}, {?TABLE, 4},
		{?TABLE, 5}, {?TABLE, 6}, {?TABLE, 7}, {?TABLE, 8},
		{?TABLE, 9}, {?TABLE, 10}, {?TABLE, 11}, {?TABLE, 12},
		{?TABLE, 13}, {?TABLE, 14}, {?TABLE, 15}, {?TABLE, 16},
		{?TABLE, 17}, {?TABLE, 18}, {?TABLE, 19}, {?TABLE, 20},
		{?TABLE, 21}, {?TABLE, 22}, {?TABLE, 23}, {?TABLE, 24},
		{?TABLE, 25}, {?TABLE, 26}, {?TABLE, 27}, {?TABLE, 28},
		{?TABLE, 29}, {?TABLE, 30}, {?TABLE, 31}, {?TABLE, 32}
	],
	ok = eCas:txn(Keys, fun txn_update/2, [], infinity).

ttxn64() ->
	Keys = [
		{?TABLE, 1}, {?TABLE, 2}, {?TABLE, 3}, {?TABLE, 4},
		{?TABLE, 5}, {?TABLE, 6}, {?TABLE, 7}, {?TABLE, 8},
		{?TABLE, 9}, {?TABLE, 10}, {?TABLE, 11}, {?TABLE, 12},
		{?TABLE, 13}, {?TABLE, 14}, {?TABLE, 15}, {?TABLE, 16},
		{?TABLE, 17}, {?TABLE, 18}, {?TABLE, 19}, {?TABLE, 20},
		{?TABLE, 21}, {?TABLE, 22}, {?TABLE, 23}, {?TABLE, 24},
		{?TABLE, 25}, {?TABLE, 26}, {?TABLE, 27}, {?TABLE, 28},
		{?TABLE, 29}, {?TABLE, 30}, {?TABLE, 31}, {?TABLE, 32},
		{?TABLE, 33}, {?TABLE, 34}, {?TABLE, 35}, {?TABLE, 36},
		{?TABLE, 37}, {?TABLE, 38}, {?TABLE, 39}, {?TABLE, 40},
		{?TABLE, 41}, {?TABLE, 42}, {?TABLE, 43}, {?TABLE, 44},
		{?TABLE, 45}, {?TABLE, 46}, {?TABLE, 47}, {?TABLE, 48},
		{?TABLE, 49}, {?TABLE, 50}, {?TABLE, 51}, {?TABLE, 52},
		{?TABLE, 53}, {?TABLE, 54}, {?TABLE, 55}, {?TABLE, 56},
		{?TABLE, 57}, {?TABLE, 58}, {?TABLE, 59}, {?TABLE, 60},
		{?TABLE, 61}, {?TABLE, 62}, {?TABLE, 63}, {?TABLE, 64}
	],
	ok = eCas:txn(Keys, fun txn_update/2, [], infinity).

ttxn128() ->
	Keys = [
		{?TABLE, 1}, {?TABLE, 2}, {?TABLE, 3}, {?TABLE, 4},
		{?TABLE, 5}, {?TABLE, 6}, {?TABLE, 7}, {?TABLE, 8},
		{?TABLE, 9}, {?TABLE, 10}, {?TABLE, 11}, {?TABLE, 12},
		{?TABLE, 13}, {?TABLE, 14}, {?TABLE, 15}, {?TABLE, 16},
		{?TABLE, 17}, {?TABLE, 18}, {?TABLE, 19}, {?TABLE, 20},
		{?TABLE, 21}, {?TABLE, 22}, {?TABLE, 23}, {?TABLE, 24},
		{?TABLE, 25}, {?TABLE, 26}, {?TABLE, 27}, {?TABLE, 28},
		{?TABLE, 29}, {?TABLE, 30}, {?TABLE, 31}, {?TABLE, 32},
		{?TABLE, 33}, {?TABLE, 34}, {?TABLE, 35}, {?TABLE, 36},
		{?TABLE, 37}, {?TABLE, 38}, {?TABLE, 39}, {?TABLE, 40},
		{?TABLE, 41}, {?TABLE, 42}, {?TABLE, 43}, {?TABLE, 44},
		{?TABLE, 45}, {?TABLE, 46}, {?TABLE, 47}, {?TABLE, 48},
		{?TABLE, 49}, {?TABLE, 50}, {?TABLE, 51}, {?TABLE, 52},
		{?TABLE, 53}, {?TABLE, 54}, {?TABLE, 55}, {?TABLE, 56},
		{?TABLE, 57}, {?TABLE, 58}, {?TABLE, 59}, {?TABLE, 60},
		{?TABLE, 61}, {?TABLE, 62}, {?TABLE, 63}, {?TABLE, 64},
		{?TABLE, 65}, {?TABLE, 66}, {?TABLE, 67}, {?TABLE, 68},
		{?TABLE, 69}, {?TABLE, 70}, {?TABLE, 71}, {?TABLE, 72},
		{?TABLE, 73}, {?TABLE, 74}, {?TABLE, 75}, {?TABLE, 76},
		{?TABLE, 77}, {?TABLE, 78}, {?TABLE, 79}, {?TABLE, 80},
		{?TABLE, 81}, {?TABLE, 82}, {?TABLE, 83}, {?TABLE, 84},
		{?TABLE, 85}, {?TABLE, 86}, {?TABLE, 87}, {?TABLE, 88},
		{?TABLE, 89}, {?TABLE, 90}, {?TABLE, 91}, {?TABLE, 92},
		{?TABLE, 93}, {?TABLE, 94}, {?TABLE, 95}, {?TABLE, 96},
		{?TABLE, 97}, {?TABLE, 98}, {?TABLE, 99}, {?TABLE, 100},
		{?TABLE, 101}, {?TABLE, 102}, {?TABLE, 103}, {?TABLE, 104},
		{?TABLE, 105}, {?TABLE, 106}, {?TABLE, 107}, {?TABLE, 108},
		{?TABLE, 109}, {?TABLE, 110}, {?TABLE, 111}, {?TABLE, 112},
		{?TABLE, 113}, {?TABLE, 114}, {?TABLE, 115}, {?TABLE, 116},
		{?TABLE, 117}, {?TABLE, 118}, {?TABLE, 119}, {?TABLE, 120},
		{?TABLE, 121}, {?TABLE, 122}, {?TABLE, 123}, {?TABLE, 124},
		{?TABLE, 125}, {?TABLE, 126}, {?TABLE, 127}, {?TABLE, 128}
	],
	ok = eCas:txn(Keys, fun txn_update/2, [], infinity).

txn_update(_Args, TxnValues) ->
	AlterTab = [{{?TABLE, Key}, bump_count(Row)} || {{?TABLE, Key}, Row} <- TxnValues],
	{alterTab, AlterTab}.

bump_count({session_snapshot, Id, PlayerId, DirtyFlag, Online, Payload, HeartbeatAt}) ->
	{session_snapshot, Id, PlayerId, DirtyFlag + 1, Online, Payload, HeartbeatAt}.

setup() ->
	ensure_ecas_started(),
	cleanup(),
	fake_db:reset(),
	persistent_term:put(?csDbMod, fake_db),
	ets:new(?TABLE, [named_table, set, public]),
	DirtyTab = ets:new(undefined, [set, public]),
	KeysTab = ets:new(undefined, [set, public]),
	persistent_term:put(?DirtyEtsTag(?TABLE), DirtyTab),
	persistent_term:put(?KeysEtsTag(?TABLE), KeysTab),
	ok.

prepare(KeyCnt) ->
	ensure_setup(),
	ets:delete_all_objects(?TABLE),
	ets:delete_all_objects(?csDirtyTab(?TABLE)),
	ets:delete_all_objects(?csKeysTab(?TABLE)),
	[insert_clean_row(Id) || Id <- lists:seq(1, KeyCnt)],
	ok.

insert_clean_row(Id) ->
	Row = item_row(Id, 1),
	ets:insert(?TABLE, ?cacheValue(Id, Row, ?cs_clean, 0, 0)),
	ets:insert(?csKeysTab(?TABLE), {Id}).

ensure_setup() ->
	case ets:info(?TABLE, name) of
		undefined -> setup();
		_ -> ok
	end.

cleanup() ->
	maybe_delete(?TABLE),
	case persistent_term:get(?DirtyEtsTag(?TABLE), undefined) of
		undefined -> ok;
		DirtyTab -> try ets:delete(DirtyTab) catch _:_ -> ok end
	end,
	case persistent_term:get(?KeysEtsTag(?TABLE), undefined) of
		undefined -> ok;
		KeysTab -> try ets:delete(KeysTab) catch _:_ -> ok end
	end,
	persistent_term:erase(?csDbMod),
	persistent_term:erase(?DirtyEtsTag(?TABLE)),
	persistent_term:erase(?KeysEtsTag(?TABLE)),
	ok.

maybe_delete(Name) ->
	case ets:info(Name, name) of
		undefined -> ok;
		_ -> ets:delete(Name)
	end.

ensure_ecas_started() ->
	case application:ensure_all_started(eCas) of
		{ok, _} -> ok;
		{error, {already_started, _}} -> ok;
		{error, {App, {already_started, _}}} when is_atom(App) -> ok;
		{error, Reason} -> error({cannot_start_ecas, Reason})
	end.

item_row(Id, DirtyFlag) ->
	{session_snapshot, Id, 7, DirtyFlag, true, <<>>, 0}.
