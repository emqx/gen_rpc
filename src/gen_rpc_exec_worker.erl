%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:

-module(gen_rpc_exec_worker).

%%% Behaviour
-behaviour(gen_server).

-include("logger.hrl").

%%% API
-export([start_link/1, worker_name/1]).

%%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%%% ===================================================
%%% API
%%% ===================================================
-spec start_link(pos_integer()) -> gen_server:startlink_ret().
start_link(Index) when is_integer(Index), Index > 0 ->
    gen_server:start_link({via, gen_rpc_registry, worker_name(Index)}, ?MODULE, Index, []).

-spec worker_name(pos_integer()) -> {exec_cast_worker, pos_integer()}.
worker_name(Index) when is_integer(Index), Index > 0 ->
    {exec_cast_worker, Index}.

%%% ===================================================
%%% gen_server callbacks
%%% ===================================================
init(Index) ->
    {ok, Index}.

%% Synchronous execution of an ordered cast. The caller (the acceptor) blocks
%% until this returns, so casts on the same worker run one after another.
handle_call({exec_cast, M, F, A}, _From, State) ->
    execute_cast(M, F, A),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast({exec_cast, M, F, A}, State) ->
    execute_cast(M, F, A),
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% ===================================================
%%% Internal functions
%%% ===================================================
execute_cast(M, F, A) ->
    try
        _ = erlang:apply(M, F, A),
        ok
    catch
        Class:Reason:Stacktrace ->
            ?log(error,
                 "event=exec_cast_failed module=~p function=~p args=\"~0p\" class=~p reason=\"~0p\" stacktrace=\"~0p\"",
                 [M, F, A, Class, Reason, Stacktrace]),
            ok
    end.
