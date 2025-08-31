%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%% Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
%%%
%%% Original concept inspired and some code copied from
%%% https://erlangcentral.org/wiki/index.php?title=Building_a_Non-blocking_TCP_server_using_OTP_principles

-module(gen_rpc_client).
-author("Panagiotis Papadomitsos <pj@ezgr.net>").

%%% Behaviour
-behaviour(gen_server).

%%% Include the HUT library
-include_lib("snabbkaffe/include/trace.hrl").
-include("logger.hrl").
%%% Include this library's name macro
-include("app.hrl").
%%% Include helpful guard macros
-include("guards.hrl").
%%% Include helpful guard macros
-include("types.hrl").

-define(log(Level, Msg, Data), ?LOG(Level, ?T_CLIENT, Msg, Data)).

-define(NAME(NODE_OR_TUPLE), {client, NODE_OR_TUPLE}).

%%% Local state
-record(state, {socket :: port() | undefined,
        driver :: atom(),
        driver_mod :: atom(),
        driver_closed :: atom(),
        driver_error :: atom(),
        max_batch_size :: integer(),
        keepalive :: tuple() | undefined}).

%%% Supervisor functions
-export([start_link/1, stop/1]).

%%% Server functions
-export([call/3, call/4, call/5, call/6, cast/3, cast/4, cast/5, ordered_cast/4]).

-export([async_call/3, async_call/4, yield/1, nb_yield/1, nb_yield/2]).

-export([eval_everywhere/3, eval_everywhere/4, eval_everywhere/5]).

-export([multicall/3, multicall/4, multicall/5]).

-export([abcast/2, abcast/3, sbcast/2, sbcast/3]).

%%% Behaviour callbacks
-export([init/1, handle_call/3, handle_cast/2,
        handle_info/2, handle_continue/2, terminate/2, code_change/3]).

%%% Process exports
-export([async_call_worker/5, cast_worker/4]).

%%% Debug/test
-export([where_is/1]).

%%% ===================================================
%%% Supervisor functions
%%% ===================================================
-spec start_link(node_or_tuple()) -> {ok, pid()} | {error, any()}.
start_link(NodeOrTuple) when ?is_node_or_tuple(NodeOrTuple) ->
    gen_server:start_link({via, gen_rpc_registry, ?NAME(NodeOrTuple)}, ?MODULE, {NodeOrTuple}, []).

-spec stop(node_or_tuple()) -> ok.
stop(NodeOrTuple) when ?is_node_or_tuple(NodeOrTuple) ->
    gen_server:stop(?NAME(NodeOrTuple), normal, infinity).

%%% ===================================================
%%% Server functions
%%% ===================================================
%% Simple server call with no args and default timeout values
-spec call(node_or_tuple(), atom() | tuple(), atom() | function()) -> term() | {badrpc,term()} | {badtcp,term()}.
call(NodeOrTuple, M, F) ->
    call(NodeOrTuple, M, F, [], undefined, undefined).

%% Simple server call with args and default timeout values
-spec call(node_or_tuple(), atom() | tuple(), atom() | function(), list()) -> term() | {badrpc,term()} | {badtcp,term()}.
call(NodeOrTuple, M, F, A) ->
    call(NodeOrTuple, M, F, A, undefined, undefined).

%% Simple server call with custom receive timeout value
-spec call(node_or_tuple(), atom() | tuple(), atom() | function(), list(), timeout()) -> term() | {badrpc,term()} | {badtcp,term()}.
call(NodeOrTuple, M, F, A, RecvTimeout) ->
    call(NodeOrTuple, M, F, A, RecvTimeout, undefined).

%% Simple server call with custom receive and send timeout values
%% This is the function that all of the above call
-spec call(node_or_tuple(), atom() | tuple(), atom() | function(), list(), timeout() | undefined, timeout() | undefined) ->
    term() | {badrpc,term()} | {badtcp,term()}.
call(Node, M, F, A, RecvTimeout, _) when Node =:= node() ->
    local_call(M, F, A, RecvTimeout);
call({Node, _}, M, F, A, RecvTimeout, _) when Node =:= node() ->
    local_call(M, F, A, RecvTimeout);
