%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%% Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
%%%

-module(local_SUITE).
-author("Panagiotis Papadomitsos <pj@ezgr.net>").

%%% CT Macros
-include_lib("test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
%%% TCP settings
-include("tcp.hrl").

%%% No need to export anything, everything is automatically exported
%%% as part of the test profile

%%% ===================================================
%%% CT callback functions
%%% ===================================================
all() ->
    gen_rpc_test_helper:get_test_functions(?MODULE).

suite() ->
    [{timetrap, {minutes, 1}}].

init_per_suite(Config) ->
    %% Starting Distributed Erlang on local node
    {ok, _Pid} = gen_rpc_test_helper:start_distribution(?MASTER),
    %% Setup the app locally
    ok = gen_rpc_test_helper:start_master(tcp),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Testcase, Config) ->
    ct:print("Running ~p", [Testcase]),
    ok = gen_rpc_test_helper:restart_application(),
    ok = gen_rpc_test_helper:start_master(tcp),
    %% Save environment variables, so they can be restored later:
    PrevEnv = application:get_all_env(?APP),
    [{prev_env, PrevEnv}|Config].

end_per_testcase(_Testcase, Config) ->
    %% Restore environment variables:
    OldEnv = proplists:get_value(prev_env, Config),
    lists:foreach(fun({K, V}) -> application:set_env(?APP, K, V) end, OldEnv).

%%% ===================================================
%%% Test cases
%%% ===================================================
%% Test supervisor's status
supervisor_black_box(_Config) ->
    true = erlang:is_process_alive(erlang:whereis(gen_rpc_acceptor_sup)),
    true = erlang:is_process_alive(erlang:whereis(gen_rpc_client_sup)),
    true = erlang:is_process_alive(erlang:whereis(gen_rpc_server_tcp)),
    true = erlang:is_process_alive(erlang:whereis(gen_rpc_dispatcher)),
    ok.

%% Test main functions
call(_Config) ->
    {_Mega, _Sec, _Micro} = gen_rpc:call(?MASTER, os, timestamp).

call_anonymous_function(_Config) ->
    {_,"\"call_anonymous_function\""} = gen_rpc:call(?MASTER, erlang, apply,[fun(A) -> {self(), io_lib:print(A)} end,
                                                     ["call_anonymous_function"]]).

call_anonymous_undef(_Config) ->
    {badrpc, {'EXIT', {undef,[{os,timestamp_undef,[],[]},_]}}}  = gen_rpc:call(?MASTER, erlang, apply, [fun() -> os:timestamp_undef() end, []]),
    ok = ct:pal("Result [call_anonymous_undef]: signal=EXIT Reason={os,timestamp_undef}").

call_mfa_undef(_Config) ->
    {badrpc, {'EXIT', {undef,[{os,timestamp_undef,_,_},_]}}} = gen_rpc:call(?MASTER, os, timestamp_undef),
    ok = ct:pal("Result [call_mfa_undef]: signal=EXIT Reason={os,timestamp_undef}").

call_mfa_exit(_Config) ->
    {badrpc, {'EXIT', die}} = gen_rpc:call(?MASTER, erlang, exit, ['die']),
    ok = ct:pal("Result [call_mfa_undef]: signal=EXIT Reason={die}").

call_mfa_throw(_Config) ->
    'throwXdown' = gen_rpc:call(?MASTER, erlang, throw, ['throwXdown']),
    ok = ct:pal("Result [call_mfa_undef]: signal=EXIT Reason={throwXdown}").

call_with_receive_timeout(_Config) ->
    {badrpc, timeout} = gen_rpc:call(?MASTER, timer, sleep, [500], 1),
    ok = timer:sleep(500).

call_with_worker_kill(_Config) ->
    {badrpc, killed} = gen_rpc:call(?MASTER, timer, kill_after, [0]).

call_module_version_check_success(_Config) ->
    stub_function = gen_rpc:call(?MASTER, {gen_rpc_test_helper, "1.0.0"}, stub_function, []).

call_module_version_check_incompatible(_Config) ->
    {badrpc, incompatible} = gen_rpc:call(?MASTER, {gen_rpc_test_helper, "X.Y.Z"}, stub_function, []).

