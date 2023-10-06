%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%% Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
%%%
%%% Original concept inspired and some code copied from
%%% https://erlangcentral.org/wiki/index.php?title=Building_a_Non-blocking_TCP_server_using_OTP_principles

-module(gen_rpc_driver_tcp).
-author("Panagiotis Papadomitsos <pj@ezgr.net>").

%%% Behaviour
-behaviour(gen_rpc_driver).

-include("logger.hrl").
-include_lib("snabbkaffe/include/trace.hrl").
%%% Include this library's name macro
-include("app.hrl").
%%% Include TCP macros
-include("tcp.hrl").
%%% Include helpful guard macros
-include("guards.hrl").

%%% Public API
-export([connect/2,
        listen/1,
        accept/1,
        get_peer/1,
        send/2,
        activate_socket/1,
        recv/3,
        close/1,
        copy_sock_opts/2,
        set_controlling_process/2,
        set_send_timeout/2,
        set_acceptor_opts/1,
        getstat/2]).

%%% ===================================================
%%% Public API
%%% ===================================================
%% Connect to a node
-spec connect(atom(), inet:port_number()) -> {ok, port()} | {error, term()}.
connect(Node, Port) when is_atom(Node) ->
    Host = gen_rpc_helper:host_from_node(Node),
    ConnTO = gen_rpc_helper:get_connect_timeout(),
    case gen_tcp:connect(Host, Port, ?TCP_DEFAULT_OPTS ++ gen_rpc_helper:get_user_tcp_opts(connect), ConnTO) of
        {ok, Socket} ->
            ?log(debug, "event=connect_to_remote_server peer=\"~s\" socket=\"~s\" result=success",
                 [Node, gen_rpc_helper:socket_to_string(Socket)]),
            {ok, Socket};
        {error, Reason} ->
            ?log(error, "event=connect_to_remote_server peer=\"~s\" result=failure reason=\"~p\"", [Node, Reason]),
            {error, {badtcp,Reason}}
    end.

-spec listen(inet:port_number()) -> {ok, port()} | {error, term()}.
listen(Port) when is_integer(Port) ->
    gen_tcp:listen(Port, ?TCP_DEFAULT_OPTS ++ gen_rpc_helper:get_user_tcp_opts(listen)
        ++ gen_rpc_helper:get_listen_ip_config()).

-spec accept(port()) -> {ok, inet:socket()} | {error, term()}.
accept(Socket) when is_port(Socket) ->
    gen_tcp:accept(Socket, infinity).

-spec activate_socket(port()) -> ok | {error, inet:posix()}.
activate_socket(Socket) when is_port(Socket) ->
    inet:setopts(Socket, [{active,true}]).

-spec send(port(), binary()) -> ok | {error, term()}.
send(Socket, Data) when is_port(Socket), is_binary(Data) ->
    case gen_tcp:send(Socket, Data) of
        {error, timeout} ->
            ?log(error, "event=send_data_failed socket=\"~s\" reason=\"timeout\"", [gen_rpc_helper:socket_to_string(Socket)]),
            {error, {badtcp,send_timeout}};
        {error, Reason} ->
            ?log(error, "event=send_data_failed socket=\"~s\" reason=\"~p\"", [gen_rpc_helper:socket_to_string(Socket), Reason]),
            {error, {badtcp,Reason}};
        ok ->
            ?log(debug, "event=send_data_succeeded socket=\"~s\"", [gen_rpc_helper:socket_to_string(Socket)]),
            ok
    end.

-spec recv(gen_tcp:socket(), non_neg_integer(), timeout()) -> {ok, binary()} | {error, _}.
recv(Socket, Length, Timeout) ->
    gen_tcp:recv(Socket, Length, Timeout).

-spec close(gen_tcp:socket()) -> ok | {error, _}.
close(Socket) ->
    gen_tcp:close(Socket).

