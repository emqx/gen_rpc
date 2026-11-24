%%--------------------------------------------------------------------
%% Copyright (c) 2026 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% @doc The packets of the authentication handshake.
%%
%% A connection is authenticated with three packets:
%%
%% ```
%%   dialer                                   acceptor
%%     | ---- {challenge, C1, Node} ------------> |
%%     | <--- {challenge_response, R1, C2} ------ |    or `badnode'
%%     | ---- {response, R2} -------------------> |
%% '''
%%
%% `C1' and `C2' are challenges, `R1' and `R2' are the responses to them, and
%% `Node' is the name of the node that the dialer wants to reach. All of them
%% are binaries. A dialer of an old release sends no node name.
%%
%% On the wire, each packet is a tuple in the Erlang external term format,
%% because the first releases built the packets with `term_to_binary/1':
%%
%% ```
%%   challenge            {gen_rpc_authenticate_c, C1}, then NodeSize:16, Node
%%   challenge_response   {gen_rpc_authenticate_cr, R1, C2}
%%   response             {gen_rpc_authenticate_r, R2}
%%   badnode              {error, {badrpc, badnode}}
%% '''
%%
%% This module builds and parses these bytes itself. It does not call
%% `term_to_binary/1' or `binary_to_term/2', which handle every kind of term:
%% a packet is made of atoms, binaries and small tuples only, and `decode/1'
%% refuses anything else. The bytes on the wire are the same as before, so
%% nodes of other releases can still authenticate.
%%
%% `decode/1' ignores the bytes after a packet. A later release can add data
%% there, as was done with the node name after the challenge.
-module(gen_rpc_auth_proto).

-export([encode/1, decode/1]).

-export_type([packet/0]).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-type packet() ::
        %% `Node' is `undefined' when the dialer sent no node name.
        {challenge, Challenge :: binary(), Node :: binary() | undefined}
      | {challenge_response, Response :: binary(), Challenge :: binary()}
      | {response, Response :: binary()}
      | badnode.

%% External term format.
-define(VERSION, 131).
-define(SMALL_TUPLE_EXT, 104).
-define(BINARY_EXT, 109).
-define(SMALL_ATOM_UTF8_EXT, 119).
-define(ATOM_UTF8_EXT, 118).
%% Atom encodings of older Erlang/OTP releases. They are decoded, never sent.
-define(SMALL_ATOM_EXT, 115).
-define(ATOM_EXT, 100).

%% Size in bits of the length field of the node name.
-define(NODE_SIZE_BITS, 16).