call(NodeOrTuple, M, F, A, RecvTimeout, SendTimeout) when ?is_node_or_tuple(NodeOrTuple), is_atom(M) orelse is_tuple(M), is_atom(F), is_list(A),
                                         RecvTimeout =:= undefined orelse ?is_timeout(RecvTimeout),
                                         SendTimeout =:= undefined orelse ?is_timeout(SendTimeout) ->
    case maybe_start_client(NodeOrTuple) of
        {ok, Pid} ->
            try
                gen_server:call(Pid, {{call,M,F,A}, SendTimeout}, gen_rpc_helper:get_call_receive_timeout(RecvTimeout))
            catch
                exit:{timeout,_Reason} -> {badrpc,timeout};
                exit:{{shutdown, {badrpc, Reason}}, {gen_server, call, _}} ->
                    %% the client gen_server stopped in handle_continue
                    {badrpc, Reason};
                exit:{{shutdown, Reason}, {gen_server, call, _}} ->
                    %% the client gen_server stopped with shutdown reason (non-badrpc)
                    {badrpc, Reason};
                exit:OtherReason -> {badrpc, {unknown_error, OtherReason}}
            end;
        {error, Reason} ->
            Reason
    end.

%% Simple server cast with no args and default timeout values
-spec cast(node_or_tuple(), atom() | tuple(), atom() | function()) -> true.
cast(NodeOrTuple, M, F) ->
    cast(NodeOrTuple, M, F, [], undefined).

%% Simple server cast with args and default timeout values
-spec cast(node_or_tuple(), atom() | tuple(), atom() | function(), list()) -> true.
cast(NodeOrTuple, M, F, A) ->
    cast(NodeOrTuple, M, F, A, undefined).

%% Simple server cast with custom send timeout value
%% This is the function that all of the above casts call
-spec cast(node_or_tuple(), atom() | tuple(), atom() | function(), list(), timeout() | undefined) -> true.
cast(NodeOrTuple, M, F, A, SendTimeout) when ?is_node_or_tuple(NodeOrTuple), is_atom(M) orelse is_tuple(M), is_atom(F), is_list(A),
                                 SendTimeout =:= undefined orelse ?is_timeout(SendTimeout) ->
    cast_worker(NodeOrTuple, ?CAST(M, F, A), undefined, SendTimeout),
    true.

-spec ordered_cast(destination(), atom() | tuple(), atom() | function(), list()) -> true.
ordered_cast(NodeOrTuple, M, F, A) when ?is_node_or_tuple(NodeOrTuple), is_atom(M) orelse is_tuple(M), is_atom(F), is_list(A) ->
    cast_worker(NodeOrTuple, ?ORDERED_CAST(M, F, A), undefined, undefined),
    true.

%% Evaluate {M, F, A} on connected nodes.
-spec eval_everywhere([atom()], atom() | tuple(), atom() | function()) -> abcast.
eval_everywhere(Nodes, M, F) ->
    eval_everywhere(Nodes, M, F, [], undefined).

%% Evaluate {M, F, A} on connected nodes.
-spec eval_everywhere([atom()], atom() | tuple(), atom() | function(), list()) -> abcast.
eval_everywhere(Nodes, M, F, A) ->
    eval_everywhere(Nodes, M, F, A, undefined).

%% Evaluate {M, F, A} on connected nodes.
-spec eval_everywhere([atom()], atom() | tuple(), atom() | function(), list(), timeout() | undefined) -> abcast.
eval_everywhere(Nodes, M, F, A, SendTimeout) when is_list(Nodes), is_atom(M) orelse is_tuple(M), is_atom(F), is_list(A),
                                             SendTimeout =:= undefined orelse ?is_timeout(SendTimeout) ->
    _ = [erlang:spawn(?MODULE, cast_worker, [Node, ?CAST(M, F, A), abcast, SendTimeout]) || Node <- Nodes],
    abcast.

%% Simple server async_call with no args
-spec async_call(node_or_tuple(), atom() | tuple(), atom() | function()) -> term() | {badrpc,term()} | {badtcp,term()}.
async_call(NodeOrTuple, M, F) ->
    async_call(NodeOrTuple, M, F, []).

