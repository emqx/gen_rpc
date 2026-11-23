%%% -*- mode: erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright (c) 2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%%

-module(gen_rpc_appup_tests).

-include_lib("eunit/include/eunit.hrl").

%% gen_rpc.erl and gen_rpc_client.erl change in 3.0.6, so every upgrade from
%% an older 3.0.x release must reload both modules. Upgrading from 3.0.6 has
%% no module changes and must not restart the application.
appup_reloads_changed_modules_test() ->
    {ok, {_, Up, Down}} = file:script("src/gen_rpc.appup.src", [{'VSN', 'VSN'}]),
    lists:foreach(
      fun(Blocks) ->
              lists:foreach(fun({Vsn, Actions}) -> assert_block(Vsn, Actions) end, Blocks)
      end, [Up, Down]).

assert_block("3.0.6", Actions) ->
    ?assertEqual([], Actions);
assert_block(<<".*">>, _Actions) ->
    ok;
assert_block(Vsn, Actions) ->
    ?assert(lists:member(load_module(gen_rpc_client), Actions), {Vsn, gen_rpc_client}),
    ?assert(lists:member(load_module(gen_rpc), Actions), {Vsn, gen_rpc}).

load_module(Module) ->
    {load_module, Module, brutal_purge, soft_purge, []}.
