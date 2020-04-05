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
    spawn_agent/0,        %% () -> spawn_agent([])
    spawn_agent/1,        %% (Options)
    lock/2,               %% (Agent,OID) -> (Agent,OID,write,[node()],all)
    lock/3,               %% (Agent,OID,Mode) -> (Agent,OID,Mode,[node()],all)
    lock/4,               %% (Agent,OID,Mode,Nodes) -> (..., all)
    lock/5,               %% (Agent,OID,Mode,Nodes,Req)
    lock_nowait/2,
    lock_nowait/3,
    lock_nowait/4,
    lock_objects/2,       %% (Agent, Objects)
    await_all_locks/1,    %% (Agent)
    transaction_status/1, %% (Agent)
    watch/2,              %% (OID, Nodes)
    unwatch/2,            %% (OID, Nodes)
    watchers/1,           %% (OID)
    change_flag/3]).      %% (Agent, Flag, Value)

-include("locks.hrl").

-spec begin_transaction() -> {agent(), lock_result()}.
%% @equiv begin_transaction([], [])
begin_transaction() ->
    locks_agent:begin_transaction([], []).

-spec begin_transaction(objs()) -> {agent(), lock_result()}.
%% @equiv begin_transaction(Objects, [])
begin_transaction(Objects) ->
    locks_agent:begin_transaction(Objects, []).

-spec begin_transaction(objs(), options()) -> {agent(), lock_result()}.
%% @doc Starts a transaction agent.
%%
%% Valid options are:
%%
%% * `{abort_on_deadlock, boolean()}' - default: `false'. Normally, when a
%%   deadlock is detected, the involved agents will resolve it by one agent
%%   surrendering a lock, but this is not always desireable. With this option,
%%   agents will abort if a deadlock is detected.
%% * `{client, pid()}' - defaults to `self()'. The agent will accept lock
%%   requests only from the designated client.
%% * `{await_nodes, boolean()}' - default: `false'. If nodes required to
%%   serve a lock request are off-line, with `{await_nodes, false}', the
%%   transaction will abort; with `{await_nodes, true}' the transaction will
%%   wait for them to return and try to re-acquire the locks.
%%
%% @end
begin_transaction(Objects, Options) when is_list(Objects), is_list(Options) ->
    locks_agent:begin_transaction(Objects, Options).

-spec spawn_agent() -> {ok, agent()}.
spawn_agent() ->
    spawn_agent([]).

-spec spawn_agent(options()) -> {ok, agent()}.
spawn_agent(Options) ->
    locks_agent:spawn_agent(Options).

-spec end_transaction(pid()) -> ok.
%% @doc Terminates the transaction agent, releasing all locks.
%%
%% Note that there is no unlock() operation. The way to release locks is
%% to end the transaction.
%% @end
end_transaction(Agent) ->
    locks_agent:end_transaction(Agent).

-spec lock(agent(), oid()) -> {ok, deadlocks()}.
%% @equiv lock(Agent, OID, write, [node()], all)
lock(Agent, OID) ->
    locks_agent:lock(Agent, OID, write, [node()], all).

-spec lock(agent(), oid(), mode()) -> {ok, deadlocks()}.
%% @equiv lock(Agent, OID, Mode, [node()], all)
lock(Agent, OID, Mode) ->
    locks_agent:lock(Agent, OID, Mode, [node()], all).

-spec lock(agent(), oid(), mode(), where()) -> {ok, deadlocks()}.
%% @equiv lock(Agent, OID, Mode, Nodes, all)
lock(Agent, OID, Mode, Nodes) ->
    locks_agent:lock(Agent, OID, Mode, Nodes, all).

-spec lock(agent(), oid(), mode(), where(), req()) -> {ok, deadlocks()}.
%% @doc Acquire a lock on object.
%%
%% This operation requires an active transaction agent
%% (see {@link begin_transaction/2}).
%%
%% The object identifier is a non-empty list, where each element represents
%% a level in a lock tree. For example, in a database `Db', with tables and
%% objects, object locks could be given as `[Db, Table, Key]', table locks
%% as `[Db, Table]' and schema locks `[Db]'.
%%
%% `Mode' can be either `read' (shared) or `write' (exclusive). If possible,
%% read locks will be upgraded to write locks when requested. Specifically,
%% this can be done if no other agent also hold a read lock, and there are
%% no waiting agents on the lock (directly or indirectly). If the lock cannot
%% be upgraded, the read lock will be removed and a write lock request will
%% be inserted in the lock queue.
%%
%% The lock request is synchronous, and will return when this and all previous
%% lock requests have been granted. The return value is `{ok, Deadlocks}',
%% where `Deadlocks' is a list of objects that have caused a deadlock.
%%
%% @end
lock(Agent, OID, Mode, Nodes, Req) ->
    locks_agent:lock(Agent, OID, Mode, Nodes, Req).

