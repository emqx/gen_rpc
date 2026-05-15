%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:

-module(gen_rpc_exec_worker_sup).

%%% Behaviour
-behaviour(supervisor).

-include("logger.hrl").

%%% API
-export([start_link/0, submit/3]).

%%% Supervisor callbacks
-export([init/1]).

%%% ===================================================
%%% API
%%% ===================================================
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec submit(module(), atom(), list()) -> ok.
submit(M, F, A) ->
    Name = gen_rpc_exec_worker:worker_name(random_worker_index()),
    case gen_rpc_registry:whereis_name(Name) of
        undefined ->
            ?log(notice, "event=exec_cast_worker_unavailable, name=~p", [Name]),
            exec_cast(M, F, A);
        Pid ->
            gen_server:cast(Pid, {exec_cast, M, F, A}),
            ok
    end.

%%% ===================================================
%%% Supervisor callbacks
%%% ===================================================
init([]) ->
    Children = [worker_spec(Index) || Index <- lists:seq(1, worker_count())],
    {ok, {{one_for_one, 15, 1}, Children}}.

%%% ===================================================
%%% Internal functions
%%% ===================================================
%%% The `exec_cast/3` function is a fallback that executes the cast directly if the worker is unavailable.
%%% Usually happens when relup failed to start the worker pool.
exec_cast(M, F, A) ->
    _ = erlang:spawn(M, F, A),
    ok.

worker_spec(Index) ->
    Name = gen_rpc_exec_worker:worker_name(Index),
    {Name, {gen_rpc_exec_worker, start_link, [Index]}, permanent, 5000, worker, [gen_rpc_exec_worker]}.

worker_count() ->
    erlang:system_info(schedulers).

random_worker_index() ->
    case worker_count() of
        1 ->
            1;
        Count ->
            erlang:phash2(make_ref(), Count) + 1
    end.