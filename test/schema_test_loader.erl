-module(schema_test_loader).

-export([load_rows/2]).

load_rows(_Table, sessions) ->
    {ok, [#{id => 9001, player_id => 101, dirty_flag => 0, payload => <<"seed">>}]};
load_rows(_Table, _Tag) ->
    {ok, []}.
