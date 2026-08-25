%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(auth_SUITE).

%%% CT Macros
-include_lib("test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("stdlib/include/assert.hrl").

%%% No need to export anything, everything is automatically exported
%%% as part of the test profile

%%% ===================================================
%%% CT callback functions
%%% ===================================================
all() ->
    [{group, tcp}, {group, ssl}].

suite() ->
    [{timetrap, {minutes, 1}}].

old_tags() ->
    ['2.8.1', '3.0.0', '3.1.0'].

groups() ->
    {Compat, Regular} =
        lists:foldl(
          fun({Fun, _Arity}, {Comp, Reg}) ->
                  case atom_to_list(Fun) of
                      "t_compat_" ++ _ -> {[Fun|Comp], Reg};
                      "t_"        ++ _ -> {Comp, [Fun|Reg]};
                      _                -> {Comp, Reg}
                  end
          end,
          {[], []},
          ?MODULE:module_info(exports)),
    CompatGroups = [{OldTag, [], Compat} || OldTag <- old_tags()],
    [{tcp, [], Regular ++ CompatGroups}, {ssl, [], Regular ++ CompatGroups}].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_group(Group, Config) when Group =:= tcp; Group =:= ssl ->
    % Our group name is the name of the driver
    Driver = Group,
    %% Starting Distributed Erlang on local node
    {ok, _Pid} = gen_rpc_test_helper:start_distribution(?MASTER),
    %% Save the driver in the state
    gen_rpc_test_helper:store_driver_in_config(Driver, Config);
init_per_group(CompatGroupTag, Config) ->
    %% Build old versions of gen_rpc to test backward/forward compatibility:
    Dir = build_old_rel(CompatGroupTag, Config),
    [{old_rel_dir, Dir}, {old_tag, CompatGroupTag} | Config].

end_per_group(_Driver, Config) ->
    Config.

init_per_testcase(Testcase, Config) ->
    snabbkaffe:fix_ct_logging(),
    logger:notice("Running ~p", [Testcase]),
    application:load(?APP),
    PrevEnv = application:get_all_env(?APP),
    %% Save environment variables, so they can be restored later:
    [{prev_env, PrevEnv}|Config].

end_per_testcase(_Testcase, Config) ->
    %% Restore environment variables:
    ok = gen_rpc_test_helper:stop_slave(),
    ok = application:stop(?APP),
    snabbkaffe:stop(),
    meck:unload(),
    %% Reset application env:
    OldEnv = proplists:get_value(prev_env, Config),
    lists:foreach(fun({K, V}) -> application:set_env(?APP, K, V) end, OldEnv),
    NewKeys = proplists:get_keys(application:get_all_env(?APP)) --
         proplists:get_keys(OldEnv),
    lists:foreach(fun(K) -> application:unset_env(?APP, K) end, NewKeys),
    ok.

%%% ===================================================
%%% Test cases
%%% ===================================================
%% Test main functions

%% Check normal flow:
t_challenge_response_ok(Config) ->
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    ?check_trace(
       #{timetrap => 5000},
       begin
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver),
           ?assertMatch(?SLAVE, gen_rpc:call(?SLAVE, erlang, node, [])),
           ?assertMatch(?SLAVE, gen_rpc:call({?SLAVE, destination}, erlang, node, []))
       end,
       fun(Trace) ->
               ?assertMatch([], ?of_kind(gen_rpc_insecure_fallback, Trace)),
               Stages = ?of_kind(gen_rpc_authentication_stage, Trace),
               ?assertMatch([1, 2, 3, 4, 1, 2, 3, 4], ?projection(stage, Stages))
       end).

%% In this testcase we don't test auth, but the rest of the gen_rpc library.
%%
%% We mock authentication to always fail and verify that it prevents access.
t_auth_server_fail(Config) ->
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    ?check_trace(
       #{timetrap => 5000},
       begin
           meck:new(gen_rpc_auth, [passthrough]),
           meck:expect(gen_rpc_auth, connect_with_auth,
                       fun(_Driver, _Node, _Port) ->
                               {error, {badrpc, invalid_cookie}}
                       end),
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver),
           ?assert(
               begin
                   Res = gen_rpc:call(?SLAVE, ?MODULE, canary, []),
                   Res =:= {badrpc, invalid_cookie} orelse match_unknown_call_error(Res)
               end
           )
       end,
       [ fun ?MODULE:prop_canary/1
       , fun ?MODULE:prop_client_authentication_failed_trace/1
       ]).

