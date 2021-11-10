%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
%%%

-module(remote_SUITE).
-author("Panagiotis Papadomitsos <pj@ezgr.net>").

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
    Cases = gen_rpc_test_helper:get_test_functions(?MODULE),
    [{tcp, [], Cases}, {ssl, [], Cases}].

init_per_group(Group, Config) ->
    % Our group name is the name of the driver
    Driver = Group,
    %% Starting Distributed Erlang on local node
    {ok, _Pid} = gen_rpc_test_helper:start_distribution(?MASTER),
    %% Setup the app locally
    ok = gen_rpc_test_helper:start_master(Driver),
    %% Save the driver in the state
    gen_rpc_test_helper:store_driver_in_config(Driver, Config).

end_per_group(_Driver, _Config) ->
    ok.

init_per_testcase(external_client_config_source, Config) ->
    PrevEnv = application:get_all_env(?APP),
    ok = gen_rpc_test_helper:restart_application(),
    ok = gen_rpc_test_helper:start_master(ssl),
    ok = gen_rpc_test_helper:start_slave(tcp),
    %% No need to restore original setting with an
    %% end_per_testcase since this setting gets overwritten
    %% upon every application restart
    ok = application:set_env(?APP, client_config_per_node, {external, ?MODULE}),
    [{prev_env, PrevEnv}|Config];
init_per_testcase(Testcase, Config) ->
    ct:print("Running ~p", [Testcase]),
    PrevEnv = application:get_all_env(?APP),
    ok = gen_rpc_test_helper:restart_application(),
    Driver = gen_rpc_test_helper:get_driver_from_config(Config),
    ok = gen_rpc_test_helper:start_master(Driver),
    ok = gen_rpc_test_helper:start_slave(Driver),
    %% Save environment variables, so they can be restored later:
    [{prev_env, PrevEnv}|Config].

end_per_testcase(_Testcase, Config) ->
    %% Restore environment variables:
    ok = gen_rpc_test_helper:stop_slave(),
    OldEnv = proplists:get_value(prev_env, Config),
    lists:foreach(fun({K, V}) -> application:set_env(?APP, K, V) end, OldEnv).

%%% ===================================================
%%% Test cases
%%% ===================================================
%% Test main functions
call(_Config) ->
    {_Mega, _Sec, _Micro} = gen_rpc:call(?SLAVE, os, timestamp).

call_mfa_undef(_Config) ->
    {badrpc, {'EXIT', {undef,[{os,timestamp_undef,_,_},_]}}} = gen_rpc:call(?SLAVE, os, timestamp_undef).

call_mfa_exit(_Config) ->
    {badrpc, {'EXIT', die}} = gen_rpc:call(?SLAVE, erlang, exit, ['die']).

call_mfa_throw(_Config) ->
    'throwXdown' = gen_rpc:call(?SLAVE, erlang, throw, ['throwXdown']).

call_with_receive_timeout(_Config) ->
    {badrpc, timeout} = gen_rpc:call(?SLAVE, timer, sleep, [500], 100),
    ok = timer:sleep(500).

call_module_version_check_success(_Config) ->
    stub_function = gen_rpc:call(?SLAVE, {gen_rpc_test_helper, "1.0.0"}, stub_function, []).

call_module_version_check_incompatible(_Config) ->
    {badrpc, incompatible} = gen_rpc:call(?SLAVE, {gen_rpc_test_helper, "X.Y.Z"}, stub_function, []).

call_module_version_check_invalid(_Config) ->
    {badrpc, incompatible} = gen_rpc:call(?SLAVE, {gen_rpc_test_helper1, "X.Y.Z"}, stub_function, []),
    {badrpc, incompatible} = gen_rpc:call(?SLAVE, {rpc, 1}, cast, []).

interleaved_call(_Config) ->
    %% Spawn 3 consecutive processes that execute gen_rpc:call
    %% to the remote node and wait an inversely proportionate time
    %% for their result (effectively rendering the results out of order)
    %% in order to test proper data interleaving
    Pid1 = erlang:spawn(ct_common, interleaved_call_proc, [?SLAVE, self(), 1, infinity]),
    Pid2 = erlang:spawn(ct_common, interleaved_call_proc, [?SLAVE, self(), 2, 1]), %% This call should timeout
    Pid3 = erlang:spawn(ct_common, interleaved_call_proc, [?SLAVE, self(), 3, infinity]),
    ok = ct_common:interleaved_call_loop(Pid1, Pid2, Pid3, 0).

