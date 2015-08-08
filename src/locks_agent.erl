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
-behaviour(gen_server).

-compile({parse_transform, locks_watcher}).

-export([start_link/0, start_link/1, start/0, start/1]).
-export([spawn_agent/1]).
-export([begin_transaction/1,
	 begin_transaction/2,
         %%	 acquire_all_or_none/2,
	 lock/2, lock/3, lock/4, lock/5,
         lock_nowait/2, lock_nowait/3, lock_nowait/4, lock_nowait/5,
	 lock_objects/2,
         surrender_nowait/4,
	 await_all_locks/1,
         monitor_nodes/2,
         change_flag/3,
	 lock_info/1,
         transaction_status/1,
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

-export([record_fields/1]).

-import(lists,[foreach/2,any/2,map/2,member/2]).

-include("locks.hrl").

-define(event(E), event(?LINE, E, none)).
-define(event(E, S), event(?LINE, E, S)).

-ifdef(DEBUG).
-define(dbg(Fmt, Args), io:fwrite(user, Fmt, Args)).
-else.
-define(dbg(F, A), ok).
-endif.

-type option()      :: {client, pid()}
                     | {abort_on_deadlock, boolean()}
                     | {await_nodes, boolean()}
                     | {notify, boolean()}.

-type transaction_status() :: no_locks
                            | {have_all_locks, list()}
                            | waiting
                            | {cannot_serve, list()}.

-record(req, {object,
              mode,
              nodes,
              claim_no = 0,
              require = all}).

-record(state, {
          locks            :: ets:tab(),
          agents           :: ets:tab(),
          interesting = [] :: [lock_id()],
          claim_no = 0     :: integer(),
          requests         :: ets:tab(),
          down = []        :: [node()],
          monitored = []   :: [{node(), reference()}],
          await_nodes = false :: boolean(),
          monitor_nodes = false :: boolean(),
          pending          :: ets:tab(),
          sync = []        :: [#lock{}],
          client           :: pid(),
          client_mref      :: reference(),
          options = []     :: [option()],
          notify = []      :: [{pid(), reference(), await_all_locks}
                               | {pid(), events}],
          answer           :: locking | waiting | done,
          deadlocks = []   :: deadlocks(),
          have_all = false :: boolean(),
          status = no_locks :: transaction_status()
         }).

-define(myclient,State#state.client).

record_fields(state     ) -> record_info(fields, state);
record_fields(req       ) -> record_info(fields, req);
record_fields(lock      ) -> record_info(fields, lock);
record_fields(locks_info) -> record_info(fields, locks_info);
record_fields(w         ) -> record_info(fields, w);
record_fields(r         ) -> record_info(fields, r);
record_fields(entry     ) -> record_info(fields, entry);
record_fields(_) ->
    no.

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

-spec start() -> {ok, pid()}.
%% @equiv start([])
start() ->
    start([]).

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
%% * `{monitor_nodes, boolean()}' - default: `false'. Works like
%% {@link net_kernel:monitor_nodes/1}, but `nodedown' and `nodeup' messages are
%% sent when the `locks' server on a given node either appears or disappears.
%% The messages (`{nodeup,Node}' and `{nodedown,Node}') are sent only to
%% the client. Can also be toggled using {@link monitor_nodes/2}.
%%
%% * `{notify, boolean()}' - default: `false'. If `{notify, true}', the client
%% will receive `{locks_agent, Agent, Info}' messages, where `Info' is either
%% a `#locks_info{}' record or `{have_all_locks, Deadlocks}'.
%% @end
start(Options0) when is_list(Options0) ->
    spawn_agent(true, Options0).

spawn_agent(Options) ->
    spawn_agent(false, Options).

spawn_agent(Wait, Options0) ->
    Client = self(),
    Options = prepare_spawn(Options0),
    F = fun() -> agent_init(Wait, Client, Options) end,
    Pid = case lists:keyfind(link, 1, Options) of
              {_, true} -> spawn_link(F);
              _         -> spawn(F)
          end,
    await_pid(Wait, Pid).

prepare_spawn(Options) ->
    case whereis(locks_server) of
        undefined -> error({not_running, locks_server});
        _ -> ok
    end,
    case lists:keymember(client, 1, Options) of
        true -> Options;
        false -> [{client, self()}|Options]
    end.

agent_init(Wait, Client, Options) ->
    case init(Options) of
        {ok, St} ->
            ack(Wait, Client, {ok, self()}),
            try loop(St)
            catch
                error:Error ->
                    error_logger:error_report(
                      [{?MODULE, aborted},
                       {reason, Error},
                       {trace, erlang:get_stacktrace()}]),
                    error(Error)
            end;
        Other ->
            ack(Wait, Client, {error, Other}),
            error(Other)
    end.

await_pid(false, Pid) ->
    {ok, Pid};
await_pid(true, Pid) ->
    MRef = erlang:monitor(process, Pid),
    receive
        {Pid, Reply} ->
            erlang:demonitor(MRef),
            Reply;
        {'DOWN', MRef, _, _, Reason} ->
            error(Reason)
    end.

ack(false, _, _) ->
    ok;
ack(true, Pid, Reply) ->
    Pid ! {self(), Reply}.

loop(#state{status = OldStatus} = St) ->
    receive Msg ->
            St1 = handle_msg(Msg, St),
            loop(maybe_status_change(OldStatus, St1))
    end.

handle_msg({'$gen_call', From, Req}, St) ->
    case handle_call(Req, From, St) of
        {reply, Reply, St1} ->
            gen_server:reply(From, Reply),
            St1;
        {noreply, St1} ->
            St1;
        {stop, Reason, Reply, _} ->
            gen_server:reply(From, Reply),
            exit(Reason);
        {stop, Reason, _} ->
            exit(Reason)
    end;
handle_msg({'$gen_cast', Msg}, St) ->
    case handle_cast(Msg, St) of
        {noreply, St1} ->
            St1;
        {stop, Reason, _} ->
            exit(Reason)
    end;
handle_msg(Msg, St) ->
    case handle_info(Msg, St) of
        {noreply, St1} -> St1;
        {stop, Reason, _} ->
            exit(Reason)
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
%% or exit if they cannot be. If no initial lock requests are given, the
%% function will not wait at all, but return directly.
%% @end
begin_transaction(Objects, Opts) ->
    {ok, Agent} = start(Opts),
    case Objects of
        [] -> {Agent, {ok,[]}};
        [_|_] ->
            _ = lock_objects(Agent, Objects),
            {Agent, await_all_locks(Agent)}
    end.


-spec await_all_locks(agent()) -> lock_result().
%% @doc Waits for all active lock requests to be granted.
%%
%% This function will return once all active lock requests have been granted.
%% If the agent determines that they cannot be granted, or if it has been
%% instructed to abort, this function will raise an exception.
%% @end
await_all_locks(Agent) ->
    call(Agent, await_all_locks,infinity).

-spec monitor_nodes(agent(), boolean()) -> boolean().
%% @doc Toggles monitoring of nodes, like net_kernel:monitor_nodes/1.
%%
%% Works like {@link net_kernel:monitor_nodes/1}, but `nodedown' and `nodeup'
%% messages are sent when the `locks' server on a given node either appears
%% or disappears. In this sense, the monitoring will signal when a viable
%% `locks' node becomes operational (or inoperational).
%% The messages (`{nodeup,Node}' and `{nodedown,Node}') are sent only to
%% the client.
monitor_nodes(Agent, Bool) when is_boolean(Bool) ->
    call(Agent, {monitor_nodes, Bool}).

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
                orelse R == majority_alive orelse R == all_alive) ->
    lock_(Agent, Obj, Mode, Where, R, wait).

lock_(Agent, Obj, Mode, [_|_] = Where, R, Wait) ->
    Ref = case Wait of
              wait -> erlang:monitor(process, Agent);
              nowait -> nowait
          end,
    lock_return(
      Wait,
      cast(Agent, {lock, Obj, Mode, Where, R, Wait, self(), Ref}, Ref)).

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

surrender_nowait(A, O, OtherAgent, Nodes) ->
    gen_server:cast(A, {surrender, O, OtherAgent, Nodes}).

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
                                      orelse Req == majority_alive
                                      orelse Req == all_alive) ->
                          lock_nowait(Agent, Obj, Mode, Where);
                     (L) ->
                          error({illegal_lock_pattern, L})
                  end, Objects).

lock_info(Agent) ->
    call(Agent, lock_info).

-spec transaction_status(agent()) -> transaction_status().
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
    call(Agent, transaction_status).

call(A, Req) ->
    call(A, Req, 5000).

call(A, Req, Timeout) ->
    case gen_server:call(A, Req, Timeout) of
        {abort, Reason} ->
            ?event({abort, Reason, [A, Req, Timeout]}),
            error(Reason);
        Res ->
            ?event({result, Res, [A, Req, Timeout]}),
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
    MonNodes = proplists:get_value(monitor_nodes, Opts, false),
    net_kernel:monitor_nodes(true),
    {ok,#state{
           locks = ets_new(locks, [ordered_set, {keypos, #lock.object}]),
           agents = ets_new(agents, [ordered_set]),
           requests = ets_new(reqs, [bag, {keypos, #req.object}]),
           down = [],
           monitored = orddict:new(),
           await_nodes = AwaitNodes,
           monitor_nodes = MonNodes,
           pending = ets_new(pending, [bag, {keypos, #req.object}]),
           sync = [],
           client = Client,
           client_mref = ClientMRef,
           notify = Notify,
           options = Opts,
           answer = locking}}.

%% @private
handle_call(lock_info, _From, #state{locks = Locks,
                                     pending = Pending} = State) ->
    {reply, {ets:tab2list(Pending), ets:tab2list(Locks)}, State};
handle_call(transaction_status, _From, #state{status = Status} = State) ->
    {reply, Status, State};
handle_call(await_all_locks, {Client, Tag}, State) ->
    {noreply, check_if_done(add_waiter(wait, Client, Tag, State))};
handle_call({monitor_nodes, Bool}, _From, St) when is_boolean(Bool) ->
    {reply, St#state.monitor_nodes, St#state{monitor_nodes = Bool}};
handle_call(stop, {Client, _}, State) when Client==?myclient ->
    {stop, normal, ok, State};
handle_call(R, _, State) ->
    {reply, {unknown_request, R}, State}.

%% @private
handle_cast({lock, Object, Mode, Nodes, Require, Wait, Client, Tag} = _Req,
            State) ->
    %%
    ?event(_Req, State),
    case matching_request(Object, Mode, Nodes, Require,
                          add_waiter(Wait, Client, Tag, State)) of
        {false, S1} ->
            ?event({no_matching_request, Object}),
            {noreply, check_if_done(
                        new_request(Object, Mode, Nodes, Require, S1))};
        {true, S1} ->
            {noreply, check_if_done(S1)}
    end;
handle_cast({surrender, O, ToAgent, Nodes} = _Req, S) ->
    ?event(_Req, S),
    case lists:all(
           fun(N) ->
                   #lock{queue = Q} = L = get_lock({O,N}, S),
                   lists:member(self(), lock_holders(L))
                       andalso in_tail(ToAgent, tl(Q))
           end, Nodes) of
        true ->
            NewS = lists:foldl(
                     fun(OID, Sx) ->
                             do_surrender(self(), OID, [ToAgent], Sx)
                     end, S, [{O, N} || N <- Nodes]),
            {noreply, check_if_done(NewS)};
        false ->
            {stop, {cannot_surrender, [O, ToAgent]}, S}
    end;
handle_cast({option, O, Val}, #state{notify = Notify,
                                     client = C, options = Opts} = S) ->
    S1 = case O of
             await_nodes ->
                 S#state{await_nodes = Val};
             notify ->
                 Entry = {C, events},
                 case Val of
                     true ->
                         S1a = case Notify of
                                   [] ->
                                       Status = all_locks_status(S),
                                       set_status(Status, S);
                                   _ -> S
                              end,
                         %% always send an initial status notification
                         C ! {?MODULE, self(), S1a#state.status},
                         S1a#state{notify = list_store(Entry, Notify)};
                     false ->
                         S#state{notify = S#state.notify -- [Entry]}
                 end;
             _ ->
                 S#state{options = lists:keystore(O, 1, Opts, {O, Val})}
         end,
    {noreply, S1};
handle_cast(_Msg, State) ->
    {noreply, State}.

list_store(E, L) ->
    case lists:member(E, L) of
        true -> L;
        false ->
            [E|L]
    end.

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

remove_locks(Object, #state{locks = Locks, agents = As,
                            interesting = I} = S) ->
    ets:match_delete(Locks, #lock{object = {Object,'_'}, _ = '_'}),
    ets:match_delete(As, {{self(),{Object,'_'}}}),
    S#state{interesting = prune_interesting(I, object, Object)}.

new_request(Object, Mode, Nodes, Require, #state{pending = Pending,
                                                 claim_no = Cl} = State) ->
    Req = #req{object = Object,
               mode = Mode,
               nodes = Nodes,
               claim_no = Cl,
               require = Require},
    ets_insert(Pending, Req),
    lists:foldl(
      fun(Node, Sx) ->
              OID = {Object, Node},
              request_lock(
                OID, Mode, ensure_monitor(Node, Sx))
      end, State, Nodes).



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

union(A, B) ->
    A ++ (B -- A).

%% @private
handle_info(#locks_info{lock = Lock0, where = Node, note = Note} = I, S0) ->
    ?event({handle_info, I}, S0),
    LockID = {Lock0#lock.object, Node},
    Lock = Lock0#lock{object = LockID},
    Prev = ets_lookup(S0#state.locks, LockID),
    State = check_note(Note, LockID, S0),
    case outdated(Prev, Lock) orelse waiting_for_ack(State, LockID) of
	true ->
            ?event({outdated_or_waiting_for_ack, [LockID]}),
	    {noreply,State};
	false ->
	    NewState = i_add_lock(State, Lock, Prev),
            {noreply, handle_locks(check_if_done(NewState, [I]))}
    end;
handle_info({surrendered, A, OID} = _Msg, State) ->
    ?event(_Msg),
    {noreply, note_deadlock(A, OID, State)};
handle_info({'DOWN', Ref, _, _, _Rsn}, #state{client_mref = Ref} = State) ->
    ?event({client_DOWN, _Rsn}),
    {stop, normal, State};
handle_info({'DOWN', _, process, {?LOCKER, Node}, _},
            #state{down = Down} = S) ->
    ?event({locker_DOWN, Node}),
    case lists:member(Node, Down) of
        true -> {noreply, S};
        false ->
            handle_nodedown(Node, S)
    end;
handle_info({'DOWN',_,_,_,_}, S) ->
    %% most likely a watcher
    {noreply, S};
handle_info({nodeup, N} = _Msg, #state{down = Down} = S) ->
    ?event(_Msg),
    case S#state.monitor_nodes orelse lists:member(N, Down) of
        true  -> watch_node(N);
        false -> ignore
    end,
    {noreply, S};
handle_info({nodedown,_}, S) ->
    %% We react on 'DOWN' messages above instead
    {noreply, S};
handle_info({locks_running,N} = Msg, #state{down=Down, pending=Pending,
                                            requests = Reqs,
                                            monitor_nodes = MonNodes,
                                            client = C} = S) ->
    ?event(Msg),
    if MonNodes ->
            C ! {nodeup, N};
       true ->
            ignore
    end,
    case lists:member(N, Down) of
        true ->
            S1 = S#state{down = Down -- [N]},
            {R, P} = Res = {requests_with_node(N, Reqs),
                            requests_with_node(N, Pending)},
            ?event({{reqs, pending}, Res}),
            case R ++ P of
                [] ->
                    {noreply, S1};
                Reissue ->
                    S2 = lists:foldl(
                           fun(#req{object = Obj, mode = Mode}, Sx) ->
                                   request_lock({Obj,N}, Mode, Sx)
                           end, ensure_monitor(N, S1), Reissue),
                    {noreply, S2}
            end;
        false ->
            {noreply, S}
    end;
handle_info({'EXIT', Client, Reason}, #state{client = Client} = S) ->
    {stop, Reason, S};
handle_info(_Msg, S) ->
    ?event({unknown_msg, _Msg}),
    {noreply, S}.


add_waiter(nowait, _, _, State) ->
    State;
add_waiter(wait, Client, Tag, #state{notify = Notify} = State) ->
    State#state{notify = [{Client, Tag, await_all_locks}|Notify]}.

%% maybe_reply(nowait, _, _, State) ->
%%     {noreply, State};
%% maybe_reply(wait, Client, Tag, State) ->
%%     await_all_locks_(Client, Tag, State).

%% await_all_locks_(Client, Tag, State) ->
%%     Status = all_locks_status(State),
%%     ?event({all_locks_status, Status}),
%%     State1 = set_status(Status, State),
%%     case Status of
%%         no_locks ->
%%             gen_server:reply({Client, Tag}, {error, no_locks}),
%% 	    {noreply, State1};
%%         {have_all_locks, Deadlocks} ->
%%             Msg = {have_all_locks, Deadlocks},
%%             gen_server:reply({Client, Tag}, Msg),
%%             {noreply, notify(Msg, State1)};
%%         waiting ->
%%             Entry = {Client, Tag, await_all_locks},
%%             {noreply, State1#state{notify = [Entry|State#state.notify]}};
%%         {cannot_serve, Objs} ->
%%             Reason = {could_not_lock_objects, Objs},
%%             gen_server:reply({Client, Tag}, Reason),
%%             {stop, {error, Reason}, State1}
%%     end.

set_status(Status, #state{status = Status} = S) ->
    S;
set_status({have_all_locks, _} = Status, S) ->
    have_all(S#state{status = Status});
set_status(Status, S) ->
    S#state{status = Status, have_all = false}.


maybe_status_change(Status, #state{status = Status} = State) ->
    ?event(no_status_change),
    State;
maybe_status_change(OldStatus, #state{status = Status} = S) ->
    ?event({status_change, OldStatus, Status}),
    notify(Status, S).

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

handle_nodedown(Node, #state{down = Down, requests = Reqs,
                             pending = Pending,
                             monitored = Mon, locks = Locks,
                             interesting = I,
                             agents = Agents,
                             monitor_nodes = MonNodes} = S) ->
    ?event({handle_nodedown, Node}, S),
    handle_monitor_on_down(Node, S),
    ets_match_delete(Locks, #lock{object = {'_',Node}, _ = '_'}),
    ets_match_delete(Agents, {{'_',{'_',Node}}}),
    Down1 = [Node|Down -- [Node]],
    S1 = S#state{down = Down1, interesting = prune_interesting(I, node, Node),
                 monitored = lists:keydelete(Node, 1, Mon)},
    Res = {requests_with_node(Node, Reqs),
           requests_with_node(Node, Pending)},
    ?event({{reqs,pending}, Res}),
    case Res of
        {[], []} ->
            {noreply, S1};
        {Rs, PRs} ->
            move_requests(Rs, Reqs, Pending),
            case S1#state.await_nodes of
                false ->
                    case [R || R <- Rs ++ PRs,
                               request_can_be_served(R, S1) =:= false] of
                        [] ->
                            {noreply, check_if_done(S1)};
                        Lost ->
                            {stop, {cannot_lock_objects, Lost}, S1}
                    end;
                true ->
                    case MonNodes == false
                        andalso lists:member(Node, nodes()) of
                        true  -> watch_node(Node);
                        false -> ignore
                    end,
                    if PRs =/= [] ->
                            {noreply, check_if_done(S1)};
                       true ->
                            {noreply, S1}
                    end
            end
    end.

handle_monitor_on_down(_, #state{monitor_nodes = false}) ->
    ok;
handle_monitor_on_down(Node, #state{monitor_nodes = true,
                                    client = C}) ->
    C ! {nodedown, Node},
    case lists:member(Node, nodes()) of
        true ->
            watch_node(Node);
        false ->
            ignore
    end,
    ok.


prune_interesting(I, node, Node) ->
    [OID || {_, N} = OID <- I, N =/= Node];
prune_interesting(I, object, Object) ->
    [OID || {O, _} = OID <- I, O =/= Object].

watch_node(N) ->
    {M, F, A} =
        locks_watcher(self()),  % expanded through parse_transform
    P = spawn(N, M, F, A),
    erlang:monitor(process, P).

check_note([], _, State) ->
    State;
check_note({surrender, A}, LockID, State) when A == self() ->
    ?event({surrender_ack, LockID}),
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

request_lock({OID, Node} = _LockID, Mode, #state{client = Client} = State) ->
    ?event({request_lock, _LockID}),
    P = {?LOCKER, Node},
    erlang:monitor(process, P),
    locks_server:lock(OID, [Node], Client, Mode),
    State.

request_surrender({OID, Node} = _LockID, #state{}) ->
    ?event({request_surrender, _LockID}),
    locks_server:surrender(OID, Node).

check_if_done(S) ->
    check_if_done(S, []).

check_if_done(#state{notify = []} = S, _) ->
    S;
check_if_done(#state{} = State, Msgs) ->
    Status = all_locks_status(State),
    notify_msgs(Msgs, set_status(Status, State)).

have_all(#state{claim_no = Cl} = State) ->
    State#state{have_all = true, claim_no = Cl + 1}.

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
handle_locks(#state{agents = As} = State) ->
    InvolvedAgents = involved_agents(As),
    case analyse(InvolvedAgents, State) of
	ok ->
	    %% possible indirect deadlocks
	    %% inefficient computation, optimizes easily
	    Tell = send_indirects(State),
            if Tell =/= [] ->
                    ?event({tell, Tell});
               true ->
                    ok
            end,
	    State;
	{deadlock,ShouldSurrender,ToObject} = _DL ->
            ?event(_DL),
            case ShouldSurrender == self()
                andalso
                (proplists:get_value(
                   abort_on_deadlock, State#state.options, false)
                 andalso object_claimed(ToObject, State)) of
                true -> abort_on_deadlock(ToObject, State);
                false -> ok
            end,
	    %% throw all lock info about this resource away,
	    %%   since it will change
	    %% this can be optimized by a foldl resulting in a pair
            do_surrender(ShouldSurrender, ToObject, InvolvedAgents, State)
    end.

do_surrender(ShouldSurrender, ToObject, InvolvedAgents,
             #state{deadlocks = Deadlocks} = State) ->
    OldLock = get_lock(ToObject, State),
    State1 = delete_lock(OldLock, State),
    NewDeadlocks = [{ShouldSurrender, ToObject} | Deadlocks],
    ?event({do_surrender, [{should_surrender, ShouldSurrender},
                           {to_object, ToObject},
                           {involved_agents, lists:sort(InvolvedAgents)}]}),
    if ShouldSurrender == self() ->
            request_surrender(ToObject, State1),
            send_surrender_info(InvolvedAgents, OldLock),
            Sync1 = [OldLock | State1#state.sync],
            set_status(
              waiting,
              State1#state{sync = Sync1,
                           deadlocks = NewDeadlocks});
       true ->
            State1#state{deadlocks = NewDeadlocks}
    end.


send_indirects(#state{interesting = I, agents = As} = State) ->
    InvolvedAgents = involved_agents(As),
    Locks = [get_lock(OID, State) || OID <- I],
    [ send_lockinfo(Agent, L)
      || Agent <- compute_indirects(InvolvedAgents),
         #lock{queue = [_,_|_]} = L <- Locks,
         interesting(State, L, Agent) ].


involved_agents(As) ->
    involved_agents(ets:first(As), As).

involved_agents({A,_}, As) ->
    [A | involved_agents(ets_next(As, {A,[]}), As)];
involved_agents('$end_of_table', _) ->
    [].

send_surrender_info(Agents, #lock{object = OID, queue = Q}) ->
    [ A ! {surrendered, self(), OID}
      || A <- Agents -- [E#entry.agent || E <- flatten_queue(Q)]].

send_lockinfo(Agent, #lock{object = {OID, Node}} = L) ->
    Agent ! #locks_info{lock = L#lock{object = OID}, where = Node}.

object_claimed({Obj,_}, #state{claim_no = Cl, requests = Rs}) ->
    Requests = ets:lookup(Rs, Obj),
    any(fun(#req{claim_no = Cl1}) ->
                Cl1 < Cl
        end, Requests).

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_FromVsn, State, _Extra) ->
    {ok, State}.

%%%%%%%%%%%%%%%%%%% data manipulation %%%%%%%%%%%%%%%%%%%

-spec all_locks_status(#state{}) ->
                              no_locks
                                  | waiting
                                  | {have_all_locks, deadlocks()}
                                  | {cannot_serve, list()}.
%%
all_locks_status(#state{pending = Pend, locks = Locks} = State) ->
    Status = all_locks_status_(State),
    ?event({locks_diagnostics,
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

lock_holder([#w{entries = [#entry{agent = A}]}|_]) ->
    A;
lock_holder([#r{entries = Es}|_]) ->
    [A || #entry{agent = A} <- Es].


all_locks_status_(#state{locks = Locks, pending = Pend} = State) ->
    case ets:info(Locks, size) of
        0 ->
            case ets:info(Pend, size) of
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


%% a lock is outdated if the version number is too old,
%%   i.e. if one of the already received locks is newer
%%
-spec outdated([#lock{}], #lock{}) -> boolean().
outdated([], _) -> false;
outdated([#lock{version = V1}], #lock{version = V2}) ->
    V1 >= V2.

-spec waiting_for_ack(#state{}, {_,_}) -> boolean().
waiting_for_ack(#state{sync = Sync}, LockID) ->
    lists:member(LockID, Sync).

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

requests_with_node(Node, R) ->
    ets:foldl(
      fun(#req{nodes = Ns} = Req, Acc) ->
              case lists:member(Node, Ns) of
                  true -> [Req|Acc];
                  false -> Acc
              end
      end, [], R).

move_requests([R|Rs], From, To) ->
    ets_delete_object(From, R),
    ets_insert(To, R),
    move_requests(Rs, From, To);
move_requests([], _, _) ->
    ok.


have_locks(Obj, #state{agents = As}) ->
    %% We need to use {element,1,{element,2,{element,1,'$_'}}} in the body,
    %% since Obj may not be a legal output pattern (e.g. [a, {x,1}]).
    ets_select(As, [{ {{self(),{Obj,'$1'}}}, [],
                      [{{{element,1,
                          {element,2,
                           {element,1,'$_'}}},'$1'}}] }]).
%% have_locks([#lock{object = Obj,
%%                   queue = [#w{entries = [#entry{agent = A}]}|_]}|T])
%%            when A == self() ->
%%     [{Obj, write} | have_locks(T)];
%% have_locks([#lock{object = Obj, queue = [#r{entries = Es}|_]}|T]) ->
%%     case lists:keymember(self(), #entry.agent, Es) of
%%         true  -> [{Obj, read} | have_locks(T)];
%%         false -> have_locks(T)
%%     end;
%% have_locks([_|T]) ->
%%     have_locks(T);
%% have_locks([]) ->
%%     [].



l_mode(#lock{queue = [#r{}|_]}) -> read;
l_mode(#lock{queue = [#w{}|_]}) -> write.

l_covers(read, write) -> true;
l_covers(M   , M    ) -> true;
l_covers(_   , _    ) -> false.

%% l_on_node(O, N, write, HaveLocks) ->
%%     lists:member({{O,N},write}, HaveLocks);
%% l_on_node(O, N, read, HaveLocks) ->
%%     lists:member({{O,N},read}, HaveLocks)
%%         orelse lists:member({{O,N},write}, HaveLocks).


i_add_lock(#state{locks = Ls, sync = Sync} = State,
           #lock{object = Obj} = Lock, Prev) ->
    store_lock_holders(Prev, Lock, State),
    ets_insert(Ls, Lock),
    log_interesting(
      Prev, Lock,
      State#state{sync = lists:keydelete(Obj, #lock.object, Sync)}).

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

delete_lock(#lock{object = OID, queue = Q} = L,
            #state{locks = Ls, agents = As, interesting = I} = S) ->
    ?event({delete_lock, L}),
    LockHolders = lock_holders(L),
    ets_delete(Ls, OID),
    [ets_delete(As, {A,OID}) || A <- LockHolders],
    case Q of
        [_,_|_] ->
            S#state{interesting = I -- [OID]};
        _ ->
            S
    end.

ets_new(T, Opts)        -> ets:new(T, Opts).
ets_insert(T, Obj)      -> ets:insert(T, Obj).
ets_lookup(T, K)        -> ets:lookup(T, K).
ets_delete(T, K)        -> ets:delete(T, K).
ets_delete_object(T, O) -> ets:delete_object(T, O).
ets_match_delete(T, P)  -> ets:match_delete(T, P).
ets_select(T, P)        -> ets:select(T, P).
ets_next(T, K)          -> ets:next(T, K).
%% ets_select(T, P, L)     -> ets:select(T, P, L).


lock_holders(#lock{queue = [#r{entries = Es}|_]}) ->
    [A || #entry{agent = A} <- Es];
lock_holders(#lock{queue = [#w{entries = Es}|_]}) ->
    [A || #entry{agent = A} <- Es].

log_interesting(Prev, #lock{object = OID, queue = Q},
                #state{interesting = I} = S) ->
    %% is interesting?
    case Q of
        [_,_|_] ->
            case Prev of
                [#lock{queue = [_,_|_]}] ->
                    S;
                _ -> S#state{interesting = [OID|I]}
            end;
        _ ->
            case Prev of
                [#lock{queue = [_,_|_]}] ->
                    S#state{interesting = I -- [OID]};
                _ ->
                    S
            end
    end.

nodes_locked(OID, M, #state{} = S) ->
    [N || {_, N} = Obj <- have_locks(OID, S),
          l_covers(M, l_mode( get_lock(Obj,S) ))].

-spec compute_indirects([agent()]) -> [agent()].
compute_indirects(InvolvedAgents) ->
    [ A || A<-InvolvedAgents, A>self()].
%% here we impose a global
%% ordering on pids !!
%% Alternatively, we send to
%% all pids

%% -spec has_a_lock([#lock{}], pid()) -> boolean().
%% has_a_lock(Locks, Agent) ->
%%     is_member(Agent, [hd(L#lock.queue) || L<-Locks]).
has_a_lock(As, Agent) ->
    case ets_next(As, {Agent,0}) of   % Lock IDs are {LockName,Node} tuples
        {Agent,_} -> true;
        _ -> false
    end.

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

%% uniq([_] = L) -> L;
%% uniq(L)       -> ordsets:from_list(L).

get_locks([H|T], Ls) ->
    [L] = ets_lookup(Ls, H),
    [L | get_locks(T, Ls)];
get_locks([], _) ->
    [].

get_lock(OID, #state{locks = Ls}) ->
    [L] = ets_lookup(Ls, OID),
    L.

%% analyse computes whether a local deadlock can be detected,
%% if not, 'ok' is returned, otherwise it returns the triple
%% {deadlock,ToSurrender,ToObject} stating which agent should
%% surrender which object.
%%
analyse(_Agents, #state{interesting = I, locks = Ls}) ->
    Locks = get_locks(I, Ls),
    Nodes =
	expand_agents([ {hd(L#lock.queue), L#lock.object} ||
                          L <- Locks]),
    Connect =
	fun({A1, O1}, {A2, _}) ->
		lists:any(
		  fun(#lock{object = Obj, queue = Queue}) ->
                          (O1==Obj)
                              andalso A1 =/= A2
                              andalso in(A1, hd(Queue))
			      andalso in_tail(A2, tl(Queue))
		  end, Locks)
	end,
    ?event({connect, Connect}),
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

event(_Line, _Event, _State) ->
    ok.
