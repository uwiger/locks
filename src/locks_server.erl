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
	 surrender/2, surrender/3,
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

-define(event(E), event(?LINE, E, none)).
-define(event(E, S), event(?LINE, E, S)).

-include("locks.hrl").

-define(LOCKS, locks_server_locks).
-define(AGENTS, locks_server_agents).

-record(st, {tabs = {ets:new(?LOCKS, [public, named_table,
                                      ordered_set, {keypos, 2}]),
		     ets:new(?AGENTS, [public, named_table, bag])},
	     monitors = dict:new(),
	     notify_as = self()}).

record_fields(st) ->
    record_info(fields, st);
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
    case ets:lookup(?LOCKS, LockID) of
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

surrender(LockID, Node) ->
    surrender_(LockID, Node, self()).

surrender(LockID, Node, TID) ->
    surrender_(LockID, Node, {self(), TID}).

surrender_(LockID, Node, Agent) ->
    cast({?LOCKER, Node}, {surrender, LockID, Agent}).

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
handle_cast({surrender, LockID, Agent} = _Msg, #st{tabs = Tabs} = S) ->
    ?event({handle_cast, _Msg}),
    Updated = do_surrender(LockID, Agent, Tabs),
    notify(Updated, S#st.notify_as, {surrender, Agent}),
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

notify(Locks, Me) ->
    notify(Locks, Me, []).

notify([#lock{queue = Q, watchers = W} = H|T], Me, Note) ->
    ?event({notify, Q, W}),
    Msg = #locks_info{lock = H, note = Note},
    _ = [send(A, Msg) || #entry{agent = A} <- queue_entries(Q)],
    _ = [send(P, Msg) || P <- W],
    notify(T, Me, Note);
notify([], _, _) ->
    ok.

send(Pid, Msg) when is_pid(Pid) ->
    ?event({send, Pid, Msg}),
    Pid ! Msg;
send({Agent,_} = _A, Msg) when is_pid(Agent) ->
    ?event({send, Agent, Msg}),
    Agent ! Msg.

queue_entries(Q) ->
    Res = queue_entries_(Q),
    ?event({queue_entries, Q, Res}),
    Res.

queue_entries_([#r{entries = Es}|Q]) ->
    Es ++ queue_entries_(Q);
queue_entries_([#w{entries = Es}|Q]) ->
    Es ++ queue_entries_(Q);
queue_entries_([]) ->
    [].

insert(ID, Agent, Client, Mode, {Locks, Tids})
  when is_list(ID), Mode==read; Mode==write ->
    Related = related_locks(ID, Locks),
    NewVsn = new_vsn(Related),
    {Check, Result} = insert_agent(Related, ID, Agent, Client, Mode, NewVsn),
    ?event({insert_agent, ID, Agent, {Check, Result}}),
    ets:insert(Tids, [{Agent,ID1} || #lock{object = ID1} <- Result]),
    check_tids(Check, ID, Agent, Result, Tids),
    ets:insert(Locks, Result),
    Result.

insert_watcher(ID, Pid, {Locks, Tids}) ->
    case ets:lookup(Locks, ID) of
	[#lock{queue = Q, watchers = Ws} = L] ->
	    L1 = L#lock{watchers = [Pid | Ws -- [Pid]]},
	    if Q == [] -> ok;
	       true ->
                    %% send first notification if lock held
                    Pid ! #locks_info{lock = ID}
	    end,
	    ets:insert(Locks, L1);
	[] ->
	    ets:insert(Locks, #lock{object = ID, watchers = [Pid]})
    end,
    ets:insert(Tids, {Pid, ID}).

delete_watcher(ID, Pid, {Locks, Tids}) ->
    case ets:lookup(Locks, ID) of
	[#lock{watchers = Ws} = L] ->
	    ets:insert(Locks, L#lock{watchers = Ws -- [Pid]}),
	    ets:delete_object(Tids, {Pid, ID});
	[] ->
	    ok
    end.

check_tids(false, _, _, _, _) ->
    false;
check_tids(true, ID, Agent, Result, Tids) ->
    #lock{queue = Q} = lists:keyfind(ID, #lock.object, Result),
    ets:insert(Tids, [{A, ID} ||
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
    case ets:lookup(?LOCKS, LockID) of
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


do_surrender(ID, Tid, {Locks, _Tids}) ->
    Related = related_locks(ID, Locks),
    Surrender = [L || L <- Related,
		      has_lock(L#lock.queue, Tid)],
    Updated =
	lists:map(
	  fun(#lock{queue = Q, version = V} = L) ->
		  V1 = V+1,
		  Q1 = move_to_last(Q, Tid, V),
		  L#lock{version = V1, queue = Q1}
	  end, Surrender),
    ets:insert(Locks, Updated),
    Updated.

has_lock([#w{entries = [#entry{agent = A1}]}|_], A) ->
    A1 =:= A;
has_lock([#r{entries = Es}|_], A) ->
    lists:keymember(A, #entry.agent, Es);
has_lock(_, _) ->
    false.


move_to_last([#w{entries = [#entry{agent = A} = E]}|T], A, V) ->
    T ++ [#w{entries = [E#entry{version = V}]}];
move_to_last([#r{entries = [#entry{agent = A} = E]}|T], A, V) ->
    append_read_entry(T, E#entry{version = V});
move_to_last([#r{entries = Es} = R | T], A, V) ->
    #entry{} = E = lists:keyfind(A, #entry.agent, Es),
    append_read_entry([R#r{entries = lists:keydelete(A, #entry.agent, Es)}|T],
		      E#entry{version = V}).

append_read_entry([#r{entries = Es} = R], E) ->
    [R#r{entries = [E|Es]}];
append_read_entry([#w{} = W], E) ->
    [W, E];
append_read_entry([H|T], E) ->
    [H | append_read_entry(T, E)];
append_read_entry([], E) ->
    [E].


do_remove_agent(A, {Locks, Agents}) ->
    case ets:lookup(Agents, A) of
	[] -> [];
	Found ->
            ?event([{removing_agent, A}, {found, Found}]),
	    ets:delete(Agents, A),
	    do_remove_agent_(Found, Locks, [])
    end.

monitor_agent(A, #st{monitors = Mons} = S) when is_pid(A) ->
    case dict:find(A, Mons) of
	{ok, _} ->
	    S;
	error ->
	    Ref = erlang:monitor(process, A),
	    S#st{monitors = dict:store(A, Ref, Mons)}
    end.

demonitor_agent(A, #st{monitors = Mons} = S) when is_pid(A) ->
    case dict:find(A, Mons) of
	{ok, Ref} ->
	    erlang:demonitor(Ref),
	    S#st{monitors = dict:erase(A, Mons)};
	error ->
	    S
    end.


do_remove_agent_([{A, ID}|T], Locks, Acc) ->
    case ets:lookup(Locks, ID) of
	[] ->
	    do_remove_agent_(T, Locks, Acc);
	[#lock{version = V, queue = Q, watchers = Ws} = L] ->
	    Q1 = trivial_lock_upgrade(
                   lists:foldr(
                     fun(#r{entries = [#entry{agent = Ax}]}, Acc1) when Ax == A ->
                             Acc1;
                        (#r{entries = Es}, Acc1) ->
                             case lists:keydelete(A, #entry.agent, Es) of
                                 [] -> Acc1;
                                 Es1 ->
                                     [#r{entries = Es1} | Acc1]
                             end;
                        (#w{entries = Es}, Acc1) ->
                             case lists:keydelete(A, #entry.agent, Es) of
                                 [] -> Acc1;
                                 Es1 ->
                                     [#w{entries = Es1} | Acc1]
                             end;
                        (E, Acc1) ->
                             [E|Acc1]
                     end, [], Q)),
            if Q1 == [], Ws == [] ->
                    ets:delete(Locks, ID);
               true ->
                    ok
            end,
	    do_remove_agent_(T, Locks, [L#lock{version = V+1, queue = Q1,
					       watchers = Ws -- [A]}|Acc])
    end;
do_remove_agent_([], Locks, Acc) ->
    ets:insert(Locks, [L || #lock{queue = Q,
				  watchers = Ws} = L <- Acc,
			    Q =/= [] orelse Ws =/= []]),
    Acc.

trivial_lock_upgrade([#r{entries = [#entry{agent = A}]} |
                      [#w{entries = [#entry{agent = A}]} | _] = T]) ->
    T;
trivial_lock_upgrade(Q) ->
    Q.


related_locks(ID, T) ->
    Pats = make_patterns(ID),
    ets:select(T, Pats).

make_patterns(ID) ->
    make_patterns(ID, []).

make_patterns([H|T], Acc) ->
    ID = Acc ++ [H],
    [{ #lock{object = ID, _ = '_'}, [], ['$_'] }
     | make_patterns(T, ID)];
make_patterns([], Acc) ->
    [{ #lock{object = Acc ++ '_', _ = '_'}, [], ['$_'] }].


new_vsn(Locks) ->
    Current =
	lists:foldl(
	  fun(#lock{version = V}, Acc) ->
		  erlang:max(V, Acc)
	  end, 0, Locks),
    Current + 1.


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

in_queue([H|T], A, Mode) ->
    case in_queue_(H, A, Mode) of
	false -> in_queue(T, A, Mode);
	true  -> true
    end;
in_queue([], _, _) ->
    false.

in_queue_(#r{entries = Entries}, A, read) ->
    lists:keymember(A, #entry.agent, Entries);
in_queue_(#w{entries = Es}, A, M) when M==read; M==write ->
    lists:keymember(A, #entry.agent, Es);
in_queue_(_, _, _) ->
    false.

into_queue(read, [#r{entries = Entries}] = Q, Entry) ->
    %% No pending write locks
    case lists:keymember(Entry#entry.agent, #entry.agent, Entries) of
	true -> Q;
	false ->
	    [#r{entries = [Entry|Entries]}]
    end;
into_queue(read,  [], Entry) ->
    [#r{entries = [Entry]}];
into_queue(write, [], Entry) ->
    [#w{entries = [Entry]}];
into_queue(write, [#r{entries = [Er]} = H], Entry) ->
    if Entry#entry.agent == Er#entry.agent ->
	    %% upgrade to write lock
	    [#w{entries = [Entry]}];
       true ->
	    [H, #w{entries = [Entry]}]
    end;
into_queue(write, [#w{entries = [#entry{agent = A}]}],
           #entry{agent = A, type = direct} = Entry) ->
    %% Refresh and ensure it's a direct lock
    [#w{entries = [Entry]}];
into_queue(Type, [H|T], #entry{agent = A, type = direct} = Entry) ->
    case H of
        #w{entries = Es} when Type == write; Type == read ->
            %% If a matching entry exists, we set to new version and
            %% set type to direct. This means we might get a direct write
            %% lock even though we asked for a read lock.
            maybe_refresh(Es, H, T, Type, A, Entry);
        #r{entries = Es} when Type == read ->
            maybe_refresh(Es, H, T, Type, A, Entry);
        _ ->
            [H | into_queue(Type, T, Entry)]
    end;
into_queue(Type, [H|T] = Q, Entry) ->
    case in_queue_(H, Entry#entry.agent, Type) of
	false ->
	    [H|into_queue(Type, T, Entry)];
	true ->
	    Q
    end.

maybe_refresh(Es, H, T, Type, A, Entry) ->
    case lists:keyfind(A, #entry.agent, Es) of
        #entry{} = E ->
            Es1 = lists:keyreplace(A, #entry.agent, Es,
                                   E#entry{type = Entry#entry.type,
                                           version = Entry#entry.version}),
            case H of
                #w{} -> [H#w{entries = Es1} | T];
                #r{} -> [H#r{entries = Es1} | T]
            end;
        false ->
            [H | into_queue(Type, T, Entry)]
    end.


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

%% set_indirect([#r{entries = Entries} = H|T]) ->
%%     [H#r{entries = [E#entry{type = indirect} || E <- Entries]}
%%      | set_indirect(T)];
%% set_indirect([#w{entry = E} = H|T]) ->
%%     [H#w{entry = E#entry{type = indirect}} | set_indirect(T)];
%% set_indirect([]) ->
%%     [].

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

split_related(Related, ID) ->
    case length(ID) of
	1 ->
	    case Related of
		[#lock{object = [_]} = Mine|Ch] -> {[], Mine, Ch};
		Ch -> {[], [], Ch}
	    end;
	2 -> split2(Related, ID);
	3 -> split3(Related, ID);
	4 -> split4(Related, ID);
	L -> split(Related, L, ID)
    end.

%%% =====

%% Generic split, will call length/1 on each ID
split(Locks, Len, ID) ->
    {Parents, Locks1} = split_ps(Locks, Len, []),
    split_(Locks1, ID, Parents).

split_ps([#lock{object = I}=H|T], Len, Acc) when length(I) < Len ->
    split_ps(T, Len, [H|Acc]);
split_ps(L, _, Acc) ->
    {lists:reverse(Acc), L}.

split_([#lock{object = ID} = Mine|Ch], ID, Parents) ->
    {Parents, Mine, Ch};
split_(Ch, ID, Parents) ->
    {Parents, #lock{object = ID}, Ch}.

%% Optimized split for ID length 2
split2([#lock{object = [_]} = H|T], ID) -> split2(T, [H], ID);
split2(L, ID) -> split2(L, [], ID).

split2([#lock{object = ID} = Mine|Ch], Ps, ID) -> {Ps, Mine, Ch};
split2(Ch, Ps, _ID) -> {Ps, [], Ch}.

%% Optimized split for ID length 3
split3(L, ID) ->
    case L of
	[#lock{object = [_]} = P1, #lock{object = [_,_]} = P2|T] ->
	    split3(T, [P1,P2], ID);
	[#lock{object = [_]} = P1|T] ->
	    split3(T, [P1], ID);
	[#lock{object = [_,_]} = P2|T] ->
	    split3(T, [P2], ID);
	[#lock{object = ID} = Mine|T] ->
	    {[], Mine, T};
	[_|_] ->
	    {[], [], L}
    end.

split3([#lock{object = ID} = Mine|Ch], Ps, ID) -> {Ps, Mine, Ch};
split3(Ch, Ps, _ID) -> {Ps, [], Ch}.

split4(L, ID) ->
    {Ps, L1} = split4_ps(L, []),
    split4(L1, Ps, ID).

split4_ps([#lock{object = [_]} = H|T], Acc) -> split4_ps(T, [H|Acc]);
split4_ps([#lock{object = [_,_]} = H|T], Acc) -> split4_ps(T, [H|Acc]);
split4_ps([#lock{object = [_,_,_]} = H|T], Acc) -> split4_ps(T, [H|Acc]);
split4_ps(L, Acc) -> {lists:reverse(Acc), L}.

split4([#lock{object = [_,_,_,_]} = Mine|Ch], Ps, _) -> {Ps, Mine, Ch};
split4(Ch, Ps, _ID) -> {Ps, [], Ch}.

event(_Line, _Msg, _St) ->
    ok.

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
