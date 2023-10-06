%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%% Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
%%%
%%% Original concept inspired and some code copied from
%%% https://erlangcentral.org/wiki/index.php?title=Building_a_Non-blocking_TCP_server_using_OTP_principles

-module(gen_rpc_driver_ssl).
-author("Panagiotis Papadomitsos <pj@ezgr.net>").

%%% Behaviour
-behaviour(gen_rpc_driver).

-include_lib("snabbkaffe/include/trace.hrl").
-include("logger.hrl").
%%% Include this library's name macro
-include("app.hrl").
%%% Include SSL macros
-include("ssl.hrl").
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
-spec connect(atom(), inet:port_number()) -> {ok, ssl:sslsocket()} | {error, term()}.
connect(Node, Port) when is_atom(Node) ->
    Host = gen_rpc_helper:host_from_node(Node),
    ConnTO = gen_rpc_helper:get_connect_timeout(),
    SslOpts = merge_ssl_options(client),
    case ssl:connect(Host, Port, SslOpts ++ gen_rpc_helper:get_user_tcp_opts(connect), ConnTO) of
        {ok, Socket} ->
            ?log(debug, "event=connect_to_remote_server peer=\"~s\" socket=\"~s\" result=success",
                 [Node, gen_rpc_helper:socket_to_string(Socket)]),
            {ok, Socket};
        {error, Reason} ->
            ?log(error, "event=connect_to_remote_server peer=\"~s\" result=failure reason=\"~p\"", [Node, Reason]),
            {error, {badtcp,Reason}}
    end.


-spec listen(inet:port_number()) -> {ok, ssl:sslsocket()} | {error, term()}.
listen(Port) when is_integer(Port) ->
    SslOpts = merge_ssl_options(server),
    ssl:listen(Port, SslOpts ++ gen_rpc_helper:get_user_tcp_opts(listen)
        ++ gen_rpc_helper:get_listen_ip_config()).

-spec accept(ssl:sslsocket()) -> {ok, ssl:sslsocket()} | {error, term()}.
accept(Socket) when is_tuple(Socket) ->
    {ok, TSocket} = ssl:transport_accept(Socket, infinity),
    case ssl:handshake(TSocket) of
        {ok, SslSocket} ->
            {ok, SslSocket};
        Error -> Error
    end.