%% Limits of what `decode/1' accepts.
%% Deepest tuple nesting: `{error, {badrpc, badnode}}'.
-define(MAX_TUPLE_DEPTH, 2).
%% Largest tuple: `{gen_rpc_authenticate_cr, Response, Challenge}'.
-define(MAX_TUPLE_ARITY, 3).

%%================================================================================
%% API
%%================================================================================

-spec encode(packet()) -> binary().
encode({challenge, Challenge, Node}) ->
    Term = encode_term({gen_rpc_authenticate_c, Challenge}),
    <<Term/binary, (encode_node(Node))/binary>>;
encode({challenge_response, Response, Challenge}) ->
    encode_term({gen_rpc_authenticate_cr, Response, Challenge});
encode({response, Response}) ->
    encode_term({gen_rpc_authenticate_r, Response});
encode(badnode) ->
    encode_term({error, {badrpc, badnode}}).

-spec decode(binary()) -> {ok, packet()} | error.
decode(Packet) ->
    case decode_term(Packet) of
        {ok, {gen_rpc_authenticate_c, Challenge}, Rest} when is_binary(Challenge) ->
            decode_node(Challenge, Rest);
        {ok, {gen_rpc_authenticate_cr, Response, Challenge}, _Rest}
          when is_binary(Response), is_binary(Challenge) ->
            {ok, {challenge_response, Response, Challenge}};
        {ok, {gen_rpc_authenticate_r, Response}, _Rest} when is_binary(Response) ->
            {ok, {response, Response}};
        {ok, {error, {badrpc, badnode}}, _Rest} ->
            {ok, badnode};
        _ ->
            error
    end.

%%================================================================================
%% Node name
%%================================================================================

%% The node name follows the challenge term: a length and the name.
encode_node(undefined) ->
    <<>>;
encode_node(Node) when byte_size(Node) < (1 bsl ?NODE_SIZE_BITS) ->
    <<(byte_size(Node)):?NODE_SIZE_BITS, Node/binary>>.

decode_node(Challenge, <<>>) ->
    {ok, {challenge, Challenge, undefined}};
decode_node(Challenge, <<Size:?NODE_SIZE_BITS, Node:Size/binary, _/binary>>) ->
    {ok, {challenge, Challenge, Node}};
decode_node(_Challenge, _Rest) ->
    error.

%%================================================================================
%% External term format: atoms, binaries and small tuples
%%================================================================================

-spec encode_term(tuple()) -> binary().
encode_term(Term) ->
    iolist_to_binary([?VERSION, encode_element(Term)]).

encode_element(Tuple)
  when is_tuple(Tuple), tuple_size(Tuple) > 0, tuple_size(Tuple) =< ?MAX_TUPLE_ARITY ->
    [?SMALL_TUPLE_EXT, tuple_size(Tuple) | [encode_element(E) || E <- tuple_to_list(Tuple)]];
encode_element(Bin) when is_binary(Bin) ->
    [<<?BINARY_EXT, (byte_size(Bin)):32>>, Bin];
encode_element(Atom) when is_atom(Atom) ->
    Name = atom_to_binary(Atom, utf8),
    [?SMALL_ATOM_UTF8_EXT, byte_size(Name), Name].

%% Decode the term at the start of a packet. Returns the term and the bytes
%% after it. An atom is never created: a name that is not an existing atom is
%% refused.
-spec decode_term(binary()) -> {ok, term(), Rest :: binary()} | error.
decode_term(Packet) ->
    case byte_at(Packet, 0) of
        ?VERSION ->
            case decode_element(Packet, 1, ?MAX_TUPLE_DEPTH) of
                {ok, Term, End} ->
                    {ok, Term, binary:part(Packet, End, byte_size(Packet) - End)};
                error ->
                    error
            end;
        _ ->
            error
    end.

%% Decode the term that starts at byte `Pos' of the packet. Returns the term
%% and the position of the first byte after it. `RemainingDepth' is how many
%% more levels of tuples may follow.
decode_element(Packet, Pos, RemainingDepth) ->
    case byte_at(Packet, Pos) of
        %% No packet has an empty tuple.
        ?SMALL_TUPLE_EXT when RemainingDepth > 0 ->
            case byte_at(Packet, Pos + 1) of
                Arity when is_integer(Arity), Arity > 0, Arity =< ?MAX_TUPLE_ARITY ->
                    decode_elements(Arity, Packet, Pos + 2, RemainingDepth - 1, []);
                _ ->
                    error
            end;
        ?BINARY_EXT ->
            decode_sized(Packet, Pos + 1, 4, binary);
        ?SMALL_ATOM_UTF8_EXT ->
            decode_sized(Packet, Pos + 1, 1, utf8);
        ?ATOM_UTF8_EXT ->
            decode_sized(Packet, Pos + 1, 2, utf8);
        ?SMALL_ATOM_EXT ->
            decode_sized(Packet, Pos + 1, 1, latin1);
        ?ATOM_EXT ->
            decode_sized(Packet, Pos + 1, 2, latin1);
        _ ->
            error
    end.

decode_elements(N, _Packet, Pos, _RemainingDepth, Acc) when N =< 0 ->
    {ok, list_to_tuple(lists:reverse(Acc)), Pos};
decode_elements(N, Packet, Pos, RemainingDepth, Acc) ->
    case decode_element(Packet, Pos, RemainingDepth) of
        {ok, Term, End} ->
            decode_elements(N - 1, Packet, End, RemainingDepth, [Term | Acc]);
        error ->
            error
    end.

%% Decode a size field of `SizeBytes' bytes at `Pos' and the data of that
%% size after it: a binary, or the name of an atom in the given encoding.
decode_sized(Packet, Pos, SizeBytes, Type) ->
    DataPos = Pos + SizeBytes,
    case DataPos =< byte_size(Packet) of
        true ->
            Size = binary:decode_unsigned(binary:part(Packet, Pos, SizeBytes)),
            End = DataPos + Size,
            case End =< byte_size(Packet) of
                true ->
                    decode_data(binary:part(Packet, DataPos, Size), Type, End);
                false ->
                    error
            end;
        false ->
            error
    end.

decode_data(Bin, binary, End) ->
    {ok, Bin, End};
decode_data(Name, Encoding, End) ->
    try
        {ok, binary_to_existing_atom(Name, Encoding), End}
    catch
        error:badarg ->
            error
    end.

byte_at(Packet, Pos) when Pos < byte_size(Packet) ->
    binary:at(Packet, Pos);
byte_at(_Packet, _Pos) ->
    eof.

%%================================================================================
%% Unit tests
%%================================================================================

-ifdef(TEST).