call_module_version_check_invalid(_Config) ->
    {badrpc, incompatible} = gen_rpc:call(?MASTER, {gen_rpc_test_helper1, "X.Y.Z"}, stub_function, []),
    {badrpc, incompatible} = gen_rpc:call(?MASTER, {rpc, 1}, cast, []).

interleaved_call(_Config) ->
    %% Spawn 3 consecutive processes that execute gen_rpc:call
    %% to the remote node and wait an inversely proportionate time
    %% for their result (effectively rendering the results out of order)
    %% in order to test proper data interleaving
    Pid1 = erlang:spawn(ct_common, interleaved_call_proc, [?MASTER, self(), 1, infinity]),
    Pid2 = erlang:spawn(ct_common, interleaved_call_proc, [?MASTER, self(), 2, 1]), %% This call should timeout
    Pid3 = erlang:spawn(ct_common, interleaved_call_proc, [?MASTER, self(), 3, infinity]),
    ok = ct_common:interleaved_call_loop(Pid1, Pid2, Pid3, 0).

authentication_timeout(_Config) ->
    ok = application:set_env(?APP, authentication_timeout, 100),

    ok = gen_rpc_test_helper:restart_application(),
    ok = gen_rpc_test_helper:start_master(tcp),

    [] = supervisor:which_children(gen_rpc_acceptor_sup),
    ct:pal("Connecting..."),
    {ok, _Sock} = gen_tcp:connect("127.0.0.1", ?MASTER_PORT, ?TCP_DEFAULT_OPTS),
    %% Give the server some time to launch the acceptor
    ok = timer:sleep(50),
    %% The acceptor has been launched
    [_Master] = supervisor:which_children(gen_rpc_acceptor_sup),
    ok = timer:sleep(1000),
    erlang:display("Waited timeout"),
    %% The acceptor should have shut down
    [] = supervisor:which_children(gen_rpc_acceptor_sup),
    ok.

cast(_Config) ->
    true = gen_rpc:cast(?MASTER, erlang, timestamp).

cast_anonymous_function(_Config) ->
    true = gen_rpc:cast(?MASTER, erlang, apply, [fun() -> os:timestamp() end, []]).

cast_mfa_undef(_Config) ->
    true = gen_rpc:cast(?MASTER, os, timestamp_undef, []).

cast_mfa_exit(_Config) ->
    true = gen_rpc:cast(?MASTER, erlang, apply, [fun() -> exit(die) end, []]).

cast_mfa_throw(_Config) ->
    true = gen_rpc:cast(?MASTER, erlang, throw, ['throwme']).

cast_inexistent_node(_Config) ->
    true = gen_rpc:cast(?FAKE_NODE, os, timestamp, [], 1000).

try_ordered_cast(_Config) ->
    Key = erlang:unique_integer([monotonic, positive]),
    ok = gen_rpc_test_helper:clear_stored(Key),
    ok = gen_rpc:try_ordered_cast({?MASTER, Key}, gen_rpc_test_helper, delayed_store, [Key, done, 200]),
    done = gen_rpc:call({?MASTER, Key}, gen_rpc_test_helper, read_stored, [Key]).

try_ordered_cast_start_failure(_Config) ->
    Key = erlang:unique_integer([monotonic, positive]),
    ok = application:set_env(?APP, client_config_per_node, {external, ?MODULE}),
    {error, {badrpc, {external_source_error, simulated_start_failure}}} =
        gen_rpc:try_ordered_cast({?MASTER, Key}, os, timestamp, []),
    undefined = gen_rpc_client:where_is({?MASTER, Key}),
    true = gen_rpc:ordered_cast({?MASTER, Key}, os, timestamp, []).

get_config(?MASTER) ->
    {error, simulated_start_failure}.

