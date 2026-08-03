%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:

-module(gen_rpc_exec_worker_sup).

%%% Behaviour
-behaviour(supervisor).

-include("logger.hrl").

%%% API
-export([start_link/0, submit/3, submit_ordered/4]).

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

%% @doc Execute a cast on the exec worker pinned by `Key', blocking until the
%% cast has finished. All casts carrying the same `Key' are executed by the
%% same worker in submission order (FIFO), which is the ordering guarantee
%% that `gen_rpc:ordered_cast' relies on.
%%
%% This keeps the previous inline-execution semantics (a cast on a connection
%% stalls that connection until it returns) while reusing the pre-created
%% worker pool, instead of spawning a new process per cast as the old
%% `spawn_monitor' based implementation did.
-spec submit_ordered(term(), module(), atom(), list()) -> ok.
submit_ordered(Key, M, F, A) ->
    Name = gen_rpc_exec_worker:worker_name(pinned_worker_index(Key)),
    case gen_rpc_registry:whereis_name(Name) of
        undefined ->
            ?log(notice, "event=exec_cast_worker_unavailable, name=~p", [Name]),
            execute_inline(M, F, A);
        Pid ->
            try
                case gen_server:call(Pid, {exec_cast, M, F, A}, infinity) of
                    ok ->
                        ok;
                    Reply ->
                        %% e.g. an older worker running pre-pool code replies
                        %% `{error, unsupported_call}' without executing the
                        %% cast (mixed-version hot upgrade); run it inline so
                        %% it is not silently dropped.
                        ?log(error,
                             "event=exec_ordered_cast_rejected reply=~p",
                             [Reply]),
                        execute_inline(M, F, A)
                end
            catch
                Class:Reason:Stack ->
                    ?log(error,
                         "event=exec_ordered_cast_failed class=~p reason=~p stack=~p",
                         [Class, Reason, Stack]),
                    execute_inline(M, F, A)
            end
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

%%% Fallback for ordered casts used when the worker pool is unavailable:
%%% execute the cast in the caller (the acceptor) process so that FIFO
%%% ordering and backpressure are preserved. The old `spawn_monitor' approach
%%% is not reused here so that no process is created per cast.
execute_inline(M, F, A) ->
    try apply(M, F, A) catch _Class:_Reason -> ok end.

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

%%% Pick a deterministic worker for a given key so that all casts sharing the
%%% key go to the same worker (FIFO execution).
pinned_worker_index(Key) ->
    erlang:phash2(Key, worker_count()) + 1.