cast(_Config) ->
    true = gen_rpc:cast(?SLAVE, erlang, timestamp).

cast_anonymous_function(_Config) ->
    true = gen_rpc:cast(?SLAVE, erlang, apply, [fun() -> os:timestamp() end, []]).

cast_mfa_undef(_Config) ->
    true = gen_rpc:cast(?SLAVE, os, timestamp_undef, []).

cast_mfa_exit(_Config) ->
    true = gen_rpc:cast(?SLAVE, erlang, apply, [fun() -> exit(die) end, []]).

cast_mfa_throw(_Config) ->
    true = gen_rpc:cast(?SLAVE, erlang, throw, ['throwme']).

cast_inexistent_node(_Config) ->
    true = gen_rpc:cast(?FAKE_NODE, os, timestamp, [], 1000).

call_node(_Config) ->
    ?SLAVE = gen_rpc:call(?SLAVE, erlang, node, []).

call_with_worker_kill(_Config) ->
    {badrpc, killed} = gen_rpc:call(?SLAVE, timer, kill_after, [0]).

async_call(_Config) ->
    YieldKey0 = gen_rpc:async_call(?SLAVE, os, timestamp, []),
    {_Mega, _Sec, _Micro} = gen_rpc:yield(YieldKey0),
    NbYieldKey0 = gen_rpc:async_call(?SLAVE, os, timestamp, []),
    {value,{_,_,_}} = gen_rpc:nb_yield(NbYieldKey0, 50),
    YieldKey = gen_rpc:async_call(?SLAVE, io_lib, print, [yield_key]),
    "yield_key" = gen_rpc:yield(YieldKey),
    NbYieldKey = gen_rpc:async_call(?SLAVE, io_lib, print, [nb_yield_key]),
    {value, "nb_yield_key"} = gen_rpc:nb_yield(NbYieldKey, 50).

async_call_yield_reentrant(_Config) ->
    YieldKey0 = gen_rpc:async_call(?SLAVE, os, timestamp, []),
    {_Mega, _Sec, _Micro} = gen_rpc:yield(YieldKey0),
    Self = self(),
    Pid = erlang:spawn(fun()->
        timeout = gen_rpc:yield(YieldKey0),
        Self ! {self(), something_went_wrong}
    end),
    receive
        _ ->
            exit(got_answer_when_none_expected)
    after
        5000 ->
            true = erlang:exit(Pid, brutal_kill)
    end,
    NbYieldKey0 = gen_rpc:async_call(?SLAVE, os, timestamp, []),
    % Verify not able to reuse Key again. Key is one time use.
    {_,_,_} = gen_rpc:yield(NbYieldKey0),
    timeout = gen_rpc:nb_yield(NbYieldKey0, 10),
    YieldKey = gen_rpc:async_call(?SLAVE, io_lib, print, [yield_key]),
    "yield_key" = gen_rpc:yield(YieldKey),
    NbYieldKey = gen_rpc:async_call(?SLAVE, io_lib, print, [nb_yield_key]),
    {value, "nb_yield_key"} = gen_rpc:nb_yield(NbYieldKey, 50).

async_call_mfa_undef(_Config) ->
    YieldKey = gen_rpc:async_call(?SLAVE, os, timestamp_undef),
    {badrpc, {'EXIT', {undef,[{os,timestamp_undef,_,_},_]}}} = gen_rpc:yield(YieldKey),
    NBYieldKey = gen_rpc:async_call(?SLAVE, os, timestamp_undef),
    {value, {badrpc, {'EXIT', {undef,[{os,timestamp_undef,_,_},_]}}}} = gen_rpc:nb_yield(NBYieldKey, 50),
    ok = ct:pal("Result [async_call_mfa_undef]: signal=EXIT Reason={os,timestamp_undef}").