%% Simple server async_call with args
-spec async_call(node_or_tuple(), atom() | tuple(), atom() | function(), list()) -> term() | {badrpc,term()} | {badtcp,term()}.
async_call(NodeOrTuple, M, F, A) when ?is_node_or_tuple(NodeOrTuple), is_atom(M) orelse is_tuple(M), is_atom(F), is_list(A) ->
    Ref = erlang:make_ref(),
    Pid = erlang:spawn(?MODULE, async_call_worker, [NodeOrTuple, M, F, A, Ref]),
    {Pid, Ref}.

%% Simple server yield with key. Delegate to nb_yield. Default timeout form configuration.
-spec yield(tuple()) -> term() | {badrpc,term()}.
yield(Key) ->
    {value,Result} = nb_yield(Key, infinity),
    Result.

%% Simple server non-blocking yield with key, default timeout value of 0
-spec nb_yield(tuple()) -> {value,term() | {badrpc,term()}} | timeout.
nb_yield(Key)->
    nb_yield(Key, 0).

%% Simple server non-blocking yield with key and custom timeout value
-spec nb_yield(tuple(), timeout()) -> {value,term() | {badrpc,term()}} | timeout.
nb_yield({Pid,Ref}, Timeout) when is_pid(Pid), is_reference(Ref), ?is_timeout(Timeout) ->
    Pid ! {self(), Ref, yield},
    receive
        {Pid, Ref, async_call, Result} ->
            {value,Result}
    after
        Timeout ->
            timeout
    end.

%% "Concurrent" call to a set of servers
-spec multicall(atom() | tuple(), atom(), list()) -> {list(), list()}.
multicall(M, F, A) when is_atom(M) orelse is_tuple(M), is_atom(F), is_list(A) ->
    multicall([node()|gen_rpc:nodes()], M, F, A).

-spec multicall(list() | atom() | tuple(), atom() | tuple(), atom() | list(), list() | timeout()) -> {list(), list()}.
multicall(M, F, A, Timeout) when is_atom(M) orelse is_tuple(M), is_atom(F), is_list(A), ?is_timeout(Timeout) ->
    multicall([node()|gen_rpc:nodes()], M, F, A, Timeout);

multicall(Nodes, M, F, A) when is_list(Nodes), is_atom(M) orelse is_tuple(M), is_atom(F), is_list(A) ->
    Keys = [async_call(Node, M, F, A) || Node <- Nodes],
    parse_multicall_results(Keys, Nodes, undefined).

-spec multicall(list(), atom() | tuple(), atom(), list(), timeout()) -> {list(), list()}.
multicall(Nodes, M, F, A, Timeout) when is_list(Nodes), is_atom(M) orelse is_tuple(M), is_atom(F), is_list(A), ?is_timeout(Timeout) ->
    Keys = [async_call(Node, M, F, A) || Node <- Nodes],
    parse_multicall_results(Keys, Nodes, Timeout).

-spec abcast(atom(), term()) -> abcast.
abcast(Name, Msg) when is_atom(Name) ->
    abcast([node()|gen_rpc:nodes()], Name, Msg).

-spec abcast(list(), atom(), term()) -> abcast.
abcast(Nodes, Name, Msg) when is_list(Nodes), is_atom(Name) ->
    _ = [erlang:spawn(?MODULE, cast_worker, [Node, {abcast,Name,Msg}, abcast, undefined]) || Node <- Nodes],
    abcast.

-spec sbcast(atom(), term()) -> {list(), list()}.
sbcast(Name, Msg) when is_atom(Name) ->
    sbcast([node()|gen_rpc:nodes()], Name, Msg).

-spec sbcast(list(), atom(), term()) -> {list(), list()}.
sbcast(Nodes, Name, Msg) when is_list(Nodes), is_atom(Name) ->
    Ref = erlang:make_ref(),
    Workers = [{erlang:spawn(?MODULE, cast_worker, [Node, {sbcast, Name, Msg, {self(), Ref, Node}}, undefined, undefined]), Node} || Node <- Nodes],
    parse_sbcast_results(Workers, Ref).

