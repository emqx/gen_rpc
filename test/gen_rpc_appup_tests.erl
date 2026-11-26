%%% -*- mode: erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright (c) 2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%%

-module(gen_rpc_appup_tests).

-include_lib("eunit/include/eunit.hrl").

%% Load the keepalive helper before the client can migrate its callback.
%% Versions predating 3.0.6 also need the new gen_rpc API module.
appup_reloads_changed_modules_test() ->
    {ok, {_, Up, Down}} = file:script("src/gen_rpc.appup.src", [{'VSN', 'VSN'}]),
    lists:foreach(
      fun(Blocks) ->
              lists:foreach(fun({Vsn, Actions}) -> assert_block(Vsn, Actions) end, Blocks)
      end, [Up, Down]).

assert_block("3.0.6", Actions) ->
    ?assertEqual([load_module(gen_rpc_keepalive), load_client()], Actions);
assert_block(<<".*">>, _Actions) ->
    ok;
assert_block(Vsn, Actions) ->
    ?assert(lists:member(load_client(), Actions), {Vsn, gen_rpc_client}),
    ?assert(lists:member(load_module(gen_rpc_keepalive), Actions), {Vsn, gen_rpc_keepalive}),
    ?assert(lists:member(load_module(gen_rpc), Actions), {Vsn, gen_rpc}).

load_client() ->
    {load_module, gen_rpc_client, brutal_purge, soft_purge, [gen_rpc_keepalive]}.

load_module(Module) ->
    {load_module, Module, brutal_purge, soft_purge, []}.
