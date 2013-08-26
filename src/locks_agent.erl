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

-module(locks_agent).

-behaviour(gen_server).

-export([start_link/0, start_link/1, start/1]).
-export([begin_transaction/1,
	 begin_transaction/2,
         %%	 acquire_all_or_none/2,
	 lock/2, lock/3, lock/4, lock/5,
         lock_nowait/2, lock_nowait/3, lock_nowait/4, lock_nowait/5,
	 lock_objects/2,
	 await_all_locks/1,
	 lock_info/1,
         %%	 await_all_or_none/1,
	 end_transaction/1]).

%% gen_server callbacks
-export([
	 init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3
	]).

-import(lists,[foreach/2,any/2,map/2,member/2]).

-include("locks.hrl").

-define(dbg(Fmt, Args), io:fwrite(user, Fmt, Args)).

-type agent()    :: pid().
-type notify_type() :: await_all_locks
                       %%		     | await_all_or_none
		     | events.
-type lock_status() :: have_all_locks | have_none.
-type deadlocks()   :: [{agent(), oid()}].
-type lock_reply()  :: {lock_status(), deadlocks()}.
-type option()      :: {client, pid()}
                     | {abort_on_exit, boolean()}.

-record(req, {object,
              mode,
              nodes,
              require = all}).

-record(state, {
          locks = []     :: [#lock{}],
          requests = []  :: [#req{}],
          down = []      :: [node()],
          monitored = [] :: [{node(), reference()}],
          pending = []   :: [oid()],
          sync = []      :: [pid()],
          client         :: pid(),
          client_mref    :: reference(),
          options = []   :: [option()],
          abort_on_exit = true :: boolean(),
          notify = []    :: [{pid(), reference(), notify_type()}],
          answer         :: locking | waiting | done,
          deadlocks = [] :: deadlocks()
         }).

-define(myclient,State#state.client).

%%% interface function

start_link() ->
    start([{link, true}]).

start_link(Options) when is_list(Options) ->
    start(lists:keystore(link, 1, Options, {link, true})).

start(Options0) when is_list(Options0) ->
    Options =
	case lists:keymember(client, 1, Options0) of
	    true -> Options0;
	    false -> [{client, self()}|Options0]
	end,
    case proplists:get_value(link, Options, true) of
        true ->
            gen_server:start_link(?MODULE, Options, []);
        false ->
            gen_server:start(?MODULE, Options, [])
    end.

-spec begin_transaction([oid()
                         | {oid(), mode()}
                         | {oid(), mode(), where()}]) ->
                               {agent(), lock_reply()}.
begin_transaction(Objects) ->
    begin_transaction(Objects, []).

begin_transaction(Objects, Opts) ->
    {ok, Agent} = start(Opts),
    _ = lock_objects(Agent, Objects),
    {Agent, await_all_locks(Agent)}.


-spec await_all_locks(agent()) -> lock_reply().
await_all_locks(Agent) ->
    call(Agent, await_all_locks,infinity).

%% -spec await_all_or_none(agent()) -> lock_reply().
%% await_all_or_none(Agent) ->
%%     call(Agent, await_all_or_none, infinity).


-spec end_transaction(agent()) -> ok.
end_transaction(Agent) when is_pid(Agent) ->
    call(Agent,stop).

-spec lock(pid(), oid()) -> {ok, list()}.
-spec lock(pid(), oid(), mode()) -> {ok, list()}.
-spec lock(pid(), oid(), mode(), [node()], req()) -> {ok, list()}.

-spec lock_objects(pid(), objs()) -> ok.

lock(Agent, [_|_] = Obj) when is_pid(Agent) ->
    lock_(Agent, Obj, write, [node()], all, wait).

lock(Agent, [_|_] = Obj, Mode)
  when is_pid(Agent) andalso (Mode==read orelse Mode==write) ->
    lock_(Agent, Obj, Mode, [node()], all, wait).

lock(Agent, [_|_] = Obj, Mode, [_|_] = Where) ->
    lock_(Agent, Obj, Mode, Where, all, wait).

lock(Agent, [_|_] = Obj, Mode, [_|_] = Where, R)
  when is_pid(Agent) andalso (Mode == read orelse Mode == write)
       andalso (R == all orelse R == any orelse R == majority) ->
    lock_(Agent, Obj, Mode, Where, R, wait).

lock_(Agent, Obj, Mode, Where, R, Wait) ->
    case lists:all(fun is_atom/1, Where) of
        true ->
            lock_return(Wait, call(Agent, {lock, Obj, Mode, Where, R, Wait}));
        false ->
            error({invalid_nodes, Where})
    end.

lock_return(wait, {have_all_locks, Deadlocks}) ->
    {ok, Deadlocks};
lock_return(nowait, ok) ->
    ok;
lock_return(_, Other) ->
    Other.

lock_nowait(A, O) -> lock_(A, O, write, [node()], all, nowait).
lock_nowait(A, O, M) -> lock_(A, O, M, [node()], all, nowait).
lock_nowait(A, O, M, W) -> lock_(A, O, M, W, all, nowait).
lock_nowait(A, O, M, W, R) -> lock_(A, O, M, W, R, nowait).

lock_objects(Agent, Objects) ->
    lists:foreach(fun({Obj, Mode}) when Mode == read; Mode == write ->
                          lock(Agent, Obj, Mode);
                     ({Obj, Mode, Where}) when Mode == read; Mode == write ->
                          lock(Agent, Obj, Mode, Where);
                     ({Obj, Mode, Where, Req})
                        when (Mode == read orelse Mode == write)
                             andalso (Req == all
                                      orelse Req == any
                                      orelse Req == majority) ->
                          lock(Agent, Obj, Mode, Where);
                     (L) ->
                          error({illegal_lock_pattern, L})
                  end, Objects).

lock_info(Agent) ->
    call(Agent, lock_info).

call(A, Req) ->
    call(A, Req, 5000).

call(A, Req, Timeout) ->
    case gen_server:call(A, Req, Timeout) of
        {abort, Reason} ->
            ?dbg("~p: call(~p, ~p) -> ABORT:~p~n", [self(), A, Req, Reason]),
            error(Reason);
        Res ->
            ?dbg("~p: call(~p, ~p) -> ~p~n", [self(), A, Req, Res]),
            Res
    end.

%% callback functions

init(Opts) ->
    case OnExit = proplists:get_value(abort_on_exit, Opts, true) of
	false ->
	    process_flag(trap_exit, true);
	true ->
	    ok
    end,
    Client = proplists:get_value(client, Opts),
    ClientMRef = erlang:monitor(process, Client),
    {ok,#state{
           locks = [],
           down = [],
           monitored = ensure_monitor_(?LOCKER, node(), orddict:new()),
           pending = [],
           sync = [],
           client = Client,
           client_mref = ClientMRef,
           abort_on_exit = OnExit,
           options = Opts,
           answer = locking}}.

handle_call({lock, Object, Mode, Nodes, Require, Wait} = _Request, {Client, Tag},
            #state{requests = Reqs} = State)
  when Client==?myclient ->
    ?dbg("~p: Req = ~p~n", [self(), _Request]),
    case lists:keyfind(Object, 1, Reqs) of
        false ->
            Req = #req{object = Object,
                       mode = Mode,
                       nodes = Nodes,
                       require = Require},
            S1 = lists:foldl(
                   fun(Node, Sx) ->
                           OID = {Object, Node},
                           request_lock(
                             OID, Mode, ensure_monitor(Node, Sx))
                   end, State#state{requests = [Req|Reqs]}, Nodes),
            maybe_reply(Wait, ok, Client, Tag, S1);
        #req{nodes = Nodes, require = Require} ->
            %% Repeated request
            maybe_reply(Wait, ok, Client, Tag, State);
        #req{nodes = PrevNodes} ->
            %% Different conditions from last time
            Reason = {conflicting_request,
                      [Object, Nodes, PrevNodes]},
            {stop, Reason, {error, Reason}, State}
    end;
handle_call(lock_info, _From, #state{locks = Locks,
                                     pending = Pending} = State) ->
    {reply, {Pending, Locks}, State};
handle_call({prepare, Ops}, {Client, _} = From, State)
  when Client =:= ?myclient ->
    case waitingfor(State) of
        [] ->
            case check_prepare(Ops, State) of
                {ok, State1} -> {reply, ok, State1};
                {error, Reason} ->
                    %% Automatically abort
                    gen_server:reply(From, Err = {abort, {prepare_error, Reason}}),
                    {stop, Err, State}
            end;
        [_|_] ->
            {reply, {error, awaiting_locks}, State}
    end;
handle_call(await_all_locks, {Client, Tag}, State) when Client =:= ?myclient ->
    ?dbg("~p: await_all_locks(~p)~n"
	 "Reqs = ~p; Locks = ~p~n",
         [self(), Client,
          State#state.pending,
          [{O,Q} || #lock{object = O,
                          queue = Q} <- State#state.locks]]),
    await_all_locks_(Client, Tag, State);
%% handle_call(await_all_or_none, {Client, Tag}, State) when Client==?myclient ->
%%     case someone_locks_all(State) of
%% 	{true, Which} ->
%% 	    {reply, {Which, State#state.deadlocks}, State};
%% 	_ ->
%% 	    Entry = {Client, Tag, await_all_or_none},
%% 	    {noreply, State#state{notify = [Entry|State#state.notify]}}
%%     end;
handle_call(stop, {Client, _}, State) when Client==?myclient ->
    {stop, normal, ok, State};
handle_call(R, _, State) ->
    {reply, {unknown_request, R}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(#locks_info{lock = Lock0, where = Node, note = Note} = I, State0) ->
    ?dbg("~p: handle_info(~p~n", [self(), I]),
    LockID = {Lock0#lock.object, Node},
    Lock = Lock0#lock{object = LockID},
    State = check_note(Note, LockID, State0),
    case outdated(State, Lock) orelse waiting_for_ack(State, LockID) of
	true ->
            ?dbg("~p: outdated or waiting for ack~n"
                 "LockID = ~p; Sync = ~p~n"
                 "Locks = ~p~n",
                 [self(), LockID, State#state.sync, State#state.locks]),
	    {noreply,State};
	false ->
	    NewState = i_add_lock(State, Lock),
	    case State#state.notify of
		[] ->
		    {noreply, handle_locks(NewState)};
		_ ->
		    {noreply, handle_locks(check_if_done(NewState))}
	    end
    end;
handle_info({surrendered, A, OID}, State) ->
    {noreply, note_deadlock(A, OID, State)};
handle_info({'DOWN', Ref, _, _, _}, #state{client_mref = Ref} = State) ->
    {stop, normal, State};
handle_info({'DOWN', _, process, {?LOCKER, Node}, _},
            #state{monitored = Mon,
                   down = Down,
                   requests = Reqs} = S) ->
    Down1 = [Node|Down -- [Node]],
    S1 = S#state{down = Down1},
    case [R#req.object || #req{nodes = Ns} = R <- Reqs,
                          lists:member(Node, Ns)] of
        [] ->
            {noreply, S#state{down = lists:keydelete(Node, 1, Mon)}};
        Objs ->
            case [O || O <- Objs,
                       request_can_be_served(O, S) =:= false] of
                [] ->
                    {noreply, S1};
                Lost ->
                    {stop, {cannot_lock_objects, Lost}, S1}
            end
    end;
handle_info({'EXIT', Client, Reason}, #state{client = Client} = S) ->
    {stop, Reason, S};
handle_info(_, State) ->
    {noreply,State}.

maybe_reply(nowait, Reply, _, _, State) ->
    {reply, Reply, State};
maybe_reply(wait, _, Client, Tag, State) ->
    await_all_locks_(Client, Tag, State).

await_all_locks_(Client, Tag, State) ->
    case all_locks_status(State) of
        no_locks ->
	    {reply, {error, no_locks}, State};
        {have_all, Deadlocks} ->
            {reply, {have_all_locks, Deadlocks}, State};
        waiting ->
            Entry = {Client, Tag, await_all_locks},
            {noreply, State#state{notify = [Entry|State#state.notify]}};
        {cannot_serve, Objs} ->
            Reason = {could_not_lock_objects, Objs},
            {stop, Reason, {error, Reason}, State}
    end.

request_can_be_served(Obj, #state{down = Down, requests = Reqs}) ->
    case lists:keyfind(Obj, #req.object, Reqs) of
        #req{nodes = Ns, require = R} ->
            case R of
                all      -> intersection(Down, Ns) == [];
                any      -> Ns -- Down =/= [];
                majority -> length(Ns -- Down) >= (length(Ns) div 2)
            end;
        false ->
            false
    end.


check_note([], _, State) ->
    State;
check_note({surrender, A}, LockID, State) when A == self() ->
    ?dbg("~p: surrender_ack (~p)~n", [self(), LockID]),
    Sync = [L || #lock{object = Ox} = L <- State#state.sync,
                 Ox =/= LockID],
    State#state{sync = Sync};
check_note({surrender, A}, LockID, State) ->
    note_deadlock(A, LockID, State).

note_deadlock(A, LockID, #state{deadlocks = Deadlocks} = State) ->
    Entry = {A, LockID},
    case member(Entry, Deadlocks) of
        false ->
            State#state{deadlocks = [Entry|Deadlocks]};
        true ->
            State
    end.

intersection(A, B) ->
    A -- (A -- B).

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

request_lock({OID, Node} = LockID, Mode, #state{pending = Reqs} = State) ->
    P = {?LOCKER, Node},
    erlang:monitor(process, P),
    locks_server:lock(OID, [Node], Mode),
    State#state{pending = [LockID | Reqs -- [LockID]]}.

request_surrender({OID, Node} = LockID, #state{}) ->
    ?dbg("request_surrender(~p~n", [LockID]),
    locks_server:surrender(OID, Node).

check_if_done(#state{pending = []} = State) ->
    State;
check_if_done(#state{} = State) ->
    case waitingfor(State) of
	[_|_] = _WF ->   % not done
            ?dbg("waitingfor() -> ~p - not done~n", [_WF]),
	    State;
	[] ->
	    %% _DLs = State#state.deadlocks,
	    Msg = {have_all_locks, State#state.deadlocks},
	    ?dbg("~p: have all locks~n", [self()]),
	    notify(Msg, State)
    end.

abort_on_deadlock(OID, State) ->
    notify({abort, Reason = {deadlock, OID}}, State),
    error(Reason).

notify(Msg, #state{notify = Notify} = State) ->
    NewNotify =
        lists:filter(
          fun({P, R, events}) ->
                  P ! {?MODULE, R, Msg},
                  true;
             ({P, R, await_all_locks}) ->
                  gen_server:reply({P, R}, Msg),
                  false;
             (_) ->
                  true
          end, Notify),
    State#state{notify = NewNotify}.

%% check_if_done(#state{notify = Notify} = State) ->
%%     case have_info_on_all_locks(State#state.pending, State#state.locks) of
%% 	false ->
%% 	    ?dbg("~p: don't yet have all info~n"
%% 		 "Reqs = ~p; Locks = ~p~n", [self(), State#state.pending,
%% 					     State#state.locks]),
%% 	    State;
%% 	true ->
%% 	    DLs = State#state.deadlocks,
%% 	    case someone_locks_all(State) of
%% 		{true, Pid} ->
%% 		    Which = if Pid == self() -> have_all_locks;
%% 			       true -> have_none
%% 			    end,
%% 		    Msg = {Which, State#state.deadlocks},
%% 		    ?dbg("~p: ~p holds all locks~n", [self(), Pid]),
%% 		    NewNotify =
%% 			lists:filter(
%% 			  fun({P, R, events}) ->
%% 				  P ! {?MODULE, R, Msg},
%% 				  true;
%% 			     ({P, R, await_all_locks}) when Pid == self() ->
%% 				  gen_server:reply({P,R}, Msg),
%% 				  false;
%% 			     ({P, R, await_all_or_none}) ->
%% 				  gen_server:reply({P,R}, Msg),
%% 				  false;
%% 			     (_) ->
%% 				  true
%% 			  end, Notify),
%% 		    State#state{notify = NewNotify};
%% 		false ->
%% 		    State
%% 	    end
%%     end.

%% have_info_on_all_locks(Pending, Locks) ->
%%     LockIDs = [L#lock.object || L <- Locks],
%%     (Pending -- LockIDs) == [].


handle_locks(#state{locks = Locks, deadlocks = Deadlocks} = State) ->
    InvolvedAgents =
        uniq( lists:flatmap(
                fun(#lock{queue = Q}) ->
                        [E#entry.agent || E <- flatten_queue(Q)]
                end, Locks) ),
    case analyse(InvolvedAgents, State#state.locks) of
	ok ->
	    %% possible indirect deadlocks
	    %% inefficient computation, optimizes easily
	    Tell =
                [ send_lockinfo(Agent, L)
                  || Agent <- compute_indirects(InvolvedAgents),
                     #lock{queue = [_,_|_]} = L <- Locks,
                     interesting(State, L, Agent) ],
            if Tell =/= [] ->
                    ?dbg("~p: Tell = ~p~n", [self(), Tell]);
               true ->
                    ok
            end,
	    State;
	{deadlock,ShouldSurrender,ToObject} ->
	    ?dbg("~p: deadlock: ShouldSurrender = ~p, ToObject = ~p~n",
		 [self(), ShouldSurrender, ToObject]),
            case ShouldSurrender == self() andalso
                proplists:get_value(
                  abort_on_deadlock, State#state.options, false) of
                true -> abort_on_deadlock(ToObject, State);
                false -> ok
            end,
	    %% throw all lock info about this resource away,
	    %%   since it will change
	    %% this can be optimized by a foldl resulting in a pair
	    NewLocks = [ L || L <- Locks,
			      L#lock.object =/= ToObject ],
	    OldLock = Locks -- NewLocks,
	    NewDeadlocks = [{ShouldSurrender, ToObject} | Deadlocks],
            if ShouldSurrender == self() ->
		    request_surrender(ToObject, State),
                    send_surrender_info(
                      InvolvedAgents,
                      lists:keyfind(ToObject, #lock.object, Locks)),
                    Sync1 = OldLock ++ State#state.sync,
                    ?dbg("~p: Sync1 = ~p~n"
                         "Old Locks = ~p~n"
                         "Old Sync = ~p~n", [self(), Sync1, Locks,
                                             State#state.sync]),
		    State#state{locks = NewLocks,
				sync = Sync1,
				deadlocks = NewDeadlocks};
               true ->
		    State#state{locks = NewLocks,
				deadlocks = NewDeadlocks}
	    end
    end.

send_surrender_info(Agents, #lock{object = OID, queue = Q}) ->
    [ A ! {surrendered, self(), OID}
      || A <- Agents -- [E#entry.agent || E <- flatten_queue(Q)]].

send_lockinfo(Agent, #lock{object = {OID, Node}} = L) ->
    Agent ! #locks_info{lock = L#lock{object = OID}, where = Node}.

terminate(_Reason, _State) ->
    ok.

code_change(_FromVsn, State, _Extra) ->
    {ok, State}.

%%%%%%%%%%%%%%%%%%% data manipulation %%%%%%%%%%%%%%%%%%%

%% Not yet implemented. The idea is to check whether conditions are met
%% for a certain operation (e.g. commit).
check_prepare(_Ops, State) ->
    {ok, State}.

-spec all_locks_status(#state{}) -> no_locks | waiting | {have_all, deadlocks()}.
%%
all_locks_status(#state{pending = Pending} = State) ->
    case Pending of
        [] ->
	    no_locks;
        [_|_] ->
	    case waitingfor(State) of
		[] ->
                    {have_all, State#state.deadlocks};
		WF ->
                    case [O || {O, _} <- WF,
                               request_can_be_served(O, State) =:= false] of
                        [] ->
                            waiting;
                        Os ->
                            {cannot_serve, Os}
                    end
	    end
    end.



%% a lock is outdated if the version number is too old,
%%   i.e. if one of the already received locks is newer
%%
-spec outdated(#state{}, #lock{}) -> boolean().
outdated(State, Lock) ->
    any(fun(L) -> newer(L, Lock) end, State#state.locks).

-spec newer(#lock{}, #lock{}) -> boolean().
newer(Lock1, Lock2) ->
    (Lock1#lock.object == Lock2#lock.object)
        andalso (Lock1#lock.version >= Lock2#lock.version).

-spec waiting_for_ack(#state{}, {_,_}) -> boolean().
waiting_for_ack(#state{sync = Sync}, LockID) ->
    lists:member(LockID, Sync).

-spec waitingfor(#state{}) -> [pid()].
waitingfor(#state{locks = Locks, pending = Pending, requests = Reqs}) ->
    HaveLocks = [L#lock.object || L <- Locks,
                                  in(self(), hd(L#lock.queue))],
    PendingTrimmed =
        lists:foldl(
          fun(#req{object = OID, require = majority, nodes = Ns}, Acc) ->
                  NodesLocked = [N || {O,N} <- HaveLocks, O == OID],
                  case length(NodesLocked) >= (length(Ns) div 2) of
                      true ->
                          [ID || {O,_} = ID <- Acc, O =/= OID];
                      false ->
                          Acc
                  end;
             (#req{object = OID, require = any, nodes = Ns}, Acc) ->
                  case [1 || {O,N} <- HaveLocks, O == OID, member(N, Ns)] of
                      [] -> Acc;
                      [_|_] ->
                          [ID || {O,_} = ID <- Acc, O =/= OID]
                  end;
             (_, Acc) ->
                  Acc
          end, Pending, Reqs),
    ?dbg("HaveLocks = ~p~n", [HaveLocks]),
    PendingTrimmed -- HaveLocks.

i_add_lock(#state{locks = Locks, sync = Sync} = State,
           #lock{object = Obj} = Lock) ->
    State#state{locks = lists:keystore(Obj, #lock.object, Locks, Lock),
		sync = lists:keydelete(Obj, #lock.object, Sync)}.

%% -spec someone_locks_all(#state{}) -> boolean().
%% someone_locks_all(#state{pending = Req, locks = Locks}) ->
%%     LockHolders = [lock_holder(L, Locks) || L <- Req],
%%     R = case lists:usort(LockHolders) of
%% 	    [Pid] when is_pid(Pid) ->
%% 		{true, Pid};
%% 	    _ ->
%% 		false
%% 	end,
%%     ?dbg("~p: someone_locks_all(~p, ~p) -> ~p~n", [self(), Req, Locks, R]),
%%     R.

%% -spec lock_holder(objectID(), [#lock{}]) -> pid() | none.
%% lock_holder(Id, Locks) ->
%%     case lists:keyfind(Id, #lock.object, Locks) of
%% 	false -> none;
%% 	#lock{queue = []} -> none;
%% 	#lock{queue = [P|_]} -> P
%%     end.

-spec compute_indirects(#state{}) -> [pid()].
compute_indirects(InvolvedAgents) ->
    [ A || A<-InvolvedAgents, A>self()].
%% here we impose a global
%% ordering on pids !!
%% Alternatively, we send to
%% all pids

-spec has_a_lock([#lock{}], pid()) -> boolean().
has_a_lock(Locks, Agent) ->
    is_member(Agent, [hd(L#lock.queue) || L<-Locks]).

%% is this lock interesting for the agent?
%%
-spec interesting(#state{}, #lock{}, agent()) -> boolean().
interesting(#state{locks = Locks}, #lock{queue = Q}, Agent) ->
    (not is_member(Agent, Q)) andalso
        has_a_lock(Locks, Agent).

is_member(A, [#r{entries = Es}|T]) ->
    lists:keymember(A, #entry.agent, Es) orelse is_member(A, T);
is_member(A, [#w{entry = #entry{agent = A}}|_]) ->
    true;
is_member(A, [_|T]) ->
    is_member(A, T);
is_member(_, []) ->
    false.

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

uniq(L) ->
    ordsets:from_list(L).

%% analyse computes whether a local deadlock can be detected,
%% if not, 'ok' is returned, otherwise it returns the triple
%% {deadlock,ToSurrender,ToObject} stating which agent should
%% surrender which object.
%%
analyse(_Agents, Locks) ->
    Nodes =
	expand_agents([ {hd(L#lock.queue), L#lock.object} || L <- Locks ]),
    Connect =
	fun({A1, O1}, {A2, _}) ->
		lists:any(
		  fun(#lock{object = Obj, queue = Queue}) ->
                          (O1==Obj)
                              andalso in(A1, hd(Queue))
			      andalso in_tail(A2, tl(Queue))
		  end, Locks)
	end,
    ?dbg("~p: Connect = ~p~n", [self(), Connect]),
    case locks_cycles:components(Nodes, Connect) of
	[] ->
	    ok;
	[Comp|_] ->
	    {ToSurrender, ToObject} = max_agent(Comp),
	    {deadlock, ToSurrender, ToObject}
    end.

expand_agents([{#w{entry = #entry{agent = A}}, Id} | T]) ->
    [{A, Id} | expand_agents(T)];
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
in(A, #w{entry = #entry{agent = A1}}) ->
    A =:= A1.

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
