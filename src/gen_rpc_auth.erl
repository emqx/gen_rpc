%%--------------------------------------------------------------------
%% Copyright (c) 2022-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-include("app.hrl").
-include("logger.hrl").
-include_lib("snabbkaffe/include/trace.hrl").

-define(log(Level, Msg, Data), ?LOG(Level, ?T_AUTH, Msg, Data)).

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

%% The packets are built and parsed by `gen_rpc_auth_proto'.

-define(UNAUTHORIZED, {badrpc, invalid_cookie}).

-define(BADPACKET, {badrpc, invalid_message}).

-define(BADNODE, {badrpc, badnode}). %% Target node name doesn't match the expected node name

%% Upper bound on a single authentication frame. The transport is told not to
%% buffer more than this before a handshake read returns; the limit is lifted
%% once the peer is authenticated, so normal RPC payloads stay unbounded.
-define(MAX_AUTH_PACKET_SIZE, 1 bsl 20). %% 1 MiB

-define(MIN_CHALLENGE_SIZE, 8).
-define(MAX_CHALLENGE_SIZE, 128).

-define(IS_STAGE2_CHALLENGE(Challenge),
        (is_binary(Challenge) andalso byte_size(Challenge) =/= ?SERVER_CHALLENGE_SIZE)).

-type auth_error() :: {badtcp, _}          %% Network errors
                    | ?BADPACKET           %% Bad packet
                    | ?UNAUTHORIZED        %% Bad cookie
                    | ?BADNODE.            %% Tried to connect to a wrong node

%%================================================================================
%% API
%%================================================================================

-spec connect_with_auth(module(), node(), port_number()) ->
                {ok, _Socket}
              | {error, auth_error()}
              | {unreachable, _Reason}.
connect_with_auth(Driver, Node, Port) ->
    connect_with_auth(Driver, Node, Port, fun authenticate_server_cr/3).

-spec authenticate_client(module(), term(), tuple()) -> ok | {error, auth_error()}.
authenticate_client(Driver, Socket, Peer) ->
    ok = Driver:set_send_timeout(Socket, gen_rpc_helper:get_send_timeout(undefined)),
    with_auth_packet_size(Driver, Socket,
                          fun() -> do_authenticate_client(Driver, Socket, Peer) end).

do_authenticate_client(Driver, Socket, Peer) ->
    RecvTimeout = gen_rpc_helper:get_authentication_timeout(),
    case Driver:recv(Socket, 0, RecvTimeout) of
        {ok, Data} when byte_size(Data) =< ?MAX_AUTH_PACKET_SIZE ->
            authenticate_client_cr(Driver, Socket, Data);
        {ok, _Data} ->
            {error, ?BADPACKET};
        {error, Reason} ->
            ?tp(error, gen_rpc_client_auth_timeout, #{peer => Peer, error => Reason, domain => ?D_AUTH}),
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
        ?tp(debug, gen_rpc_authentication_stage, #{stage => 1, socket => Socket, peer => Peer, domain => ?D_AUTH}),
        send(Driver, Socket, Packet, challenge),
        %% Receive response to our challenge and a new challenge:
        RecvPacket = recv(Driver, Socket, challenge_response),
        Result = stage3(ClientChallenge, RecvPacket),
        ?tp(debug, gen_rpc_authentication_stage, #{stage => 3, socket => Socket, peer => Peer, result => Result, domain => ?D_AUTH}),
        case Result of
            {ok, Packet2} ->
                %% Send the final response to the client:
                send(Driver, Socket, Packet2, response);
                {error, Error} ->
                ?tp(error, gen_rpc_authentication_bad_cookie, #{socket => Socket, error => Error, peer => Peer, domain => ?D_AUTH}),
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
                 , domain => ?D_AUTH
                 }),
            {error, {badtcp, Reason}}
    end.

-spec authenticate_client_cr(module(), port(), binary()) -> ok | {error, auth_error()}.
authenticate_client_cr(Driver, Socket, Data) ->
    Peer = Driver:get_peer(Socket),
    Result2 = stage2(Data),
    ?tp(debug, gen_rpc_authentication_stage, #{stage => 2, socket => Socket, peer => Peer, result => Result2, domain => ?D_AUTH}),
    try
        case Result2 of
            {ok, {ServerChallenge, Packet}} ->
                send(Driver, Socket, Packet, challenge_response),
                RecvPacket = recv(Driver, Socket, response),
                Result = stage4(ServerChallenge, RecvPacket),
                ?tp(debug, gen_rpc_authentication_stage, #{stage => 4, socket => Socket, peer => Peer, result => Result, domain => ?D_AUTH}),
                Result;
            {error, ?BADNODE} = Error ->
                send(Driver, Socket, gen_rpc_auth_proto:encode(badnode), challenge_error),
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
                 , domain => ?D_AUTH
                 }),
            {error, {badtcp, Reason}}
    end.

%%================================================================================
%% Wrapper functions for network (throwing)
%%================================================================================

recv(Driver, Socket, Meta) ->
    RecvTimeout = gen_rpc_helper:get_call_receive_timeout(undefined),
    case Driver:recv(Socket, 0, RecvTimeout) of
        {ok, Packet} when byte_size(Packet) =< ?MAX_AUTH_PACKET_SIZE ->
            Packet;
        {ok, _Packet} ->
            throw({badtcp, recv, Meta, oversized});
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
            case with_auth_packet_size(Driver, Socket, fun() -> Fun(Driver, Node, Socket) end) of
                ok ->
                    {ok, Socket};
                Err ->
                    Driver:close(Socket),
                    Err
            end;
        {error, {_Class, Reason}} ->
            {unreachable, Reason}
    end.

%% Run the handshake with the transport packet size capped, so the transport
%% does not buffer more than an authentication frame before a read returns.
%% The cap is lifted once the peer is authenticated, so normal RPC payloads
%% are not limited by it. The socket may already be gone when the option is
%% set; that is reported like any other transport error.
-spec with_auth_packet_size(module(), term(), fun(() -> ok | {error, auth_error()})) ->
          ok | {error, auth_error()}.
with_auth_packet_size(Driver, Socket, Handshake) ->
    case Driver:set_packet_size(Socket, ?MAX_AUTH_PACKET_SIZE) of
        ok ->
            case Handshake() of
                ok ->
                    reset_packet_size(Driver, Socket);
                Error ->
                    Error
            end;
        {error, Reason} ->
            {error, {badtcp, Reason}}
    end.

reset_packet_size(Driver, Socket) ->
    case Driver:set_packet_size(Socket, 0) of
        ok ->
            ok;
        {error, Reason} ->
            {error, {badtcp, Reason}}
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
    case gen_rpc_auth_proto:decode(Packet) of
        {ok, {challenge, Challenge, undefined}} when ?IS_STAGE2_CHALLENGE(Challenge) ->
            %% Old style of challenge packet that doesn't
            %% include the node name. We just hope the client
            %% knows where it's going:
            ?tp(gen_rpc_auth_cr_v1_fallback, #{}),
            {ok, make_cr(Secret, Challenge)};
        {ok, {challenge, Challenge, Node}} when ?IS_STAGE2_CHALLENGE(Challenge) ->
            case Node =:= atom_to_binary(node(), utf8) of
                true ->
                    {ok, make_cr(Secret, Challenge)};
                false ->
                    {error, ?BADNODE}
            end;
        _Badpacket ->
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
    Packet = gen_rpc_auth_proto:encode({challenge, Challenge, atom_to_binary(Node, utf8)}),
    {Challenge, Packet}.

-spec make_cr(secret(), challenge()) -> {challenge(), packet()}.
make_cr(Secret, Challenge) ->
    NewChallenge = crypto:strong_rand_bytes(?SERVER_CHALLENGE_SIZE),
    Response = response(Secret, Challenge),
    {NewChallenge, gen_rpc_auth_proto:encode({challenge_response, Response, NewChallenge})}.

-spec check_cr(secret(), challenge(), packet()) -> {ok, challenge()} | {error, auth_error()}.
check_cr(Secret, MyChallenge, Packet) ->
    case gen_rpc_auth_proto:decode(Packet) of
        {ok, {challenge_response, Response, NewChallenge}} ->
            case check_response(Secret, MyChallenge, Response) of
                true ->
                    {ok, NewChallenge};
                false ->
                    {error, ?UNAUTHORIZED}
            end;
        {ok, badnode} ->
            {error, ?BADNODE};
        _Badpacket ->
            {error, ?BADPACKET}
    end.

-spec make_r(binary(), binary()) -> binary().
make_r(Secret, Challenge) ->
    gen_rpc_auth_proto:encode({response, response(Secret, Challenge)}).

-spec check_r(binary(), binary(), binary()) -> ok | {error, auth_error()}.
check_r(Secret, Challenge, Packet) ->
    case gen_rpc_auth_proto:decode(Packet) of
        {ok, {response, Response}} ->
            case check_response(Secret, Challenge, Response) of
                true ->
                    ok;
                false ->
                    {error, ?UNAUTHORIZED}
            end;
        _Badpacket ->
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
    crypto:strong_rand_bytes(challenge_size()).

%% Dialer challenge size, normalised to a power of two in
%% [?MIN_CHALLENGE_SIZE, ?MAX_CHALLENGE_SIZE]. A power of two never equals
%% the reserved responder size, so the two sides can never pick the same
%% size however `challenge_size' is configured.
challenge_size() ->
    clamp_pow2(application:get_env(gen_rpc, challenge_size, ?MIN_CHALLENGE_SIZE)).

