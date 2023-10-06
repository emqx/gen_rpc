%%% -*-mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
%%% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%% Copyright 2015, 2023 Panagiotis Papadomitsos. All Rights Reserved.
%%%

-include("tcp.hrl").

%%% Default SSL options common to client and server
-define(SSL_DEFAULT_COMMON_OPTS,
        ([ {secure_renegotiate,true}
         , {reuse_sessions,true}
         , {verify, verify_peer}
         %%, {keep_secrets, true} % debug only
         ] ++ ?TCP_DEFAULT_OPTS)).

-define(SSL_DEFAULT_SERVER_OPTS,
        [{fail_if_no_peer_cert,true},
        {log_alert,false},
        {honor_cipher_order,true},
        {client_renegotiation,true}]).

-define(SSL_DEFAULT_CLIENT_OPTS,
        [{server_name_indication,disable},
         {depth,10}]).