%% In this testcase we don't test auth, but the rest of the gen_rpc library.
%%
%% We mock authentication to always fail and verify that it prevents access.
t_auth_client_fail(Config) ->
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    ?check_trace(
       #{timetrap => 5000},
       begin
           meck:new(gen_rpc_auth, [passthrough]),
           meck:expect(gen_rpc_auth, authenticate_client,
                       fun(_Driver, _Socket, _Peer) ->
                               {error, {badrpc, invalid_cookie}}
                       end),
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver),
           Node = node(),
           ?assertNotMatch(canary_is_dead,
                           erpc:call(?SLAVE, gen_rpc, call, [Node, ?MODULE, canary, []]))
       end,
       [ fun ?MODULE:prop_canary/1
       ]).

%% The client has invalid cookie:
t_challenge_response_invalid_cookie_client(Config) ->
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    ?check_trace(
       #{timetrap => 5000},
       try
           application:set_env(?APP, secret_cookie, <<"wrong">>),
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver),
           ?assertMatch({badrpc, invalid_cookie}, gen_rpc:call(?SLAVE, ?MODULE, canary, []))
       after
           application:unset_env(?APP, secret_cookie)
       end,
       [ fun ?MODULE:prop_canary/1
       , fun ?MODULE:prop_no_fallback/1
       ]).

%% The server has invalid cookie:
t_challenge_response_invalid_cookie_server(Config) ->
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    ?check_trace(
       #{timetrap => 5000},
       begin
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver),
           erpc:call(?SLAVE, application, set_env, [?APP, secret_cookie, <<"wrong">>]),
           ?assertMatch({badrpc, invalid_cookie},
                        gen_rpc:call(?SLAVE, ?MODULE, canary, []))
       end,
       [ fun ?MODULE:prop_canary/1
       , fun ?MODULE:prop_no_fallback/1
       ]).

%% Invalid client port mapping configuration that points to the wrong node:
t_cr_invalid_server(Config) ->
    application:set_env(?APP, port_discovery, manual),
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    ?check_trace(
       #{timetrap => 5000},
       begin
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver),
           ?assertMatch({badrpc, badnode},
                        gen_rpc:call(?BAD_NODE, ?MODULE, canary, [])),
           %% Check with destination:
           ?assertMatch({badrpc, badnode},
                        gen_rpc:call({?BAD_NODE, foo}, ?MODULE, canary, []))
       end,
       [ fun ?MODULE:prop_canary/1
       , fun ?MODULE:prop_no_fallback/1
       ]).