-spec where_is(node_or_tuple()) -> pid() | undefined.
where_is(NodeOrTuple) ->
    gen_rpc_registry:whereis_name(?NAME(NodeOrTuple)).

%%% ===================================================
%%% Behaviour callbacks
%%% ===================================================
init({NodeOrTuple}) ->
    %% Set process label for OTP >= 27
    ok = set_process_label_if_supported({?MODULE, NodeOrTuple}),
    {Node, Key} = case is_atom(NodeOrTuple) of
                      true ->
                          {NodeOrTuple, undefined};
                      false ->
                          NodeOrTuple
                  end,
    ok = gen_rpc_helper:set_optimal_process_flags(),
    case gen_rpc_helper:get_client_config_per_node(Node) of
        {error, Reason} ->
            ?log(error, "external_source_error",
                 #{action => falling_back_to_local,
                   cause => Reason}),
            {stop, {badrpc, {external_source_error, Reason}}};
        {Driver, Port} ->
            {DriverMod, DriverClosed, DriverError} = gen_rpc_helper:get_client_driver_options(Driver),
            ?log(debug, "initializing_client",
                 #{driver => Driver,
                   node => Node,
                   port => Port}),
            MaxBatchSize = application:get_env(?APP, max_batch_size, 0),
            InitialState = #state{socket=undefined,
                                  driver=Driver,
                                  driver_mod=DriverMod,
                                  driver_closed=DriverClosed,
                                  driver_error=DriverError,
                                  max_batch_size=MaxBatchSize,
                                  keepalive=undefined},
            %% Return immediately, connection happens in handle_continue
            {ok, InitialState, {continue, {connect, Node, Port, Key}}}
    end.

%% Handle async connection initialization
handle_continue({connect, Node, Port, Key}, #state{driver_mod = DriverMod, driver = Driver} = State) ->
    case gen_rpc_auth:connect_with_auth(DriverMod, Node, Port) of
        {ok, Socket} ->
            Interval = application:get_env(?APP, keepalive_interval, 60), % 60s
            StatFun = fun() ->
                              case DriverMod:getstat(Socket, [recv_oct]) of
                                  {ok, [{recv_oct, RecvOct}]} -> {ok, RecvOct};
                                  {error, Error}              -> {error, Error}
                              end
                      end,
            case gen_rpc_keepalive:start(StatFun, Interval, {keepalive, check}) of
                {ok, KeepAlive} ->
                    ConnectedState = State#state{socket=Socket, keepalive=KeepAlive},
                    {noreply, ConnectedState, gen_rpc_helper:get_inactivity_timeout(?MODULE)};
                {error, Error} ->
                    ?log(error, "start_keepalive_failed",
                         #{driver => Driver,
                           node => Node,
                           port => Port,
                           key => Key,
                           cause => Error}),
                    {stop, {shutdown, Error}, State}
            end;
        {error, ReasonTuple} ->
            ?log(error, "client_authentication_failed",
                 #{driver => Driver,
                   node => Node,
                   port => Port,
                   key => Key,
                   cause => ReasonTuple}),
            {stop, {shutdown, ReasonTuple}, State};
        {unreachable, Reason} ->
            %% This should be badtcp but to conform with
            %% the RPC library we return badrpc
            ?log(error, "failed_to_connect_server",
                 #{driver => Driver,
                   node => Node,
                   port => Port,
                   key => Key,
                   cause => Reason}),
            {stop, {shutdown, {badrpc, Reason}}, State}
    end.

%% This is the actual CALL handler
handle_call({{call,_M,_F,_A} = PacketTuple, SendTimeout}, Caller, #state{socket=Socket, driver=Driver, driver_mod=DriverMod} = State) ->
    Packet = erlang:term_to_iovec({PacketTuple, Caller}),
    ok = DriverMod:set_send_timeout(Socket, SendTimeout),
    case DriverMod:send(Socket, Packet) of
        {error, Reason} ->
            ?log(error, "failed_to_send_call",
                 #{driver => Driver,
                   socket => gen_rpc_helper:socket_to_string(Socket),
                   caller => Caller,
                   cause => Reason}),
            {stop, {shutdown, Reason}, Reason, State};
        ok ->
            %% We need to enable the socket and perform the call only if the call succeeds
            ok = DriverMod:activate_socket(Socket),
            {noreply, State, gen_rpc_helper:get_inactivity_timeout(?MODULE)}
    end;

