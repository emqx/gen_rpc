%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%% Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
%%%
%%% Original concept inspired and some code copied from
%%% https://erlangcentral.org/wiki/index.php?title=Building_a_Non-blocking_TCP_server_using_OTP_principles

-module(gen_rpc_server).
-author("Panagiotis Papadomitsos <pj@ezgr.net>").

%%% Behaviour
-behaviour(gen_statem).

%%% Include the HUT library
-include("logger.hrl").
%%% Include this library's name macro
-include("app.hrl").

-define(log(Level, Msg, Data), ?LOG(Level, ?T_SERVER, Msg, Data)).

%%% Local state
%%% Local state
-record(state, {socket :: port(),
        driver :: atom(),
        driver_mod :: atom()}).

%%% Server functions
-export([start_link/1, stop/1]).

%% gen_statem callbacks
-export([init/1, handle_event/4, callback_mode/0, terminate/3, code_change/4]).

%% State machine states
-export([waiting_for_connection/3]).

%%% ===================================================
%%% Supervisor functions
%%% ===================================================
-spec start_link(atom()) -> {ok, pid()} | {error, any()}.
start_link(Driver) when is_atom(Driver) ->
    case gen_rpc_helper:is_driver_enabled(Driver) of
        false -> ignore;
        true -> gen_statem:start_link({local, make_process_name(Driver)}, ?MODULE, {Driver}, [])
    end.

-spec stop(atom()) -> ok.
stop(Driver) when is_atom(Driver) ->
    gen_statem:stop(make_process_name(Driver), normal, infinity).

%%% ===================================================
%%% Behaviour callbacks
%%% ===================================================
init({Driver}) ->
    ok = gen_rpc_helper:set_optimal_process_flags(),
    _ = erlang:process_flag(trap_exit, false),
    {DriverMod, DriverPort, _ClosedMsg, _ErrorMsg} = gen_rpc_helper:get_server_driver_options(Driver),
    case DriverMod:listen(DriverPort) of
        {ok, Socket} ->
            %% Launch a new acceptor with a new accept socket
            ?log(info, "server_setup_successfully",
                 #{driver => Driver,
                   port => DriverPort,
                   socket => gen_rpc_helper:socket_to_string(Socket)}),
            {ok, waiting_for_connection, #state{socket=Socket, driver=Driver, driver_mod=DriverMod}, {next_event,internal,accept}};
        {error, Reason} ->
            ?log(error, "failed_to_setup_server",
                 #{driver => Driver,
                   port => DriverPort,
                   cause => Reason}),
            {stop, Reason}
    end.

callback_mode() ->
    state_functions.

waiting_for_connection(internal, accept, #state{socket=ListSock, driver=Driver, driver_mod=DriverMod} = State) ->
    case DriverMod:accept(ListSock) of
        {ok, AccSock} ->
            %% `gen_rpc_server' is a main process, it should never
            %% crash due to client misbehavior. So we wrap everything
            %% in try/catch.
            try
                Peer = DriverMod:get_peer(AccSock),
                {ok, AccPid} = gen_rpc_acceptor_sup:start_child(Driver, Peer),
                case DriverMod:copy_sock_opts(ListSock, AccSock) of
                    ok -> ok;
                    {error, Reason} -> exit({set_sock_opt, Reason})
                end,
                ok = DriverMod:set_controlling_process(AccSock, AccPid),
                ok = gen_rpc_acceptor:set_socket(AccPid, AccSock)
            catch
                EC:Err:Stack ->
                    ?log(warning, "failed_to_accept",
                         #{driver => Driver,
                           error_class => EC,
                           error => Err,
                           stack => Stack})
            end,
            {keep_state_and_data, {next_event,internal,accept}};
        {error, Reason} ->
            ?log(error, "socket_error_event",
                 #{driver => Driver,
                   socket => gen_rpc_helper:socket_to_string(ListSock),
                   event => Reason,
                   action => stopping}),
            {stop, {socket_error, Reason}, State}
    end.

handle_event(EventType, Event, StateName, #state{socket=Socket, driver=Driver} = State) ->
    ?log(error, "unknown_event",
         #{driver => Driver,
           socket => gen_rpc_helper:socket_to_string(Socket),
           event_type => EventType,
           payload => Event,
           action => stopping}),
    {stop, {StateName, undefined_event, Event}, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%% ===================================================
%%% Private functions
%%% ===================================================

-spec make_process_name(atom()) -> atom().
make_process_name(Driver) when is_atom(Driver) ->
    DriverStr = erlang:atom_to_list(Driver),
    erlang:list_to_atom("gen_rpc_server_" ++ DriverStr).