async_call_mfa_exit(_Config) ->
    YieldKey = gen_rpc:async_call(?SLAVE, erlang, exit, ['die']),
    {badrpc, {'EXIT', die}} = gen_rpc:yield(YieldKey),
    NBYieldKey = gen_rpc:async_call(?SLAVE, erlang, exit, ['die']),
    {value, {badrpc, {'EXIT', die}}} = gen_rpc:nb_yield(NBYieldKey, 50),
    ok = ct:pal("Result [async_call_mfa_undef]: signal=EXIT Reason={os,timestamp_undef}").

async_call_mfa_throw(_Config) ->
    YieldKey = gen_rpc:async_call(?SLAVE, erlang, throw, ['throwXdown']),
    'throwXdown' = gen_rpc:yield(YieldKey),
    NBYieldKey = gen_rpc:async_call(?SLAVE, erlang, throw, ['throwXdown']),
    {value, 'throwXdown'} = gen_rpc:nb_yield(NBYieldKey, 50),
    ok = ct:pal("Result [async_call_mfa_undef]: throw Reason={throwXdown}").

async_call_yield_timeout(_Config) ->
    NBYieldKey = gen_rpc:async_call(?SLAVE, timer, sleep, [1000]),
    timeout = gen_rpc:nb_yield(NBYieldKey, 5),
    ok = ct:pal("Result [async_call_yield_timeout]: signal=badrpc Reason={timeout}").

async_call_nb_yield_infinity(_Config) ->
    YieldKey = gen_rpc:async_call(?SLAVE, timer, sleep, [1000]),
    ok = gen_rpc:yield(YieldKey),
    NBYieldKey = gen_rpc:async_call(?SLAVE, timer, sleep, [1000]),
    {value, ok} = gen_rpc:nb_yield(NBYieldKey, infinity),
    ok = ct:pal("Result [async_call_yield_infinity]: timer_sleep Result={ok}").

client_inactivity_timeout(_Config) ->
    ok = application:set_env(?APP, client_inactivity_timeout, 500),
    {_Mega, _Sec, _Micro} = gen_rpc:call(?SLAVE, os, timestamp),
    ok = timer:sleep(600),
    undefined = gen_rpc_client:where_is(?SLAVE),
    [] = supervisor:which_children(gen_rpc_client_sup).

server_inactivity_timeout(_Config) ->
    ok = rpc:call(?SLAVE, application, set_env, [?APP, server_inactivity_timeout, 500]),
    {_Mega, _Sec, _Micro} = gen_rpc:call(?SLAVE, os, timestamp),
    ok = timer:sleep(600),
    undefined = gen_rpc_client:where_is(?SLAVE),
    [] = supervisor:which_children(gen_rpc_client_sup).

random_local_tcp_close(_Config) ->
    {_Mega, _Sec, _Micro} = rpc:call(?SLAVE, gen_rpc, call, [?MASTER, os, timestamp, []]),
    [{_,AccPid,_,_}] = supervisor:which_children(gen_rpc_acceptor_sup),
    true = erlang:exit(AccPid, kill),
    ok = timer:sleep(600), % Give some time to the supervisor to kill the children
    [] = rpc:call(?SLAVE, gen_rpc, nodes, []),
    [] = supervisor:which_children(gen_rpc_acceptor_sup),
    [] = rpc:call(?SLAVE, supervisor, which_children, [gen_rpc_client_sup]).

random_remote_tcp_close(_Config) ->
    {_Mega, _Sec, _Micro} = gen_rpc:call(?SLAVE, os, timestamp),
    [{_,AccPid,_,_}] = rpc:call(?SLAVE, supervisor, which_children, [gen_rpc_acceptor_sup]),
    true = rpc:call(?SLAVE, erlang, exit, [AccPid,kill]),
    ok = timer:sleep(600),
    [] = gen_rpc:nodes(),
    [] = supervisor:which_children(gen_rpc_client_sup),
    [] = rpc:call(?SLAVE, supervisor, which_children, [gen_rpc_acceptor_sup]).