%% Taken from prim_inet.  We are merely copying some socket options from the
%% listening socket to the new acceptor socket.
-spec copy_sock_opts(port(), port()) -> ok | {error, any()}.
copy_sock_opts(ListSock, AccSock) when is_port(ListSock), is_port(AccSock) ->
    true = inet_db:register_socket(AccSock, inet_tcp),
    case prim_inet:getopts(ListSock, ?ACCEPTOR_COPY_TCP_OPTS) of
        {ok, SockOpts} ->
            case prim_inet:setopts(AccSock, SockOpts) of
                ok -> ok;
                Error -> Error
            end;
        Error ->
            Error
        end.

-spec get_peer(port()) -> {inet:ip4_address(), inet:port_number()}.
get_peer(Socket) when is_port(Socket) ->
    {ok, Peer} = inet:peername(Socket),
    Peer.

-spec set_controlling_process(port(), pid()) -> ok | {error, term()}.
set_controlling_process(Socket, Pid) when is_port(Socket), is_pid(Pid) ->
    gen_tcp:controlling_process(Socket, Pid).

-spec set_send_timeout(port(), timeout() | undefined) -> ok.
set_send_timeout(Socket, SendTimeout) when is_port(Socket) ->
    ok = inet:setopts(Socket, [{send_timeout, gen_rpc_helper:get_send_timeout(SendTimeout)}]),
    ok.

-spec set_acceptor_opts(port()) -> ok.
set_acceptor_opts(Socket) when is_port(Socket) ->
    ok = set_socket_keepalive(os:type(), Socket),
    ok = inet:setopts(Socket, [{send_timeout, gen_rpc_helper:get_send_timeout(undefined)}|?ACCEPTOR_DEFAULT_TCP_OPTS ++ gen_rpc_helper:get_user_tcp_opts(accept)]),
    ok.

-spec getstat(port(), list()) -> ok | {error, term()}.
getstat(Socket, OptNames) ->
    inet:getstat(Socket, OptNames).

%%% ===================================================
%%% Private functions
%%% ===================================================
set_socket_keepalive({unix, darwin}, Socket) ->
    {ok, KeepIdle} = application:get_env(?APP, socket_keepalive_idle),
    {ok, KeepInterval} = application:get_env(?APP, socket_keepalive_interval),
    {ok, KeepCount} = application:get_env(?APP, socket_keepalive_count),
    ok = inet:setopts(Socket, [{raw, ?DARWIN_SOL_SOCKET, ?DARWIN_SO_KEEPALIVE, <<1:32/native>>}]),
    ok = inet:setopts(Socket, [{raw, ?DARWIN_IPPROTO_TCP, ?DARWIN_TCP_KEEPALIVE, <<KeepIdle:32/native>>}]),
    ok = inet:setopts(Socket, [{raw, ?DARWIN_IPPROTO_TCP, ?DARWIN_TCP_KEEPINTVL, <<KeepInterval:32/native>>}]),
    ok = inet:setopts(Socket, [{raw, ?DARWIN_IPPROTO_TCP, ?DARWIN_TCP_KEEPCNT, <<KeepCount:32/native>>}]),
    ok;

set_socket_keepalive({unix, linux}, Socket) ->
    {ok, KeepIdle} = application:get_env(?APP, socket_keepalive_idle),
    {ok, KeepInterval} = application:get_env(?APP, socket_keepalive_interval),
    {ok, KeepCount} = application:get_env(?APP, socket_keepalive_count),
    ok = inet:setopts(Socket, [{raw, ?LINUX_SOL_SOCKET, ?LINUX_SO_KEEPALIVE, <<1:32/native>>}]),
    ok = inet:setopts(Socket, [{raw, ?LINUX_SOL_TCP, ?LINUX_TCP_KEEPIDLE, <<KeepIdle:32/native>>}]),
    ok = inet:setopts(Socket, [{raw, ?LINUX_SOL_TCP, ?LINUX_TCP_KEEPINTVL, <<KeepInterval:32/native>>}]),
    ok = inet:setopts(Socket, [{raw, ?LINUX_SOL_TCP, ?LINUX_TCP_KEEPCNT, <<KeepCount:32/native>>}]),
    ok;

set_socket_keepalive(_Unsupported, _Socket) ->
    ok.