%% Regression test for the removed insecure auth fallback: the peer
%% closes the connection during challenge-response.  Before 4.0.0 this
%% made the client (with `insecure_auth_fallback_allowed' set) open a
%% second connection and send the raw cookie.  Capture every byte the
%% client sends and assert the cookie is never transmitted.
t_no_cookie_on_wire_peer_closes(Config) ->
    no_cookie_on_wire(Config, close_on_challenge, {badrpc, {badtcp, closed}}).

%% Regression test for the removed insecure auth fallback: the peer
%% rejects challenge-response with a bad response (the other condition
%% that used to trigger the fallback).  Capture every byte the client
%% sends and assert the cookie is never transmitted.
t_no_cookie_on_wire_peer_rejects(Config) ->
    no_cookie_on_wire(Config, reject_challenge, {badrpc, invalid_cookie}).

no_cookie_on_wire(Config, Mode, ExpectedResult) ->
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    Cookie = <<"super_secret_cookie_must_not_leak">>,
    ?check_trace(
       #{timetrap => 5000},
       begin
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = application:set_env(?APP, secret_cookie, Cookie),
           {FakePeer, Port} = start_fake_peer(Driver, Mode),
           %% Point the client configuration for ?SLAVE at the fake peer:
           ok = application:set_env(?APP, client_config_per_node,
                                    {internal, #{?SLAVE => Port}}),
           Result = gen_rpc:call(?SLAVE, ?MODULE, canary, []),
           {Connections, Packets} = stop_fake_peer(FakePeer),
           %% The core property: no captured byte sequence contains
           %% the cookie:
           lists:foreach(
             fun(Packet) ->
                     ?assertEqual(nomatch, binary:match(Packet, Cookie), Packet)
             end,
             Packets),
           %% The call failed.  The client process may stop before the
           %% caller's request reaches it; the error is then wrapped
           %% in unknown_error:
           ?assert(Result =:= ExpectedResult orelse match_unknown_call_error(Result),
                   {unexpected_result, Result}),
           %% The client must not open a second connection to retry
           %% with a downgraded protocol:
           ?assertEqual(1, Connections),
           %% The only packet the client sends is the CR challenge:
           ?assertMatch([_], Packets),
           [ChallengePacket] = Packets,
           ?assertMatch({gen_rpc_authenticate_c, _},
                        binary_to_term(ChallengePacket))
       end,
       [ fun ?MODULE:prop_canary/1
       , fun ?MODULE:prop_no_fallback/1
       ]).

%% Compatibility: a peer that speaks challenge-response (gen_rpc 3.0.0
%% and later) authenticates normally.  A peer that predates
%% challenge-response must fail to authenticate: the insecure auth
%% fallback was removed in 4.0.0, so this node never reveals the
%% cookie to such a peer.
t_compat_old_server(Config) ->
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    ?check_trace(
       #{timetrap => 5000},
       begin
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver, old_path(Config)),
           case peer_speaks_cr(Config) of
               true ->
                   ?assertMatch(?SLAVE, gen_rpc:call(?SLAVE, erlang, node, []));
               false ->
                   ?assertMatch({badrpc, _}, gen_rpc:call(?SLAVE, ?MODULE, canary, []))
           end
       end,
       [ fun ?MODULE:prop_canary/1
       , fun ?MODULE:prop_no_insecure_fallback/1
       ]).

%% Compatibility: same as t_compat_old_server, but the old peer is the
%% client.  An old client that sends the legacy cookie packet must be
%% rejected.
t_compat_old_client(Config) ->
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    ?check_trace(
       #{timetrap => 5000},
       begin
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver, old_path(Config)),
           Result = erpc:call(?SLAVE, gen_rpc, call, [?MASTER, ?MODULE, canary, []]),
           case peer_speaks_cr(Config) of
               true ->
                   ?assertMatch(canary_is_dead, Result);
               false ->
                   %% The 2.8.1 client reports the closed connection
                   %% as {badtcp, closed}:
                   ?assertMatch({Err, _} when Err =:= badrpc orelse Err =:= badtcp,
                                Result)
           end,
           Config
       end,
       [ fun ?MODULE:prop_compat_client_canary/2
       , fun ?MODULE:prop_no_insecure_fallback/1
       ]).

%% Compatibility (bad cookie): authentication must fail for every peer
%% version.
t_compat_old_server_invalid_cookie(Config) ->
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    ?check_trace(
       #{timetrap => 5000},
       begin
           application:set_env(?APP, secret_cookie, <<"wrong_cookie">>),
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver, old_path(Config)),
           case peer_speaks_cr(Config) of
               true ->
                   ?assertMatch({badrpc, invalid_cookie},
                                gen_rpc:call(?SLAVE, ?MODULE, canary, []));
               false ->
                   ?assertMatch({badrpc, _},
                                gen_rpc:call(?SLAVE, ?MODULE, canary, []))
           end
       end,
       [ fun ?MODULE:prop_canary/1
       , fun ?MODULE:prop_no_insecure_fallback/1
       ]).

%% Compatibility (bad cookie): same as above, but the old peer is the
%% client.
t_compat_old_client_invalid_cookie(Config) ->
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    ?check_trace(
       #{timetrap => 5000},
       begin
           application:set_env(?APP, secret_cookie, <<"wrong_cookie">>),
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver, old_path(Config)),
           Result = erpc:call(?SLAVE, gen_rpc, call, [?MASTER, ?MODULE, canary, []]),
           case peer_speaks_cr(Config) of
               true ->
                   ?assertMatch({badrpc, invalid_cookie}, Result);
               false ->
                   %% The 2.8.1 client reports the closed connection
                   %% as {badtcp, closed}:
                   ?assertMatch({Err, _} when Err =:= badrpc orelse Err =:= badtcp,
                                Result)
           end
       end,
       [ fun ?MODULE:prop_canary/1
       , fun ?MODULE:prop_no_insecure_fallback/1
       ]).

%%% ===================================================
%%% Auxiliary functions for test cases
%%% ===================================================

canary() ->
    ?tp(gen_rpc_canary, #{}),
    canary_is_dead.

prop_canary(Trace) ->
    ?assertMatch([], ?of_kind(gen_rpc_canary, Trace)).

prop_client_authentication_failed_trace(Trace) ->
    Events = ?of_kind(client_authentication_failed, Trace),
    ?assertMatch([_ | _], Events),
    ?assert(
        lists:any(
            fun
                (#{cause := {badrpc, invalid_cookie}}) ->
                    true;
                (_) ->
                    false
            end,
            Events
        )
    ).

prop_no_fallback(Trace) ->
    ?assertMatch([], ?of_kind([gen_rpc_insecure_fallback, gen_rpc_auth_cr_v1_fallback], Trace)).

%% The insecure auth fallback was removed in 4.0.0.  The trace point is
%% gone from the code; this property is a tripwire in case it is ever
%% reintroduced.
prop_no_insecure_fallback(Trace) ->
    ?assertMatch([], ?of_kind(gen_rpc_insecure_fallback, Trace)).

prop_compat_client_canary(Config, Trace) ->
    case peer_speaks_cr(Config) of
        true ->
            ?assertMatch([_], ?of_kind(gen_rpc_canary, Trace));
        false ->
            ?assertMatch([], ?of_kind(gen_rpc_canary, Trace))
    end.

%%% ===================================================
%%% Fake peer: captures every byte the client sends
%%% ===================================================

%% Start a peer that speaks just enough of the protocol to trigger the
%% two conditions that used to activate the insecure auth fallback,
%% while capturing every packet the client sends:
%%
%% - close_on_challenge: receive the CR challenge, then close the
%%   connection.
%% - reject_challenge: receive the CR challenge, then answer it with a
%%   challenge-response computed from a wrong secret, so the client
%%   fails with `invalid_cookie'.
%%
%% Each accepted connection is reported to the test process as a
%% `{fake_peer_connection, Pid}' message and each received packet as a
%% `{fake_peer_packet, Pid, Packet}' message.
start_fake_peer(Driver, Mode) ->
    Parent = self(),
    Pid = spawn_link(fun() -> fake_peer_init(Driver, Mode, Parent) end),
    receive
        {fake_peer_up, Pid, Port} ->
            {Pid, Port}
    after 5000 ->
            error(fake_peer_start_timeout)
    end.

stop_fake_peer(Pid) ->
    unlink(Pid),
    MRef = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', MRef, process, Pid, _} ->
            ok
    end,
    collect_fake_peer_events(Pid, 0, []).

collect_fake_peer_events(Pid, Connections, Packets) ->
    receive
        {fake_peer_connection, Pid} ->
            collect_fake_peer_events(Pid, Connections + 1, Packets);
        {fake_peer_packet, Pid, Packet} ->
            collect_fake_peer_events(Pid, Connections, Packets ++ [Packet])
    after 0 ->
            {Connections, Packets}
    end.

fake_peer_init(tcp, Mode, Parent) ->
    {ok, LSock} = gen_tcp:listen(0, fake_peer_listen_opts()),
    {ok, Port} = inet:port(LSock),
    Parent ! {fake_peer_up, self(), Port},
    fake_peer_accept_loop(tcp, LSock, Mode, Parent);
fake_peer_init(ssl, Mode, Parent) ->
    %% Present the real slave certificate, so the client's peer
    %% verification succeeds and authentication proceeds to the
    %% challenge-response stage:
    Prefix = code:priv_dir(?APP),
    CertFile = filename:join([Prefix, "ssl", atom_to_list(?SLAVE)]),
    CaFile = filename:join([Prefix, "ssl", "ca.cert.pem"]),
    Opts = [ {certfile, CertFile ++ ".cert.pem"}
           , {keyfile, CertFile ++ ".key.pem"}
           , {cacertfile, CaFile}
           , {verify, verify_none}
           | fake_peer_listen_opts()],
    {ok, LSock} = ssl:listen(0, Opts),
    {ok, {_Ip, Port}} = ssl:sockname(LSock),
    Parent ! {fake_peer_up, self(), Port},
    fake_peer_accept_loop(ssl, LSock, Mode, Parent).

fake_peer_listen_opts() ->
    [binary, {packet, 4}, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}].

