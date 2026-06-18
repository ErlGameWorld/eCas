-module(eCas_txn_eunit).

-include("eCas.hrl").
-include_lib("eunit/include/eunit.hrl").

txn_empty_list_returns_fun_value_test() ->
	?assertEqual(empty_ok, eCas:txn([], fun(_Args, []) -> empty_ok end, undefined)).

txn_args_passed_through_test() ->
	?assertEqual({got_args, my_args}, eCas:txn([], fun(Args, []) -> {got_args, Args} end, my_args)).

txn_none_tab_key_only_locks_and_returns_default_test() ->
	?assertEqual(
		locked,
		eCas:txn({noneTab, player_lock, locked_default}, fun(_Args, Values) ->
			case Values of
				[{{noneTab, player_lock}, locked_default}] -> locked;
				Other -> error({unexpected_txn_values, Other})
			end
		end, undefined)
	).

txn_plain_single_key_reads_default_and_commits_test() ->
	Table = plain_txn_tab,
	setup_plain(Table),
	try
		Ret = eCas:txn({Table, 1, {plain_row, 1, <<"default">>}}, fun(_Args, Values) ->
			?assertEqual([{{Table, 1}, {plain_row, 1, <<"default">>}}], Values),
			{alterTab, committed, [{{Table, 1}, {plain_row, 1, <<"new">>}}]}
		end, undefined),
		?assertEqual(committed, Ret),
		?assertEqual([{plain_row, 1, <<"new">>}], ets:lookup(Table, 1))
	after
		cleanup(Table)
	end.

txn_rejects_plain_key_mismatch_test() ->
	Table = plain_txn_tab,
	setup_plain(Table),
	try
		ets:insert(Table, {plain_row, 1, <<"old">>}),
		mute_error_logger(),
		Ret = eCas:txn({Table, 1}, fun(_Args, _Values) ->
			%% 写入行的主键(2)与锁定的 key(1) 不一致，必须被拒绝
			{alterTab, [{{Table, 1}, {plain_row, 2, <<"bad">>}}]}
		end, undefined),
		?assertEqual({error, {key_mismatch, Table, 1, 2}}, Ret),
		?assertEqual([{plain_row, 1, <<"old">>}], ets:lookup(Table, 1)),
		?assertEqual([], ets:lookup(Table, 2))
	after
		unmute_error_logger(),
		cleanup(Table)
	end.

txn_fun_error_does_not_apply_any_change_test() ->
	setup_cache(items),
	try
		Old = item_row(701, sword, 1),
		New = item_row(701, potion, 9),
		ets:insert(items, {701, Old, ?cs_clean, 0, 11}),
		ets:insert(?csKeysTab(items), {701}),
		mute_error_logger(),
		Ret = eCas:txn({items, 701}, fun(_Args, _Values) ->
			%% Fun 异常时还没进入 alterTab 提交，缓存和 dirty 状态都不能改变
			error({planned_failure, New})
		end, undefined),
		?assertMatch({error, {txn_error, {error, {planned_failure, New}, _}}}, Ret),
		?assertMatch([{701, Old, ?cs_clean, 0, _}], ets:lookup(items, 701)),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 701)),
		?assertEqual([{701}], ets:lookup(?csKeysTab(items), 701))
	after
		unmute_error_logger(),
		cleanup(items)
	end.

txn_commit_failure_rolls_back_all_main_changes_test() ->
	setup_cache(players),
	try
		Old = player_row(801, <<"old">>, 1, 10),
		New = player_row(801, <<"new">>, 2, 20),
		Created = player_row(802, <<"created">>, 1, 0),
		Bad = player_row(803, <<"bad">>, 1, 0),
		ets:insert(players, {801, Old, ?cs_clean, 0, 22}),
		mute_error_logger(),
		Ret = eCas:txn([{players, 801}, {players, 802, Created}], fun(_Args, Values) ->
			?assertEqual([{{players, 801}, Old}, {{players, 802}, Created}], Values),
			{alterTab, [
				{{players, 801}, New},
				{{players, 802}, Bad}
			]}
		end, undefined),
		?assertEqual({error, {key_mismatch, players, 802, 803}}, Ret),
		?assertEqual([{801, Old, ?cs_clean, 0, 22}], ets:lookup(players, 801)),
		?assertEqual([], ets:lookup(players, 802))
	after
		unmute_error_logger(),
		cleanup(players)
	end.

