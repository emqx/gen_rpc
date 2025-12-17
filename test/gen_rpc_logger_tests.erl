%%--------------------------------------------------------------------
%% Copyright (c) 2025 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(gen_rpc_logger_tests).

-include_lib("eunit/include/eunit.hrl").
-include("logger.hrl").

%% Test logger module implementation
-export([log/4]).

%% Test logger module callback
log(Level, Type, Msg, Data) ->
    %% Add self pid to data and send message back to self
    Self = self(),
    DataWithPid = Data#{test_pid => Self},
    Self ! {log_called, Level, Type, Msg, DataWithPid},
    ok.

%% Tests
custom_logger_test() ->
    application:load(gen_rpc),
    %% Save original logger config
    OriginalLogger = application:get_env(gen_rpc, logger, undefined),
    try
        %% Set the test logger module
        application:set_env(gen_rpc, logger, ?MODULE),

        %% Test with error level (always allowed)
        TestData = #{key => value, number => 42},
        gen_rpc_logger:log(error, ?T_CLIENT, "test_message", fun() -> TestData end),

        %% Wait for the log callback message
        receive
            {log_called, Level, Type, Msg, Data} ->
                ?assertEqual(error, Level),
                ?assertEqual(?T_CLIENT, Type),
                ?assertEqual("test_message", Msg),
                ?assertEqual(TestData#{test_pid => self()}, Data)
        after
            1000 ->
                ?assert(false, "Log callback was not called")
        end,

        %% Test with different type
        gen_rpc_logger:log(error, ?T_ACCEPTOR, "error_message", fun() -> #{error => true} end),

        %% Wait for the second log callback message
        receive
            {log_called, Level2, Type2, Msg2, Data2} ->
                ?assertEqual(error, Level2),
                ?assertEqual(?T_ACCEPTOR, Type2),
                ?assertEqual("error_message", Msg2),
                ?assertEqual(#{error => true, test_pid => self()}, Data2)
        after
            1000 ->
                ?assert(false, "Second log callback was not called")
        end
    after
        %% Cleanup
        case OriginalLogger of
            undefined ->
                application:unset_env(gen_rpc, logger);
            _ ->
                application:set_env(gen_rpc, logger, OriginalLogger)
        end
    end.
