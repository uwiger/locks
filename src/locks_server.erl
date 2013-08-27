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
	 remove_agent/1, remove_agent/2]).

-export([start_link/0,
	 init/1,
	 handle_call/3,
	 handle_info/2,
	 handle_cast/2,
	 terminate/2,
	 code_change/3]).

-ifdef(TEST).
-define(dbg(Fmt, Args), io:fwrite(Fmt, Args)).
-else.
-define(dbg(F,A), ok).
-endif.

-include("locks.hrl").

-record(st, {tabs = {ets:new(locks, [public, ordered_set, {keypos, 2}]),
		     ets:new(agents, [public, bag])},
	     monitors = dict:new(),
	     notify_as = self()}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #st{}}.

lock(LockID, Mode) when Mode==read; Mode==write ->
    lock_(LockID, [node()], self(), Mode).

lock(LockID, Nodes, Mode) when is_list(LockID), is_list(Nodes), Mode==read;
			       is_list(LockID), is_list(Nodes), Mode==write ->
    lock_(LockID, Nodes, self(), Mode).

lock(LockID, Nodes, TID, Mode)
  when is_list(LockID), is_list(Nodes), Mode==read;
       is_list(LockID), is_list(Nodes), Mode==write ->
    lock_(LockID, Nodes, {self(), TID}, Mode).

lock_(LockID, Nodes, TID, Mode) when is_list(LockID), is_list(Nodes) ->
    Msg = {lock, LockID, TID, Mode},
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

handle_cast({lock, LockID, Agent, Mode}, #st{tabs = Tabs} = S) ->
    Updated = insert(LockID, Agent, Mode, Tabs),
    notify(Updated, S#st.notify_as),
    {noreply, monitor_agent(Agent, S)};
handle_cast({surrender, LockID, Agent}, #st{tabs = Tabs} = S) ->
    Updated = do_surrender(LockID, Agent, Tabs),
    notify(Updated, S#st.notify_as, {surrender, Agent}),
    {noreply, S};
handle_cast({remove_agent, Agent}, #st{tabs = Tabs} = S) ->
    Updated = do_remove_agent(Agent, Tabs),
    notify(Updated, S#st.notify_as),
    {noreply, demonitor_agent(Agent, S)};
handle_cast(_, S) ->
    {noreply, S}.

handle_info({lock, _, _, _} = Msg, #st{} = S) ->
    handle_cast(Msg, S);
handle_info({remove_agent, _} = Msg, S) ->
    handle_cast(Msg, S);
handle_info({'DOWN', _Ref, process, Pid, _}, #st{tabs = Tabs} = S) ->
    Updated = do_remove_agent(Pid, Tabs),
    notify(Updated, S#st.notify_as),
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

notify([#lock{queue = Q} = H|T], Me, Note) ->
    _ = [send(A, #locks_info{lock = H, note = Note})
	 || #entry{agent = A} <- queue_entries(Q)],
    notify(T, Me, Note);
notify([], _, _) ->
    ok.

send(Pid, Msg) when is_pid(Pid) ->
    Pid ! Msg.

queue_entries([#r{entries = Es}|Q]) ->
    Es ++ queue_entries(Q);
queue_entries([#w{entry = E}|Q]) ->
    [E|queue_entries(Q)];
queue_entries([]) ->
    [].


insert(ID, Tid, Mode, {Locks, Tids})
  when is_list(ID), Mode==read; Mode==write ->
    Related = related_locks(ID, Locks),
    NewVsn = new_vsn(Related),
    {Check, Result} = insert_agent(Related, ID, Tid, Mode, NewVsn),
    ets:insert(Tids, [{Tid,ID1} || #lock{object = ID1} <- Result]),
    check_tids(Check, ID, Tid, Result, Tids),
    ets:insert(Locks, Result),
    Result.

check_tids(false, _, _, _, _) ->
    false;
check_tids(true, ID, Tid, Result, Tids) ->
    #lock{queue = Q} = lists:keyfind(ID, #lock.object, Result),
    ets:insert(Tids, [{T, ID} || #entry{agent = T} <- flatten_queue(Q),
				 T =/= Tid]).

flatten_queue(Q) ->
    flatten_queue(Q, []).

%% NOTE! This function doesn't preserve order;
%% it returns a flat list of #entry{} records from the queue.
flatten_queue([#r{entries = Es}|Q], Acc) ->
    flatten_queue(Q, Es ++ Acc);
flatten_queue([#w{entry = E}|Q], Acc) ->
    flatten_queue(Q, [E|Acc]);
flatten_queue([], Acc) ->
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

has_lock([#w{entry = #entry{agent = A1}}|_], A) ->
    A1 =:= A;
has_lock([#r{entries = Es}|_], A) ->
    lists:keymember(A, #entry.agent, Es).

move_to_last([#w{entry = #entry{agent = A} = E}|T], A, V) ->
    T ++ [#w{entry = E#entry{version = V}}];
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
	[#lock{version = V, queue = Q} = L] ->
	    Q1 = lists:foldr(
		   fun(#r{entries = [#entry{agent = Ax}]}, Acc1) when Ax == A ->
			   Acc1;
		      (#r{entries = Es}, Acc1) ->
			   [#r{entries = lists:keydelete(A, #entry.agent, Es)}
			    | Acc1];
		      (#w{entry = #entry{agent = Ax}}, Acc1) when Ax == A ->
			   Acc1;
		      (E, Acc1) ->
			   [E|Acc1]
		   end, [], Q),
	    if Q1 == [] ->
		    ets:delete(Locks, ID);
	       true ->
		    ok
	    end,
	    do_remove_agent_(T, Locks, [L#lock{version = V+1, queue = Q1}|Acc])
    end;
do_remove_agent_([], Locks, Acc) ->
    ets:insert(Locks, [L || #lock{queue = Q} = L <- Acc, Q =/= []]),
    Acc.

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


insert_agent([], ID, A, Mode, Vsn) ->
    %% No related locks; easy case.
    Entry = #entry{agent = A, version = Vsn},
    Q  = case Mode of
	     read -> [#r{entries = [Entry]}];
	     write -> [#w{entry = Entry}]
	 end,
    L = #lock{object = ID, version = Vsn, queue = Q},
    {false, [L]};
insert_agent([_|_] = Related, ID, A, Mode, Vsn) ->
    %% Append entry to existing locks. Main challenge is merging child lock
    %% queues.
    Entry = #entry{agent = A,
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
		    {false, []}
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
in_queue_(#w{entry = #entry{agent = A1}}, A, M) when M==read; M==write ->
    A == A1;
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
    [#w{entry = Entry}];
into_queue(write, [#r{entries = [Er]} = H], Entry) ->
    if Entry#entry.agent == Er#entry.agent ->
	    %% upgrade to write lock
	    [#w{entry = Entry}];
       true ->
	    [H, #w{entry = Entry}]
    end;
into_queue(write, [#r{entries = Es} = H|T], #entry{agent = A} = Entry) ->
    H1 = case lists:keymember(A, #entry.agent, Es) of
	     true -> H#r{entries = lists:keydelete(A, #entry.agent, Es)};
	     false -> H
	 end,
    [H1 | into_queue(write, T, Entry)];
into_queue(Type, [H|T] = Q, Entry) ->
    case in_queue_(H, Entry#entry.agent, Type) of
	false ->
	    [H|into_queue(Type, T, Entry)];
	true ->
	    Q
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

set_indirect(#w{entry = #entry{} = E} = W) ->
    W#w{entry = E#entry{type = indirect}};
set_indirect(#r{entries = Es} = R) ->
    R#r{entries = [E#entry{type = indirect} || E <- Es]}.

sort_insert(#w{entry = #entry{agent = A, version = Vsn}},
	    [#w{entry = #entry{agent = A, version = Vsn2} = E} = W | T]) ->
    [W#w{entry = E#entry{version = erlang:max(Vsn, Vsn2)}} | T];
sort_insert(#r{entries = Esa},
	    [#r{entries = Esb} = R | T]) ->
    [R#r{entries = sort_insert_entries(Esa, Esb)} | T];
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

%% ===================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

lock_test_() ->
    {setup,
     fun() ->
	     application:start(locks)
     end,
     fun(_) ->
	     application:stop(locks)
     end,
     [
      fun() -> simple_lock() end,
      fun() -> simple_upgrade() end
     ]}.

simple_lock() ->
    Msgs1 = req(lock, [<<"a">>, <<"1">>], write),
    [#locks_info{lock = #lock{object = [<<"a">>, <<"1">>]}}] = Msgs1,
    ?dbg("~p - msgs: ~p~n", [?LINE, Msgs1]),
    Msgs2 = req(lock, [<<"a">>, <<"1">>, <<"x">>], read),
    ?dbg("~p - msgs: ~p~n", [?LINE, Msgs2]),
    Msgs3 = req(lock, [<<"a">>], read),
    ?dbg("~p - msgs: ~p~n", [?LINE, Msgs3]),
    remove_agent([node()]),
    ok.

simple_upgrade() ->
    Msgs1 = req(lock, [<<"a">>, <<"1">>], read),
    ?dbg("~p - msgs: ~p~n", [?LINE, Msgs1]),
    Msgs2 = req(lock, [<<"a">>, <<"1">>, <<"x">>], write),
    ?dbg("~p - msgs: = ~p~n", [?LINE, Msgs2]),
    Msgs3 = req(lock, [<<"a">>], read),
    ?dbg("~p - msgs: ~p~n", [?LINE, Msgs3]),
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