txn_multitable_commit_updates_all_state_test() ->
	PlainTab = plain_txn_multi_tab,
	setup_plain(PlainTab),
	setup_cache(players),
	setup_cache(items),
	try
		PlainOld = {plain_row, 1, <<"old">>},
		PlainNew = {plain_row, 1, <<"new">>},
		PlayerOld = player_row(901, <<"pold">>, 1, 10),
		PlayerNew = player_row(901, <<"pnew">>, 2, 20),
		ItemOld = item_row(902, sword, 1),
		ItemNew = ItemOld#{count => 7, attrs => #{rune => 1}},
		ets:insert(PlainTab, PlainOld),
		ets:insert(players, {901, PlayerOld, ?cs_clean, 0, 0}),
		ets:insert(items, {902, ItemOld, ?cs_clean, 0, 0}),
		ets:insert(?csKeysTab(items), {902}),
		Ret = eCas:txn([{PlainTab, 1}, {players, 901}, {items, 902}], fun(multitable, Values) ->
			?assertEqual([
				{{PlainTab, 1}, PlainOld},
				{{players, 901}, PlayerOld},
				{{items, 902}, ItemOld}
			], Values),
			{alterTab, committed, [
				{{PlainTab, 1}, PlainNew},
				{{players, 901}, PlayerNew},
				{{items, 902}, ItemNew}
			]}
		end, multitable),
		?assertEqual(committed, Ret),
		?assertEqual([PlainNew], ets:lookup(PlainTab, 1)),
		?assertMatch([{901, PlayerNew, ?cs_update, 0, _}], ets:lookup(players, 901)),
		?assertEqual([{901, ?cs_update}], ets:lookup(?csDirtyTab(players), 901)),
		[ItemStored] = ets:lookup(items, 902),
		?assertEqual(?cs_update, element(?csDirtyStatePos, ItemStored)),
		?assert(element(?csDirtyMask, ItemStored) band 8 =:= 8),
		?assert(element(?csDirtyMask, ItemStored) band 16 =:= 16),
		?assertEqual([{902, ?cs_update}], ets:lookup(?csDirtyTab(items), 902))
	after
		cleanup(PlainTab),
		cleanup(players),
		cleanup(items)
	end.

txn_none_tab_alter_is_ignored_test() ->
	?assertEqual(ok, eCas:txn({noneTab, only_lock, locked}, fun(_Args, Values) ->
		case Values of
			[{{noneTab, only_lock}, locked}] -> ok;
			Other -> error({unexpected_txn_values, Other})
		end,
		{alterTab, [{{noneTab, only_lock}, should_ignore}]}
	end, undefined)).

txn_hotdata_read_hit_refreshes_access_time_test() ->
	setup_cache(items),
	try
		Row = item_row(1001, sword, 1),
		OldAccessTime = erlang:monotonic_time(second) - 100,
		ets:insert(items, {1001, Row, ?cs_clean, 0, OldAccessTime}),
		ets:insert(?csKeysTab(items), {1001}),
		Ret = eCas:txn({items, 1001}, fun(_Args, Values) ->
			?assertEqual([{{items, 1001}, Row}], Values),
			read_ok
		end, undefined),
		?assertEqual(read_ok, Ret),
		[{1001, Row, ?cs_clean, 0, NewAccessTime}] = ets:lookup(items, 1001),
		?assert(NewAccessTime > OldAccessTime)
	after
		cleanup(items)
	end.

txn_rejects_alter_key_not_locked_test() ->
	setup_cache(players),
	try
		Row = player_row(2, <<"other">>, 1, 0),
		Ret = eCas:txn({players, 1}, fun(_Args, _Values) ->
			{alterTab, [{{players, 2}, Row}]}
		end, undefined),
		?assertEqual({error, {txn_alter_key_not_locked, {players, 2}}}, Ret),
		?assertEqual([], ets:lookup(players, 2))
	after
		cleanup(players)
	end.