%% A packet is the same bytes that term_to_binary/1 gives for the tuple of
%% the first releases, so a node of another release can decode it.
encode_prop() ->
    ?FORALL({A, B, Node}, {binary(), binary(), node_name()},
            begin
                NodeSize = byte_size(Node),
                C = reference_encode({gen_rpc_authenticate_c, A}),
                ?assertEqual(C, encode({challenge, A, undefined})),
                ?assertEqual(<<C/binary, NodeSize:16, Node/binary>>,
                             encode({challenge, A, Node})),
                ?assertEqual(reference_encode({gen_rpc_authenticate_cr, A, B}),
                             encode({challenge_response, A, B})),
                ?assertEqual(reference_encode({gen_rpc_authenticate_r, A}),
                             encode({response, A})),
                true
            end).

encode_test() ->
    ?assert(proper:quickcheck(encode_prop(), 500)),
    ?assertEqual(reference_encode({error, {badrpc, badnode}}), encode(badnode)).

%% What term_to_binary/2 gives for a term, with atoms in UTF-8. This is the
%% default from Erlang/OTP 26.
reference_encode(Term) ->
    term_to_binary(Term, [{minor_version, 2}]).

%% Every packet is decoded to what was encoded.
roundtrip_prop() ->
    ?FORALL(Packet, packet(),
            {ok, Packet} =:= decode(encode(Packet))).

roundtrip_test() ->
    ?assert(proper:quickcheck(roundtrip_prop(), 500)).

%% Bytes after the node name are ignored, as before.
decode_ignores_bytes_after_node_name_test() ->
    Packet = encode({challenge, <<"challenge">>, <<"node@host">>}),
    ?assertEqual({ok, {challenge, <<"challenge">>, <<"node@host">>}},
                 decode(<<Packet/binary, "more">>)).

%% A node name that is shorter than its length field says is refused.
decode_refuses_short_node_name_test() ->
    Packet = encode({challenge, <<"challenge">>, undefined}),
    ?assertEqual(error, decode(<<Packet/binary, 0>>)),
    ?assertEqual(error, decode(<<Packet/binary, 10:16, "node@host">>)).

%% Erlang/OTP releases differ in how they encode an atom. All four atom
%% encodings are accepted, so peers on other releases can still authenticate.
decode_atom_encodings_test() ->
    Name = <<"gen_rpc_authenticate_r">>,
    Size = byte_size(Name),
    Response = <<"response">>,
    Atoms = [ <<?SMALL_ATOM_UTF8_EXT, Size, Name/binary>>
            , <<?ATOM_UTF8_EXT, Size:16, Name/binary>>
            , <<?SMALL_ATOM_EXT, Size, Name/binary>>
            , <<?ATOM_EXT, Size:16, Name/binary>>
            ],
    lists:foreach(
      fun(Atom) ->
              Packet = <<?VERSION, ?SMALL_TUPLE_EXT, 2, Atom/binary,
                         ?BINARY_EXT, (byte_size(Response)):32, Response/binary>>,
              ?assertEqual({ok, {response, Response}}, decode(Packet))
      end,
      Atoms).

%% A tuple of the right shape with a field that is not a binary is refused.
decode_refuses_other_fields_test() ->
    Terms = [ {gen_rpc_authenticate_c, error}
            , {gen_rpc_authenticate_c, {<<"a">>, <<"b">>}}
            , {gen_rpc_authenticate_cr, <<"response">>, error}
            , {gen_rpc_authenticate_cr, error, <<"challenge">>}
            , {gen_rpc_authenticate_r, error}
            , {gen_rpc_authenticate_r, <<"a">>, <<"b">>}
            , {error, {badrpc, error}}
            , {error, badnode}
            , gen_rpc_authenticate_r
            ],
    lists:foreach(
      fun(Term) ->
              Packet = term_to_binary(Term),
              ?assertEqual({ok, Term, <<>>}, decode_term(Packet)),
              ?assertEqual(error, decode(Packet))
      end,
      Terms).

%% Only atoms, binaries and small tuples of those are decoded. Any other
%% term is refused, although binary_to_term/2 accepts it.
decode_refuses_other_terms_test() ->
    Terms = [ 1, -1, 1 bsl 64, 1.0, [], [a], "abc", <<1:1>>, #{}, #{a => b}
            , self(), make_ref(), fun erlang:node/0
            , {gen_rpc_authenticate_c, [<<"ab">>, <<"cd">>]}
            , {gen_rpc_authenticate_r, "abc"}
            , {}            %% fewer elements than any packet
            , {a, b, c, d}  %% more elements than any packet
            , {a, {b, {c}}} %% deeper than any packet
            ],
    lists:foreach(
      fun(Term) ->
              Packet = term_to_binary(Term),
              ?assertEqual(Term, binary_to_term(Packet, [safe])),
              ?assertEqual(error, decode_term(Packet)),
              ?assertEqual(error, decode(Packet))
      end,
      Terms).