-spec lock_nowait(agent(), oid()) -> ok.
%% @equiv lock_nowait(Agent, OID, write, [node()], all)
lock_nowait(Agent, OID) ->
    lock_nowait(Agent, OID, write, [node()], all).

-spec lock_nowait(agent(), oid(), mode()) -> ok.
%% @equiv lock_nowait(Agent, OID, Mode, [node()], all)
lock_nowait(Agent, OID, Mode) ->
    locks_agent:lock_nowait(Agent, OID, Mode, [node()], all).

-spec lock_nowait(agent(), oid(), mode(), where()) -> ok.
%% @equiv lock_nowait(Agent, OID, Mode, Nodes, all)
lock_nowait(Agent, OID, Mode, Nodes) ->
    locks_agent:lock_nowait(Agent, OID, Mode, Nodes, all).

-spec lock_nowait(agent(), oid(), mode(), where(), req()) -> ok.
%% @doc Non-blocking equivalent to lock/5.
%%
%% See {@link lock/5} for a description of the arguments.
%% This function returns `ok'. To check the lock outcome,
%% use {@link await_all_locks/1} or a subsequent call to
%% {@link lock/5} (which waits for all requested locks).
%% @end
lock_nowait(Agent, OID, Mode, Nodes, Req) ->
    locks_agent:lock_nowait(Agent, OID, Mode, Nodes, Req).

-spec lock_objects(agent(), objs()) -> ok.
%% @doc Asynchronously locks several objects at once.
%%
%% This function is equivalent to repeatedly calling {@link lock_nowait/5},
%% essentially:
%%
%% <pre lang="erlang">
%% lists:foreach(
%%     fun({OID, Mode}) -&gt; lock_nowait(Agent, OID, Mode);
%%        ({OID, Mode, Nodes}) -&gt; lock_nowait(Agent, OID, Mode, Nodes);
%%        ({OID, Mode, Nodes, Req}) -&gt; lock_nowait(Agent,OID,Mode,Nodes,Req)
%%     end, Objects)
%% </pre>
%% @end
lock_objects(Agent, Objects) ->
    locks_agent:lock_objects(Agent, Objects).

-spec await_all_locks(agent()) -> lock_result().
%% @doc Await the results of all requested locks.
%%
%% This function blocks until all requested locks have been acquired, or it
%% is determined that they cannot be (and the transaction aborts).
%%
%% The return value is `{have_all_locks | have_none, Deadlocks}',
%% where `Deadlocks' is a list of `{OID, Node}' pairs that were either
%% surrendered or released as a result of an abort triggered by the deadlock
%% analysis.
%% @end
await_all_locks(Agent) ->
    locks_agent:await_all_locks(Agent).

%% @doc Inquire about the current status of the transaction.
%% Return values:
%% <dl>
%% <dt>`no_locks'</dt>
%%   <dd>No locks have been requested</dd>
%% <dt>`{have_all_locks, Deadlocks}'</dt>
%%   <dd>All requested locks have been claimed, `Deadlocks' indicates whether
%%       any deadlocks were resolved in the process.</dd>
%% <dt>`waiting'</dt>
%%   <dd>Still waiting for some locks.</dd>
%% <dt>`{cannot_serve, Objs}'</dt>
%%   <dd>Some lock requests cannot be served, e.g. because some nodes are
%%       unavailable.</dd>
%% </dl>
%% @end
transaction_status(Agent) ->
    locks_agent:transaction_status(Agent).

-spec watch(oid(), [node()]) -> ok.
%% @doc Subscribe to lock state changes.
%%
%% This function ensures that `#lock_info{}' messages are sent for each
%% lock state change in `OID' on `Nodes'. The subscription is not
%% persistent; if a node dies, the knowledge of processes watching locks
%% on that node will disappear.
%% @end
watch(OID, Nodes) ->
    locks_server:watch(OID, Nodes).

change_flag(Agent, Option, Bool)
  when is_boolean(Bool), Option == abort_on_deadlock;
       is_boolean(Bool), Option == await_nodes;
       is_boolean(Bool), Option == notify ->
    locks_agent:change_flag(Agent, Option, Bool).

-spec unwatch(oid(), [node()]) -> ok.
%% @doc Remove a subscription created by {@link watch/2}.
%%
%% This function removes a subscription created by {@link watch/2}.
%% @end
unwatch(OID, Nodes) ->
    locks_server:unwatch(OID, Nodes).

-spec watchers(oid()) -> [pid()].
%% @doc List the process IDs of watchers of `OID' on the current node.
%% @end
watchers(OID) ->
    locks_server:watchers(OID).
