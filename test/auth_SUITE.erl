%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

groups() ->
    Cases = [F || {F, _A} <- ?MODULE:module_info(exports),
                  case atom_to_list(F) of
                      "t_" ++ _ -> true;
                      _         -> false
                  end],
    [{tcp, [], Cases}, {ssl, [], Cases}].

init_per_group(Group, Config) ->
    % Our group name is the name of the driver
    Driver = Group,
    %% Starting Distributed Erlang on local node
    {ok, _Pid} = gen_rpc_test_helper:start_distribution(?MASTER),
    %% Save the driver in the state
    gen_rpc_test_helper:store_driver_in_config(Driver, Config).

end_per_group(_Driver, _Config) ->
    ok.

init_per_testcase(external_client_config_source, Config) ->
    PrevEnv = application:get_all_env(?APP),
    %% No need to restore original setting with an
    %% end_per_testcase since this setting gets overwritten
    %% upon every application restart
    ok = application:set_env(?APP, client_config_per_node, {external, ?MODULE}),
    [{prev_env, PrevEnv}|Config];
init_per_testcase(Testcase, Config) ->
    snabbkaffe:fix_ct_logging(),
    logger:notice("Running ~p", [Testcase]),
    PrevEnv = application:get_all_env(?APP),
    %% Save environment variables, so they can be restored later:
    [{prev_env, PrevEnv}|Config].

end_per_testcase(_Testcase, Config) ->
    %% Restore environment variables:
    ok = gen_rpc_test_helper:stop_slave(),
    ok = application:stop(gen_rpc),
    OldEnv = proplists:get_value(prev_env, Config),
    snabbkaffe:stop(),
    meck:unload(),
    lists:foreach(fun({K, V}) -> application:set_env(?APP, K, V) end, OldEnv).

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
           ?assertMatch(?SLAVE, gen_rpc:call(?SLAVE, erlang, node, []))
       end,
       fun(Trace) ->
               ?assertMatch([], ?of_kind(gen_rpc_insecure_fallback, Trace)),
               Stages = ?of_kind(gen_rpc_authentication_stage, Trace),
               ?assertMatch([1, 2, 3, 4], ?projection(stage, Stages))
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
           meck:expect(gen_rpc_auth, authenticate_server,
                       fun(_Driver, _Socket) ->
                               {error, {badrpc, unauthorized}}
                       end),
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver),
           ?assertMatch({badrpc, unauthorized}, gen_rpc:call(?SLAVE, ?MODULE, canary, []))
       end,
       [ fun ?MODULE:prop_canary/1
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
                               {error, {badrpc, unauthorized}}
                       end),
           ok = gen_rpc_test_helper:start_master(Driver),
           ok = gen_rpc_test_helper:start_slave(Driver),
           Node = node(),
           ?assertNotMatch(canary_is_dead,
                           erpc:call(?SLAVE,
                                     fun() ->
                                             gen_rpc:call(Node, ?MODULE, canary, [])
                                     end))
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
           ?assertMatch({badrpc, unauthorized}, gen_rpc:call(?SLAVE, ?MODULE, canary, []))
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
           erpc:call(?SLAVE,
                     fun() ->
                             application:set_env(?APP, secret_cookie, <<"wrong">>)
                     end),
           ?assertMatch({badrpc, unauthorized},
                        gen_rpc:call(?SLAVE, ?MODULE, canary, []))
       end,
       [ fun ?MODULE:prop_canary/1
       , fun ?MODULE:prop_no_fallback/1
       ]).

%%% ===================================================
%%% Auxiliary functions for test cases
%%% ===================================================

canary() ->
    ?tp(gen_rpc_canary, #{}),
    canary_is_dead.

prop_canary(Trace) ->
    ?assertMatch([], ?of_kind(gen_rpc_canary, Trace)).

prop_no_fallback(Trace) ->
    ?assertMatch([], ?of_kind(gen_rpc_insecure_fallback, Trace)).