rpc_module_whitelist(_Config) ->
    ok = rpc:call(?SLAVE, application, set_env, [?APP, rpc_module_list, [erlang, os]]),
    ok = rpc:call(?SLAVE, application, set_env, [?APP, rpc_module_control, whitelist]),
    {_Mega, _Sec, _Micro} = gen_rpc:call(?SLAVE, os, timestamp),
    ?SLAVE = gen_rpc:call(?SLAVE, erlang, node),
    {badrpc, unauthorized} = gen_rpc:call(?SLAVE, application, which_applications).

rpc_module_blacklist(_Config) ->
    ok = rpc:call(?SLAVE, application, set_env, [?APP, rpc_module_list, [erlang, os]]),
    ok = rpc:call(?SLAVE, application, set_env, [?APP, rpc_module_control, blacklist]),
    {badrpc, unauthorized} = gen_rpc:call(?SLAVE, os, timestamp),
    {badrpc, unauthorized} = gen_rpc:call(?SLAVE, erlang, node),
    60000 = gen_rpc:call(?SLAVE, timer, seconds, [60]).

external_client_config_source(_Config) ->
    ok = application:set_env(?APP, client_config_per_node, {external, ?MODULE}),
    {_Mega, _Sec, _Micro} = gen_rpc:call(?SLAVE, os, timestamp).

wrong_cookie(_Config) ->
    OrigCookie = erlang:get_cookie(),
    RandCookie = list_to_atom(atom_to_list(OrigCookie) ++ "123"),
    true = erlang:set_cookie(node(), RandCookie),
    {badrpc, invalid_cookie} = gen_rpc:call(?SLAVE, os, timestamp, []),
    true = erlang:set_cookie(node(), OrigCookie).

multiple_casts_test(_Config) ->
    %% Send multiple casts and check that they are received in order
    N = 10000,
    L = [integer_to_binary(L) || L <- lists:seq(12000, 12000 + N)],
    Last = lists:last(L),
    ?check_trace(
       begin
           ?wait_async_action( [begin
                                    ?tp(test_cast, #{seqno => I}),
                                    true = gen_rpc:cast({?SLAVE, 1}, gen_rpc_test_helper, test_call, [I])
                                end || I <- L]
                             , #{?snk_kind := do_test_call, seqno := Last}
                             ),
           ok
       end,
       fun(_Ret, Trace) ->
               %% 1. Check that all casts were received by a local client process before sending over net:
               ?assert(
                  ?strict_causality( #{?snk_kind := test_cast, seqno := _SeqNoA}
                                   , #{?snk_kind := gen_rpc_cast, cast := {cast, gen_rpc_test_helper, test_call, [_SeqNoB]}}
                                   , _SeqNoA == _SeqNoB
                                   , Trace
                                   )),
               ?assert(
                  ?strict_causality( #{?snk_kind := gen_rpc_cast,      cast   := _CastA, sendto := _SendToA}
                                   , #{?snk_kind := gen_rpc_send_cast, packet := _CastB, sendto := _SendToB}
                                   , _CastA == _CastB andalso _SendToA == _SendToB
                                   , Trace
                                   )),
               %% 2. Check that no message reordering occurs on the client side:
               snabbkaffe:strictly_increasing(?projection(packet, ?of_kind(gen_rpc_send_cast, Trace))),
               %% 3. Check that no errors were detected:
               ?assertMatch([], ?of_kind(gen_rpc_error, Trace)),
               %% 4. Check delivery of the messages:
               ?assert(
                  ?strict_causality( #{?snk_kind := gen_rpc_send_cast, packet := _PacketA}
                                   , #{?snk_kind := gen_rpc_acceptor_receive, packet := _PacketB}
                                   , _PacketA == _PacketB
                                   , Trace
                                   )),
               %% 5. Check that all the messages were delivered:
               Calls = ?of_kind(do_test_call, Trace),
               ?projection_complete(seqno, Calls, L),
               %% 6. Check that all calls are executed in order:
               %% snabbkaffe:strictly_increasing(Calls), %% FIXME: Fails due to bug
               true
       end).

%%% ===================================================
%%% Auxiliary functions for test cases
%%% ===================================================

%% Enable TCP only communication to the slave when testing
%% the external client config source
%% This should force communication with the slave
%% over TCP even on the SSL group
get_config(?SLAVE) ->
  {tcp, ?SLAVE_PORT}.
