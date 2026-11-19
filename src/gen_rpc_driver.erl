%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%% Copyright 2015 Panagiotis Papadomitsos. All Rights Reserved.
%%%

-module(gen_rpc_driver).

-callback connect(atom(), inet:port_number()) -> {ok, term()} | {error, term()}.

-callback listen(inet:port_number()) -> {ok, term()} | {error, term()}.

-callback accept(term()) -> {ok, inet:socket() | ssl:sslsocket()} | {error, term()}.

%% Called by rpc client which should receive replies ASAP.
-callback activate_socket(term()) -> ok | {error, term()}.

%% Called by rpc acceptor which may need to pose back-pressure towards client.
-callback activate_socket(term(), pos_integer()) -> ok | {error, term()}.

-callback recv(term(), non_neg_integer(), timeout()) -> {ok, binary()} | {error, _Reason}.

-callback send(term(), binary()) -> ok | {error, term()}.

-callback close(term()) -> ok | {error, _}.

-callback get_peer(term()) -> {inet:ip4_address(), inet:port_number()}.

-callback copy_sock_opts(term(), term()) -> ok | {error, any()}.

-callback set_controlling_process(term(), pid()) -> ok | {error, term()}.

-callback set_send_timeout(term(), timeout() | undefined) -> ok.

-callback set_acceptor_opts(term()) -> ok.

-callback set_packet_size(term(), non_neg_integer()) -> ok | {error, term()}.

-ifdef(TEST).
%% Stub function to fool code coverage
-export([stub/0]).
stub() -> ok.
-endif.