async_call(_Config) ->
    YieldKey0 = gen_rpc:async_call(?MASTER, os, timestamp, []),
    {_Mega, _Sec, _Micro} = gen_rpc:yield(YieldKey0),
    NbYieldKey0 = gen_rpc:async_call(?MASTER, os, timestamp, []),
    {value, {_,_,_}} = gen_rpc:nb_yield(NbYieldKey0, 500),
    YieldKey = gen_rpc:async_call(?MASTER, io_lib, print, [yield_key]),
    "yield_key" = gen_rpc:yield(YieldKey),
    NbYieldKey = gen_rpc:async_call(?MASTER, io_lib, print, [nb_yield_key]),
    {value, "nb_yield_key"} = gen_rpc:nb_yield(NbYieldKey, 500).

async_call_yield_reentrant(_Config) ->
    YieldKey0 = gen_rpc:async_call(?MASTER, os, timestamp, []),
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
    NbYieldKey0 = gen_rpc:async_call(?MASTER, os, timestamp, []),
    {value, {_,_,_}} = gen_rpc:nb_yield(NbYieldKey0, 500),
    % Verify not able to reuse Key again. Key is one time use.
    timeout = gen_rpc:nb_yield(NbYieldKey0, 5),
    YieldKey = gen_rpc:async_call(?MASTER, io_lib, print, [yield_key]),
    "yield_key" = gen_rpc:yield(YieldKey),
    NbYieldKey = gen_rpc:async_call(?MASTER, io_lib, print, [nb_yield_key]),
    {value, "nb_yield_key"} = gen_rpc:nb_yield(NbYieldKey, 500).

async_call_anonymous_function(_Config) ->
    YieldKey = gen_rpc:async_call(?MASTER, erlang, apply, [fun(A) -> {self(), io_lib:print(A)} end,
                                  [yield_key_anonymous_func]]),
    {_, "yield_key_anonymous_func"} = gen_rpc:yield(YieldKey),
    NBYieldKey = gen_rpc:async_call(?MASTER, erlang, apply,[fun(A) -> {self(), io_lib:print(A)} end,
                                    [nb_yield_key_anonymous_func]]),
    {value, {_, "nb_yield_key_anonymous_func"}} = gen_rpc:nb_yield(NBYieldKey, 500).

async_call_anonymous_undef(_Config) ->
    YieldKey = gen_rpc:async_call(?MASTER, erlang, apply, [fun() -> os:timestamp_undef() end, []]),
    {badrpc, {'EXIT', {undef,[{os,timestamp_undef,[],[]},_]}}} = gen_rpc:yield(YieldKey),
    NBYieldKey = gen_rpc:async_call(?MASTER, erlang, apply, [fun() -> os:timestamp_undef() end, []]),
    {value, {badrpc, {'EXIT', {undef,[{os,timestamp_undef,[],[]},_]}}}} = gen_rpc:nb_yield(NBYieldKey, 500),
    ok = ct:pal("Result [async_call_anonymous_undef]: signal=EXIT Reason={os,timestamp_undef}").

async_call_mfa_undef(_Config) ->
    YieldKey = gen_rpc:async_call(?MASTER, os, timestamp_undef),
    {badrpc, {'EXIT', {undef,[{os,timestamp_undef,_,_},_]}}} = gen_rpc:yield(YieldKey),
    NBYieldKey = gen_rpc:async_call(?MASTER, os, timestamp_undef),
    {value, {badrpc, {'EXIT', {undef,[{os,timestamp_undef,_,_},_]}}}} = gen_rpc:nb_yield(NBYieldKey, 500),
    ok = ct:pal("Result [async_call_mfa_undef]: signal=EXIT Reason={os,timestamp_undef}").

async_call_mfa_exit(_Config) ->
    YieldKey = gen_rpc:async_call(?MASTER, erlang, exit, ['die']),
    {badrpc, {'EXIT', die}} = gen_rpc:yield(YieldKey),
    NBYieldKey = gen_rpc:async_call(?MASTER, erlang, exit, ['die']),
    {value, {badrpc, {'EXIT', die}}} = gen_rpc:nb_yield(NBYieldKey, 500),
    ok = ct:pal("Result [async_call_mfa_undef]: signal=EXIT Reason={os,timestamp_undef}").