txn_allows_duplicate_alter_key_test() ->
	setup_cache(players),
	try
		Row1 = player_row(1, <<"a">>, 1, 0),
		Row2 = player_row(1, <<"b">>, 2, 0),
		Ret = eCas:txn({players, 1}, fun(_Args, _Values) ->
			{alterTab, [{{players, 1}, Row1}, {{players, 1}, Row2}]}
		end, undefined),
		?assertEqual(ok, Ret),
		?assertMatch([{1, Row2, ?cs_new, 0, _}], ets:lookup(players, 1))
	after
		cleanup(players)
	end.

txn_whole_reads_hit_and_default_for_miss_test() ->
	setup_cache(players),
	try
		Row1 = player_row(1, <<"hit">>, 10, 100),
		Row2 = player_row(2, <<"default">>, 1, 0),
		ets:insert(players, {1, Row1, ?cs_clean, 0, 0}),
		Ret = eCas:txn([{players, 1}, {players, 2, Row2}], fun(_Args, Values) ->
			?assertEqual([{{players, 1}, Row1}, {{players, 2}, Row2}], Values),
			read_ok
		end, undefined),
		?assertEqual(read_ok, Ret)
	after
		cleanup(players)
	end.

txn_hotdata_reads_main_cache_db_and_default_test() ->
	setup_cache(items),
	try
		Row101 = item_row(101, sword, 1),
		Row102 = item_row(102, potion, 2),
		Row103 = item_row(103, shield, 3),
		ets:insert(items, {101, Row101, ?cs_clean, 0, 0}),
		ets:insert(?csKeysTab(items), {101}),
		ets:insert(?csKeysTab(items), {102}),
		fake_db:seed(items, [maps:put(table_name, items, Row102)]),
		Ret = eCas:txn([{items, 101}, {items, 102}, {items, 103, Row103}], fun(_Args, Values) ->
			?assertEqual([{{items, 101}, Row101}, {{items, 102}, Row102}, {{items, 103}, Row103}], Values),
			read_ok
		end, undefined),
		?assertEqual(read_ok, Ret),
		?assertMatch([{102, Row102, ?cs_clean, 0, _}], ets:lookup(items, 102))
	after
		cleanup(items)
	end.

txn_dirty_update_tracks_changed_fields_test() ->
	setup_cache(items),
	try
		Old = item_row(201, sword, 1),
		New = Old#{count => 5, attrs => #{gem => 1}},
		ets:insert(items, {201, Old, ?cs_clean, 0, 0}),
		ets:insert(?csKeysTab(items), {201}),
		ok = eCas:txn({items, 201}, fun(_Args, _Values) ->
			{alterTab, [{{items, 201}, New}]}
		end, undefined),
		[Stored] = ets:lookup(items, 201),
		DirtyMask = element(?csDirtyMask, Stored),
		?assertEqual(?cs_update, element(?csDirtyStatePos, Stored)),
		?assert(DirtyMask band 8 =:= 8),
		?assert(DirtyMask band 16 =:= 16),
		?assertEqual([{201, ?cs_update}], ets:lookup(?csDirtyTab(items), 201))
	after
		cleanup(items)
	end.

txn_hotdata_default_commit_creates_key_and_dirty_new_test() ->
	setup_cache(items),
	try
		Row = item_row(301, sword, 1),
		ok = eCas:txn({items, 301, Row}, fun(_Args, Values) ->
			?assertEqual([{{items, 301}, Row}], Values),
			{alterTab, [{{items, 301}, Row}]}
		end, undefined),
		?assertMatch([{301, Row, ?cs_new, 0, _}], ets:lookup(items, 301)),
		?assertEqual([{301}], ets:lookup(?csKeysTab(items), 301)),
		?assertEqual([{301, ?cs_new}], ets:lookup(?csDirtyTab(items), 301))
	after
		cleanup(items)
	end.

txn_hotdata_delete_existing_marks_del_test() ->
	setup_cache(items),
	try
		Row = item_row(401, sword, 1),
		ets:insert(items, {401, Row, ?cs_clean, 0, 0}),
		ets:insert(?csKeysTab(items), {401}),
		ok = eCas:txn({items, 401}, fun(_Args, _Values) ->
			{alterTab, [{{items, 401}, del}]}
		end, undefined),
		?assertEqual([], ets:lookup(items, 401)),
		?assertEqual([], ets:lookup(?csKeysTab(items), 401)),
		?assertEqual([{401, ?cs_del}], ets:lookup(?csDirtyTab(items), 401))
	after
		cleanup(items)
	end.

