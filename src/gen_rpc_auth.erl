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
-module(gen_rpc_auth).

-include("logger.hrl").
-include_lib("snabbkaffe/include/trace.hrl").

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API:
-export([connect_with_auth/3, authenticate_client/3, get_cookie/0]).

-export_type([auth_error/0]).

%%================================================================================
%% Types
%%================================================================================

-type secret() :: binary().

-type challenge() :: binary().

-type packet() :: binary().

-type port_number() :: 0..65535.

%% Packets
%% Client challenge:
-record(gen_rpc_authenticate_c,
        { challenge :: challenge()
        }).

%% Server response + client challenge
-record(gen_rpc_authenticate_cr,
        { response  :: binary()
        , challenge :: challenge()
        }).

%% Client response to the challenge:
-record(gen_rpc_authenticate_r,
        { response  :: binary()
        }).

-define(UNAUTHORIZED, {badrpc, invalid_cookie}).

-define(BADPACKET, {badrpc, invalid_message}).

-define(BADNODE, {badrpc, badnode}). %% Target node name doesn't match the expected node name

-type auth_error() :: {badtcp, _}          %% Network errors
                    | ?BADPACKET           %% Bad packet
                    | ?UNAUTHORIZED        %% Bad cookie
                    | ?BADNODE.            %% Tried to connect to a wrong node

-define(NODE_SIZE_BITS, 16).

%%================================================================================
%% API
%%================================================================================

-spec connect_with_auth(module(), node(), port_number()) ->
                {ok, _Socket}
              | {error, auth_error()}
              | {unreachable, _Reason}.
