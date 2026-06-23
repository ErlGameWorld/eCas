%%%-------------------------------------------------------------------
%%% @doc eCas 顶层 supervisor。
%%%
%%% 默认启动为空 supervisor。
%%% 具体表进程由 eCas:start/1 分批动态挂到该 supervisor 下面。
%%%-------------------------------------------------------------------
-module(eCas_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-export([startTable/2, stopTable/1]).

-define(SERVER, ?MODULE).

start_link() ->
	supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
	SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
	{ok, {SupFlags, []}}.

startTable(Table, StartInfo) ->
	ChildSpec = #{
		id => {csTabSrv, Table},
		start => {csTabSrv, start_link, [Table, StartInfo]},
		restart => permanent,
		shutdown => infinity,
		type => worker,
		modules => [csTabSrv]
	},
	supervisor:start_child(?SERVER, ChildSpec).

stopTable(Table) ->
	ChildId = {csTabSrv, Table},
	case supervisor:terminate_child(?SERVER, ChildId) of
		ok ->
			supervisor:delete_child(?SERVER, ChildId);
		{error, not_found} ->
			ok;
		Error ->
			Error
	end.