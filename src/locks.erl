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
%% Key contributor: Thomas Arts <thomas.arts@quviq.com>
%%
%%=============================================================================
%% @doc Official API for the 'locks' system
%%
%% This module contains the supported interface functions for
%%
%% * starting and stopping a transaction (agent)
%% * acquiring locks via an agent
%% * awaiting requested locks
%%
%% @end

-module(locks).

-export(
   [begin_transaction/0,  %% () -> begin_transaction(Options)
    begin_transaction/1,  %% (Objects) -> (Objects, [])
    begin_transaction/2,  %% (Objects, Options)
    end_transaction/1,    %% (Agent)
    lock/2,               %% (Agent,OID) -> (Agent,OID,write,[node()],all)
    lock/3,               %% (Agent,OID,Mode) -> (Agent,OID,Mode,[node()],all)
    lock/4,               %% (Agent,OID,Mode,Nodes) -> (..., all)
    lock/5,               %% (Agent,OID,Mode,Nodes,Req)
    lock_nowait/2,
    lock_nowait/3,
    lock_nowait/4,
    lock_objects/2,       %% (Agent, Objects)
    await_all_locks/1]).  %% (Agent)

-include("locks.hrl").

-spec begin_transaction() -> {agent(), lock_result()}.
begin_transaction() ->
    locks_agent:begin_transaction([], []).

-spec begin_transaction(objs()) -> {agent(), lock_result()}.
begin_transaction(Objects) ->
    locks_agent:begin_transaction(Objects, []).

-spec begin_transaction(objs(), options()) -> {agent(), lock_result()}.
begin_transaction(Objects, Options) when is_list(Objects), is_list(Options) ->
    locks_agent:begin_transaction(Objects, Options).

-spec end_transaction(pid()) -> ok.
end_transaction(Agent) ->
    locks_agent:end_transaction(Agent).

-spec lock(agent(), oid()) -> {ok, deadlocks()}.
lock(Agent, OID) ->
    locks_agent:lock(Agent, OID, write, [node()], all).

-spec lock(agent(), oid(), mode()) -> {ok, deadlocks()}.
lock(Agent, OID, Mode) ->
    locks_agent:lock(Agent, OID, Mode, [node()], all).

-spec lock(agent(), oid(), mode(), where()) -> {ok, deadlocks()}.
lock(Agent, OID, Mode, Nodes) ->
    locks_agent:lock(Agent, OID, Mode, Nodes, all).

-spec lock(agent(), oid(), mode(), where(), req()) -> {ok, deadlocks()}.
lock(Agent, OID, Mode, Nodes, Req) ->
    locks_agent:lock(Agent, OID, Mode, Nodes, Req).

-spec lock_nowait(agent(), oid()) -> ok.
lock_nowait(Agent, OID) ->
    lock_nowait(Agent, OID, write, [node()], all).

-spec lock_nowait(agent(), oid(), mode()) -> ok.
lock_nowait(Agent, OID, Mode) ->
    locks_agent:lock_nowait(Agent, OID, Mode, [node()], all).

-spec lock_nowait(agent(), oid(), mode(), where()) -> ok.
lock_nowait(Agent, OID, Mode, Nodes) ->
    locks_agent:lock_nowait(Agent, OID, Mode, Nodes, all).

-spec lock_nowait(agent(), oid(), mode(), where(), req()) -> ok.
lock_nowait(Agent, OID, Mode, Nodes, Req) ->
    locks_agent:lock_nowait(Agent, OID, Mode, Nodes, Req).

-spec lock_objects(agent(), objs()) -> ok.
lock_objects(Agent, Objects) ->
    locks_agent:lock_objects(Agent, Objects).

-spec await_all_locks(agent()) -> lock_result().
await_all_locks(Agent) ->
    locks_agent:await_all_locks(Agent).