connect_with_auth(Driver, Node, Port) ->
    Fallback = insecure_fallback_allowed(),
    case connect_with_auth(Driver, Node, Port, fun authenticate_server_cr/3) of
        {ok, Socket} ->
            {ok, Socket};
        Err when Fallback, Err =:= {error, {badtcp, closed}} orelse
                           Err =:= {error, ?UNAUTHORIZED} ->
            ?tp(warning, gen_rpc_insecure_fallback, #{peer => {Node, Port}, role => client}),
            connect_with_auth(Driver, Node, Port, fun authenticate_server_insecure/3);
        Result ->
            Result
    end.

-spec authenticate_client(module(), term(), tuple()) -> ok | {error, auth_error()}.
authenticate_client(Driver, Socket, Peer) ->
    ok = Driver:set_send_timeout(Socket, gen_rpc_helper:get_send_timeout(undefined)),
    RecvTimeout = gen_rpc_helper:get_authentication_timeout(),
    Fallback = insecure_fallback_allowed(),
    case Driver:recv(Socket, 0, RecvTimeout) of
        {ok, Data} ->
            case authenticate_client_cr(Driver, Socket, Data) of
                {error, ?BADPACKET} when Fallback ->
                    ?tp(warning, gen_rpc_insecure_fallback, #{peer => Peer, role => server}),
                    authenticate_client_insecure(Driver, Socket, Peer, Data);
                Result ->
                    Result
            end;
        {error, Reason} ->
            ?tp(error, gen_rpc_client_auth_timeout, #{peer => Peer, error => Reason}),
            {error, {badtcp, Reason}}
    end.

%%================================================================================
%% Challenge-response
%%================================================================================

-spec authenticate_server_cr(module(), node(), port()) -> ok | {error, auth_error()}.
authenticate_server_cr(Driver, RemoteNode, Socket) ->
    Peer = Driver:get_peer(Socket),
    try
        %% Send challenge:
        {ClientChallenge, Packet} = stage1(RemoteNode),
        ?tp(debug, gen_rpc_authentication_stage, #{stage => 1, socket => Socket, peer => Peer}),
        send(Driver, Socket, Packet, challenge),
        %% Receive response to our challenge and a new challenge:
        RecvPacket = recv(Driver, Socket, challenge_response),
        Result = stage3(ClientChallenge, RecvPacket),
        ?tp(debug, gen_rpc_authentication_stage, #{stage => 3, socket => Socket, peer => Peer, result => Result}),
        case Result of
            {ok, Packet2} ->
                %% Send the final response to the client:
                send(Driver, Socket, Packet2, response);
            {error, Error} ->
                ?tp(error, gen_rpc_authentication_bad_cookie, #{socket => Socket, error => Error, peer => Peer}),
                {error, Error}
        end
    catch
        {badtcp, Action, Meta, Reason} ->
            ?tp(error, gen_rpc_authentication_badtcp,
                #{ packet => Meta
                 , reason => Reason
                 , peer => Peer
                 , socket => Socket
                 , action => Action
                 }),
            {error, {badtcp, Reason}}
    end.

-spec authenticate_client_cr(module(), port(), binary()) -> ok | {error, auth_error()}.
authenticate_client_cr(Driver, Socket, Data) ->
    Peer = Driver:get_peer(Socket),
    Result2 = stage2(Data),
    ?tp(debug, gen_rpc_authentication_stage, #{stage => 2, socket => Socket, peer => Peer, result => Result2}),
    try
        case Result2 of
            {ok, {ServerChallenge, Packet}} ->
                send(Driver, Socket, Packet, challenge_response),
                RecvPacket = recv(Driver, Socket, response),
                Result = stage4(ServerChallenge, RecvPacket),
                ?tp(debug, gen_rpc_authentication_stage, #{stage => 4, socket => Socket, peer => Peer, result => Result}),
                Result;
            {error, ?BADNODE} = Error ->
                send(Driver, Socket, term_to_binary(Error), challenge_error),
                Error;
            Error ->
                Error
        end
    catch
        {badtcp, Action, Meta, Reason} ->
            ?tp(error, gen_rpc_authentication_badtcp,
                #{ packet => Meta
                 , reason => Reason
                 , peer => Peer
                 , socket => Socket
                 , action => Action
                 }),
            {error, {badtcp, Reason}}
    end.

%%================================================================================
%% Insecure fallback
%%================================================================================

%% TODO: Drop these functions in the next major release

-spec authenticate_server_insecure(module(), node(), term()) -> ok | {error, auth_error()}.
authenticate_server_insecure(Driver, _Node, Socket) ->
    Peer = Driver:get_peer(Socket),
    try
        %% Send cookie to the remote server:
        Cookie = get_cookie_atom(),
        Packet = case Driver of
                     gen_rpc_driver_tcp ->
                         erlang:term_to_binary({gen_rpc_authenticate_connection, Cookie});
                     gen_rpc_driver_ssl ->
                         %% Just another quirk of the old auth process...
                         erlang:term_to_binary({gen_rpc_authenticate_connection, node(), Cookie})
                 end,
        ?tp(gen_rpc_auth_server_insecure_send, #{socket => Socket}),
        send(Driver, Socket, Packet, insecure_cookie),
        %% Wait for the reply:
        RecvPacket = recv(Driver, Socket, insecure_response),
        ?tp(gen_rpc_auth_server_insecure_recv, #{socket => Socket, response => RecvPacket}),
        try erlang:binary_to_term(RecvPacket, [safe]) of
            gen_rpc_connection_authenticated ->
                ?log(debug, "event=connection_authenticated socket=\"~s\"",
                     [gen_rpc_helper:socket_to_string(Socket)]),
                ok;
            {gen_rpc_connection_rejected, invalid_cookie} ->
                ?log(error, "event=authentication_rejected socket=\"~s\" reason=\"invalid_cookie\"",
                     [gen_rpc_helper:socket_to_string(Socket)]),
                {error, ?UNAUTHORIZED};
            _Else ->
                ?log(error, "event=authentication_reception_error socket=\"~s\" reason=\"invalid_payload\"",
                     [gen_rpc_helper:socket_to_string(Socket)]),
                {error, ?BADPACKET}
        catch
            error:badarg ->
                {error, ?BADPACKET}
        end
    catch
        {badtcp, Action, Meta, Reason} ->
            ?tp(error, gen_rpc_server_auth_fallback_badtcp,
                #{ packet => Meta
                 , reason => Reason
                 , peer => Peer
                 , socket => Socket
                 , action => Action
                 }),
            {error, {badtcp, Reason}}
    end.

-spec authenticate_client_insecure(module(), port(), tuple(), binary()) -> ok | {error, auth_error()}.
authenticate_client_insecure(Driver, Socket, Peer, Data) ->
    Cookie = get_cookie_atom(),
    CheckResult =
        try erlang:binary_to_term(Data, [safe]) of
            {gen_rpc_authenticate_connection, Cookie} ->
                ok;
            {gen_rpc_authenticate_connection, _Node, Cookie} ->
                %% Old authentication packet sent by SSL driver
                ok;
            {gen_rpc_authenticate_connection, _InvalidCookie} ->
                %% Note: this case may not actually trigger, since
                %% `binary_to_term' runs with `safe' option, so
                %% instead of `invalid_cookie' the error code becomes
                %% `corrupt_data'. But it's more secure, since it
                %% prevents atom table DOS attack.
                invalid_cookie;
            {gen_rpc_authenticate_connection, _Node, _InvalidCookie} ->
                %% Note: same problem as above
                %%
                %% Old authentication packet sent by SSL driver
                invalid_cookie;
            _ ->
                erroneous_data
        catch
            error:badarg ->
                corrupt_data
        end,
    LogLevel = case CheckResult of
                   ok -> debug;
                   _  -> error
               end,
    ?tp(LogLevel, gen_rpc_client_auth_fallback, #{peer => Peer, socket => Socket, result => CheckResult}),
    try
        case CheckResult of
            ok ->
                Packet = erlang:term_to_binary(gen_rpc_connection_authenticated),
                send(Driver, Socket, Packet, reply),
                ok;
            invalid_cookie ->
                Packet = erlang:term_to_binary({gen_rpc_connection_rejected, invalid_cookie}),
                send(Driver, Socket, Packet, reply),
                {error, ?UNAUTHORIZED};
            Err ->
                {error, Err}
        end
    catch
        {badtcp, Action, Meta, Reason} ->
            ?tp(error, gen_rpc_client_auth_fallback_badtcp,
                #{ packet => Meta
                 , reason => Reason
                 , peer => Peer
                 , socket => Socket
                 , action => Action
                 }),
            {error, {badtcp, Reason}}
    end.

%%================================================================================
%% Wrapper functions for network (throwing)
%%================================================================================

recv(Driver, Socket, Meta) ->
    RecvTimeout = gen_rpc_helper:get_call_receive_timeout(undefined),
    case Driver:recv(Socket, 0, RecvTimeout) of
        {ok, Packet} ->
            Packet;
        {error, Reason} ->
            throw({badtcp, recv, Meta, Reason})
    end.

send(Driver, Socket, Packet, Meta) ->
    case Driver:send(Socket, Packet) of
        ok ->
            ok;
        {error, Reason} ->
            throw({badtcp, send, Meta, Reason})
    end.

-spec connect_with_auth(module(), node(), port_number(), fun((module(), node(), _Socket) -> ok | {error, auth_error()})) ->
          {ok, _Socket} | {error, auth_error()} | {unreachable, _Reason}.
connect_with_auth(Driver, Node, Port, Fun) ->
    case Driver:connect(Node, Port) of
        {ok, Socket} ->
            ok = Driver:set_send_timeout(Socket, gen_rpc_helper:get_send_timeout(undefined)),
            case Fun(Driver, Node, Socket) of
                ok ->
                    {ok, Socket};
                Err ->
                    Driver:close(Socket),
                    Err
            end;
        {error, {_Class, Reason}} ->
            {unreachable, Reason}
    end.

%%================================================================================
%% Challenge-response stages (pure functions)
%%================================================================================

-spec stage1(node()) -> {challenge(), packet()}.
stage1(Node) ->
    make_c(Node).

-spec stage2(packet()) -> {ok, {challenge(), packet()}} | {error, auth_error()}.
stage2(Packet) ->
    stage2(get_cookie(), Packet).

-spec stage3(challenge(), packet()) -> {ok, packet()} | {error, _}.
stage3(MyChallenge, Packet) ->
    stage3(get_cookie(), MyChallenge, Packet).

-spec stage4(challenge(), packet()) -> ok | {error, auth_error()}.
stage4(MyChallenge, Packet) ->
    stage4(get_cookie(), MyChallenge, Packet).

-spec stage2(secret(), packet()) -> {ok, {challenge(), packet()}} | {error, auth_error()}.
stage2(Secret, Packet) ->
    try erlang:binary_to_term(Packet, [safe, used]) of
        {#gen_rpc_authenticate_c{challenge = Challenge}, Used} ->
            case split_binary(Packet, Used) of
                {_, <<>>} ->
                    %% Old style of challenge packet that doesn't
                    %% include the node name. We just hope the client
                    %% knows where it's going:
                    ?tp(gen_rpc_auth_cr_v1_fallback, #{}),
                    {ok, make_cr(Secret, Challenge)};
                {_, <<Size:?NODE_SIZE_BITS, NodeBin:Size/bytes, _/binary>>} ->
                    case NodeBin =:= atom_to_binary(node(), utf8) of
                        true ->
                            {ok, make_cr(Secret, Challenge)};
                        false ->
                            {error, ?BADNODE}
                    end;
                _ ->
                    ?log(error, "event=authentication_stage2_invalid_packet packet=~p", [Packet]),
                    {error, ?BADPACKET}
            end;
        _Badterm ->
            {error, ?BADPACKET}
    catch
        _:_ ->
            {error, ?BADPACKET}
    end.

-spec stage3(secret(), challenge(), packet()) -> {ok, packet()} | {error, auth_error()}.
stage3(Secret, MyChallenge, Packet) ->
    case check_cr(Secret, MyChallenge, Packet) of
        {ok, NewChallenge} ->
            {ok, make_r(Secret, NewChallenge)};
        Err ->
            Err
    end.

-spec stage4(secret(), challenge(), packet()) -> ok | {error, auth_error()}.
stage4(Secret, MyChallenge, Packet) ->
    check_r(Secret, MyChallenge, Packet).

%%================================================================================
%% Internal pure functions
%%================================================================================

-spec make_c(node()) -> {challenge(), packet()}.
make_c(Node) ->
    Challenge = rand_bytes(),
    Part1 = erlang:term_to_binary(#gen_rpc_authenticate_c{challenge = Challenge}),
    Part2 = atom_to_binary(Node, utf8),
    Size = size(Part2),
    %% Node name should be at most 255 characters in length, but it
    %% may include utf8 characters, which are at most 4 bytes in size.
    %% That give us maximum binary size of 1024 bytes, that should fit
    %% in 10 bits. So two bytes should be enough to encode the `Size':
    true = Size < (1 bsl ?NODE_SIZE_BITS), % assert
    {Challenge, <<Part1/binary, Size:?NODE_SIZE_BITS, Part2/binary>>}.

-spec make_cr(secret(), challenge()) -> {challenge(), packet()}.
make_cr(Secret, Challenge) ->
    NewChallenge = rand_bytes(),
    Term = #gen_rpc_authenticate_cr{
              challenge = NewChallenge,
              response  = response(Secret, Challenge)
             },
    {NewChallenge, erlang:term_to_binary(Term)}.

-spec check_cr(secret(), challenge(), packet()) -> {ok, challenge()} | {error, auth_error()}.
check_cr(Secret, MyChallenge, Packet) ->
    try erlang:binary_to_term(Packet, [safe]) of
        #gen_rpc_authenticate_cr{response = Response, challenge = NewChallenge} ->
            case check_response(Secret, MyChallenge, Response) of
                true ->
                    {ok, NewChallenge};
                false ->
                    {error, ?UNAUTHORIZED}
            end;
        {error, ?BADNODE} = Error ->
            Error;
        _Badarg ->
            {error, ?BADPACKET}
    catch
        _:_ ->
            {error, ?BADPACKET}
    end.

-spec make_r(binary(), binary()) -> binary().
make_r(Secret, Challenge) ->
    Term = #gen_rpc_authenticate_r{
              response = response(Secret, Challenge)
             },
    erlang:term_to_binary(Term).

-spec check_r(binary(), binary(), binary()) -> ok | {error, auth_error()}.
check_r(Secret, Challenge, Packet) ->
    try erlang:binary_to_term(Packet, [safe]) of
        #gen_rpc_authenticate_r{response = Response} ->
            case check_response(Secret, Challenge, Response) of
                true ->
                    ok;
                false ->
                    {error, ?UNAUTHORIZED}
            end;
        _Badarg ->
            {error, ?BADPACKET}
    catch
        _:_ ->
            {error, ?BADPACKET}
    end.

-spec response(binary(), binary()) -> binary().
response(Secret, Challenge) ->
    crypto:hash(sha256, [Secret, Challenge]).

-spec check_response(binary(), binary(), binary()) -> boolean().
check_response(Secret, Challenge, Response) ->
    Expected = response(Secret, Challenge),
    compare_binaries(Response, Expected).

-spec rand_bytes() -> binary().
rand_bytes() ->
    Size = application:get_env(gen_rpc, challenge_size, 8),
    crypto:strong_rand_bytes(Size).

-spec compare_binaries(binary(), binary()) -> boolean().
compare_binaries(A, B) ->
    case do_compare_binaries(binary_to_list(A), binary_to_list(B), 0) of
        0 -> true;
        _ -> false
    end.

-spec do_compare_binaries([byte()], [byte()], byte()) -> byte().
do_compare_binaries([A|L1], [B|L2], Acc) ->
    do_compare_binaries(L1, L2, Acc bor (A bxor B));
do_compare_binaries(_, _, Acc) ->
    Acc.

insecure_fallback_allowed() ->
    application:get_env(gen_rpc, insecure_auth_fallback_allowed, false).

get_cookie() ->
    case application:get_env(gen_rpc, secret_cookie) of
        {ok, Cookie} ->
            Cookie;
        undefined ->
            atom_to_binary(erlang:get_cookie(), utf8)
    end.

get_cookie_atom() ->
    case application:get_env(gen_rpc, secret_cookie) of
        {ok, Cookie} ->
            binary_to_atom(Cookie, utf8);
        undefined ->
            erlang:get_cookie()
    end.

%%================================================================================
%% Unit tests
%%================================================================================

-ifdef(TEST).

-spec make_c_v1() -> {challenge(), packet()}.
make_c_v1() ->
    Challenge = rand_bytes(),
    Term = #gen_rpc_authenticate_c{challenge = Challenge},
    {Challenge, erlang:term_to_binary(Term)}.

-spec stage1_v1() -> {challenge(), packet()}.
stage1_v1() ->
    make_c_v1().

rand_bytes_test() ->
    ?assert(is_binary(rand_bytes())).

compare_binaries_test() ->
    A1 = crypto:hash(sha256, <<"a">>),
    A2 = crypto:hash(sha256, <<"ab">>),
    ?assert(compare_binaries(A1, A1)),
    ?assert(compare_binaries(A2, A2)),
    ?assertNot(compare_binaries(A1, A2)),
    ?assertNot(compare_binaries(A2, A1)),
    ?assertNot(compare_binaries(<<"abcdef">>, A1)),
    ?assertNot(compare_binaries(A1, <<"abcdef">>)).

%% Check response created with a valid secret
check_response_ok_prop() ->
    ?FORALL({Secret, Challenge}, {binary(), binary()},
            begin
                Response = response(Secret, Challenge),
                check_response(Secret, Challenge, Response)
            end).

check_response_ok_test() ->
    ?assert(proper:quickcheck(check_response_ok_prop(), 100)).

%% Check response created with invalid secret
check_response_fail_prop() ->
    ?FORALL({Secret1, Secret2, Challenge}, {binary(), binary(), binary()},
            ?IMPLIES(Secret1 =/= Secret2,
                     begin
                         Response = response(Secret2, Challenge),
                         not check_response(Secret1, Challenge, Response)
                     end)).

check_response_fail_test() ->
    ?assert(proper:quickcheck(check_response_fail_prop(), 100)).

%% Check normal flow of authentication (same shared secret)
auth_flow_ok_prop() ->
    ?FORALL(Secret, binary(),
            begin
                {ClientChallenge, P1} = stage1(node()),
                {ok, {ServerChallenge, P2}} = stage2(Secret, P1),
                {ok, P3} = stage3(Secret, ClientChallenge, P2),
                ok =:= stage4(Secret, ServerChallenge, P3)
            end).

auth_flow_ok_test() ->
    ?assert(proper:quickcheck(auth_flow_ok_prop(), 100)).

%% Check normal flow of authentication (same shared secret), but without node name in the first packet
auth_flow_ok_v1_prop() ->
    ?FORALL(Secret, binary(),
            begin
                {ClientChallenge, P1} = stage1_v1(),
                {ok, {ServerChallenge, P2}} = stage2(Secret, P1),
                {ok, P3} = stage3(Secret, ClientChallenge, P2),
                ok =:= stage4(Secret, ServerChallenge, P3)
            end).

auth_flow_ok_v1_test() ->
    ?assert(proper:quickcheck(auth_flow_ok_v1_prop(), 100)).

%% Check exceptional flow when the client tries to connect to a wrong server:
auth_flow_wrong_server_fail_test() ->
    {_ClientChallenge, P1} = stage1('badnode@localhost'),
    ?assertMatch({error, ?BADNODE}, stage2(P1)).

%% Check exceptional flow when the server's secret is incorrect:
auth_flow_server_fail_prop() ->
    ?FORALL({Secret1, Secret2}, {binary(), binary()},
            ?IMPLIES(Secret1 =/= Secret2,
                     begin
                         {ClientChallenge, P1} = stage1(node()),
                         {ok, {_ServerChallenge, P2}} = stage2(Secret1, P1),
                         ?assertMatch({error, _}, stage3(Secret2, ClientChallenge, P2)),
                         true
                     end)).

auth_flow_server_fail_test() ->
    ?assert(proper:quickcheck(auth_flow_server_fail_prop(), 100)).

%% Check exceptional flow when the server's secret is incorrect (v1):
auth_flow_server_fail_v1_prop() ->
    ?FORALL({Secret1, Secret2}, {binary(), binary()},
            ?IMPLIES(Secret1 =/= Secret2,
                     begin
                         {ClientChallenge, P1} = stage1_v1(),
                         {ok, {_ServerChallenge, P2}} = stage2(Secret1, P1),
                         ?assertMatch({error, _}, stage3(Secret2, ClientChallenge, P2)),
                         true
                     end)).

auth_flow_server_fail_v1_test() ->
    ?assert(proper:quickcheck(auth_flow_server_fail_v1_prop(), 100)).

%% Check exceptional flow when the client's secret is incorrect:
auth_flow_client_fail_prop() ->
    ?FORALL({Secret1, Secret2}, {binary(), binary()},
            ?IMPLIES(Secret1 =/= Secret2,
                     begin
                         {ClientChallenge, P1} = stage1(node()),
                         {ok, {ServerChallenge, P2}} = stage2(Secret1, P1),
                         {ok, P3} = stage3(Secret1, ClientChallenge, P2),
                         ?assertMatch({error, _}, stage4(Secret2, ServerChallenge, P3)),
                         true
                     end)).

auth_flow_client_fail_test() ->
    ?assert(proper:quickcheck(auth_flow_client_fail_prop(), 100)).

-endif.
