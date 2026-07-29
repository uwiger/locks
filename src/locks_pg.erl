%% -*- mode: erlang; indent-tabs-mode: nil; -*-
%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%
%% Copyright (C) 2013 Ulf Wiger. All rights reserved.
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
%%---- END COPYRIGHT ---------------------------------------------------------
%%
%% @doc Scoped process groups for locks peer discovery.
%%
%% Thin wrapper around OTP `pg` used so leader candidates (and optionally
%% lock servers) can discover each other via an explicit society membership
%% channel, independent of lock-queue gossip.
%% @end
-module(locks_pg).

-define(SCOPE, ?MODULE).

-export([ start_link/0
        , join/2
        , leave/2
        , monitor/1
        , get_members/1 ]).

start_link() ->
    pg:start_link(?SCOPE).

monitor(Group) ->
    pg:monitor(?SCOPE, Group).

join(Group, PidOrPids) ->
    pg:join(?SCOPE, Group, PidOrPids).

leave(Group, PidOrPids) ->
    pg:leave(?SCOPE, Group, PidOrPids).

get_members(Group) ->
    pg:get_members(?SCOPE, Group).