clamp_pow2(N) when is_integer(N), N =< ?MIN_CHALLENGE_SIZE ->
    ?MIN_CHALLENGE_SIZE;
clamp_pow2(N) when is_integer(N), N >= ?MAX_CHALLENGE_SIZE ->
    ?MAX_CHALLENGE_SIZE;
clamp_pow2(N) when is_integer(N) ->
    next_pow2(N, ?MIN_CHALLENGE_SIZE);
clamp_pow2(_) ->
    ?MIN_CHALLENGE_SIZE.

next_pow2(N, Acc) when Acc >= N -> Acc;
next_pow2(N, Acc) -> next_pow2(N, Acc bsl 1).

-spec compare_binaries(binary(), binary()) -> boolean().
compare_binaries(A, B) ->
    do_compare_binaries(A, B, 0, 0).

-spec do_compare_binaries(binary(), binary(), non_neg_integer(), byte()) -> boolean().
do_compare_binaries(A, B, I, Acc) when I < byte_size(A), I < byte_size(B) ->
    do_compare_binaries(A, B, I + 1, Acc bor (binary:at(A, I) bxor binary:at(B, I)));
do_compare_binaries(A, B, I, Acc) when I =:= byte_size(A), I =:= byte_size(B) ->
    Acc =:= 0;