%% Catch-all for calls - die if we get a message we don't expect
handle_call(Msg, _Caller, #state{socket=Socket, driver=Driver} = State) ->
    ?log(error, "unknown_call_received",
         #{driver => Driver,
           socket => gen_rpc_helper:socket_to_string(Socket),
           message => Msg,
           action => stopping}),
    {stop, {unknown_call, Msg}, {unknown_call, Msg}, State}.

%% This is the actual ASYNC CALL handler
handle_cast({{async_call,_M,_F,_A} = PacketTuple, Caller, Ref}, #state{socket=Socket, driver=Driver, driver_mod=DriverMod} = State) ->
    Packet = erlang:term_to_iovec({PacketTuple, {Caller,Ref}}),
    ok = DriverMod:set_send_timeout(Socket, undefined),
    case DriverMod:send_async(Socket, Packet) of
        {error, Reason} ->
            ?log(error, "failed_to_send_async_call",
                 #{driver => Driver,
                   socket => gen_rpc_helper:socket_to_string(Socket),
                   worker_pid => Caller,
                   call_ref => Ref,
                   cause => Reason}),
            {stop, {shutdown, Reason}, Reason, State};
        ok ->
            %% We need to enable the socket and perform the call only if the call succeeds
            ok = DriverMod:activate_socket(Socket),
            %% Reply will be handled from the worker
            {noreply, State, gen_rpc_helper:get_inactivity_timeout(?MODULE)}
    end;

%% Catch-all for casts - die if we get a message we don't expect
handle_cast(Msg, #state{socket=Socket, driver=Driver} = State) ->
    ?log(error, "unknown_cast_received",
         #{driver => Driver,
           socket => gen_rpc_helper:socket_to_string(Socket),
           message => Msg,
           action => stopping}),
    {stop, {unknown_cast, Msg}, State}.

