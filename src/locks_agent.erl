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
%% @doc Transaction agent for the locks system
%%
%% This module implements the recommended API for users of the `locks' system.
%% While the `locks_server' has a low-level API, the `locks_agent' is the
%% part that detects and resolves deadlocks.
%%
%% The agent runs as a separate process from the client, and monitors the
%% client, terminating immediately if it dies.
%% @end
-module(locks_agent).

-behaviour(gen_server).

-compile({parse_transform, locks_watcher}).

-export([start_link/0, start_link/1, start/1]).
-export([begin_transaction/1,
	 begin_transaction/2,
         %%	 acquire_all_or_none/2,
	 lock/2, lock/3, lock/4, lock/5,
         lock_nowait/2, lock_nowait/3, lock_nowait/4, lock_nowait/5,
	 lock_objects/2,
	 await_all_locks/1,
         change_flag/3,
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

-ifdef(DEBUG).
-define(dbg(Fmt, Args), io:fwrite(user, Fmt, Args)).
-else.
-define(dbg(F, A), ok).
-endif.

-type option()      :: {client, pid()}
                     | {abort_on_deadlock, boolean()}
                     | {await_nodes, boolean()}
                     | {notify, boolean()}.

-record(req, {object,
              mode,
              nodes,
              require = all}).

-record(state, {
          locks = []       :: [#lock{}],
          claimed = []     :: [lock_id()],
          requests = []    :: [#req{}],
          down = []        :: [node()],
          monitored = []   :: [{node(), reference()}],
          await_nodes = false :: boolean(),
          pending = []     :: [lock_id()],
          sync = []        :: [#lock{}],
          client           :: pid(),
          client_mref      :: reference(),
          options = []     :: [option()],
          notify = []      :: [{pid(), reference(), await_all_locks}
                               | {pid(), events}],
          answer           :: locking | waiting | done,
          deadlocks = []   :: deadlocks(),
          have_all = false :: boolean()
         }).

-define(myclient,State#state.client).

%%% interface function

%% @spec start_link() -> {ok, pid()}
%% @equiv start_link([])
start_link() ->
    start([{link, true}]).

-spec start_link([option()]) -> {ok, pid()}.
%% @doc Starts an agent with options, linking to the client.
%%
%% Note that even if `{link, false}' is specified in the Options, this will
%% be overridden by `{link, true}', implicit in the function name.
%%
%% Linking is normally not required, as the agent will always monitor the
%% client and terminate if the client dies.
%%
%% See also {@link start/1}.
%% @end
start_link(Options) when is_list(Options) ->
    start(lists:keystore(link, 1, Options, {link, true})).

-spec start([option()]) -> {ok, pid()}.
%% @doc Starts an agent with options.
%%
%% Options are:
%%
%% * `{client, pid()}' - defaults to `self()', indicating which process is
%% the client. The agent will monitor the client, and only accept lock
%% requests from it (this may be extended in future version).
%%
%% * `{link, boolean()}' - default: `false'. Whether to link the current
%% process to the agent. This is normally not required, but will have the
%% effect that the current process (normally the client) receives an 'EXIT'
%% signal if the agent aborts.
%%
%% * `{abort_on_deadlock, boolean()}' - default: `false'. Normally, when
%% deadlocks are detected, one agent will be picked to surrender a lock.
%% This can be problematic if the client has already been notified that the
%% lock has been granted. If `{abort_on_deadlock, true}', the agent will
%% abort if it would otherwise have had to surrender, <b>and</b> the client
%% has been told that the lock has been granted.
%%
%% * `{await_nodes, boolean()}' - default: `false'. If nodes 'disappear'
%% (i.e. the locks_server there goes away) and `{await_nodes, false}',
%% the agent will consider those nodes lost and may abort if the lock
%% request(s) cannot be granted without the lost nodes. If `{await_nodes,true}',
%% the agent will wait for the nodes to reappear, and reclaim the lock(s) when
%% they do.
%%
%% * `{notify, boolean()}' - default: `false'. If `{notify, true}', the client
%% will receive `{locks_agent, Agent, Info}' messages, where `Info' is either
%% a `#locks_info{}' record or `{have_all_locks, Deadlocks}'.
%% @end
start(Options0) when is_list(Options0) ->
    case whereis(locks_server) of
        undefined -> error({not_running, locks_server});
        _ -> ok
    end,
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

-spec begin_transaction(objs()) -> {agent(), lock_result()}.
%% @equiv begin_transaction(Objects, [])
%%
begin_transaction(Objects) ->
    begin_transaction(Objects, []).

-spec begin_transaction(objs(), options()) -> {agent(), lock_result()}.
%% @doc Starts an agent and requests a number of locks at the same time.
%%
%% For a description of valid options, see {@link start/1}.
%%
%% This function will return once the given lock requests have been granted,
%% or exit if they cannot be.
%% @end
begin_transaction(Objects, Opts) ->
    {ok, Agent} = start(Opts),
    _ = lock_objects(Agent, Objects),
    {Agent, await_all_locks(Agent)}.


-spec await_all_locks(agent()) -> lock_result().
%% @doc Waits for all active lock requests to be granted.
%%
%% This function will return once all active lock requests have been granted.
%% If the agent determines that they cannot be granted, or if it has been
%% instructed to abort, this function will raise an exception.
%% @end
await_all_locks(Agent) ->
    call(Agent, await_all_locks,infinity).


-spec end_transaction(agent()) -> ok.
%% @doc Ends the transaction, terminating the agent.
%%
%% All lock requests issued via the agent will automatically be released.
%% @end
end_transaction(Agent) when is_pid(Agent) ->
    call(Agent,stop).

-spec lock(pid(), oid()) -> {ok, list()}.
%%
lock(Agent, [_|_] = Obj) when is_pid(Agent) ->
    lock_(Agent, Obj, write, [node()], all, wait).

-spec lock(pid(), oid(), mode()) -> {ok, list()}.
%% @equiv lock(Agent, Obj, Mode, [node()], all, wait)
lock(Agent, [_|_] = Obj, Mode)
  when is_pid(Agent) andalso (Mode==read orelse Mode==write) ->
    lock_(Agent, Obj, Mode, [node()], all, wait).

-spec lock(pid(), oid(), mode(), [node()]) -> {ok, list()}.
%%
lock(Agent, [_|_] = Obj, Mode, [_|_] = Where) ->
    lock_(Agent, Obj, Mode, Where, all, wait).

-spec lock(pid(), oid(), mode(), [node()], req()) -> {ok, list()}.
%%
lock(Agent, [_|_] = Obj, Mode, [_|_] = Where, R)
  when is_pid(Agent) andalso (Mode == read orelse Mode == write)
       andalso (R == all orelse R == any orelse R == majority
                orelse R == majority_alive) ->
    lock_(Agent, Obj, Mode, Where, R, wait).

lock_(Agent, Obj, Mode, Where, R, Wait) ->
    case lists:all(fun is_atom/1, Where) of
        true ->
            Ref = case Wait of
                      wait -> erlang:monitor(process, Agent);
                      nowait -> nowait
                  end,
            lock_return(
              Wait,
              cast(Agent, {lock, Obj, Mode, Where, R, Wait, self(), Ref}, Ref));
        false ->
            error({invalid_nodes, Where})
    end.

change_flag(Agent, Option, Bool)
  when is_boolean(Bool), Option == abort_on_deadlock;
       is_boolean(Bool), Option == await_nodes;
       is_boolean(Bool), Option == notify ->
    gen_server:cast(Agent, {option, Option, Bool}).

cast(Agent, Msg, Ref) ->
    gen_server:cast(Agent, Msg),
    await_reply(Ref).

await_reply(nowait) ->
    ok;
await_reply(Ref) ->
    receive
        {'DOWN', Ref, _, _, Reason} ->
            error(Reason);
        {Ref, {abort, Reason}} ->
            error(Reason);
        {Ref, Reply} ->
            Reply
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


-spec lock_objects(pid(), objs()) -> ok.
%%
lock_objects(Agent, Objects) ->
    lists:foreach(fun({Obj, Mode}) when Mode == read; Mode == write ->
                          lock_nowait(Agent, Obj, Mode);
                     ({Obj, Mode, Where}) when Mode == read; Mode == write ->
                          lock_nowait(Agent, Obj, Mode, Where);
                     ({Obj, Mode, Where, Req})
                        when (Mode == read orelse Mode == write)
                             andalso (Req == all
                                      orelse Req == any
                                      orelse Req == majority
                                      orelse Req == majority_alive) ->
                          lock_nowait(Agent, Obj, Mode, Where);
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

%% @private
init(Opts) ->
    Client = proplists:get_value(client, Opts),
    ClientMRef = erlang:monitor(process, Client),
    Notify = case proplists:get_value(notify, Opts, false) of
                 true -> [{Client, events}];
                 false -> []
             end,
    AwaitNodes = proplists:get_value(await_nodes, Opts, false),
    net_kernel:monitor_nodes(true),
    {ok,#state{
           locks = [],
           down = [],
           monitored = ensure_monitor_(?LOCKER, node(), orddict:new()),
           await_nodes = AwaitNodes,
           pending = [],
           sync = [],
           client = Client,
           client_mref = ClientMRef,
           notify = Notify,
           options = Opts,
           answer = locking}}.

%% @private
handle_call(lock_info, _From, #state{locks = Locks,
                                     pending = Pending} = State) ->
    {reply, {Pending, Locks}, State};
handle_call(await_all_locks, {Client, Tag}, State) ->
    ?dbg("~p: await_all_locks(~p)~n"
	 "Reqs = ~p; Locks = ~p~n",
         [self(), Client,
          State#state.pending,
          [{O,Q} || #lock{object = O,
                          queue = Q} <- State#state.locks]]),
    await_all_locks_(Client, Tag, State);
handle_call(stop, {Client, _}, State) when Client==?myclient ->
    {stop, normal, ok, State};
handle_call(R, _, State) ->
    {reply, {unknown_request, R}, State}.

%% @private
handle_cast({lock, Object, Mode, Nodes, Require, Wait, Client, Tag} = _Request,
            #state{requests = Reqs} = State)
  when Client==?myclient ->
    ?dbg("~p: Req = ~p~n", [self(), _Request]),
    case lists:keyfind(Object, #req.object, Reqs) of
        false ->
            ?dbg("~p: no previous request for ~p~n", [self(), Object]),
            S1 = new_request(Object, Mode, Nodes, Require, State),
            maybe_reply(Wait, Client, Tag, S1);
        #req{nodes = Nodes1, require = Require, mode = Mode} = Req ->
            ?dbg("~p: repeated request for ~p~n", [self(), Object]),
            %% Repeated request
            case Nodes -- Nodes1 of
                [] ->
                    %% no new nodes
                    maybe_reply(Wait, Client, Tag, State);
                [_|_] = New ->
                    S1 = add_nodes(New, Req, State),
                    maybe_reply(Wait, Client, Tag, S1)
            end;
        #req{nodes = Nodes, require = Require, mode = write} when Mode==read ->
            ?dbg("~p: found old request for write lock on ~p~n", [self(),
                                                                  Object]),
            %% The old request is sufficient
            maybe_reply(Wait, Client, Tag, State);
        #req{nodes = Nodes, require = Require, mode = read} when Mode==write ->
            ?dbg("~p: need to upgrade existing read lock on ~p~n",
                 [self(), Object]),
            NewLocks = [L || #lock{object = OID} = L <- State#state.locks,
                             element(1, OID) =/= Object],
            ?dbg("~p: Remove old lock info on ~p~n", [self(), Object]),
            S1 = new_request(Object, Mode, Nodes, Require,
                             State#state{locks = NewLocks}),
            maybe_reply(Wait, Client, Tag, S1);
        #req{nodes = PrevNodes} ->
            %% Different conditions from last time
            Reason = {conflicting_request,
                      [Object, Nodes, PrevNodes]},
            {stop, Reason, {error, Reason}, State}
    end;
handle_cast({option, O, Val}, #state{options = Opts} = S) ->
    S1 = case O of
             await_nodes ->
                 S#state{await_nodes = Val};
             notify ->
                 Entry = {S#state.client, events},
                 case Val of
                     true ->
                         S#state{notify = [Entry|S#state.notify -- [Entry]]};
                     false ->
                         S#state{notify = S#state.notify -- [Entry]}
                 end;
             _ ->
                 S#state{options = lists:keystore(O, 1, Opts, {O, Val})}
         end,
    {noreply, S1};
handle_cast(_Msg, State) ->
    {noreply, State}.

new_request(Object, Mode, Nodes, Require, #state{requests = Reqs} = State) ->
    Req = #req{object = Object,
               mode = Mode,
               nodes = Nodes,
               require = Require},
    lists:foldl(
      fun(Node, Sx) ->
              OID = {Object, Node},
              request_lock(
                OID, Mode, ensure_monitor(Node, Sx))
      end, State#state{requests = [Req|Reqs]}, Nodes).

add_nodes(Nodes, #req{object = Object, mode = Mode, nodes = OldNodes} = Req,
          #state{requests = Reqs} = State) ->
    AllNodes = union(Nodes, OldNodes),
    Req1 = Req#req{nodes = AllNodes},
    lists:foldl(
      fun(Node, Sx) ->
              OID = {Object, Node},
              request_lock(
                OID, Mode, ensure_monitor(Node, Sx))
      end, State#state{requests =
                           lists:keyreplace(
                             Object, #req.object, Reqs, Req1)}, Nodes).

union(A, B) ->
    A ++ (B -- A).

%% @private
handle_info(#locks_info{lock = Lock0, where = Node, note = Note} = I, S0) ->
    ?dbg("~p: handle_info(~p~n", [self(), I]),
    LockID = {Lock0#lock.object, Node},
    Lock = Lock0#lock{object = LockID},
    State = check_note(Note, LockID, S0),
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
		    {noreply, handle_locks(check_if_done(NewState, [I]))}
	    end
    end;
handle_info({surrendered, A, OID}, State) ->
    {noreply, note_deadlock(A, OID, State)};
handle_info({'DOWN', Ref, _, _, _}, #state{client_mref = Ref} = State) ->
    {stop, normal, State};
handle_info({'DOWN', _, process, {?LOCKER, Node}, _},
            #state{down = Down} = S) ->
    case lists:member(Node, Down) of
        true -> {noreply, S};
        false ->
            handle_nodedown(Node, S)
    end;
handle_info({'DOWN',_,_,_,_}, S) ->
    %% most likely a watcher
    {noreply, S};
handle_info({nodeup, N}, #state{down = Down} = S) ->
    case lists:member(N, Down) of
        true  -> watch_node(N);
        false -> ignore
    end,
    {noreply, S};
handle_info({nodedown,_}, S) ->
    %% We react on 'DOWN' messages above instead
    {noreply, S};
handle_info({locks_running,N}, #state{down = Down, requests = Reqs} = S) ->
    case lists:member(N, Down) of
        true ->
            S1 = S#state{down = Down -- [N]},
            case [{O,M} || #req{nodes = Ns, object = O, mode = M} <- Reqs,
                           lists:member(N, Ns)] of
                [] ->
                    {noreply, S1};
                Reissue ->
                    S2 = lists:foldl(
                           fun({Obj,Mode}, Sx) ->
                                   request_lock(
                                     {Obj,N}, Mode, Sx)
                           end, ensure_monitor(N, S1), Reissue),
                    {noreply, S2}
            end;
        false ->
            {noreply, S}
    end;
handle_info({'EXIT', Client, Reason}, #state{client = Client} = S) ->
    {stop, Reason, S};
handle_info(_Msg, State) ->
    io:fwrite("Unknown msg: ~p~n", [_Msg]),
    {noreply,State}.

maybe_reply(nowait, _, _, State) ->
    {noreply, State};
maybe_reply(wait, Client, Tag, State) ->
    await_all_locks_(Client, Tag, State).

await_all_locks_(Client, Tag, State) ->
    case all_locks_status(State) of
        no_locks ->
            gen_server:reply({Client, Tag}, {error, no_locks}),
	    {noreply, State};
        {have_all, Deadlocks} ->
            Msg = {have_all_locks, Deadlocks},
            gen_server:reply({Client, Tag}, Msg),
            {noreply, notify(Msg, State#state{have_all = true})};
        waiting ->
            Entry = {Client, Tag, await_all_locks},
            {noreply, State#state{notify = [Entry|State#state.notify]}};
        {cannot_serve, Objs} ->
            Reason = {could_not_lock_objects, Objs},
            gen_server:reply({Client, Tag}, Reason),
            {stop, {error, Reason}, State}
    end.

request_can_be_served(_, #state{await_nodes = true}) ->
    true;
request_can_be_served(Obj, #state{down = Down, requests = Reqs}) ->
    case lists:keyfind(Obj, #req.object, Reqs) of
        #req{nodes = Ns, require = R} ->
            case R of
                all       -> intersection(Down, Ns) == [];
                any       -> Ns -- Down =/= [];
                majority  -> length(Ns -- Down) > (length(Ns) div 2);
                majority_alive ->
                    true
            end;
        false ->
            false
    end.

handle_nodedown(Node, #state{down = Down, requests = Reqs,
                             monitored = Mon, locks = Locks} = S) ->
    ?dbg("~p: handle_nodedown (~p)~n", [self(), Node]),
    Locks1 = [L || #lock{object = {_Oid, N}} = L <- Locks, N =/= Node],
    Down1 = [Node|Down -- [Node]],
    S1 = S#state{down = Down1, locks = Locks1},
    case [R#req.object || #req{nodes = Ns} = R <- Reqs,
                          lists:member(Node, Ns)] of
        [] ->
            {noreply, S#state{down = lists:keydelete(Node, 1, Mon)}};
        Objs ->
            case S1#state.await_nodes of
                false ->
                    case [O || O <- Objs,
                               request_can_be_served(O, S1) =:= false] of
                        [] ->
                            {noreply, check_if_done(S1)};
                        Lost ->
                            {stop, {cannot_lock_objects, Lost}, S1}
                    end;
                true ->
                    case lists:member(Node, nodes()) of
                        true  -> watch_node(Node);
                        false -> ignore
                    end,
                    {noreply, S1}
            end
    end.


watch_node(N) ->
    {M, F, A} =
        locks_watcher(self()),  % expanded through parse_transform
    P = spawn(N, M, F, A),
    erlang:monitor(process, P).

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

request_lock({OID, Node} = LockID, Mode, #state{pending = Reqs,
                                                client = Client} = State) ->
    P = {?LOCKER, Node},
    erlang:monitor(process, P),
    locks_server:lock(OID, [Node], Client, Mode),
    State#state{pending = [LockID | Reqs -- [LockID]]}.

request_surrender({OID, Node} = _LockID, #state{}) ->
    ?dbg("request_surrender(~p~n", [_LockID]),
    locks_server:surrender(OID, Node).

check_if_done(S) ->
    check_if_done(S, []).

check_if_done(#state{pending = []} = State, Msgs) ->
    notify_msgs(Msgs, have_all(State));
check_if_done(#state{} = State, Msgs) ->
    case waitingfor(State) of
	[_|_] = _WF ->   % not done
            ?dbg("~p: waitingfor() -> ~p - not done~n", [self(), _WF]),
            %% We don't clear the 'claimed' list here, since it tells us if
            %% we have told our client we have a certain lock
	    notify_msgs(Msgs, State#state{have_all = false});
	[] ->
	    %% _DLs = State#state.deadlocks,
	    Msg = {have_all_locks, State#state.deadlocks},
	    ?dbg("~p: have all locks~n", [self()]),
	    notify_msgs([Msg|Msgs], have_all(State))
    end.

have_all(#state{locks = Locks} = State) ->
    State#state{have_all = true,
                claimed = [OID || #lock{object = OID} <- Locks]}.

abort_on_deadlock(OID, State) ->
    notify({abort, Reason = {deadlock, OID}}, State),
    error(Reason).

notify_msgs([M|Ms], S) ->
    S1 = notify_msgs(Ms, S),
    notify(M, S1);
notify_msgs([], S) ->
    S.


notify(Msg, #state{notify = Notify} = State) ->
    NewNotify =
        lists:filter(
          fun({P, events}) ->
                  P ! {?MODULE, self(), Msg},
                  true;
             ({P, R, await_all_locks}) when element(1,Msg) == have_all_locks ->
                  gen_server:reply({P, R}, Msg),
                  false;
             (_) ->
                  true
          end, Notify),
    State#state{notify = NewNotify}.

handle_locks(#state{have_all = true} = State) ->
    %% If we have all locks we've asked for, no need to search for potential
    %% deadlocks - reasonably, we cannot be involved in one.
    State;
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
            case ShouldSurrender == self()
                andalso
                (proplists:get_value(
                   abort_on_deadlock, State#state.options, false)
                 andalso lists:member(ToObject,
                                      State#state.claimed) == true)  of
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

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_FromVsn, State, _Extra) ->
    {ok, State}.

%%%%%%%%%%%%%%%%%%% data manipulation %%%%%%%%%%%%%%%%%%%

-spec all_locks_status(#state{}) ->
                              no_locks | waiting | {have_all, deadlocks()}
                                  | {cannot_serve, list()}.
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

-spec waitingfor(#state{}) -> [lock_id()].
waitingfor(#state{locks = Locks, pending = Pending, requests = Reqs,
                  down = Down}) ->
    HaveLocks = [L#lock.object || L <- Locks,
                                  in(self(), hd(L#lock.queue))],
    PendingTrimmed =
        lists:foldl(
          fun(#req{object = OID, require = majority, nodes = Ns}, Acc) ->
                  NodesLocked = [N || {O,N} <- HaveLocks, O == OID],
                  case length(NodesLocked) > (length(Ns) div 2) of
                      true ->
                          [ID || {O,_} = ID <- Acc, O =/= OID];
                      false ->
                          Acc
                  end;
             (#req{object = OID, require = majority_alive, nodes = Ns}, Acc) ->
                  Alive = Ns -- Down,
                  NodesLocked = [N || {O,N} <- HaveLocks, O == OID],
                  case length(NodesLocked) > (length(Alive) div 2) of
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
    ?dbg("~p: HaveLocks = ~p~n", [self(), HaveLocks]),
    PendingTrimmed -- HaveLocks.

i_add_lock(#state{locks = Locks, sync = Sync} = State,
           #lock{object = Obj} = Lock) ->
    State#state{locks = lists:keystore(Obj, #lock.object, Locks, Lock),
		sync = lists:keydelete(Obj, #lock.object, Sync)}.


-spec compute_indirects([agent()]) -> [agent()].
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
    %% No need to analyse locks that have no waiters
    InterestingLocks = [L || #lock{queue = [_,_|_]} = L <- Locks],
    analyse_(InterestingLocks).

analyse_(Locks) ->
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

