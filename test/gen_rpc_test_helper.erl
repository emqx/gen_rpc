%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright (c) 2015-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%% Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
%%%
-module(gen_rpc_test_helper).
-author("Panagiotis Papadomitsos <pj@ezgr.net>").
-vsn("1.0.0").

%%% CT Macros
-include_lib("test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-compile(nowarn_deprecated_function). %% Silence the warnings about slave module

%%% Public API
-export([start_distribution/1,
         start_master/1,
         start_slave/2,
         start_slave/1,
         stop_slave/0,
         set_driver_configuration/2,
         set_application_environment/1,
         store_driver_in_config/2,
         get_driver_from_config/1,
         get_test_functions/1,
         spawn_long_running/1,
         spawn_short_running/0,
         stub_function/0,
         ping/1,
         test_call/1,
         init_integration_test_config/0
        ]).

-compile(nowarn_deprecated_function).

%%% ===================================================
%%% Public API
%%% ===================================================

init_integration_test_config() ->
    _ = application:load(gen_rpc),
    ProjRoot = os:getenv("PROJ_ROOT"),
    case os:getenv("TEST_WITH_SOCKET_IP") of
        [_|_] = IpStr ->
            {ok, Ip} = inet:parse_address(IpStr),
            io:format(user, "===< Setting 'socket_ip' ~p~n", [Ip]),
            ok = set_env(socket_ip, Ip);
        _ ->
            io:format(user, "===< Not setting 'socket_ip'~n", [])
    end,
    case os:getenv("TEST_WITH_IPV6ONLY") of
        "true" ->
            io:format(user, "===< Setting 'ipv6_only' to 'true'~n", []),
            ok = set_env(ipv6_only, true);
        _ ->
            io:format(user, "===< Not forcing 'ipv6_only'", [])
    end,
    case os:getenv("TEST_WITH_SSL") of
        "true" ->
            io:format(user, "===< Setting default driver to 'ssl'~n", []),
            ok = set_env(default_client_driver, ssl),
            %% disable tcp
            ok = set_env(tcp_server_port, false),
            %% enable ssl
            ok = set_env(ssl_server_port, 5370),
            ok = set_env(ssl_server_options, certs(ProjRoot)),
            ok = set_env(ssl_client_options, certs(ProjRoot));
        _ ->
            io:format(user, "===< Not testing with SSL~n", [])
    end.

set_env(Key, Value) ->
     application:set_env(gen_rpc, Key, Value, [{persistent, true}]).

certs(Dir) ->
    [ {certfile, filename:join(Dir, "priv/ssl/gen_rpc_master@127.0.0.1.cert.pem")},
      {keyfile, filename:join(Dir, "priv/ssl/gen_rpc_master@127.0.0.1.key.pem")},
      {cacertfile, filename:join(Dir, "priv/ssl/ca.cert.pem")}
    ].

%% Start target test erlang node
start_distribution(Node)->
    %% Try to spin up net_kernel
    case net_kernel:start([Node, longnames]) of
        {ok, _} ->
            {ok, {Node, started}};
        {error,{already_started, _Pid}} ->
            {ok, {Node, already_started}};
        {error, Reason} ->
            ok = ct:pal("function=start_target event=fail_start_target reason=\"~p\"", [Reason]),
            {error, Reason}
    end.

start_master(Driver) ->
    ok = set_application_environment(?MASTER),
    ok = set_driver_configuration(Driver, ?MASTER),
    %% Start the application remotely
    {ok, _Apps} = application:ensure_all_started(?APP),
    ok.

start_slave(Driver) ->
    start_slave(Driver, code:get_path()).

start_slave(Driver, Paths) ->
    stop_slave(),
    %% Starting a slave node with Distributed Erlang
    SlaveStr = atom_to_list(?SLAVE),
    [NameStr, IpStr] = string:tokens(SlaveStr, [$@]),
    Name = list_to_atom(NameStr),
    ok = do_start_peer(IpStr, Name),
    ok = rpc:call(?SLAVE, code, add_pathsz, [Paths]),
    ok = set_application_environment(?SLAVE),
    ok = set_driver_configuration(Driver, ?SLAVE),
    %% Start the application remotely
    {ok, _SlaveApps} = rpc:call(?SLAVE, application, ensure_all_started, [?APP]),
    snabbkaffe:forward_trace(?SLAVE),
    ok.

do_start_peer(IpStr, Name) ->
    {ok,  Pid, Node} = peer:start(#{host => IpStr, longnames => true, name => Name}),
    _ = register(Node, Pid),
    ok.

stop_slave() ->
    try
        ok = peer:stop(?SLAVE)
    catch
        exit : noproc ->
            ok
    end.

set_application_environment(?MASTER) ->
    ok = lists:foreach(fun({Application, Key, Value}) ->
        ok = application:set_env(Application, Key, Value, [{persistent, true}])
    end, ?TEST_APPLICATION_ENV),
    ok;

set_application_environment(?SLAVE) ->
    ok = lists:foreach(fun({Application, Key, Value}) ->
        ok = rpc:call(?SLAVE, application, set_env, [Application, Key, Value, [{persistent, true}]])
    end, ?TEST_APPLICATION_ENV),
    ok.

set_driver_configuration(ssl, ?MASTER) ->
    Prefix = code:priv_dir(?APP),
    CertFile = filename:join([Prefix, "ssl", atom_to_list(?MASTER)]),
    CaFile = filename:join([Prefix, "ssl", "ca.cert.pem"]),
    ok = application:set_env(?APP, default_client_driver, ssl, [{persistent, true}]),
    ok = application:set_env(?APP, ssl_server_port, ?MASTER_PORT, [{persistent, true}]),
    ok = application:set_env(?APP, certfile, CertFile ++ ".cert.pem", [{persistent, true}]),
    ok = application:set_env(?APP, keyfile, CertFile ++ ".key.pem", [{persistent, true}]),
    ok = application:set_env(?APP, cacertfile, CaFile, [{persistent, true}]);

set_driver_configuration(ssl, ?SLAVE) ->
    Prefix = code:priv_dir(?APP),
    CertFile = filename:join([Prefix, "ssl", atom_to_list(?SLAVE)]),
    CaFile = filename:join([Prefix, "ssl", "ca.cert.pem"]),
    ok = rpc:call(?SLAVE, application, set_env, [?APP, default_client_driver, ssl, [{persistent, true}]]),
    ok = rpc:call(?SLAVE, application, set_env, [?APP, ssl_server_port, ?SLAVE_PORT, [{persistent, true}]]),
    ok = rpc:call(?SLAVE, application, set_env, [?APP, ssl_server_options, [
                  {certfile, CertFile ++ ".cert.pem"},
                  {keyfile, CertFile ++ ".key.pem"},
                  {cacertfile, CaFile}], [{persistent, true}]]),
    ok = rpc:call(?SLAVE, application, set_env, [?APP, ssl_client_options, [
                  {certfile, CertFile ++ ".cert.pem"},
                  {keyfile, CertFile ++ ".key.pem"},
                  {cacertfile, CaFile}], [{persistent, true}]]),
    ok;

set_driver_configuration(tcp, ?MASTER) ->
    ok = application:set_env(?APP, default_client_driver, tcp, [{persistent, true}]),
    ok = application:set_env(?APP, tcp_server_port, ?MASTER_PORT, [{persistent, true}]),
    ok;

set_driver_configuration(tcp, ?SLAVE) ->
    ok = rpc:call(?SLAVE, application, set_env, [?APP, default_client_driver, tcp, [{persistent, true}]]),
    ok = rpc:call(?SLAVE, application, set_env, [?APP, tcp_server_port, ?SLAVE_PORT, [{persistent, true}]]),
    ok.

store_driver_in_config(Driver, State) ->
    lists:keystore(driver, 1, State, {driver,Driver}).

restart_application() ->
    _ = application:stop(?APP),
    ok = timer:sleep(100),
    {ok, _Apps} = application:ensure_all_started(?APP),
    ok.

get_test_functions(Module) ->
    {exports, Functions} = lists:keyfind(exports, 1, Module:module_info()),
    [FName || {FName, _} <- lists:filter(
                               fun ({module_info,_}) -> false;
                                   ({all,_}) -> false;
                                   %% Local tests
                                   ({init_per_suite,_}) -> false;
                                   ({end_per_suite,_}) -> false;
                                   ({interleaved_call_proc,_}) -> false;
                                   ({interleaved_call_executor,_}) -> false;
                                   ({interleaved_call_loop,_}) -> false;
                                   ({get_config,_}) -> false;
                                   %% Multi RPC
                                   ({spawn_listener,_}) -> false;
                                   ({spawn_listener2,_}) -> false;
                                   ({loop1,_}) -> false;
                                   ({loop2,_}) -> false;
                                   ({wait_for_reply,_}) -> false;
                                   ({terminate_process,_}) -> false;
                                   %% Else
                                   ({_,1}) -> true;
                                   ({_,_}) -> false
                               end, Functions)].

get_driver_from_config(Config) ->
    case lists:keyfind(driver, 1, Config) of
        false -> ?DEFAULT_DRIVER;
        {driver, Driver} -> Driver
    end.

spawn_long_running(TimeSpan) ->
    spawn(fun() -> timer:sleep(TimeSpan) end).

spawn_short_running() ->
    spawn(fun() -> exit(normal) end).

stub_function() ->
  stub_function.

ping({Node, Process, Msg}) ->
    {Process, Node} ! {pong, {node(), Process, Msg}}.

test_call(SeqNo) ->
    ?tp(do_test_call, #{seqno => SeqNo}).