async_call_mfa_throw(_Config) ->
    YieldKey = gen_rpc:async_call(?MASTER, erlang, throw, ['throwXdown']),
    'throwXdown' = gen_rpc:yield(YieldKey),
    NBYieldKey = gen_rpc:async_call(?MASTER, erlang, throw, ['throwXdown']),
    {value, 'throwXdown'} = gen_rpc:nb_yield(NBYieldKey, 500),
    ok = ct:pal("Result [async_call_mfa_undef]: throw Reason={throwXdown}").

async_call_yield_timeout(_Config) ->
    NBYieldKey = gen_rpc:async_call(?MASTER, timer, sleep, [100]),
    timeout = gen_rpc:nb_yield(NBYieldKey, 5),
    ok = ct:pal("Result [async_call_yield_timeout]: signal=badrpc Reason={timeout}").

async_call_nb_yield_infinity(_Config) ->
    YieldKey = gen_rpc:async_call(?MASTER, timer, sleep, [100]),
    ok = gen_rpc:yield(YieldKey),
    NBYieldKey = gen_rpc:async_call(?MASTER, timer, sleep, [100]),
    {value, ok} = gen_rpc:nb_yield(NBYieldKey, infinity),
    ok = ct:pal("Result [async_call_yield_infinity]: timer_sleep Result={ok}").

async_call_inexistent_node(_Config) ->
    YieldKey1 = gen_rpc:async_call(?FAKE_NODE, os, timestamp, []),
    {badrpc, _} = gen_rpc:yield(YieldKey1),
    YieldKey2 = gen_rpc:async_call(?FAKE_NODE, os, timestamp, []),
    {value, {badrpc, _}} = gen_rpc:nb_yield(YieldKey2, 10000).

client_inactivity_timeout(_Config) ->
    ok = application:set_env(?APP, client_inactivity_timeout, 500),
    {_Mega, _Sec, _Micro} = gen_rpc:call(?MASTER, os, timestamp),
    ok = timer:sleep(600),
    %% Lookup the client named process, shouldn't be there
    undefined = whereis(?MASTER).

server_inactivity_timeout(_Config) ->
    ok = application:set_env(?APP, server_inactivity_timeout, 500),
    {_Mega, _Sec, _Micro} = gen_rpc:call(?MASTER, os, timestamp),
    ok = timer:sleep(600),
    %% Lookup the client named process, shouldn't be there
    [] = supervisor:which_children(gen_rpc_acceptor_sup).

random_tcp_close(_Config) ->
    {_Mega, _Sec, _Micro} = gen_rpc:call(?MASTER, os, timestamp),
    [{_,AccPid,_,_}] = supervisor:which_children(gen_rpc_acceptor_sup),
    true = erlang:exit(AccPid, normal),
    ok = timer:sleep(500), % Give some time to the supervisor to kill the children
    [] = gen_rpc:nodes(),
    [] = supervisor:which_children(gen_rpc_acceptor_sup),
    [] = supervisor:which_children(gen_rpc_client_sup).

rpc_module_whitelist(_Config) ->
    ok = application:set_env(?APP, rpc_module_list, [erlang, os]),
    ok = application:set_env(?APP, rpc_module_control, whitelist),
    {_Mega, _Sec, _Micro} = gen_rpc:call(?MASTER, os, timestamp),
    ?MASTER = gen_rpc:call(?MASTER, erlang, node),
    {badrpc, unauthorized} = gen_rpc:call(?MASTER, application, which_applications).

rpc_module_blacklist(_Config) ->
    ok = application:set_env(?APP, rpc_module_list, [erlang, os]),
    ok = application:set_env(?APP, rpc_module_control, blacklist),
    {badrpc, unauthorized} = gen_rpc:call(?MASTER, os, timestamp),
    {badrpc, unauthorized} = gen_rpc:call(?MASTER, erlang, node),
    abcast = gen_rpc:abcast([?MASTER], init, {stop, stop}),
    {[], [?MASTER]} = gen_rpc:sbcast([?MASTER], init, {stop, stop}),
    60000 = gen_rpc:call(?MASTER, timer, seconds, [60]).

driver_stub(_Config) ->
    ok = gen_rpc_driver:stub().

client_config_stub(_Config) ->
    ok = gen_rpc_client_config:stub().
