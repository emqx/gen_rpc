%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%% Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
%%%
%%% Original concept inspired and some code copied from
%%% https://erlangcentral.org/wiki/index.php?title=Building_a_Non-blocking_TCP_server_using_OTP_principles

-module(gen_rpc_acceptor).
-author("Panagiotis Papadomitsos <pj@ezgr.net>").

%%% Behaviour
-behaviour(gen_statem).

-include_lib("snabbkaffe/include/trace.hrl").
-include("types.hrl").
-include("logger.hrl").
%%% Include this library's name macro
-include("app.hrl").

-define(log(Level, Msg, Data), ?LOG(Level, ?T_ACCEPTOR, Msg, Data)).

%%% Local state
-record(state, {socket = undefined :: port() | undefined,
        driver :: atom(),
        driver_mod :: atom(),
        driver_closed :: atom(),
        driver_error :: atom(),
        peer :: {inet:ip4_address(), inet:port_number()},
        control :: whitelist | blacklist | disabled,
        list :: sets:set() | undefined}).

-define(ACTIVE_N, application:get_env(?APP, acceptor_socket_active_n, 100)).

%%% Ignore dialyzer warning for call_middleman
%%% The non-local return is deliberate
-dialyzer([{no_return, [call_middleman/3]}]).

%%% Server functions
-export([start_link/2, set_socket/2, stop/1]).

%% gen_statem callbacks
-export([init/1, handle_event/4, callback_mode/0, terminate/3, code_change/4]).

%% State machine states
-export([waiting_for_socket/3, waiting_for_data/3]).

%%% Process exports
-export([call_worker/8, call_middleman/3]).

%%% ===================================================
%%% Supervisor functions
%%% ===================================================
-spec start_link(atom(), {inet:ip4_address(), inet:port_number()}) -> {ok, pid()} | {error, any()}.
start_link(Driver, Peer) when is_atom(Driver), is_tuple(Peer) ->
    Name = {acceptor, Peer},
    gen_statem:start_link({via, gen_rpc_registry, Name}, ?MODULE, {Driver, Peer}, []).

-spec stop(pid()) -> ok.
stop(Pid) when is_pid(Pid) ->
    gen_statem:stop(Pid, normal, infinity).

%%% ===================================================
%%% Server functions
%%% ===================================================
-spec set_socket(pid(), gen_tcp:socket()) -> ok.
set_socket(Pid, Socket) when is_pid(Pid) ->
    gen_statem:call(Pid, {socket_ready,Socket}, infinity).

%%% ===================================================
%%% Behaviour callbacks
%%% ===================================================
init({Driver, Peer}) ->
    ok = gen_rpc_helper:set_optimal_process_flags(),
    {Control, ControlList} = gen_rpc_helper:get_rpc_module_control(),
    {DriverMod, _DriverPort, DriverClosed, DriverError} = gen_rpc_helper:get_server_driver_options(Driver),
    {ok, waiting_for_socket, #state{driver=Driver,
                                    driver_mod=DriverMod,
                                    driver_error=DriverError,
                                    driver_closed=DriverClosed,
                                    peer=Peer,
                                    control=Control,
                                    list=ControlList}}.

callback_mode() ->
    state_functions.

