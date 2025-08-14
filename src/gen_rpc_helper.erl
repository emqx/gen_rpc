%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%% Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
%%%

-module(gen_rpc_helper).
-author("Panagiotis Papadomitsos <pj@ezgr.net>").

%%% Since a lot of these functions are simple
%%% let's inline them
-compile([inline]).

%%% Include this library's name macro
-include("app.hrl").
%%% Include helpful guard macros
-include("types.hrl").

-include_lib("snabbkaffe/include/trace.hrl").

-define(DEFAULT_LISTEN_PORT, 5370).
-define(MAX_PORT_LIMIT, 60000).

%%% Public API
-export([peer_to_string/1,
         socket_to_string/1,
         host_from_node/1,
         set_optimal_process_flags/0,
         is_driver_enabled/1,
         merge_sockopt_lists/2,
         get_user_tcp_opts/1,
         user_tcp_opt_key/1,
         get_server_driver_options/1,
         get_client_config_per_node/1,
         get_client_driver_options/1,
         get_connect_timeout/0,
         get_send_timeout/1,
         get_rpc_module_control/0,
         get_authentication_timeout/0,
         get_call_receive_timeout/1,
         get_sbcast_receive_timeout/0,
         get_control_receive_timeout/0,
         get_inactivity_timeout/1,
         get_async_call_inactivity_timeout/0,
         get_listen_ip_config/0,
         term_to_iovec/1]).

%%% ===================================================
%%% Public API
%%% ===================================================

%% term_to_iovec/1 wrapper to conditionally compress based on threshold
-spec term_to_iovec(term()) -> erlang:iovec().
term_to_iovec(Term) ->
  {ok, Compress} = application:get_env(?APP, compress),
  do_term_to_iovec(Term, Compress).

do_term_to_iovec(Term, Compress) when is_integer(Compress), Compress >= 1, Compress =< 9 ->
    Size = erlang:external_size(Term),
    {ok, CompressionThreshold} = application:get_env(?APP, compression_threshold),
    case Size > CompressionThreshold of
        true  ->
            Data = erlang:term_to_iovec(Term, [{compressed, Compress}]),
            ?tp_ignore_side_effects_in_prod(gen_rpc_compress_payload, #{ threshold => CompressionThreshold,
                                                                         original_size => Size,
                                                                         compressed_size => iolist_size(Data)
                                                                       }),
            Data;
        false -> erlang:term_to_iovec(Term)
    end;
do_term_to_iovec(Term, _) ->
    erlang:term_to_iovec(Term).

%% Return the connected peer's IP
-spec peer_to_string({inet:ip_address(), inet:port_number()} | inet:ip_address()) -> string().
peer_to_string({Ip, Port}) when tuple_size(Ip) =:= 4 ->
    inet:ntoa(Ip) ++ ":" ++ integer_to_list(Port);
peer_to_string({Ip, Port}) when tuple_size(Ip) =:= 8 ->
    "[" ++ inet:ntoa(Ip) ++ "]:" ++ integer_to_list(Port);
peer_to_string(Ip) when is_tuple(Ip) andalso (tuple_size(Ip) =:= 4 orelse tuple_size(Ip) =:= 8) ->
    peer_to_string({Ip, 0}).

-spec socket_to_string(term()) -> string().
socket_to_string(Socket) when is_port(Socket) ->
    io_lib:format("~p", [Socket]);

socket_to_string(Socket) when is_tuple(Socket) ->
    case Socket of
        {sslsocket, _, {TcpSock, _}} ->
            io_lib:format("~p", [TcpSock]);
        {sslsocket,{_, TcpSock, _, _}, _} ->
            io_lib:format("~p", [TcpSock]);
        _Else ->
            ssl_socket
    end.

%% Return the remote Erlang hostname
-spec host_from_node(node()) -> string().
host_from_node(Node) when is_atom(Node) ->
    NodeStr = atom_to_list(Node),
    [_Name, Host] = string:tokens(NodeStr, [$@]),
    Host.

%% Set optimal process flags
-spec set_optimal_process_flags() -> ok.
set_optimal_process_flags() ->
    _ = erlang:process_flag(trap_exit, true),
    _ = erlang:process_flag(priority, high),
    _ = erlang:process_flag(message_queue_data, off_heap),
    ok.

%% Merge lists that contain both tuples and simple values observing
%% keys in proplists
-spec merge_sockopt_lists(list(), list()) -> list().
merge_sockopt_lists(List1, List2) ->
    SList1 = lists:usort(fun hybrid_proplist_compare/2, List1),
    SList2 = lists:usort(fun hybrid_proplist_compare/2, List2),
    lists:umerge(fun hybrid_proplist_compare/2, SList1, SList2).

