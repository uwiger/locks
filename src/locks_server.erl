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
-module(locks_server).
-behavior(gen_server).

-export([lock/2, lock/3, lock/4,
	 surrender/3, surrender/4,
	 watch/2, unwatch/2,
	 remove_agent/1, remove_agent/2]).

-export([clients/1,
         agents/1,
         watchers/1]).

-export([start_link/0,
	 init/1,
	 handle_call/3,
	 handle_info/2,
	 handle_cast/2,
	 terminate/2,
	 code_change/3]).

-export([record_fields/1]).

-include("locks.hrl").
-include("locks_server.hrl").

record_fields(st) ->
    record_info(fields, st);
record_fields(surr) ->
    record_info(fields, surr);
record_fields(_) ->
    no.


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    catch locks_watcher ! locks_running,
    {ok, #st{}}.

clients(LockID) ->
    fold_lock_queue(fun(#entry{client = C}, Acc) ->
                            [C|Acc]
                    end, [], LockID).
agents(LockID) ->
    fold_lock_queue(fun(#entry{agent = A}, Acc) ->
                            [A|Acc]
                    end, [], LockID).

watchers(LockID) ->
    case ets_lookup(?LOCKS, LockID) of
        [#lock{watchers = Ws}] ->
            Ws;
        [] ->
            []
    end.

lock(LockID, Mode) when Mode==read; Mode==write ->
    lock_(LockID, [node()], self(),self(), Mode).

lock(LockID, Nodes, Mode) when is_list(LockID), is_list(Nodes), Mode==read;
			       is_list(LockID), is_list(Nodes), Mode==write ->
    lock_(LockID, Nodes, self(), self(), Mode).

lock(LockID, Nodes, Client, Mode)
  when is_list(LockID), is_list(Nodes), is_pid(Client), Mode==read;
       is_list(LockID), is_list(Nodes), is_pid(Client), Mode==write ->
    lock_(LockID, Nodes, self(), Client, Mode).

lock_(LockID, Nodes, Agent, Client, Mode)
  when is_list(LockID), is_list(Nodes), is_pid(Client) ->
    Msg = {lock, LockID, Agent, Client, Mode},
    _ = [cast({?LOCKER, N}, Msg) || N <- Nodes],
    ok.

watch(LockID, Nodes) ->
    Msg = {watch, LockID, self()},
    _ = [cast({?LOCKER, N}, Msg) || N <- Nodes],
    ok.

unwatch(LockID, Nodes) ->
    Msg = {unwatch, LockID, self()},
    _ = [cast({?LOCKER, N}, Msg) || N <- Nodes],
    ok.

surrender(LockID, Node, Vsn) ->
    surrender_(LockID, Node, Vsn, self()).

surrender(LockID, Node, Vsn, TID) ->
    surrender_(LockID, Node, Vsn, {self(), TID}).

surrender_(LockID, Node, Vsn, Agent) ->
    cast({?LOCKER, Node}, {surrender, LockID, Vsn, Agent}).

remove_agent(Nodes) when is_list(Nodes) ->
    [cast({?LOCKER, N}, {remove_agent, self()}) || N <- Nodes],
    ok.

remove_agent(Nodes, Agent) when is_list(Nodes) ->
    [cast({?LOCKER, N}, {remove_agent, {self(), Agent}}) || N <- Nodes],
    ok.

cast({Name, Node} = P, Msg) when is_atom(Name), is_atom(Node) ->
    gen_server:cast(P, Msg).

%% ==== Server callbacks =====================================

handle_call(_Req, _From, S) ->
    {reply, {error, unknown_request}, S}.

handle_cast({lock, LockID, Agent, Client, Mode} = _Msg, #st{tabs = Tabs} = S) ->
    ?event({handle_cast, _Msg}),
    Updated = insert(LockID, Agent, Client, Mode, Tabs),
    ?event({updated, Updated}),
    notify(Updated, S#st.notify_as),
    {noreply, monitor_agent(Agent, S)};
handle_cast({surrender, LockID, Vsn, Agent} = _Msg, #st{tabs = Tabs} = S) ->
    ?event({handle_cast, _Msg}),
    Updated = do_surrender(LockID, Vsn, Agent, Tabs),
    ?event({updated, Updated}),
    notify(Updated, S#st.notify_as, {surrender, Agent, Vsn}),
    {noreply, S};
handle_cast({remove_agent, Agent} = _Msg, #st{tabs = Tabs} = S) ->
    ?event({handle_cast, _Msg}),
    Updated = do_remove_agent(Agent, Tabs),
    ?event([{agent_removed, Agent}, {updated, Updated}]),
    notify(Updated, S#st.notify_as),
    ?event(notify_done),
    {noreply, demonitor_agent(Agent, S)};
handle_cast({watch, LockID, Pid} = _Msg, #st{tabs = Tabs} = S) ->
    ?event({handle_cast, _Msg}),
    insert_watcher(LockID, Pid, Tabs),
    {noreply, monitor_agent(Pid, S)};
handle_cast({unwatch, LockID, Pid} = _Msg, #st{tabs = Tabs} = S) ->
    ?event({handle_cast, _Msg}),
    delete_watcher(LockID, Pid, Tabs),
    {noreply, S};
handle_cast(_Msg, S) ->
    ?event({unknown_cast, _Msg}),
    {noreply, S}.

handle_info({lock, _, _, _} = Msg, #st{} = S) ->
    ?event({handle_info, Msg}),
    handle_cast(Msg, S);
handle_info({remove_agent, _} = Msg, S) ->
    ?event({handle_info, Msg}),
    handle_cast(Msg, S);
handle_info({'DOWN', _Ref, process, Pid, _} = _Msg, #st{tabs = Tabs} = S) ->
    ?event({handle_info, _Msg}),
    Updated = do_remove_agent(Pid, Tabs),
    ?event({updated, Pid, Updated}),
    notify(Updated, S#st.notify_as),
    ?event(notify_done),
    {noreply, demonitor_agent(Pid, S)};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _) ->
    ok.

code_change(_FromVsn, S, _Extra) ->
    {ok, S}.

%% ==== End Server callbacks =================================

notify(Locks, As) ->
    locks_server_lib:notify(Locks, As, []).

notify(Locks, As, Note) ->
    locks_server_lib:notify(Locks, As, Note).

insert(ID, Agent, Client, Mode, {Locks, Tids, Admin})
  when is_list(ID), Mode==read; Mode==write ->
    Related = related_locks(ID, Locks),
    NewVsn = new_vsn(Admin),
    {Check, Result} = insert_agent(Related, ID, Agent, Client, Mode, NewVsn),
    ?event({insert_agent, ID, Agent, {Check, Result}}),
    ets_insert(Tids, [{{Agent,ID1}} || #lock{object = ID1} <- Result]),
    check_tids(Check, ID, Agent, Result, Tids),
    ets_insert(Locks, Result),
    Result.

insert_watcher(ID, Pid, {Locks, Tids, _Admin}) ->
    case ets_lookup(Locks, ID) of
	[#lock{queue = Q, watchers = Ws} = L] ->
	    L1 = L#lock{watchers = [Pid | Ws -- [Pid]]},
	    if Q == [] -> ok;
	       true ->
                    %% send first notification if lock held
                    Pid ! #locks_info{lock = ID}
	    end,
	    ets_insert(Locks, L1);
	[] ->
	    ets_insert(Locks, #lock{object = ID, watchers = [Pid]})
    end,
    ets_insert(Tids, {{Pid, ID}}).

delete_watcher(ID, Pid, {Locks, Tids, _Admin}) ->
    case ets_lookup(Locks, ID) of
	[#lock{watchers = Ws} = L] ->
	    ets_insert(Locks, L#lock{watchers = Ws -- [Pid]}),
	    ets_delete(Tids, {Pid, ID});
	[] ->
	    ok
    end.

check_tids(false, _, _, _, _) ->
    false;
check_tids(true, ID, Agent, Result, Tids) ->
    #lock{queue = Q} = lists:keyfind(ID, #lock.object, Result),
    ets_insert(Tids, [{{A, ID}} ||
                         #entry{agent = A, type = Type} <- flatten_queue(Q),
                         A =/= Agent orelse Type == indirect]).

flatten_queue(Q) ->
    flatten_queue(Q, []).

%% NOTE! This function doesn't preserve order;
%% it returns a flat list of #entry{} records from the queue.
flatten_queue([#r{entries = Es}|Q], Acc) ->
    flatten_queue(Q, Es ++ Acc);
flatten_queue([#w{entries = Es}|Q], Acc) ->
    flatten_queue(Q, Es ++ Acc);
flatten_queue([], Acc) ->
    Acc.

%% Fold over the queue of LockID, if such a lock exists; otherwise -> [].
%% Order is not guaranteed to represent wait order.
fold_lock_queue(F, Acc, LockID) ->
    case ets_lookup(?LOCKS, LockID) of
        [] ->
            [];
        [#lock{queue = Q}] ->
            fold_queue(F, Acc, Q)
    end.

fold_queue(F, Acc, [#r{entries = Es}|Q]) ->
    fold_queue(F, lists:foldl(F, Acc, Es), Q);
fold_queue(F, Acc, [#w{entries = Es}|Q]) ->
    fold_queue(F, lists:foldl(F, Acc, Es), Q);
fold_queue(_, Acc, []) ->
    Acc.

%% Idea:
%% We must find the responsible direct lock and surrender it, as well as
%% all indirect locks that are a consequence of the direct lock
%% If one or more of the indirect locks could be a consequence of another
%% of our direct locks in the found set, also release that lock and all its
%% indirect locks. Then reapply the direct locks (they will end up last in
%% line, and relevant indirect locks will also be reapplied as a result.)
%% 1. Find related locks (parents and children); extend the found set if
%%    a parent lock entry for A is an indirect lock: then also include any
%%    other children, referenced by A, of that parent.
%% 2. Split into direct and indirect locks.
%% 3. Group direct locks with indirect locks that would be a result
%%    Each direct lock forms a group, represented as a list,
%%    [ DirectLock | IndirectLocks ].
%% 4. Select all groups that have the ID to surrender anywhere in the list
%%    (either as a direct or indirect lock).
%% 5. Remove agent A from all locks in the found groups.
%% 6. Re-apply the direct locks.
%% 7. Increment versions of updated locks.
do_surrender(ID, Vsn, A, {Locks, Agents, Admin}) ->
    case find_lock(Locks, ID) of
        {ok, #lock{version = Vsn}} ->
            do_surrender(related_locks(ID, A, Agents, Locks),
                         ID, A, Locks, Agents, Admin);
        Other ->
            ?event({lock_not_found_or_wrong_vsn, ID, Other}),
            []
    end.

do_surrender([], _, _, _, _, _) ->
    %% Found no locks matching the parameters
    [];
do_surrender([_|_] = Related, ID, A, Locks, Agents, Admin) ->
    ?event({related_locks, Related}),
    Groups = group_related(Related, A),
    AffectedGroups = affected_groups(Groups, ID),  % list of lists
    Reapply = [hd(G) || G <- AffectedGroups],
    AllLocks = lists:ukeysort(#surr.id, lists:append(AffectedGroups)),
    NewVsn = new_vsn(Admin),
    AllLocks1 =
        [remove_agent_from_lock(A, S#surr.lock, NewVsn) || S <- AllLocks],
    {Check, Updated} =
        lists:foldl(
          fun(#surr{id = L, mode = Mode, client = Client}, {Chk, Acc}) ->
                  {Check, Upd} =
                      insert_agent(Acc, L, A, Client, Mode, NewVsn),
                  {Check orelse Chk,
                   lists:foldl(fun(Lock, Acc2) ->
                                       lists:keyreplace(
                                         Lock#lock.object,
                                         #lock.object, Acc2, Lock)
                               end, Acc, Upd)}
          end, {false, AllLocks1}, Reapply),
    check_tids(Check, ID, A, Updated, Agents),
    _Updated1 = process_updated(Updated, A, Locks, Agents).

group_related(Locks, A) ->
    {Direct, Indirect} = split_direct_indirect(Locks, A),
    group_indirects(Direct, Indirect).

split_direct_indirect(Locks, A) ->
    split_direct_indirect(Locks, A, [], []).

split_direct_indirect([#lock{queue = Q} = H|T], A, D, I) ->
    case find_first_entry(Q, A) of
        {Mode, #entry{type = direct, version = V, client = Client}} ->
            split_direct_indirect(T, A, [#surr{id = H#lock.object,
                                               mode = Mode,
                                               type = direct,
                                               client = Client,
                                               vsn = V,
                                               lock = H}|D], I);
        {Mode, #entry{type = indirect, version = V, client = Client}} ->
            split_direct_indirect(T, A, D, [#surr{id = H#lock.object,
                                                  mode = Mode,
                                                  type = indirect,
                                                  client = Client,
                                                  vsn = V,
                                                  lock = H}|I])
    end;
split_direct_indirect([], _, D, I) ->
    {lists:reverse(D), lists:reverse(I)}.

find_first_entry([H|T], A) ->
    {Mode, Entries} = case H of
                          #w{entries = Es} -> {write, Es};
                          #r{entries = Es} -> {read, Es}
                      end,
    case lists:keyfind(A, #entry.agent, Entries) of
        #entry{} = E ->
            {Mode, E};
        false ->
            find_first_entry(T, A)
    end.

group_indirects(Direct, Indirect) ->
    [[S | lists:filter(fun(#surr{id = Id1}) ->
                               lists:prefix(S#surr.id, Id1)
                                   orelse
                                   lists:prefix(Id1, S#surr.id)
                       end, Indirect)]
     || S <- Direct].

affected_groups(Groups, ID) ->
    [G || G <- Groups,
          lists:keymember(ID, #surr.id, G)].

process_updated([#lock{object = ID,
                       queue = [],
                       watchers = Ws} = H|T], A, Locks, Agents) ->
    ets_delete(Agents, {A, ID}),
    if Ws =:= [] ->
            ets_delete(Locks, ID),
            process_updated(T, A, Locks, Agents);
       true ->
            ets_insert(Locks, H),
            [H | process_updated(T, A, Locks, Agents)]
    end;
process_updated([H|T], A, Locks, Agents) ->
    ets:insert(Locks, H),
    [H | process_updated(T, A, Locks, Agents)];
process_updated([], _, _, _) ->
    [].

do_remove_agent(A, Tabs) ->
    locks_server_lib:remove_agent(A, Tabs).

monitor_agent(A, #st{monitors = Mons} = S) when is_pid(A) ->
    case maps:is_key(A, Mons) of
        true ->
	    S;
        false ->
	    Ref = erlang:monitor(process, A),
	    S#st{monitors = Mons#{A => Ref}}
    end.

demonitor_agent(A, #st{monitors = Mons} = S) when is_pid(A) ->
    case maps:find(A, Mons) of
	{ok, Ref} ->
	    erlang:demonitor(Ref),
	    S#st{monitors = maps:remove(A, Mons)};
	error ->
	    S
    end.

remove_agent_from_lock(Agent, Lock, NewVsn) ->
    locks_server_lib:remove_agent_from_lock(Agent, Lock, NewVsn).

related_locks(ID, A, Agents, Locks) ->
    Pats = agent_patterns(ID, A, []),
    IDs = ets_select(Agents, Pats),
    get_locks(IDs, A, ID, IDs, Agents, Locks).

get_locks([ID|T], _A, ID, _Vis, _Agents, Locks) ->
    %% All following should be children of ID
    [get_lock(Locks, ID) | [get_lock(Locks, L) || L <- T]];
get_locks([H|T], A, ID, Vis, Agents, Locks) ->
    #lock{queue = Q} = L = get_lock(Locks, H),
    case find_first_entry(Q, A) of
        {_Mode, #entry{type = indirect}} ->
            %% Must include possible direct-lock children that were not
            %% in the original set (since they intersect in indirect-lock
            %% parents). Don't fetch any lock twice.
            Pat = [{ {{A, H ++ '_'}}, [], [{element,2,{element,1,'$_'}}]}],
            Extra = [I || I <- ets_select(Agents, Pat),
                          not lists:member(I, Vis)],
            [L | [get_lock(Locks, X) || X <- Extra]]
                ++ get_locks(T, A, ID, Extra ++ Vis, Agents, Locks);
        _ ->
            [L|get_locks(T, A, ID, Vis, Agents, Locks)]
    end;
get_locks([], _, _, _, _, _) ->
    [].

agent_patterns([H|T], Tid, Acc) ->
    Id = Acc ++ [H],
    [{ {{Tid, Id}}, [], [{element, 2, {element, 1, '$_'}}] }
     | agent_patterns(T, Tid, Id)];
agent_patterns([], Tid, Acc) ->
    [{ {{Tid, Acc ++ '_'}}, [], [{element, 2, {element, 1, '$_'}}] }].

get_lock(T, Id) ->
    [L] = ets_lookup(T, Id),
    L.

find_lock(T, Id) ->
    case ets_lookup(T, Id) of
        [] ->
            error;
        [L] ->
            {ok, L}
    end.

related_locks(ID, T) ->
    locks_server_lib:related_locks(ID, T).

new_vsn(Tab) ->
    locks_server_lib:new_vsn(Tab).

insert_agent([], ID, A, Client, Mode, Vsn) ->
    %% No related locks; easy case.
    Entry = #entry{agent = A, client = Client, version = Vsn},
    Q  = case Mode of
	     read -> [#r{entries = [Entry]}];
	     write -> [#w{entries = [Entry]}]
	 end,
    L = #lock{object = ID, version = Vsn, queue = Q},
    {false, [L]};
insert_agent([_|_] = Related, ID, A, Client, Mode, Vsn) ->
    %% Append entry to existing locks. Main challenge is merging child lock
    %% queues.
    Entry = #entry{agent = A,
                   client = Client,
		   version = Vsn,
		   type = indirect},
    case split_related(Related, ID) of
	{[], [], [_|_] = Children} ->
	    %% Collect child lock queues
	    {Children1, Queue} = update_children(Children, Entry, Mode, Vsn),
	    {true, [#lock{object = ID, version = Vsn,
			  queue = into_queue(
				    Mode, Queue, Entry#entry{type = direct})}
		    | Children1]};
	{[_|_] = Parents, [], Children} ->
	    {Parents1, Queue} = update_parents(Parents, Entry, Mode, Vsn),
	    Children1 = append_entry(Children, Entry, Mode, Vsn),
	    {true, Parents1 ++ [#lock{object = ID, version = Vsn,
				      queue = into_queue(
						Mode, Queue,
						Entry#entry{type = direct})}
				| Children1]};
	{Parents, #lock{queue = Queue} = Mine, Children} ->
	    case in_queue(Queue, A, Mode) of
		false ->
		    Parents1 = append_entry(Parents, Entry, Mode, Vsn),
		    Children1 = append_entry(Children, Entry, Mode, Vsn),
		    {false, Parents1 ++
			 [Mine#lock{version = Vsn,
				    queue =
					into_queue(
					  Mode, Queue,
					  Entry#entry{type = direct})}
			  | Children1]};
		true ->
                    %% We may still need to refresh. Assume that the agent
                    %% requires an update (very true on lock upgrade)
		    {false, [Mine#lock{version = Vsn,
                                       queue =
                                           into_queue(
                                             Mode, Queue,
                                             Entry#entry{type = direct})}]}
	    end
    end.

in_queue(Q, A, Mode) ->
    locks_server_lib:in_queue(Q, A, Mode).

into_queue(Mode, Q, Entry) ->
    locks_server_lib:into_queue(Mode, Q, Entry).

append_entry([#lock{queue = Q} = H|T], Entry, Mode, Vsn) ->
    [H#lock{version = Vsn, queue = into_queue(Mode, Q, Entry)}
     | append_entry(T, Entry, Mode, Vsn)];
append_entry([], _, _, _) ->
    [].

update_parents(Locks, Entry, Mode, Vsn) ->
    update_parents(Locks, Entry, Mode, Vsn, []).

%% The nearest parent's queue is reused for our own lock (and we just append
%% our own entry with type = direct).
%%
update_parents([#lock{queue = Q} = H|T], Entry, Mode, Vsn, Acc) ->
    Acc1 = [H#lock{version = Vsn, queue = into_queue(Mode, Q, Entry)}|Acc],
    if T == [] -> {lists:reverse(Acc1), [set_indirect(E) || E <- Q]};
       true    -> update_parents(T, Entry, Mode, Vsn, Acc1)
    end.

update_children(Children, Entry, Mode, Vsn) ->
    update_children(Children, Entry, Mode, Vsn, [], []).

update_children([#lock{queue = Q} = H | T], Entry, Mode, Vsn, Acc, QAcc) ->
    QAcc1 = merge_queue(Q, QAcc),
    ?event({merge_queue, Q, QAcc, QAcc1}),
    Acc1 = [H#lock{version = Vsn,
		   queue = into_queue(Mode, Q, Entry)} | Acc],
    if T == [] ->
	    {lists:reverse(Acc1), QAcc1};
       true ->
	    update_children(T, Entry, Mode, Vsn, Acc1, QAcc1)
    end.

merge_queue([H|T], Q) ->
    merge_queue(T, sort_insert(set_indirect(H), Q));
merge_queue([], Q) ->
    Q.

set_indirect(#w{entries = Es} = W) ->
    W#w{entries = [E#entry{type = indirect} || E <- Es]};
set_indirect(#r{entries = Es} = R) ->
    R#r{entries = [E#entry{type = indirect} || E <- Es]}.

sort_insert(#w{entries = Esa}, [#w{entries =Esb} = W | T]) ->
    [W#w{entries = sort_insert_entries(Esa, Esb)} | T];
sort_insert(#r{entries = Esa}, [#r{entries = Esb} = R | T]) ->
    [R#r{entries = sort_insert_entries(Esa, Esb)} | T];
sort_insert(#r{entries = Esr} = R, [#w{entries = Esw} = W | T]) ->
    case upgrade_entries(Esr, Esw) of
        {[], Esw1} ->
            [W#w{entries = Esw1} | T];
        {Esr1, Esw1} ->
            [W#w{entries = Esw1} | sort_insert(R#r{entries = Esr1}, T)]
    end;
sort_insert(#w{entries = Esw} = W, [#r{entries = Esr} = R | T]) ->
    case upgrade_entries(Esr, Esw) of
        {[], Esw1} ->
            [W#w{entries = Esw1} | T];
        {Esr1, Esw1} ->
            [R#r{entries = Esr1} | sort_insert(W#w{entries = Esw1}, T)]
    end;
sort_insert(E, [H|T]) ->
    [H|sort_insert(E, T)];
sort_insert(E, []) ->
    [E].

sort_insert_entries([#entry{agent = A, version = Vsn} = En|T], Es) ->
    Es1 =
	case lists:keyfind(A, #entry.agent, Es) of
	    #entry{version = Vsn2} when Vsn2 >= Vsn -> Es;
	    #entry{} -> lists:keyreplace(A, #entry.agent, Es, En);
	    false ->
		[En|Es]
	end,
    sort_insert_entries(T, Es1);
sort_insert_entries([], Es) ->
    Es.

upgrade_entries(Esr, Esw) ->
    R = upgrade_entries(Esr, Esw, []),
    ?event({upgrade_entries, Esr, Esw, R}),
    R.

%% The order of the lists don't matter, so we don't reverse
upgrade_entries([], Esw, Accr) ->
    {Accr, Esw};
upgrade_entries([#entry{agent = A, version = Vsn} = E|Esr], Esw, Accr) ->
    case lists:keyfind(A, #entry.agent, Esw) of
        #entry{version = Vsn2} when Vsn2 >= Vsn ->
            upgrade_entries(Esr, Esw, Accr);
        #entry{} ->
            upgrade_entries(
              Esr, lists:keyreplace(A, #entry.agent, Esw, E), Accr);
        false ->
            upgrade_entries(Esr, Esw, [E|Accr])
    end.

split_related(Related, Id) ->
    locks_server_lib:split_related(Related, Id).

ets_insert(T, Data) -> ets:insert(T, Data).
ets_lookup(T, K)    -> ets:lookup(T, K).
ets_select(T, Pat)  -> ets:select(T, Pat).
ets_delete(T, K)    -> ets:delete(T, K).

%% ===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

lock_test_() ->
    {setup,
     fun() ->
	     ok = application:start(locks)
     end,
     fun(_) ->
	     ok = application:stop(locks)
     end,
     [
      fun() -> simple_lock() end,
      fun() -> simple_upgrade() end
     ]}.

simple_lock() ->
    L1 = [?MODULE, ?LINE],
    Msgs1 = req(lock, L1, write),
    [#locks_info{lock = #lock{object = L1}}] = Msgs1,
    ?event({msgs, Msgs1}),
    L2 = L1 ++ [x],
    _Msgs2 = req(lock, L2, read),
    ?event({msgs, _Msgs2}),
    L3 = [?MODULE],
    _Msgs3 = req(lock, L3, read),
    ?event({msgs, _Msgs3}),
    remove_agent([node()]),
    ok.

simple_upgrade() ->
    L1 = [?MODULE, ?LINE],
    _Msgs1 = req(lock, L1, read),
    ?event({msgs, _Msgs1}),
    L2 = L1 ++ [x],
    _Msgs2 = req(lock, L2, write),
    ?event({msgs, _Msgs2}),
    L3 = [?MODULE],
    _Msgs3 = req(lock, L3, read),
    ?event({msgs, _Msgs3}),
    ok.


req(lock, ID, Mode) ->
    lock(ID, Mode),
    timer:sleep(500),
    lists:sort(fun(#locks_info{lock = #lock{object = A}},
		   #locks_info{lock = #lock{object = B}}) ->
		       A =< B
	       end, recv_replies()).

recv_replies() ->
    receive
	#locks_info{} = Msg ->
	    [Msg | recv_replies()]
    after 0 ->
	    []
    end.

-endif.