do_compare_binaries(_, _, _, _) ->
    false.

get_cookie() ->
    case application:get_env(gen_rpc, secret_cookie) of
        {ok, Cookie} ->
            Cookie;
        undefined ->
            atom_to_binary(erlang:get_cookie(), utf8)
    end.

%%================================================================================
%% Unit tests
%%================================================================================

-ifdef(TEST).

-spec make_c_v1() -> {challenge(), packet()}.
make_c_v1() ->
    Challenge = rand_bytes(),
    {Challenge, gen_rpc_auth_proto:encode({challenge, Challenge, undefined})}.

-spec stage1_v1() -> {challenge(), packet()}.
stage1_v1() ->
    make_c_v1().

%% Build a v1 (no node name) initiator packet carrying an arbitrary
%% challenge term, as a peer would send it to the acceptor's stage2.
mk_c_packet(Challenge) ->
    erlang:term_to_binary({gen_rpc_authenticate_c, Challenge}).

rand_bytes_test() ->
    ?assert(is_binary(rand_bytes())).

clamp_pow2_test() ->
    ?assertEqual(8, clamp_pow2(1)),
    ?assertEqual(8, clamp_pow2(8)),
    ?assertEqual(16, clamp_pow2(9)),
    ?assertEqual(64, clamp_pow2(?SERVER_CHALLENGE_SIZE)),
    ?assertEqual(64, clamp_pow2(64)),
    ?assertEqual(128, clamp_pow2(65)),
    ?assertEqual(128, clamp_pow2(1000)),
    ?assertEqual(8, clamp_pow2(not_an_integer)).

%% A peer challenge of the reserved responder size must be rejected, so the
%% acceptor cannot be made to sign a challenge it issued itself (reflection).
stage2_rejects_reserved_size_test() ->
    Secret = <<"cookie">>,
    Reserved = crypto:strong_rand_bytes(?SERVER_CHALLENGE_SIZE),
    ?assertEqual({error, ?BADPACKET}, stage2(Secret, mk_c_packet(Reserved))),
    %% A normal-size challenge is still accepted:
    Ok = crypto:strong_rand_bytes(?MIN_CHALLENGE_SIZE),
    ?assertMatch({ok, {_, _}}, stage2(Secret, mk_c_packet(Ok))).