txn_delete_new_whole_row_clears_dirty_test() ->
	setup_cache(players),
	try
		Row = player_row(501, <<"new">>, 1, 0),
		ets:insert(players, {501, Row, ?cs_new, 0, 0}),
		ets:insert(?csDirtyTab(players), {501, ?cs_new}),
		ok = eCas:txn({players, 501}, fun(_Args, _Values) ->
			{alterTab, [{{players, 501}, del}]}
		end, undefined),
		?assertEqual([], ets:lookup(players, 501)),
		?assertEqual([], ets:lookup(?csDirtyTab(players), 501))
	after
		cleanup(players)
	end.

txn_delete_new_hotdata_row_clears_keys_and_dirty_test() ->
	setup_cache(items),
	try
		Row = item_row(1101, sword, 1),
		ets:insert(items, {1101, Row, ?cs_new, 0, 0}),
		ets:insert(?csKeysTab(items), {1101}),
		ets:insert(?csDirtyTab(items), {1101, ?cs_new}),
		ok = eCas:txn({items, 1101}, fun(_Args, _Values) ->
			{alterTab, [{{items, 1101}, del}]}
		end, undefined),
		?assertEqual([], ets:lookup(items, 1101)),
		?assertEqual([], ets:lookup(?csKeysTab(items), 1101)),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 1101))
	after
		cleanup(items)
	end.

txn_delete_missing_hotdata_without_key_is_noop_test() ->
	setup_cache(items),
	try
		ok = eCas:txn({items, 1201}, fun(_Args, Values) ->
			?assertEqual([{{items, 1201}, undefined}], Values),
			{alterTab, [{{items, 1201}, del}]}
		end, undefined),
		?assertEqual([], ets:lookup(items, 1201)),
		?assertEqual([], ets:lookup(?csKeysTab(items), 1201)),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 1201))
	after
		cleanup(items)
	end.

txn_rollback_restores_dirty_update_after_later_failure_test() ->
	setup_cache(items),
	try
		Old = item_row(1301, sword, 1),
		New = Old#{count => 9, attrs => #{rollback => true}},
		Bad = item_row(9999, potion, 1),
		OldRow = {1301, Old, ?cs_update, 8, 123},
		ets:insert(items, OldRow),
		ets:insert(?csKeysTab(items), {1301}),
		ets:insert(?csDirtyTab(items), {1301, ?cs_update}),
		Ret = eCas:txn([{items, 1301}, {items, 1302}], fun(_Args, _Values) ->
			{alterTab, [
				{{items, 1301}, New},
				{{items, 1302}, Bad}
			]}
		end, undefined),
		?assertEqual({error, {key_mismatch, items, 1302, 9999}}, Ret),
		?assertEqual([OldRow], ets:lookup(items, 1301)),
		?assertEqual([{1301}], ets:lookup(?csKeysTab(items), 1301)),
		?assertEqual([{1301, ?cs_update}], ets:lookup(?csDirtyTab(items), 1301)),
		?assertEqual([], ets:lookup(items, 1302)),
		?assertEqual([], ets:lookup(?csKeysTab(items), 1302)),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 1302))
	after
		cleanup(items)
	end.

txn_rollback_restores_create_old_dirty_after_later_failure_test() ->
	setup_cache(items),
	try
		Created = item_row(1401, sword, 1),
		Bad = item_row(9999, potion, 1),
		ets:insert(?csDirtyTab(items), {1401, ?cs_del}),
		Ret = eCas:txn({items, 1402}, fun(_Args, _Values) ->
			{alterTab, [
				{{items, 1401}, new, Created},
				{{items, 1402}, Bad}
			]}
		end, undefined),
		?assertEqual({error, {key_mismatch, items, 1402, 9999}}, Ret),
		?assertEqual([], ets:lookup(items, 1401)),
		?assertEqual([], ets:lookup(?csKeysTab(items), 1401)),
		?assertEqual([{1401, ?cs_del}], ets:lookup(?csDirtyTab(items), 1401)),
		?assertEqual([], ets:lookup(items, 1402)),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 1402))
	after
		cleanup(items)
	end.

