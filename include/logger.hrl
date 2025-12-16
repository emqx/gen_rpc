%% Copyright (c) 2013-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-ifndef(GEN_RPC_LOGGER).
-define(GEN_RPC_LOGGER, true).

-define(T_ACCEPTOR, acceptor).
-define(T_DISPATCHER, dispatcher).
-define(T_AUTH, auth).
-define(T_SERVER, server).
-define(T_DRIVER, driver).
-define(T_CLIENT, client).
%% Domains
-define(D_CLIENT, [gen_rpc, ?T_CLIENT]).
-define(D_AUTH, [gen_rpc, ?T_CLIENT]).
-define(D_ACCEPTOR, [gen_rpc, ?T_ACCEPTOR]).
-define(D_DISPATCHER, [gen_rpc, ?T_DISPATCHER]).
-define(D_DRIVER, [gen_rpc, ?T_DRIVER]).
-define(D_SERVER, [gen_rpc, ?T_SERVER]).

-define(LOG(Level, Type, Msg, Data),
        gen_rpc_logger:log(Level, Type, Msg, fun() -> Data end)).

-endif.