fake_peer_accept_loop(Driver, LSock, Mode, Parent) ->
    case fake_peer_accept(Driver, LSock) of
        {ok, Socket} ->
            Parent ! {fake_peer_connection, self()},
            fake_peer_serve(Driver, Socket, Mode, Parent),
            fake_peer_accept_loop(Driver, LSock, Mode, Parent);
        {error, _} ->
            ok
    end.

fake_peer_accept(tcp, LSock) ->
    gen_tcp:accept(LSock);
fake_peer_accept(ssl, LSock) ->
    case ssl:transport_accept(LSock) of
        {ok, TSock} ->
            ssl:handshake(TSock, 5000);
        Error ->
            Error
    end.

fake_peer_serve(Driver, Socket, Mode, Parent) ->
    case fake_peer_recv(Driver, Socket) of
        {ok, Packet} ->
            Parent ! {fake_peer_packet, self(), Packet},
            case Mode of
                close_on_challenge ->
                    fake_peer_close(Driver, Socket);
                reject_challenge ->
                    %% Answer the challenge with a response computed
                    %% from a wrong secret (matching the record format
                    %% of gen_rpc_auth):
                    Reply = term_to_binary({gen_rpc_authenticate_cr,
                                            crypto:strong_rand_bytes(32),
                                            crypto:strong_rand_bytes(8)}),
                    _ = fake_peer_send(Driver, Socket, Reply),
                    fake_peer_serve(Driver, Socket, Mode, Parent)
            end;
        {error, _} ->
            fake_peer_close(Driver, Socket)
    end.