%% This is the actual CAST handler for CAST
handle_info({PacketTuple, SendTimeout}, State = #state{max_batch_size = 0}) when ?IS_CAST_MSG(PacketTuple) ->
    send_cast(PacketTuple, State, SendTimeout, true);
handle_info({PacketTuple, SendTimeout}, State = #state{max_batch_size = MaxBatchSize}) when ?IS_CAST_MSG(PacketTuple) ->
    send_cast(drain_cast(MaxBatchSize, [PacketTuple]), State, SendTimeout, true);

%% This is the actual CAST handler for SBCAST
handle_info({{sbcast,_Name,_Msg,_Caller} = PacketTuple, undefined}, State) ->
    send_cast(PacketTuple, State, undefined, true);

%% Handle any TCP packet coming in
handle_info({Driver,Socket,Data}, #state{socket=Socket, driver=Driver, driver_mod=DriverMod} = State) ->
    MessageFromWire = erlang:binary_to_term(Data),
    ?tp_ignore_side_effects_in_prod(
        gen_rpc_client_receive_message, #{ socket => gen_rpc_helper:socket_to_string(Socket)
                                         , packet => MessageFromWire
                                         , domain => ?D_CLIENT
                                         }),
    _Reply = case MessageFromWire of
        {call, Caller, Reply} ->
            gen_server:reply(Caller, Reply);
        {async_call, {Caller, Ref}, Reply} ->
            Caller ! {self(), Ref, async_call, Reply};
        {sbcast, {Caller, Ref, Node}, Reply} ->
            Caller ! {Ref, Node, Reply};
        OtherData ->
            ?log(error, "erroneous_reply_received",
                 #{driver => Driver,
                   socket => gen_rpc_helper:socket_to_string(Socket),
                   data => OtherData,
                   action => ignoring})
    end,
    ok = DriverMod:activate_socket(Socket),
    {noreply, State, gen_rpc_helper:get_inactivity_timeout(?MODULE)};

handle_info({DriverClosed, Socket}, #state{socket=Socket, driver=Driver, driver_closed=DriverClosed} = State) ->
    ?log(error, "rpc_channel_closed",
         #{driver => Driver,
           socket => gen_rpc_helper:socket_to_string(Socket),
           action => stopping}),
    {stop, normal, State};

handle_info({DriverError, Socket, Reason}, #state{socket=Socket, driver=Driver, driver_error=DriverError} = State) ->
    ?log(error, "rpc_channel_error",
         #{driver => Driver,
           socket => gen_rpc_helper:socket_to_string(Socket),
           cause => Reason,
           action => stopping}),
    {stop, normal, State};

%% Handle the inactivity timeout gracefully
handle_info(timeout, #state{socket=Socket, driver=Driver} = State) ->
    ?log(info, "client_inactivity_timeout",
         #{driver => Driver,
           socket => gen_rpc_helper:socket_to_string(Socket),
           action => stopping}),
    {stop, normal, State};

handle_info({keepalive, check}, #state{driver=Driver, keepalive=KeepAlive} = State) ->
    case gen_rpc_keepalive:check(KeepAlive) of
        {ok, KeepAlive1} ->
            {noreply, State#state{keepalive=KeepAlive1}, gen_rpc_helper:get_inactivity_timeout(?MODULE)};
        {error, timeout} ->
            send_ping(State#state{keepalive=gen_rpc_keepalive:resume(KeepAlive)});
        {error, Reason} ->
            ?log(error, "keepalive_check_failed",
                 #{driver => Driver,
                   cause => Reason,
                   action => stopping}),
            {stop, {shutdown, Reason}, State}
    end;

handle_info({inet_reply, _Socket, ok}, State) ->
    {noreply, State};

handle_info({inet_reply, _Socket, {error, Reason}}, State) ->
    {stop, {async_send_error, Reason}, State};

%% Catch-all for info - our protocol is strict so die!
handle_info(Msg, #state{socket=Socket, driver=Driver} = State) ->
    ?log(error, "unknown_message_received",
         #{driver => Driver,
           socket => gen_rpc_helper:socket_to_string(Socket),
           message => Msg,
           action => stopping}),
    {stop, {unknown_info, Msg}, State}.

%% Stub functions
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{keepalive=undefined}) ->
    ok;
terminate(_Reason, #state{keepalive=KeepAlive}) ->
    gen_rpc_keepalive:cancel(KeepAlive),
    ok.

%%% ===================================================
%%% Helper functions
%%% ===================================================

%% Set process label for OTP >= 27
-if(?OTP_RELEASE >= 27).
set_process_label_if_supported(Label) ->
    proc_lib:set_label(Label).
-else.
set_process_label_if_supported(_Label) ->
    ok.
-endif.

%%% ===================================================
%%% Private functions
%%% ===================================================
send_cast(PacketTuple, #state{socket=Socket, driver=Driver, driver_mod=DriverMod} = State, SendTimeout, Activate) ->
    ?tp_ignore_side_effects_in_prod(
        gen_rpc_send_packet, #{ packet  => PacketTuple
                              , timeout => SendTimeout
                              , driver  => Driver
                              , socket  => gen_rpc_helper:socket_to_string(Socket)
                              }),
    Packet = erlang:term_to_iovec(PacketTuple),
    ok = DriverMod:set_send_timeout(Socket, SendTimeout),
    case DriverMod:send_async(Socket, Packet) of
        {error, Reason} ->
            ?tp(error, gen_rpc_error, #{ error  => transmission_failed
                                       , packet => cast
                                       , socket => gen_rpc_helper:socket_to_string(Socket)
                                       , driver => Driver
                                       , reason => Reason
                                       , domain => ?D_CLIENT
                                       }),
            {stop, {shutdown, Reason}, State};
        ok ->
            ok = case Activate of
                     true -> DriverMod:activate_socket(Socket);
                     _    -> ok
                 end,
            {noreply, State, gen_rpc_helper:get_inactivity_timeout(?MODULE)}
    end.

send_ping(#state{socket=Socket, driver=Driver, driver_mod=DriverMod} = State) ->
    Packet = erlang:term_to_iovec(ping),
    ok = DriverMod:set_send_timeout(Socket, undefined),
    case DriverMod:send(Socket, Packet) of
        {error, Reason} ->
            ?log(error, "faild_to_send_ping",
                 #{driver => Driver,
                   socket => gen_rpc_helper:socket_to_string(Socket),
                   cause => Reason}),
            {stop, {shutdown, Reason}, State};
        ok ->
            %% We should keep this flag same as previous
            ok = DriverMod:activate_socket(Socket),
            {noreply, State, gen_rpc_helper:get_inactivity_timeout(?MODULE)}
    end.

cast_worker(NodeOrTuple, Cast, Ret, SendTimeout) ->
    %% Create a unique name for the client because we register as such
    PidName = ?NAME(NodeOrTuple),
    ?tp_ignore_side_effects_in_prod(
        gen_rpc_input, #{ input => Cast
                        , target => NodeOrTuple
                        , sendto => SendTimeout
                        , pid => PidName
                        }),
    case gen_rpc_registry:whereis_name(PidName) of
        undefined ->
            ?tp(info, gen_rpc_client_process_not_found, #{target => NodeOrTuple, domain => ?D_CLIENT}),
            case gen_rpc_dispatcher:start_client(NodeOrTuple) of
                {ok, NewPid} ->
                    %% We take care of CALL inside the gen_server
                    %% This is not resilient enough if the caller's mailbox is full
                    %% but it's good enough for now
                    erlang:send(NewPid, {Cast, SendTimeout}),
                    Ret;
                {error, _Reason} ->
                    Ret
            end;
        Pid ->
            ?tp_ignore_side_effects_in_prod(
                gen_rpc_client_process_found, #{pid => Pid, target => NodeOrTuple}),
            erlang:send(Pid, {Cast, SendTimeout}),
            Ret
    end.

async_call_worker(NodeOrTuple, M, F, A, Ref) ->
    TTL = gen_rpc_helper:get_async_call_inactivity_timeout(),
    PidName = ?NAME(NodeOrTuple),
    case gen_rpc_registry:whereis_name(PidName) of
        undefined ->
            ?log(debug, "client_process_not_found",
                 #{target => NodeOrTuple,
                   action => spawning_client}),
            case gen_rpc_dispatcher:start_client(NodeOrTuple) of
                {ok, NewPid} ->
                    %% Monitor the client process in case it dies before handling the cast
                    MRef = erlang:monitor(process, NewPid),
                    ok = gen_server:cast(NewPid, {{async_call,M,F,A}, self(), Ref}),
                    wait_for_async_reply(NewPid, MRef, Ref, TTL);
                {error, {badrpc,_} = RpcError} ->
                    wait_for_yield_and_send(RpcError, Ref, TTL)
            end;
        Pid ->
            %% Monitor the client process in case it dies before handling the cast
            MRef = erlang:monitor(process, Pid),
            ok = gen_server:cast(Pid, {{async_call,M,F,A}, self(), Ref}),
            wait_for_async_reply(Pid, MRef, Ref, TTL)
    end.

wait_for_async_reply(Pid, MRef, Ref, TTL) ->
    receive
        %% Wait for the reply from the node's gen_rpc client process
        {Pid,Ref,async_call,Reply} ->
            erlang:demonitor(MRef, [flush]),
            wait_for_yield_and_send(Reply, Ref, TTL);
        {'DOWN', MRef, process, Pid, Reason} ->
            %% Client process died before handling the cast
            ErrorReply = case Reason of
                {shutdown, {badrpc, _} = BadRpc} -> BadRpc;
                {shutdown, ShutdownReason} -> {badrpc, ShutdownReason};
                _ -> {badrpc, Reason}
            end,
            wait_for_yield_and_send(ErrorReply, Ref, TTL)
    after
        TTL ->
            erlang:demonitor(MRef, [flush]),
            exit({error, async_call_cleanup_timeout_reached})
    end.

wait_for_yield_and_send(Result, Ref, TTL) ->
    %% Wait for a yield request from the caller and send the result
    receive
        {YieldPid,Ref,yield} ->
            YieldPid ! {self(), Ref, async_call, Result}
    after
        TTL ->
            exit({error, async_call_cleanup_timeout_reached})
    end.

parse_multicall_results(Keys, Nodes, undefined) ->
    parse_multicall_results(Keys, Nodes, infinity);

parse_multicall_results(Keys, Nodes, Timeout) ->
    AsyncResults = [nb_yield(Key, Timeout) || Key <- Keys],
    {RealResults, RealBadNodes, _} = lists:foldl(fun
        ({value, {BadReply, _Reason}}, {Results, BadNodes, [Node|RestNodes]}) when BadReply =:= badrpc; BadReply =:= badtcp ->
            {Results, [Node|BadNodes], RestNodes};
        ({value, Value}, {Results, BadNodes, [_Node|RestNodes]}) ->
            {[Value|Results], BadNodes, RestNodes};
        (timeout, {Results, BadNodes, [Node|RestNodes]}) ->
            {Results, [Node|BadNodes], RestNodes}
    end, {[], [], Nodes}, AsyncResults),
    {RealResults, RealBadNodes}.

parse_sbcast_results(WorkerPids, Ref) ->
    Timeout = gen_rpc_helper:get_sbcast_receive_timeout(),
    parse_sbcast_results(WorkerPids, Ref, {[], []}, Timeout).

parse_sbcast_results([{_Pid,Node}|WorkerPids], Ref, {Good, Bad}, Timeout) ->
    receive
        {Ref, Node, error} ->
            parse_sbcast_results(WorkerPids, Ref, {Good, [Node|Bad]}, Timeout);
        {Ref, Node, success} ->
            parse_sbcast_results(WorkerPids, Ref, {[Node|Good], Bad}, Timeout)
    after
        Timeout ->
            parse_sbcast_results(WorkerPids, Ref, {Good, [Node|Bad]}, Timeout)
    end;

parse_sbcast_results([], _Ref, Results, _Timeout) ->
    Results.

drain_cast(N, CastReqs) when N =< 0 ->
    ?tp_ignore_side_effects_in_prod(gen_rpc_cast_batch, #{ size => length(CastReqs) }),
    lists:reverse(CastReqs);
drain_cast(N, CastReqs) ->
    receive
        {?CAST(_M,_F,_A) = Req, _} ->
            drain_cast(N-1, [Req | CastReqs]);
        {?ABCAST(_N, _M) = Req, _} ->
            drain_cast(N-1, [Req | CastReqs]);
        {?ORDERED_CAST(_M, _F, _A) = Req, _} ->
            drain_cast(N-1, [Req | CastReqs])
    after 0 ->
        lists:reverse(CastReqs)
    end.

-spec maybe_start_client(node_or_tuple()) -> {ok, pid()} | {error, any()}.
maybe_start_client(NodeOrTuple) ->
    %% Create a unique name for the client because we register as such
    PidName = ?NAME(NodeOrTuple),
    case gen_rpc_registry:whereis_name(PidName) of
        undefined ->
            ?log(debug, "client_process_not_found",
                 #{target => NodeOrTuple,
                   action => spawning_client}),
            gen_rpc_dispatcher:start_client(NodeOrTuple);
        Pid ->
            {ok, Pid}
    end.

%% Bypass the pipeline for local calls.
%%
%% Note: this function doesn't support authorization checks and/or
%% module version checks.
%%
%% Note: `call_middleman' returns value by throwing an error... So we
%% have to suppress dialyzer warning:
-dialyzer({no_return, [local_call/4]}).
local_call(M, F, A, undefined) ->
    local_call(M, F, A, infinity);
local_call({M, _Version}, F, A, Timeout) ->
    local_call(M, F, A, Timeout);
local_call(M, F, A, Timeout) ->
    {Pid, MRef} = spawn_monitor(fun() ->
                                        gen_rpc_acceptor:call_middleman(M, F, A)
                                end),
    receive
        {'DOWN', MRef, process, Pid, {call_middleman_result, Reason}} ->
            Reason;
        {'DOWN', MRef, process, Pid, Other} ->
            {badrpc, Other}
    after Timeout ->
            erlang:demonitor(MRef, [flush]),
            {badrpc, timeout}
    end.
