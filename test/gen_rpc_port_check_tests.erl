%%--------------------------------------------------------------------
%% Copyright (c) 2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(gen_rpc_port_check_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APP, gen_rpc).

check_server_ports_available_stateless_conflict_test() ->
    Port = gen_rpc_helper:port(node()),
    maybe_with_blocker(
        Port,
        fun() ->
            with_env(
                #{
                    port_discovery => stateless,
                    tcp_server_port => 5369,
                    ssl_server_port => false
                },
                fun() ->
                    ?assertMatch(
                        {error, [#{driver := tcp, port := Port, reason := eaddrinuse}]},
                        gen_rpc:check_server_ports_available()
                    )
                end
            )
        end
    ).

check_server_ports_available_manual_conflict_test() ->
    {ok, Blocker} = gen_tcp:listen(0, [binary, {reuseaddr, true}, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(Blocker),
    try
        with_env(
            #{
                port_discovery => manual,
                tcp_server_port => Port,
                ssl_server_port => false
            },
            fun() ->
                ?assertMatch(
                    {error, [#{driver := tcp, port := Port, reason := eaddrinuse}]},
                    gen_rpc:check_server_ports_available()
                )
            end
        )
    after
        ok = gen_tcp:close(Blocker)
    end.

check_server_ports_available_manual_conflict_ipv6_test() ->
    with_ipv6_support(
        fun() ->
            {ok, Blocker} = gen_tcp:listen(
                0,
                [binary, inet6, {reuseaddr, true}, {active, false}, {ip, {0, 0, 0, 0, 0, 0, 0, 1}}]
            ),
            {ok, {_, Port}} = inet:sockname(Blocker),
            try
                with_env(
                    #{
                        port_discovery => manual,
                        tcp_server_port => Port,
                        ssl_server_port => false,
                        socket_ip => {0, 0, 0, 0, 0, 0, 0, 1}
                    },
                    fun() ->
                        ?assertMatch(
                            {error, [#{
                                driver := tcp,
                                ip := {0, 0, 0, 0, 0, 0, 0, 1},
                                port := Port,
                                reason := eaddrinuse
                            }]},
                            gen_rpc:check_server_ports_available()
                        )
                    end
                )
            after
                ok = gen_tcp:close(Blocker)
            end
        end
    ).

maybe_with_blocker(Port, Fun) ->
    case gen_tcp:listen(Port, [binary, {reuseaddr, true}, {active, false}, {ip, {127, 0, 0, 1}}]) of
        {ok, Blocker} ->
            try
                Fun()
            after
                ok = gen_tcp:close(Blocker)
            end;
        {error, eaddrinuse} ->
            %% The port is already occupied by another process; this is enough for this test.
            Fun();
        {error, Reason} ->
            error({failed_to_prepare_port_blocker, Port, Reason})
    end.

with_env(Overrides, Fun) ->
    Saved = save_env(maps:keys(Overrides)),
    try
        maps:foreach(
            fun(Key, Value) ->
                ok = application:set_env(?APP, Key, Value)
            end,
            Overrides
        ),
        Fun()
    after
        restore_env(Saved)
    end.

save_env(Keys) ->
    maps:from_list([{Key, application:get_env(?APP, Key)} || Key <- Keys]).

restore_env(Saved) ->
    maps:foreach(
        fun
            (Key, undefined) ->
                application:unset_env(?APP, Key);
            (Key, {ok, Value}) ->
                ok = application:set_env(?APP, Key, Value)
        end,
        Saved
    ).

with_ipv6_support(Fun) ->
    case gen_tcp:listen(
        0,
        [binary, inet6, {reuseaddr, true}, {active, false}, {ip, {0, 0, 0, 0, 0, 0, 0, 1}}]
    ) of
        {ok, Probe} ->
            ok = gen_tcp:close(Probe),
            Fun();
        {error, eafnosupport} ->
            ok;
        {error, einval} ->
            ok;
        {error, Reason} ->
            error({unexpected_ipv6_probe_error, Reason})
    end.