fake_peer_recv(tcp, Socket) ->
    gen_tcp:recv(Socket, 0, 5000);
fake_peer_recv(ssl, Socket) ->
    ssl:recv(Socket, 0, 5000).

fake_peer_send(tcp, Socket, Data) ->
    gen_tcp:send(Socket, Data);
fake_peer_send(ssl, Socket, Data) ->
    ssl:send(Socket, Data).

fake_peer_close(tcp, Socket) ->
    gen_tcp:close(Socket);
fake_peer_close(ssl, Socket) ->
    ssl:close(Socket).

old_path(Config) ->
    OldRelDir = proplists:get_value(old_rel_dir, Config),
    %% TODO: different releases could use different versions of the
    %% dependencies, so it's safer to just use all ebin paths from the
    %% old rel.
    Paths = lists:filter(fun(Path) -> not lists:suffix("gen_rpc/ebin", Path) end,
                         code:get_path()),
    [OldRelDir|Paths].

%% build old version app
%% ensure REBAR_PROFILE is 'default' because the 'test' profile
%% uses a deprecated module
%% have to use 'sed' command to delete the line '  , {fail_if_no_peer_cert, true}
%% because this option is no longer allowed in newer version OTP (26)
build_old_rel(Tag, Config) ->
    DataDir = filename:join(proplists:get_value(data_dir, Config), Tag),
    Ret = os:cmd("mkdir -p '" ++ DataDir ++ "' &&
                  cd '" ++ DataDir ++ "' &&
                  git clone https://github.com/emqx/gen_rpc.git || true &&
                  cd gen_rpc &&
                  git checkout '" ++ atom_to_list(Tag) ++ "' &&
                  sed -i 's/^\s*, {fail_if_no_peer_cert, true}/%&/' include/ssl.hrl &&
                  sed -i 's|{snabbkaffe,.*}|{snabbkaffe, {git, \"https://github.com/kafka4beam/snabbkaffe\", {tag, \"1.0.10\"}}}|' rebar.config &&
                  env REBAR_PROFILE=default rebar3 compile &&
                  echo 'DONE'"),
    case lists:suffix("DONE\n", Ret) of
        true ->
            ok;
        false ->
            ct:pal("~ts", [Ret]),
            error(compilation_failed)
    end,
    filename:join(DataDir, "gen_rpc/_build/default/lib/gen_rpc/ebin").

peer_speaks_cr(Config) ->
    %% Challenge-response authentication was introduced in 3.0.0.
    %% Older peers only speak the insecure cookie protocol and cannot
    %% authenticate with this version.
    atom_to_list(proplists:get_value(old_tag, Config)) >= "3".

match_unknown_call_error({badrpc, {unknown_error, _}}) ->
    true;
match_unknown_call_error(_) ->
    false.