%% A non-binary (iolist) challenge must be rejected even though crypto:hash/2
%% would accept it as iodata: a byte_size guard alone is bypassable.
stage2_rejects_non_binary_test() ->
    Secret = <<"cookie">>,
    ?assertEqual({error, ?BADPACKET}, stage2(Secret, mk_c_packet([<<"ab">>, <<"cd">>]))).

%% Drive authenticate_client/3 over a mocked driver with a valid handshake
%% term in both encodings. The plain request must reach the next stage (the
%% acceptor replies with a challenge-response); the compressed request must be
%% refused, with no reply sent. A compressed packet is never decompressed.
authenticate_client_recv_path_test_() ->
    {foreach, fun mock_driver_setup/0, fun mock_driver_cleanup/1,
     [ {"plain handshake reaches the challenge-response stage",
        fun() ->
                Packet = mk_c_packet(crypto:strong_rand_bytes(?MIN_CHALLENGE_SIZE)),
                scripted_recv([{ok, Packet}, {error, closed}]),
                %% The stage4 recv fails with closed, but only after the
                %% acceptor has replied to the peer's challenge:
                ?assertMatch({error, {badtcp, closed}},
                             authenticate_client(mock_driver, socket, peer)),
                ?assertMatch([{challenge_response, _, _}], sent_packets())
        end},
       {"compressed handshake is refused",
        fun() ->
                %% A valid handshake term whose binary form starts with the
                %% compressed-term tag and stays under the encoded-size limit,
                %% yet decodes to more than 1 MiB:
                Big = binary:copy(<<0>>, 1 bsl 20),
                Packet = erlang:term_to_binary({gen_rpc_authenticate_c, Big},
                                               [compressed]),
                ?assertMatch(<<131, 80, _/binary>>, Packet),
                ?assert(byte_size(Packet) =< ?MAX_AUTH_PACKET_SIZE),
                scripted_recv([{ok, Packet}, {error, closed}]),
                ?assertEqual({error, ?BADPACKET},
                             authenticate_client(mock_driver, socket, peer)),
                ?assertEqual(0, meck:num_calls(mock_driver, send, '_'))
        end} ]}.

-define(TEST_COOKIE, <<"test_cookie">>).
-define(TEST_ENV, [secret_cookie, send_timeout, authentication_timeout, call_receive_timeout]).

mock_driver_setup() ->
    application:set_env(?APP, secret_cookie, ?TEST_COOKIE),
    application:set_env(?APP, send_timeout, 5000),
    application:set_env(?APP, authentication_timeout, 5000),
    application:set_env(?APP, call_receive_timeout, 5000),
    meck:new(mock_driver, [non_strict]),
    meck:expect(mock_driver, set_send_timeout, fun(_, _) -> ok end),
    meck:expect(mock_driver, set_packet_size, fun(_, _) -> ok end),
    meck:expect(mock_driver, get_peer, fun(_) -> {{127, 0, 0, 1}, 5000} end),
    meck:expect(mock_driver, send, fun(_, _) -> ok end).

mock_driver_cleanup(_) ->
    meck:unload(mock_driver),
    lists:foreach(fun(K) -> application:unset_env(?APP, K) end, ?TEST_ENV).

scripted_recv(Seq) ->
    meck:expect(mock_driver, recv, 3, meck:seq(Seq)).

sent_packets() ->
    [begin
         {ok, Packet} = gen_rpc_auth_proto:decode(Sent),
         Packet
     end
     || {_Pid, {mock_driver, send, [_Socket, Sent]}, _Ret} <- meck:history(mock_driver)].