txn_rollback_restores_hotdata_delete_after_later_failure_test() ->
	setup_cache(items),
	try
		Old = item_row(1501, sword, 1),
		Bad = item_row(9999, potion, 1),
		OldRow = {1501, Old, ?cs_update, 8, 321},
		ets:insert(items, OldRow),
		ets:insert(?csKeysTab(items), {1501}),
		ets:insert(?csDirtyTab(items), {1501, ?cs_update}),
		Ret = eCas:txn([{items, 1501}, {items, 1502}], fun(_Args, _Values) ->
			{alterTab, [
				{{items, 1501}, del},
				{{items, 1502}, Bad}
			]}
		end, undefined),
		?assertEqual({error, {key_mismatch, items, 1502, 9999}}, Ret),
		?assertEqual([OldRow], ets:lookup(items, 1501)),
		?assertEqual([{1501}], ets:lookup(?csKeysTab(items), 1501)),
		?assertEqual([{1501, ?cs_update}], ets:lookup(?csDirtyTab(items), 1501)),
		?assertEqual([], ets:lookup(items, 1502)),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 1502))
	after
		cleanup(items)
	end.

txn_rollback_restores_whole_delete_after_later_failure_test() ->
	setup_cache(players),
	try
		Old = player_row(1601, <<"old">>, 1, 10),
		Bad = player_row(9999, <<"bad">>, 1, 0),
		OldRow = {1601, Old, ?cs_clean, 0, 456},
		ets:insert(players, OldRow),
		Ret = eCas:txn([{players, 1601}, {players, 1602}], fun(_Args, _Values) ->
			{alterTab, [
				{{players, 1601}, del},
				{{players, 1602}, Bad}
			]}
		end, undefined),
		?assertEqual({error, {key_mismatch, players, 1602, 9999}}, Ret),
		?assertEqual([OldRow], ets:lookup(players, 1601)),
		?assertEqual([], ets:lookup(?csDirtyTab(players), 1601)),
		?assertEqual([], ets:lookup(players, 1602)),
		?assertEqual([], ets:lookup(?csDirtyTab(players), 1602))
	after
		cleanup(players)
	end.

txn_new_create_failure_leaves_existing_key_state_unchanged_test() ->
	setup_cache(items),
	try
		Row = item_row(1701, sword, 1),
		ets:insert(?csKeysTab(items), {1701}),
		Ret = eCas:txn([], fun(_Args, _Values) ->
			{alterTab, [{{items, 1701}, new, Row}]}
		end, undefined),
		?assertEqual({error, {create_failed, items, 1701}}, Ret),
		?assertEqual([], ets:lookup(items, 1701)),
		?assertEqual([{1701}], ets:lookup(?csKeysTab(items), 1701)),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 1701))
	after
		cleanup(items)
	end.

txn_new_key_mismatch_leaves_no_dirty_state_test() ->
	setup_cache(items),
	try
		Bad = item_row(9999, sword, 1),
		Ret = eCas:txn([], fun(_Args, _Values) ->
			{alterTab, [{{items, 1702}, new, Bad}]}
		end, undefined),
		?assertEqual({error, {key_mismatch, items, 1702, 9999}}, Ret),
		?assertEqual([], ets:lookup(items, 1702)),
		?assertEqual([], ets:lookup(?csKeysTab(items), 1702)),
		?assertEqual([], ets:lookup(?csDirtyTab(items), 1702))
	after
		cleanup(items)
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

setup_cache_without_dirty(Table) ->
	cleanup(Table),
	fake_db:reset(),
	persistent_term:put(?csDbMod, fake_db),
	ets:new(Table, [named_table, set, public]),
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

mute_error_logger() ->
	error_logger:tty(false).

unmute_error_logger() ->
	error_logger:tty(true).

player_row(Id, Account, Level, Gold) ->
	#{id => Id, account => Account, level => Level, gold => Gold, profile => #{}, created_at => <<>>}.

item_row(Id, Type, Count) ->
	#{id => Id, player_id => 7, item_type => Type, count => Count, attrs => #{}, updated_at => <<>>}.