-spec is_driver_enabled(atom()) -> boolean().
is_driver_enabled(Driver) when is_atom(Driver) ->
    case application:get_env(?APP, driver) of
        {ok, OtherDriver} when OtherDriver =/= Driver ->
            %% Driver is set explicitly, and it's a different one:
            false;
        _ ->
            %% Either the driver is not set, or the settings match:
            Setting = erlang:list_to_atom(lists:concat([Driver, "_server_port"])),
            case application:get_env(?APP, Setting) of
                {ok, false} ->
                    false;
                {ok, _Port} ->
                    true
            end
    end.

-spec get_server_driver_options(atom()) -> tuple().
get_server_driver_options(Driver) when is_atom(Driver) ->
    DriverStr = erlang:atom_to_list(Driver),
    DriverMod = erlang:list_to_atom("gen_rpc_driver_" ++ DriverStr),
    ClosedMsg = erlang:list_to_atom(DriverStr ++ "_closed"),
    ErrorMsg = erlang:list_to_atom(DriverStr ++ "_error"),
    DriverPort = case application:get_env(?APP, port_discovery, manual) of
        manual ->
            PortSetting = erlang:list_to_atom(DriverStr ++ "_server_port"),
            {ok, Port} = application:get_env(?APP, PortSetting),
            Port;
        stateless ->
            port(node())
    end,
    {DriverMod, DriverPort, ClosedMsg, ErrorMsg}.

-spec get_client_driver_options(atom()) -> tuple().
get_client_driver_options(Driver) when is_atom(Driver) ->
    DriverStr = erlang:atom_to_list(Driver),
    DriverMod = erlang:list_to_atom("gen_rpc_driver_" ++ DriverStr),
    ClosedMsg = erlang:list_to_atom(DriverStr ++ "_closed"),
    ErrorMsg = erlang:list_to_atom(DriverStr ++ "_error"),
    {DriverMod, ClosedMsg, ErrorMsg}.

-spec get_client_config_per_node(node_or_tuple()) -> {atom(), inet:port_number()} | {error, {atom(), term()}}.
get_client_config_per_node({Node, _Key}) ->
    get_client_config_per_node(Node);
get_client_config_per_node(Node) when is_atom(Node) ->
    {ok, NodeConfig} = application:get_env(?APP, client_config_per_node),
    case NodeConfig of
        {external, Module} when is_atom(Module) ->
            try Module:get_config(Node) of
                {Driver, Port} when is_atom(Driver), is_integer(Port), Port > 0 ->
                    {Driver, Port};
                {error, Reason} ->
                    {error, Reason}
            catch
                Class:Reason ->
                    {error, {Class,Reason}}
            end;
        {internal, NodeMap} ->
            get_client_config_from_map(Node, NodeMap)
    end.

-spec get_connect_timeout() -> timeout().
get_connect_timeout() ->
    {ok, ConnTO} = application:get_env(?APP, connect_timeout),
    ConnTO.

%% Merges user-defined call receive timeout values with app timeout values
-spec get_call_receive_timeout(undefined | timeout()) -> timeout().
get_call_receive_timeout(undefined) ->
    {ok, RecvTimeout} = application:get_env(?APP, call_receive_timeout),
    RecvTimeout;

get_call_receive_timeout(Else) ->
    Else.

-spec get_rpc_module_control() -> {atom(), atom() | sets:set()}.
get_rpc_module_control() ->
    case application:get_env(?APP, rpc_module_control) of
        {ok, disabled} ->
            {disabled, disabled};
        {ok, Type} when Type =:= whitelist; Type =:= blacklist ->
            {ok, List} = application:get_env(?APP, rpc_module_list),
            {Type, sets:from_list(List)}
    end.

%% Retrieves the default authentication timeout
-spec get_authentication_timeout() -> timeout().
get_authentication_timeout() ->
    {ok, AuthTO} = application:get_env(?APP, authentication_timeout),
    AuthTO.

%% Returns the default sbcast receive timeout
-spec get_sbcast_receive_timeout() -> timeout().
get_sbcast_receive_timeout() ->
    {ok, RecvTimeout} = application:get_env(?APP, sbcast_receive_timeout),
    RecvTimeout.

%% Returns the default dispatch receive timeout
-spec get_control_receive_timeout() -> timeout().
get_control_receive_timeout() ->
    {ok, RecvTimeout} = application:get_env(?APP, control_receive_timeout),
    RecvTimeout.

%% Merges user-defined send timeout values with app timeout values
-spec get_send_timeout(undefined | timeout()) -> timeout().
get_send_timeout(undefined) ->
    {ok, SendTimeout} = application:get_env(?APP, send_timeout),
    SendTimeout;
get_send_timeout(Else) ->
    Else.

%% Returns default inactivity timeouts for different modules
-spec get_inactivity_timeout(gen_rpc_client | gen_rpc_acceptor) -> timeout().
get_inactivity_timeout(gen_rpc_client) ->
    {ok, TTL} = application:get_env(?APP, client_inactivity_timeout),
    TTL;

get_inactivity_timeout(gen_rpc_acceptor) ->
    {ok, TTL} = application:get_env(?APP, server_inactivity_timeout),
    TTL.