compare_binaries_test() ->
    A1 = crypto:hash(sha256, <<"a">>),
    A2 = crypto:hash(sha256, <<"ab">>),
    ?assert(compare_binaries(A1, A1)),
    ?assert(compare_binaries(A2, A2)),
    ?assertNot(compare_binaries(A1, A2)),
    ?assertNot(compare_binaries(A2, A1)),
    ?assertNot(compare_binaries(<<"abcdef">>, A1)),
    ?assertNot(compare_binaries(A1, <<"abcdef">>)),
    ?assertNot(compare_binaries(<<>>, A1)),
    ?assertNot(compare_binaries(A1, <<>>)),
    ?assertNot(compare_binaries(binary:part(A1, 0, 4), A1)),
    ?assertNot(compare_binaries(A1, binary:part(A1, 0, 4))),
    ?assertNot(compare_binaries(<<A1/binary, 0>>, A1)),
    ?assertNot(compare_binaries(A1, <<A1/binary, 0>>)).

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

%% The acceptor must cap the transport packet size before its first handshake
%% read, and lift the cap only after the peer is authenticated, via the driver.
auth_packet_size_test_() ->
    {foreach, fun mock_driver_setup/0, fun mock_driver_cleanup/1,
     [ {"cap is applied before the first read and kept on failure",
        fun() ->
                scripted_recv([{error, closed}]),
                ?assertMatch({error, {badtcp, closed}},
                             authenticate_client(mock_driver, socket, peer)),
                ?assertEqual(1, meck:num_calls(mock_driver, set_packet_size,
                                               [socket, ?MAX_AUTH_PACKET_SIZE])),
                %% Not reset while unauthenticated:
                ?assertEqual(0, meck:num_calls(mock_driver, set_packet_size, [socket, 0])),
                Seq = driver_call_seq(),
                ?assert(first_index(set_packet_size, Seq) < first_index(recv, Seq))
        end},
       {"cap is lifted after a successful handshake",
        fun() ->
                scripted_handshake(),
                ?assertEqual(ok, authenticate_client(mock_driver, socket, peer)),
                ?assertEqual(1, meck:num_calls(mock_driver, set_packet_size,
                                               [socket, ?MAX_AUTH_PACKET_SIZE])),
                ?assertEqual(1, meck:num_calls(mock_driver, set_packet_size, [socket, 0])),
                Seq = driver_call_seq(),
                ?assert(first_index(set_packet_size, Seq) < first_index(recv, Seq)),
                ?assert(last_index(set_packet_size, Seq) > first_index(recv, Seq))
        end},
       {"failing to apply the cap is a transport error, nothing is read",
        fun() ->
                meck:expect(mock_driver, set_packet_size, fun(_, _) -> {error, einval} end),
                scripted_handshake(),
                ?assertEqual({error, {badtcp, einval}},
                             authenticate_client(mock_driver, socket, peer)),
                ?assertEqual(0, meck:num_calls(mock_driver, recv, '_'))
        end},
       {"failing to lift the cap is a transport error",
        fun() ->
                meck:expect(mock_driver, set_packet_size,
                            fun(_, 0) -> {error, einval};
                               (_, _) -> ok
                            end),
                scripted_handshake(),
                ?assertEqual({error, {badtcp, einval}},
                             authenticate_client(mock_driver, socket, peer))
        end} ]}.

%% Script the peer's side of a successful handshake: the first read returns its
%% challenge, the second its response to the acceptor's challenge, derived
%% from the challenge-response the acceptor has just sent.
scripted_handshake() ->
    {_, Challenge} = stage1_v1(),
    meck:expect(
      mock_driver, recv,
      fun(_, _, _) ->
              case meck:num_calls(mock_driver, recv, '_') of
                  0 ->
                      {ok, Challenge};
                  _ ->
                      [{challenge_response, _, ServerChallenge}] = sent_packets(),
                      {ok, make_r(?TEST_COOKIE, ServerChallenge)}
              end
      end).

driver_call_seq() ->
    [{F, A} || {_Pid, {mock_driver, F, A}, _Ret} <- meck:history(mock_driver)].

first_index(Fun, Seq) ->
    index_of(Fun, Seq, 1).

index_of(_Fun, [], _I) ->
    not_found;
index_of(Fun, [{Fun, _} | _], I) ->
    I;
index_of(Fun, [_ | T], I) ->
    index_of(Fun, T, I + 1).

last_index(Fun, Seq) ->
    last_index(Fun, Seq, 1, not_found).

last_index(_Fun, [], _I, Acc) ->
    Acc;
last_index(Fun, [{Fun, _} | T], I, _Acc) ->
    last_index(Fun, T, I + 1, I);
last_index(Fun, [_ | T], I, Acc) ->
    last_index(Fun, T, I + 1, Acc).

-endif.