waiting_for_socket({call,From}, {socket_ready,Socket}, #state{driver_mod=DriverMod, peer=_Peer} = State) ->
    ok = DriverMod:set_acceptor_opts(Socket),
    % Now we own the socket
    ?tp(gen_rpc_acquiring_socket_ownership,
        #{ driver    => DriverMod
         , socket    => gen_rpc_helper:socket_to_string(Socket)
         , peer      => gen_rpc_helper:peer_to_string(_Peer)
         }),
    ok = gen_statem:reply(From, ok),
    wait_for_auth(State#state{socket = Socket}).

waiting_for_data(info, {Passive, Socket},
                 #state{socket=Socket, driver_mod=DriverMod}) when Passive =:= tcp_passive orelse Passive =:= ssl_passive ->
    ok = DriverMod:activate_socket(Socket, ?ACTIVE_N),
    keep_state_and_data;
waiting_for_data(info, {Driver,Socket,Data},
                 #state{socket=Socket, driver=Driver, driver_mod=DriverMod, peer=Peer, control=Control, list=List} = State) ->
    ?tp_ignore_side_effects_in_prod(
        gen_rpc_acceptor_receive, #{ socket => gen_rpc_helper:socket_to_string(Socket)
                                   , peer   => Peer
                                   , packet => catch erlang:binary_to_term(Data)
                                   }),
    %% The meat of the whole project: process a function call and return
    %% the data
    try erlang:binary_to_term(Data) of
        {{CallType,M,F,A}, Caller} when CallType =:= call; CallType =:= async_call ->
            {ModVsnAllowed, RealM} = check_module_version_compat(M),
            case check_if_module_allowed(RealM, Control, List) of
                true ->
                    case ModVsnAllowed of
                        true ->
                            _WorkerPid = erlang:spawn(?MODULE, call_worker, [CallType, RealM, F, A, Caller, Socket, Driver, DriverMod]),
                            {keep_state_and_data, gen_rpc_helper:get_inactivity_timeout(?MODULE)};
                        false ->
                            ?log(debug, "incompatible_module_version",
                                 #{driver => Driver,
                                   socket => gen_rpc_helper:socket_to_string(Socket),
                                   method => CallType,
                                   mod => RealM}),
                            reply_immediately({CallType, Caller, {badrpc,incompatible}}, State)
                    end;
                false ->
                    ?log(debug, "request_not_allowed",
                         #{driver => Driver,
                           socket => gen_rpc_helper:socket_to_string(Socket),
                           control => Control,
                           method => CallType,
                           mod => RealM}),
                    reply_immediately({CallType, Caller, {badrpc,unauthorized}}, State)
            end;
        ?CAST(M, F, A) ->
            handle_cast(M, F, A, false, State),
            {keep_state_and_data, gen_rpc_helper:get_inactivity_timeout(?MODULE)};
        ?ORDERED_CAST(M, F, A) ->
            handle_cast(M, F, A, true, State),
            {keep_state_and_data, gen_rpc_helper:get_inactivity_timeout(?MODULE)};
        ?ABCAST(N, M) ->
            handle_abcast(N, M, State),
            {keep_state_and_data, gen_rpc_helper:get_inactivity_timeout(?MODULE)};
        BatchCast when is_list(BatchCast) ->
            lists:foreach(fun(?CAST(M, F, A))         -> handle_cast(M, F, A, false, State);
                             (?ORDERED_CAST(M, F, A)) -> handle_cast(M, F, A, true, State);
                             (?ABCAST(N, M))          -> handle_abcast(N, M, State);
                             (Invalid)                -> ?tp(error, gen_rpc_invalid_batch, #{socket => gen_rpc_helper:socket_to_string(Socket), data => Invalid, domain => ?D_ACCEPTOR})
                          end,
                          BatchCast),
            {keep_state_and_data, gen_rpc_helper:get_inactivity_timeout(?MODULE)};
        {sbcast, Name, Msg, Caller} ->
            Reply = case check_if_module_allowed(erlang, Control, List) of
                true ->
                    case erlang:whereis(Name) of
                        undefined ->
                            error;
                        Pid ->
                            erlang:send(Pid, Msg),
                            success
                    end;
                false ->
                    ?log(debug, "request_not_allowed",
                         #{driver => Driver,
                           socket => gen_rpc_helper:socket_to_string(Socket),
                           control => Control,
                           method => sbcast}),
                     error
            end,
            reply_immediately({sbcast, Caller, Reply}, State);
        ping ->
            ?log(debug, "ping_received",
                 #{driver => Driver,
                   socket => gen_rpc_helper:socket_to_string(Socket),
                   peer => gen_rpc_helper:peer_to_string(Peer),
                   action => ignore}),
            {keep_state_and_data, gen_rpc_helper:get_inactivity_timeout(?MODULE)};
        OtherData ->
            ?tp(error, gen_rpc_error, #{ error  => erroneous_data_received
                                       , socket => gen_rpc_helper:socket_to_string(Socket)
                                       , peer   => gen_rpc_helper:peer_to_string(Peer)
                                       , domain => ?D_ACCEPTOR
                                       , data   => OtherData
                                       }),
            {stop, {badrpc,erroneous_data}, State}
    catch
        error:badarg ->
            {stop, {badtcp,corrupt_data}, State}
    end;

