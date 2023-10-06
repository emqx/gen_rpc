#!/usr/bin/env escript

%% this script is passed as '--script' option for 'rebar3 shell' command.
%% it is evaluated before starting the apps so it can inject configs.
main(_) ->
    ok = gen_rpc_test_helper:init_integration_test_config().
