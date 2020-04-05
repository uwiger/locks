%% -*- mode: erlang; indent-tabs-mode: nil; -*-
%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%
%% Copyright (C) 2013-20 Ulf Wiger. All rights reserved.
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
%%---- END COPYRIGHT ---------------------------------------------------------
%% Key contributor: Thomas Arts <thomas.arts@quviq.com>
%%
%%=============================================================================
%% @doc Support functions for locks_agent
%% @end

-module(locks_agent_lib).
-export([ all_locks_status/1
        , analyse/1 ]).

-export([ get_lock/2
        , matching_request/5
        , send_indirects/1
        , store_lock_holders/3
        , lock_holders/1
        , move_requests/3
        , involved_agents/1
        , prune_interesting/3
        , request_lock/3
        , ensure_monitor/2
        , request_can_be_served/2
        , in_tail/2
        , add_msgs/2 ]).

-import(lists,[foreach/2,any/2,map/2,member/2]).

-include("locks_agent.hrl").


-spec all_locks_status(#state{}) ->
                              no_locks
                                  | waiting
                                  | {have_all_locks, deadlocks()}
                                  | {cannot_serve, list()}.
%%
all_locks_status(#state{pending = Pend, locks = Locks} = State) ->
    Status = all_locks_status_(State),
    ?costly_event({locks_diagnostics,
                   [{pending, pp_pend(ets:tab2list(Pend))},
                    {locks, pp_locks(ets:tab2list(Locks))}]}),
    ?event({all_locks_status, Status}),
    Status.

pp_pend(Pend) ->
    [{O, M, Ns, Req} || #req{object = O, mode = M, nodes = Ns,
                             require = Req} <- Pend].

pp_locks(Locks) ->
    [{O,lock_holder(Q)} ||
        #lock{object = O, queue = Q} <- Locks].

lock_holder([#w{entries = Es}|_]) ->
    [A || #entry{agent = A} <- Es];
lock_holder([#r{entries = Es}|_]) ->
    [A || #entry{agent = A} <- Es].


all_locks_status_(#state{locks = Locks, pending = Pend} = State) ->
    case ets_info(Locks, size) of
        0 ->
            case ets_info(Pend, size) of
                0 -> no_locks;
                _ ->
                    waiting
            end;
        _ ->
            case waitingfor(State) of
                [] ->
                    {have_all_locks, State#state.deadlocks};
                WF ->
                    case [O || {O, _} <- WF,
                               requests_for_obj_can_be_served(
                                 O, State) =:= false] of
                        [] ->
                            waiting;
                        Os ->
                            {cannot_serve, Os}
                    end
            end
    end.

requests_for_obj_can_be_served(Obj, #state{pending = Pending} = S) ->
    lists:all(
      fun(R) ->
              request_can_be_served(R, S)
      end, ets:lookup(Pending, Obj)).

request_can_be_served(_, #state{await_nodes = true}) ->
    true;
request_can_be_served(#req{nodes = Ns, require = R}, #state{down = Down}) ->
    case R of
        all       -> intersection(Down, Ns) == [];
        any       -> Ns -- Down =/= [];
        majority  -> length(Ns -- Down) > (length(Ns) div 2);
        majority_alive -> true;
        all_alive      -> true
    end.

-spec waitingfor(#state{}) -> [lock_id()].
waitingfor(#state{requests = Reqs,
                  pending = Pending, down = Down} = S) ->
    %% HaveLocks = [{L#lock.object, l_mode(Q)} || #lock{queue = Q} = L <- Locks,
    %%                                            in(self(), hd(Q))],
    {Served, PendingOIDs} =
        ets:foldl(
          fun(#req{object = OID, mode = M,
                   require = majority, nodes = Ns} = R,
              {SAcc, PAcc}) ->
                  NodesLocked = nodes_locked(OID, M, S),
                  case length(NodesLocked) > (length(Ns) div 2) of
                      false ->
                          {SAcc, ordsets:add_element(OID, PAcc)};
                      true ->
                          {[R|SAcc], PAcc}
                  end;
             (#req{object = OID, mode = M,
                   require = majority_alive, nodes = Ns} = R,
              {SAcc, PAcc}) ->
                  Alive = Ns -- Down,
                  NodesLocked = nodes_locked(OID, M, S),
                  case length(NodesLocked) > (length(Alive) div 2) of
                      false ->
                          {SAcc, ordsets:add_element(OID, PAcc)};
                      true ->
                          {[R|SAcc], PAcc}
                  end;
             (#req{object = OID, mode = M,
                   require = any, nodes = Ns} = R, {SAcc, PAcc}) ->
                  case [N || N <- nodes_locked(OID, M, S),
                             member(N, Ns)] of
                      [_|_] -> {[R|SAcc], PAcc};
                      [] ->
                          {SAcc, ordsets:add_element(OID, PAcc)}
                  end;
             (#req{object = OID, mode = M,
                   require = all, nodes = Ns} = R, {SAcc, PAcc}) ->
                  NodesLocked = nodes_locked(OID, M, S),
                  case Ns -- NodesLocked of
                      [] -> {[R|SAcc], PAcc};
                      [_|_] ->
                          {SAcc, ordsets:add_element(OID, PAcc)}
                  end;
             (#req{object = OID, mode = M,
                   require = all_alive, nodes = Ns} = R, {SAcc, PAcc}) ->
                  Alive = Ns -- Down,
                  NodesLocked = nodes_locked(OID, M, S),
                  case Alive -- NodesLocked of
                      [] -> {[R|SAcc], PAcc};
                      [_|_] ->
                          {SAcc, ordsets:add_element(OID, PAcc)}
                  end;
             (_, Acc) ->
                  Acc
          end, {[], ordsets:new()}, Pending),
    ?event([{served, Served}, {pending_oids, PendingOIDs}]),
    move_requests(Served, Pending, Reqs),
    PendingOIDs.

nodes_locked(OID, M, #state{} = S) ->
    [N || {_, N} = Obj <- have_locks(OID, S),
          l_covers(M, l_mode( get_lock(Obj,S) ))].

l_mode(#lock{queue = [#r{}|_]}) -> read;
l_mode(#lock{queue = [#w{}|_]}) -> write.

l_covers(read, write) -> true;
l_covers(M   , M    ) -> true;
l_covers(_   , _    ) -> false.

intersection(A, B) ->
    A -- (A -- B).

get_lock(OID, #state{locks = Ls}) ->
    [L] = ets_lookup(Ls, OID),
    L.

move_requests([R|Rs], From, To) ->
    ets_delete_object(From, R),
    ets_insert(To, R),
    move_requests(Rs, From, To);
move_requests([], _, _) ->
    ok.

store_lock_holders(Prev, #lock{object = Obj} = Lock,
                   #state{agents = As}) ->
    PrevLockHolders = case Prev of
                          [PrevLock] -> lock_holders(PrevLock);
                          [] -> []
                      end,
    LockHolders = lock_holders(Lock),
    [ets_delete(As, {A,Obj}) || A <- PrevLockHolders -- LockHolders],
    [ets_insert(As, {{A,Obj}}) || A <- LockHolders -- PrevLockHolders],
    ok.

lock_holders(#lock{queue = [#r{entries = Es}|_]}) ->
    [A || #entry{agent = A} <- Es];
lock_holders(#lock{queue = [#w{entries = [#entry{agent = A}]}|_]}) ->
    %% exclusive lock held
    [A];
lock_holders(#lock{queue = [#w{entries = [_,_|_]}|_]}) ->
    %% contention for write lock; no-one actually holds the lock
    [].

prune_interesting(I, node, Node) ->
    [OID || {_, N} = OID <- I, N =/= Node];
prune_interesting(I, object, Object) ->
    [OID || {O, _} = OID <- I, O =/= Object].

send_indirects(#state{interesting = I, agents = As} = State) ->
    InvolvedAgents = involved_agents(As),
    Locks = [get_lock(OID, State) || OID <- I],
    [ send_lockinfo(Agent, L)
      || Agent <- compute_indirects(InvolvedAgents),
         #lock{queue = [_,_|_]} = L <- Locks,
         interesting(State, L, Agent) ].

-spec compute_indirects([agent()]) -> [agent()].
compute_indirects(InvolvedAgents) ->
    [ A || A<-InvolvedAgents, A>self()].

send_lockinfo(Agent, #lock{object = {OID, Node}} = L) ->
    Agent ! #locks_info{lock = L#lock{object = OID}, where = Node}.

involved_agents(As) ->
    involved_agents(ets:first(As), As).

involved_agents({A,_}, As) ->
    [A | involved_agents(ets_next(As, {A,[]}), As)];
involved_agents('$end_of_table', _) ->
    [].

%% is this lock interesting for the agent?
%%
-spec interesting(#state{}, #lock{}, agent()) -> boolean().
interesting(#state{agents = As}, #lock{queue = Q}, Agent) ->
    (not is_member(Agent, Q)) andalso
        has_a_lock(As, Agent).

is_member(A, [#r{entries = Es}|T]) ->
    lists:keymember(A, #entry.agent, Es) orelse is_member(A, T);
is_member(A, [#w{entries = Es}|T]) ->
    lists:keymember(A, #entry.agent, Es) orelse is_member(A, T);
is_member(_, []) ->
    false.

%% -spec has_a_lock([#lock{}], pid()) -> boolean().
%% has_a_lock(Locks, Agent) ->
%%     is_member(Agent, [hd(L#lock.queue) || L<-Locks]).
has_a_lock(As, Agent) ->
    case ets_next(As, {Agent,0}) of   % Lock IDs are {LockName,Node} tuples
        {Agent,_} -> true;
        _ -> false
    end.

have_locks(Obj, #state{agents = As}) ->
    %% We need to use {element,1,{element,2,{element,1,'$_'}}} in the body,
    %% since Obj may not be a legal output pattern (e.g. [a, {x,1}]).
    ets_select(As, [{ {{self(),{Obj,'$1'}}}, [],
                      [{{{element,1,
                          {element,2,
                           {element,1,'$_'}}},'$1'}}] }]).

ets_insert(T, Obj)      -> ets:insert(T, Obj).
ets_lookup(T, K)        -> ets:lookup(T, K).
ets_delete(T, K)        -> ets:delete(T, K).
ets_delete_object(T, O) -> ets:delete_object(T, O).
ets_select(T, P)        -> ets:select(T, P).
ets_info(T, I)          -> ets:info(T, I).
ets_next(T, K)          -> ets:next(T, K).

matching_request(Object, Mode, Nodes, Require,
                 #state{requests = Requests,
                        pending = Pending} = S) ->
    case any_matching_request_(ets_lookup(Pending, Object), Pending,
                               Object, Mode, Nodes, Require, S) of
        {false, S1} ->
            any_matching_request_(ets_lookup(Requests, Object), Requests,
                                  Object, Mode, Nodes, Require, S1);
        True -> True
    end.

any_matching_request_([R|Rs], Tab, Object, Mode, Nodes, Require, S) ->
    case matching_request_(R, Tab, Object, Mode, Nodes, Require, S) of
        {false, S1} ->
            any_matching_request_(Rs, Tab, Object, Mode, Nodes, Require, S1);
        True -> True
    end;
any_matching_request_([], _, _, _, _, _, S) ->
    {false, S}.

matching_request_(Req, Tab, Object, Mode, Nodes, Require, S) ->
    case Req of
        #req{nodes = Nodes1, require = Require, mode = Mode} ->
            ?event({repeated_request, Object}),
            %% Repeated request
            case Nodes -- Nodes1 of
                [] ->
                    {true, S};
                [_|_] = New ->
                    {true, add_nodes(New, Req, Tab, S)}
            end;
        #req{nodes = Nodes, require = Require, mode = write}
          when Mode==read ->
            ?event({found_old_write_request, Object}),
            %% The old request is sufficient
            {true, S};
        #req{nodes = Nodes, require = Require, mode = read} when Mode==write ->
            ?event({need_upgrade, Object}),
            {false, remove_locks(Object, S)};
        #req{nodes = PrevNodes} ->
            %% Different conditions from last time
            Reason = {conflicting_request,
                      [Object, Nodes, PrevNodes]},
            error(Reason)
    end.

add_nodes(Nodes, #req{object = Object, mode = Mode, nodes = OldNodes} = Req,
          Tab, #state{pending = Pending} = State) ->
    AllNodes = union(Nodes, OldNodes),
    Req1 = Req#req{nodes = AllNodes},
    %% replace request
    ets_delete_object(Tab, Req),
    ets_insert(Pending, Req1),
    lists:foldl(
      fun(Node, Sx) ->
              OID = {Object, Node},
              request_lock(
                OID, Mode, ensure_monitor(Node, Sx))
      end, State, Nodes).

remove_locks(Object, #state{locks = Locks, agents = As,
                            interesting = I} = S) ->
    ets:match_delete(Locks, #lock{object = {Object,'_'}, _ = '_'}),
    ets:match_delete(As, {{self(),{Object,'_'}}}),
    S#state{interesting = prune_interesting(I, object, Object)}.

request_lock({OID, Node} = _LockID, Mode, #state{client = Client} = State) ->
    ?event({request_lock, _LockID}),
    P = {?LOCKER, Node},
    erlang:monitor(process, P),
    locks_server:lock(OID, [Node], Client, Mode),
    State.

ensure_monitor(Node, S) when Node == node() ->
    S;
ensure_monitor(Node, #state{monitored = Mon} = S) ->
    Mon1 = ensure_monitor_(?LOCKER, Node, Mon),
    S#state{monitored = Mon1}.

ensure_monitor_(Locker, Node, Mon) ->
    case orddict:is_key(Node, Mon) of
        true ->
            Mon;
        false ->
            Ref = erlang:monitor(process, {Locker, Node}),
            orddict:store(Node, Ref, Mon)
    end.

union(A, B) ->
    A ++ (B -- A).

%% analyse computes whether a local deadlock can be detected,
%% if not, 'ok' is returned, otherwise it returns the triple
%% {deadlock,ToSurrender,ToObject} stating which agent should
%% surrender which object.
%%
analyse(Locks) ->
    Nodes =
	expand_agents([ {hd(L#lock.queue), L#lock.object} ||
                          L <- Locks]),
    Connect =
	fun({A1, O1}, {A2, _}) when A1 =/= A2 ->
                lists:any(
                     fun(#lock{object = Obj, queue = Queue}) ->
                             (O1=:=Obj)
                                 andalso in(A1, hd(Queue))
                                 andalso in_tail(A2, tl(Queue))
                     end, Locks);
           (_, _) ->
                false
	end,
    case locks_cycles:components(Nodes, Connect) of
	[] ->
	    ok;
	[Comp|_] ->
	    {ToSurrender, ToObject} = max_agent(Comp),
	    {deadlock, ToSurrender, ToObject}
    end.

expand_agents([{#w{entries = Es}, Id} | T]) ->
    expand_agents_(Es, Id, T);
expand_agents([{#r{entries = Es}, Id} | T]) ->
    expand_agents_(Es, Id, T);
expand_agents([]) ->
    [].

expand_agents_([#entry{agent = A}|T], Id, Tail) ->
    [{A, Id}|expand_agents_(T, Id, Tail)];
expand_agents_([], _, Tail) ->
    expand_agents(Tail). % return to higher-level recursion

in(A, #r{entries = Entries}) ->
    lists:keymember(A, #entry.agent, Entries);
in(A, #w{entries = Entries}) ->
    lists:keymember(A, #entry.agent, Entries).

in_tail(A, Tail) ->
    lists:any(fun(X) ->
                      in(A, X)
              end, Tail).

max_agent([{A, O}]) ->
    {A, O};
max_agent([{A1, O1}, {A2, _O2} | Rest]) when A1 > A2 ->
    max_agent([{A1, O1} | Rest]);
max_agent([{_A1, _O1}, {A2, O2} | Rest]) ->
    max_agent([{A2, O2} | Rest]).

add_msgs([H|T], Msgs) ->
    add_msgs(T, append_msg(H, Msgs));
add_msgs([], Msgs) ->
    Msgs.

append_msg(#locks_info{lock = #lock{object = O, version = V}} = I, Msgs) ->
    append(Msgs, O, V, I).

append([#locks_info{lock = #lock{object = O, version = V1}}|T] = L, O, V, I) ->
    if V > V1 ->
            [I|T];
       true ->
            L
    end;
append([H|T], O, V, I) ->
    [H|append(T, O, V, I)];
append([], _, _, I) ->
    [I].