%% Handle the inactivity timeout gracefully
waiting_for_data(timeout, _Undefined, #state{socket=Socket, driver=Driver} = State) ->
    ?log(info, "server_inactivity_timeout",
         #{driver => Driver,
           socket => gen_rpc_helper:socket_to_string(Socket),
           action => stopping}),
    {stop, normal, State};

waiting_for_data(info, {DriverClosed, Socket} = Msg, #state{socket=Socket, driver_closed=DriverClosed} = State) ->
    handle_event(info, Msg, waiting_for_data, State);

waiting_for_data(info, {DriverError, Socket, _Reason} = Msg, #state{socket=Socket, driver_error=DriverError} = State) ->
    handle_event(info, Msg, waiting_for_data, State).

handle_event(info, {DriverClosed, Socket}, _StateName, #state{socket=Socket, driver=Driver, driver_closed=DriverClosed, peer=Peer} = State) ->
    ?tp(notice, gen_rpc_channel_closed, #{ driver => Driver
                                         , socket => gen_rpc_helper:socket_to_string(Socket)
                                         , peer   => gen_rpc_helper:peer_to_string(Peer)
                                         , action => stopping
                                         , domain => ?D_ACCEPTOR
                                         }),
    {stop, normal, State};

handle_event(info, {DriverError, Socket, Reason}, _StateName, #state{socket=Socket, driver=Driver, driver_error=DriverError, peer=Peer} = State) ->
    ?tp(error, gen_rpc_error, #{ error  => channel_error
                               , driver => Driver
                               , socket => gen_rpc_helper:socket_to_string(Socket)
                               , peer   => gen_rpc_helper:peer_to_string(Peer)
                               , action => stopping
                               , reason => Reason
                               , domain => ?D_ACCEPTOR
                               }),
    {stop, normal, State};

handle_event(EventType, Event, StateName, #state{peer = Peer, driver=Driver} = State) ->
    ?tp(error, gen_rpc_error, #{ error     => unknown_event
                               , driver    => Driver
                               , EventType => Event
                               , socket    => gen_rpc_helper:peer_to_string(Peer)
                               , action    => stopping
                               , domain    => ?D_ACCEPTOR
                               }),
    {stop, {StateName, undefined_event, Event}, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%% ===================================================
%%% Private functions
%%% ===================================================


wait_for_auth(#state{socket=Socket, driver=Driver, driver_mod=DriverMod, peer=Peer} = State) ->
    case gen_rpc_auth:authenticate_client(DriverMod, Socket, Peer) of
        {error, Reason} ->
            ok = DriverMod:close(Socket),
            {stop, Reason, State};
        ok ->
            case DriverMod:activate_socket(Socket, ?ACTIVE_N) of
                ok ->
                    {next_state, waiting_for_data, State};
                {error, _Posix} ->
                    ?log(notice, "channel_closed_before_data",
                         #{driver => Driver,
                           socket => gen_rpc_helper:socket_to_string(Socket),
                           peer => gen_rpc_helper:peer_to_string(Peer)}),
                    {stop, normal, State}
            end
    end.

%% Process an RPC call request outside of the state machine
call_worker(CallType, M, F, A, Caller, Socket, Driver, DriverMod) ->
    % If called MFA return exception, not of type term().
    % This fails term_to_binary coversion, crashes process
    % and manifest as timeout. Wrap inside anonymous function with catch
    % will crash the worker quickly not manifest as a timeout.
    % See call_MFA_undef test.
    {MPid, MRef} = erlang:spawn_monitor(?MODULE, call_middleman, [M,F,A]),
    receive
        {'DOWN', MRef, process, MPid, {call_middleman_result, Res}} ->
            reply_call_result({CallType, Caller, Res}, Socket, Driver, DriverMod);
        {'DOWN', MRef, process, MPid, AbnormalExit} ->
            reply_call_result({CallType, Caller, {badrpc, AbnormalExit}}, Socket, Driver, DriverMod)
    end.

%% Handle a call worker message
reply_call_result({_CallType,_Caller,_Res} = Payload, Socket, Driver, DriverMod) ->
    case DriverMod:send(Socket, gen_rpc_helper:term_to_iovec(Payload)) of
        ok ->
            ok;
        {error, Reason} ->
            ?log(error, "failed_to_send_call_reply",
                 #{driver => Driver,
                   socket => gen_rpc_helper:socket_to_string(Socket),
                   reason => Reason})
    end.

call_middleman(M, F, A) ->
    Res = try
            erlang:apply(M, F, A)
          catch
               throw:Term -> Term;
               exit:Reason -> {badrpc, {'EXIT', Reason}};
               error:Reason:Stacktrace -> {badrpc, {'EXIT', {Reason, Stacktrace}}}
          end,
    erlang:exit({call_middleman_result, Res}),
    ok.

%% Check if the function is RPC-enabled
check_if_module_allowed(_Module, disabled, _List) ->
    true;

check_if_module_allowed(Module, whitelist, List) ->
    sets:is_element(Module, List);

check_if_module_allowed(Module, blacklist, List) ->
    not sets:is_element(Module, List).

%% Check if the module version called is compatible with the one
%% requested by the caller
check_module_version_compat({M, Version}) ->
    try
        Attrs = M:module_info(attributes),
        {vsn, VsnList} = lists:keyfind(vsn, 1, Attrs),
        case VsnList of
            [Vsn] when Vsn =:= Version ->
                {true, M};
            Vsn when Vsn =:= Version ->
                {true, M};
            _Else ->
                {false, M}
        end
    catch
        error:undef ->
            ?log(debug, "module_not_found", #{mod => M}),
            {false, M};
        error:badarg ->
            ?log(debug, "invalid_module_definition", #{mod => M}),
            {false, M}
    end;

check_module_version_compat(M) ->
    {true, M}.

handle_cast(M, F, A, Ordered, #state{socket=Socket, driver=Driver, peer=_Peer, control=Control, list=List}) ->
    {ModVsnAllowed, RealM} = check_module_version_compat(M),
    case check_if_module_allowed(RealM, Control, List) of
        true ->
            case ModVsnAllowed of
                true ->
                    exec_cast(RealM, F, A, Ordered);
                false ->
                    ?log(debug, "incompatible_module_version",
                         #{driver => Driver,
                           socket => gen_rpc_helper:socket_to_string(Socket),
                           mod => RealM})
            end;
        false ->
            ?log(debug,
                 "request_not_allowed",
                 #{driver => Driver,
                   socket => gen_rpc_helper:socket_to_string(Socket),
                   method => cast,
                   control => Control,
                   mod => RealM
                  })
    end.

handle_abcast(Name, Msg, #state{socket=Socket, driver=Driver, control=Control, list=List}) ->
    case check_if_module_allowed(erlang, Control, List) of
        true ->
            Msg = erlang:send({Name, node()}, Msg);
        false ->
            ?log(debug, "request_not_allowed",
                 #{driver => Driver,
                   socket => gen_rpc_helper:socket_to_string(Socket),
                   control => Control,
                   method => abcast})
        end.

exec_cast(M, F, A, _PreserveOrder = true) ->
    {Pid, MRef} = erlang:spawn_monitor(M, F, A),
    receive
        {'DOWN', MRef, process, Pid, _} -> ok
    end;
exec_cast(M, F, A, _PreserveOrder = false) ->
    _ = erlang:spawn(M, F, A),
    ok.

reply_immediately(Payload, #state{driver_mod = DriverMod, driver = Driver, socket = Socket}) ->
    reply_call_result(Payload, Socket, Driver, DriverMod),
    {keep_state_and_data, gen_rpc_helper:get_inactivity_timeout(?MODULE)}.