-spec get_async_call_inactivity_timeout() -> timeout().
get_async_call_inactivity_timeout() ->
    {ok, TTL} = application:get_env(?APP, async_call_inactivity_timeout),
    TTL.

-spec get_user_tcp_opts(listen | accept | connect) -> list().
get_user_tcp_opts(Type) ->
    get_user_tcp_opts(?USER_TCP_OPTS, Type).

%%% ===================================================
%%% Private functions
%%% ===================================================
get_client_config_from_map(Node, NodeConfig) ->
    case maps:find(Node, NodeConfig) of
        error ->
            {ok, Driver} = application:get_env(?APP, default_client_driver),
            DriverStr = erlang:atom_to_list(Driver),
            case application:get_env(?APP, port_discovery, manual) of
                manual ->
                    PortSetting = erlang:list_to_atom(DriverStr ++ "_client_port"),
                    {ok, Port} = application:get_env(?APP, PortSetting),
                    {Driver, Port};
                stateless ->
                    {Driver, port(Node)}
            end;
        {ok, {Driver,Port}} ->
            {Driver, Port};
        {ok, Port} ->
            {ok, Driver} = application:get_env(?APP, default_client_driver),
            {Driver, Port}
    end.

hybrid_proplist_compare({K1,_V1}, {K2,_V2}) ->
    K1 =< K2;

hybrid_proplist_compare(K1, K2) ->
    K1 =< K2.

get_user_tcp_opts(Keys, Type) ->
    lists:foldl(
        fun(Key, OptAcc) ->
            case application:get_env(?APP, Key) of
                undefined -> OptAcc;
                {ok, Val} -> [{user_tcp_opt_key(Key), Val} | OptAcc]
            end
        end, [], Keys) ++ ipv6_opts(Type).

%% Add 'inet6' to listen and connect options when 'ipv6_only' is configured 'true'
%% There is no need to force with 'ipv6_v6only' in inet options
%% becase we control both client and server code.
%% That is, it's enough to provide just 'inet6' option in connect options and
%% the client will try to connect server using ipv6.
ipv6_opts(accept) ->
    %% 'inet6' is not a valid option for 'inet:setopts' (for acceptor)
    [];
ipv6_opts(_) ->
    case {get_socket_ip(), is_ipv6_only()} of
        {{inet6, _Ip}, true} ->
            %% Configured to lisetn on ipv6 and want to use v6 only, add 'inet6' option.
            [inet6];
        {undefined, true} ->
            %% Listen address is ont configured.
            %% We try to add 'inet6' for both server and client.
            [inet6];
        _ ->
            %% When self-node is configured to listen on ipv4:
            %%   'listen':  it should absolutely not add 'inet6' option.
            %%   'connect': it is very much unlikely that the peer accepts
            %%              ipv6-only client hence no need to add 'inet6'
            %% Wehn self-node is configured to listen on ipv6:
            %%   'listen':  there is no need to add 'inet6' because the
            %%              8-tuple already implied 'inet6'.
            %%   'connect': it will by default try to connect server
            %%              with ipv4, server should usually accept it
            %%              even it is only listening on a v6 address.
            %%              This should allow a rolling upgrade of
            %%              nodes when deployed in a dule-stack
            %%              network.
            []
    end.

is_ipv6_only() ->
    {ok, true} =:= application:get_env(ipv6_only).

get_socket_ip() ->
    case application:get_env(?APP, socket_ip) of
        {ok, Ip} when is_tuple(Ip) andalso tuple_size(Ip) =:= 4 ->
            {inet, Ip};
        {ok, Ip} when is_tuple(Ip) andalso tuple_size(Ip) =:= 8 ->
            {inet6, Ip};
        _ ->
            undefined
    end.

get_listen_ip_config() ->
    case get_socket_ip() of
        undefined -> [];
        {_, IP} -> [{ip, IP}]
    end.

user_tcp_opt_key(socket_buffer) -> buffer;
user_tcp_opt_key(socket_recbuf) -> recbuf;
user_tcp_opt_key(socket_sndbuf) -> sndbuf.


%% @doc Figure out dist port from node's name.
-spec(port(node() | string()) -> inet:port_number()).
port(Name) when is_atom(Name) ->
    port(atom_to_list(Name));
port(Name) when is_list(Name) ->
    %% Figure out the base port.
    BasePort = ?DEFAULT_LISTEN_PORT,
    %% Now, figure out our "offset" on top of the base port.  The
    %% offset is the integer just to the left of the @ sign in our node
    %% name.  If there is no such number, the offset is 0.
    %%
    %% Also handle the case when no hostname was specified.
    BasePort + offset(Name).

%% @doc Figure out the offset by node's name
offset(NodeName) ->
    ShortName = re:replace(NodeName, "@.*$", ""),
    case re:run(ShortName, "[0-9]+$", [{capture, first, list}]) of
        nomatch ->
            0;
        {match, [OffsetAsString]} ->
            list_to_integer(OffsetAsString) rem ?MAX_PORT_LIMIT
    end.