%% A packet is accepted in its plain encoding only. The same term with a
%% large tuple header, or compressed, is refused, although binary_to_term/2
%% accepts both.
decode_refuses_other_encodings_test() ->
    Challenge = binary:copy(<<1>>, 128),
    Term = {gen_rpc_authenticate_c, Challenge},
    Plain = term_to_binary(Term),
    {<<?VERSION, ?SMALL_TUPLE_EXT, 2>>, Elements} = split_binary(Plain, 3),
    LargeTuple = <<?VERSION, 105, 2:32, Elements/binary>>,
    Compressed = term_to_binary(Term, [compressed]),
    ?assertMatch(<<?VERSION, 80, _/binary>>, Compressed),
    ?assertEqual({ok, {challenge, Challenge, undefined}}, decode(Plain)),
    lists:foreach(
      fun(Packet) ->
              ?assertEqual(Term, binary_to_term(Packet, [safe])),
              ?assertEqual(error, decode(Packet))
      end,
      [LargeTuple, Compressed]).

%% Truncated and malformed packets are refused without an exception.
decode_malformed_test() ->
    Packet = encode({challenge_response, <<"response">>, <<"challenge">>}),
    lists:foreach(
      fun(Size) ->
              ?assertEqual(error, decode(binary:part(Packet, 0, Size)))
      end,
      lists:seq(0, byte_size(Packet) - 1)),
    {<<?VERSION>>, Body} = split_binary(Packet, 1),
    ?assertEqual(error, decode(Body)),
    ?assertEqual(error, decode(<<130, Body/binary>>)).

%% An atom that does not exist is refused, and it is not created.
decode_unknown_atom_test() ->
    Unique = integer_to_binary(erlang:unique_integer([positive])),
    Name = <<"gen_rpc_auth_proto_no_such_atom_", Unique/binary>>,
    lists:foreach(
      fun(Packet) ->
              ?assertEqual(error, decode(Packet)),
              ?assertError(badarg, binary_to_existing_atom(Name, utf8))
      end,
      [ <<?VERSION, ?SMALL_ATOM_UTF8_EXT, (byte_size(Name)), Name/binary>>
      , <<?VERSION, ?ATOM_EXT, (byte_size(Name)):16, Name/binary>>
      ]).

%% decode/1 and decode_term/1 never raise. When decode_term/1 accepts a
%% packet, it returns what binary_to_term/2 returns for it.
decode_term_prop() ->
    ?FORALL(Packet, oneof([term_packet(), mutated_term_packet(), binary()]),
            begin
                _ = decode(Packet),
                case decode_term(Packet) of
                    error ->
                        true;
                    Decoded ->
                        Decoded =:= reference_decode(Packet)
                end
            end).

decode_term_test() ->
    ?assert(proper:quickcheck(decode_term_prop(), 2000)).

%% What binary_to_term/2 makes of a packet, in the shape of decode_term/1.
reference_decode(Packet) ->
    {Term, Used} = binary_to_term(Packet, [safe, used]),
    {_, Rest} = split_binary(Packet, Used),
    {ok, Term, Rest}.

packet() ->
    oneof([ {challenge, binary(), oneof([undefined, node_name()])}
          , {challenge_response, binary(), binary()}
          , {response, binary()}
          , badnode
          ]).

node_name() ->
    ?LET(Name, binary(), <<"node@", Name/binary>>).

term_packet() ->
    ?LET({Term, Rest}, {packet_term(?MAX_TUPLE_DEPTH), binary()},
         <<(term_to_binary(Term))/binary, Rest/binary>>).

packet_term(0) ->
    oneof([packet_atom(), binary()]);
packet_term(Depth) ->
    Element = packet_term(Depth - 1),
    oneof([ packet_atom()
          , binary()
          , {}
          , {Element}
          , {Element, Element}
          , {Element, Element, Element}
          ]).

packet_atom() ->
    oneof([ gen_rpc_authenticate_c, gen_rpc_authenticate_cr, gen_rpc_authenticate_r
          , error, badrpc, badnode, node()
          ]).

%% A packet with one byte replaced.
mutated_term_packet() ->
    ?LET({Packet, Pos, Byte}, {term_packet(), non_neg_integer(), byte()},
         begin
             HeadSize = Pos rem byte_size(Packet),
             Head = binary:part(Packet, 0, HeadSize),
             Tail = binary:part(Packet, HeadSize + 1, byte_size(Packet) - HeadSize - 1),
             <<Head/binary, Byte, Tail/binary>>
         end).

-endif.