-spec send(ssl:sslsocket(), binary()) -> ok | {error, term()}.
send(Socket, Data) when is_tuple(Socket), is_binary(Data) ->
    ?tp(gen_rpc_driver_send, #{data => Data, driver => ssl}),
    case ssl:send(Socket, Data) of
        {error, timeout} ->
            ?tp(error, gen_rpc_error, #{ error  => send_data_failed
                                       , socket => gen_rpc_helper:socket_to_string(Socket)
                                       , reason => timeout
                                       }),
            {error, {badtcp,send_timeout}};
        {error, Reason} ->
            ?tp(error, gen_rpc_error, #{ error  => send_data_failed
                                       , socket => gen_rpc_helper:socket_to_string(Socket)
                                       , reason => Reason
                                       }),
            {error, {badtcp, Reason}};
        ok ->
            ?tp(gen_rpc_driver_send_ok, #{driver => ssl}),
            ok
    end.

-spec activate_socket(ssl:sslsocket()) -> ok | {error, inet:posix()}.
activate_socket(Socket) when is_tuple(Socket) ->
    ssl:setopts(Socket, [{active, true}]).

-spec recv(ssl:sslsocket(), non_neg_integer(), timeout()) -> {ok, binary()} | {error, _}.
recv(Socket, Length, Timeout) ->
    ssl:recv(Socket, Length, Timeout).

-spec close(ssl:sslsocket()) -> ok | {error, _}.
close(Socket) ->
    ssl:close(Socket).

-spec copy_sock_opts(port(), port()) -> ok | {error, any()}.
copy_sock_opts(_ListSock, _AccSock) ->
    ok. % SSL copies the socket's options to the acceptor by default

-spec get_peer(ssl:sslsocket()) -> {inet:ip4_address(), inet:port_number()}.
get_peer(Socket) when is_tuple(Socket) ->
    {ok, Peer} = ssl:peername(Socket),
    Peer.

-spec set_controlling_process(ssl:sslsocket(), pid()) -> ok | {error, term()}.
set_controlling_process(Socket, Pid) when is_tuple(Socket), is_pid(Pid) ->
    ssl:controlling_process(Socket, Pid).

-spec set_send_timeout(ssl:sslsocket(), timeout() | undefined) -> ok.
set_send_timeout(Socket, SendTimeout) when is_tuple(Socket) ->
    ok = ssl:setopts(Socket, [{send_timeout, gen_rpc_helper:get_send_timeout(SendTimeout)}]),
    ok.

-spec set_acceptor_opts(ssl:sslsocket()) -> ok.
set_acceptor_opts(Socket) when is_tuple(Socket) ->
    ok = set_socket_keepalive(os:type(), Socket),
    ok = ssl:setopts(Socket, [{send_timeout, gen_rpc_helper:get_send_timeout(undefined)} |
                              gen_rpc_helper:get_user_tcp_opts(accept)]),
    ok.

-spec getstat(ssl:sslsocket(), list()) -> ok | {error, any()}.
getstat(Socket, OptNames) ->
    ssl:getstat(Socket, OptNames).

%%% ===================================================
%%% Private functions
%%% ===================================================
merge_ssl_options(client) ->
    {ok, ExtraOpts} = application:get_env(?APP, ssl_client_options),
    DefaultOpts = ?SSL_DEFAULT_COMMON_OPTS ++ ?SSL_DEFAULT_CLIENT_OPTS ++ get_cert_options(),
    gen_rpc_helper:merge_sockopt_lists(ExtraOpts, DefaultOpts);

merge_ssl_options(server) ->
    {ok, ExtraOpts} = application:get_env(?APP, ssl_server_options),
    DefaultOpts = ?SSL_DEFAULT_COMMON_OPTS ++ ?SSL_DEFAULT_SERVER_OPTS ++ get_cert_options(),
    gen_rpc_helper:merge_sockopt_lists(ExtraOpts, DefaultOpts).

get_cert_options() ->
    [{Key, Val} || Key <- [certfile, keyfile, cacertfile],
                   {ok, Val} <- [application:get_env(?APP, Key)]].

set_socket_keepalive({unix, darwin}, Socket) ->
    {ok, KeepIdle} = application:get_env(?APP, socket_keepalive_idle),
    {ok, KeepInterval} = application:get_env(?APP, socket_keepalive_interval),
    {ok, KeepCount} = application:get_env(?APP, socket_keepalive_count),
    ok = ssl:setopts(Socket, [{raw, ?DARWIN_SOL_SOCKET, ?DARWIN_SO_KEEPALIVE, <<1:32/native>>}]),
    ok = ssl:setopts(Socket, [{raw, ?DARWIN_IPPROTO_TCP, ?DARWIN_TCP_KEEPALIVE, <<KeepIdle:32/native>>}]),
    ok = ssl:setopts(Socket, [{raw, ?DARWIN_IPPROTO_TCP, ?DARWIN_TCP_KEEPINTVL, <<KeepInterval:32/native>>}]),
    ok = ssl:setopts(Socket, [{raw, ?DARWIN_IPPROTO_TCP, ?DARWIN_TCP_KEEPCNT, <<KeepCount:32/native>>}]),
    ok;

set_socket_keepalive({unix, linux}, Socket) ->
    {ok, KeepIdle} = application:get_env(?APP, socket_keepalive_idle),
    {ok, KeepInterval} = application:get_env(?APP, socket_keepalive_interval),
    {ok, KeepCount} = application:get_env(?APP, socket_keepalive_count),
    ok = ssl:setopts(Socket, [{raw, ?LINUX_SOL_SOCKET, ?LINUX_SO_KEEPALIVE, <<1:32/native>>}]),
    ok = ssl:setopts(Socket, [{raw, ?LINUX_SOL_TCP, ?LINUX_TCP_KEEPIDLE, <<KeepIdle:32/native>>}]),
    ok = ssl:setopts(Socket, [{raw, ?LINUX_SOL_TCP, ?LINUX_TCP_KEEPINTVL, <<KeepInterval:32/native>>}]),
    ok = ssl:setopts(Socket, [{raw, ?LINUX_SOL_TCP, ?LINUX_TCP_KEEPCNT, <<KeepCount:32/native>>}]),
    ok;

set_socket_keepalive(_Unsupported, _Socket) ->
    ok.

%% Dump session keys for wireshark. To enable this feature, add
%% `{keep_secrets, true}' to `SSL_DEFAULT_COMMON_OPTS' macro
%% dump_keys(Socket) ->
%%     {ok, [{keylog, Keylog}]} = ssl:connection_information(Socket, [keylog]),
%%     IOList = [[I, $\n] || I <- Keylog],
%%     file:write_file("/tmp/keydump", IOList, [append]).
