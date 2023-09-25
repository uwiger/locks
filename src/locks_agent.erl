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
         async_await_all_locks/1,
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

-include("locks_agent.hrl").

-ifdef(DEBUG).
-define(dbg(Fmt, Args), io:fwrite(user, Fmt, Args)).
-else.
-define(dbg(F, A), ok).
-endif.

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
                error:Error:ST ->
                    error_logger:error_report(
                      [{?MODULE, aborted},
                       {reason, Error},
                       {trace, ST}]),
                    error(Error)
            end
        %% Other ->
        %%     ack(Wait, Client, {error, Other}),
        %%     error(Other)
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
            St2 = next_msg(St1),
            loop(maybe_status_change(OldStatus, St2))
    end.

next_msg(St) ->
    receive
        Msg ->
            St1 = handle_msg(Msg, St),
            next_msg(St1)
    after 0 ->
            maybe_check_if_done(St)
    end.

handle_msg({'$gen_call', From, Req}, St) ->
    case handle_call(Req, From, maybe_check_if_done(St)) of
        {reply, Reply, St1} ->
            gen_server:reply(From, Reply),
            St1;
        {noreply, St1} ->
            St1;
        {stop, Reason, Reply, _} ->
            gen_server:reply(From, Reply),
            exit(Reason)
        %% {stop, Reason, _} ->
        %%     exit(Reason)
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

async_await_all_locks(Agent) ->
    cast(Agent, {await_all_locks, self()}).

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

cast(Agent, Msg) ->
    gen_server:cast(Agent, Msg).

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
                 true -> [Client];
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
handle_call(await_all_locks, {Client, Tag},
            #state{status = Status, awaiting_all = Aw} = State) ->
    case Status of
        {have_all_locks, _} ->
            {noreply, notify_have_all(
                        State#state{awaiting_all = [{Client, Tag}|Aw]})};
        _ ->
            {noreply, check_if_done(add_waiter(wait, Client, Tag, State))}
    end;
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
handle_cast({await_all_locks, Pid},
            #state{status = Status, awaiting_all = Aw} = State) ->
    case Status of
        {have_all_locks, _} ->
            {noreply, notify_have_all(
                        State#state{awaiting_all = [{Pid,async}|Aw]})};
        _ ->
            {noreply, check_if_done(add_waiter(wait, Pid, async, State))}
    end;
handle_cast({surrender, O, ToAgent, Nodes} = _Req, S) ->
    ?event(_Req, S),
    case lists:all(
           fun(N) ->
                   #lock{queue = Q} = L = get_lock({O,N}, S),
                   lists:member(self(), lock_holders(L))
                       andalso locks_agent_lib:in_tail(ToAgent, tl(Q))
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
                         S1a#state{notify = list_store(C, Notify)};
                     false ->
                         S#state{notify = S#state.notify -- [C]}
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

matching_request(Object, Mode, Nodes, Require, S) ->
    locks_agent_lib:matching_request(Object, Mode, Nodes, Require, S).

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

%% @private
handle_info(#locks_info{lock = Lock0, where = Node, note = Note} = I, S0) ->
    ?event({handle_info, I}, S0),
    LockID = {Lock0#lock.object, Node},
    V = Lock0#lock.version,
    Lock = Lock0#lock{object = LockID},
    Prev = ets_lookup(S0#state.locks, LockID),
    State = gc_sync(LockID, V, check_note(Note, LockID, S0)),
    case outdated(Prev, Lock) of
	true ->
            ?event({outdated, [LockID]}),
	    {noreply,State};
	false ->
	    NewState = i_add_lock(State, Lock, Prev),
            {noreply, handle_locks(check_if_done(NewState, [I]))}
    end;
handle_info({surrendered, A, OID, _V} = _Msg, State) ->
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
                    move_requests(R, Reqs, Pending),
                    S2 = lists:foldl(
                           fun(#req{object = Obj, mode = Mode}, Sx) ->
                                   request_lock({Obj,N}, Mode, Sx)
                           end, ensure_monitor(N, S1), Reissue),
                    {noreply, check_if_done(S2)}
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
add_waiter(wait, Client, Tag, #state{awaiting_all = Aw} = State) ->
    State#state{awaiting_all = [{Client, Tag} | Aw]}.

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

request_can_be_served(R, S) ->
    locks_agent_lib:request_can_be_served(R, S).

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

prune_interesting(I, Type, Node) ->
    locks_agent_lib:prune_interesting(I, Type, Node).

watch_node(N) ->
    {M, F, A} =
        locks_watcher(self()),  % expanded through parse_transform
    P = spawn(N, M, F, A),
    erlang:monitor(process, P).

check_note({surrender, A, V}, LockID, State) when A == self() ->
    ?event({surrender_ack, LockID, V}),
    State;
check_note({surrender, A, _V}, LockID, State) ->
    note_deadlock(A, LockID, State);
check_note(_, _, State) ->
    State.

gc_sync(LockID, V, #state{sync = Sync} = State) ->
    Sync1 = [L || #lock{object = Ox, version = Vx} = L <- Sync,
                  Ox =/= LockID, Vx =< V],
    State#state{sync = Sync1}.

note_deadlock(A, LockID, #state{deadlocks = Deadlocks} = State) ->
    Entry = {A, LockID},
    case member(Entry, Deadlocks) of
        false ->
            State#state{deadlocks = [Entry|Deadlocks]};
        true ->
            State
    end.

ensure_monitor(Node, S) ->
    locks_agent_lib:ensure_monitor(Node, S).

request_lock(LockId, Mode, S) ->
    locks_agent_lib:request_lock(LockId, Mode, S).

request_surrender({OID, Node} = _LockID, Vsn, #state{}) ->
    ?event({request_surrender, _LockID, Vsn}),
    locks_server:surrender(OID, Node, Vsn).

check_if_done(#state{check = {true,_}} = S) ->
    S;
check_if_done(#state{check = false} = S) ->
    S#state{check = {true, []}}.

check_if_done(#state{check = {true, Msgs}} = S, Msgs1) ->
    S#state{check = {true, add_msgs(Msgs1, Msgs)}};
check_if_done(#state{check = false} = S, Msgs) ->
    S#state{check = {true, Msgs}}.

add_msgs(Msgs, OldMsgs) ->
    locks_agent_lib:add_msgs(Msgs, OldMsgs).

maybe_check_if_done(#state{check = {true, Msgs}} = S) ->
    maybe_handle_locks(do_check_if_done(S#state{check = false}, Msgs));
maybe_check_if_done(S) ->
    S.

do_check_if_done(#state{} = State, Msgs) ->
    Status = all_locks_status(State),
    notify_msgs(Msgs, set_status(Status, State)).

have_all(#state{have_all = Prev, claim_no = Cl} = State) ->
    Cl1 = case Prev of
              true -> Cl;
              false -> Cl + 1
          end,
    notify_have_all(State#state{have_all = true, claim_no = Cl1}).

notify_have_all(#state{awaiting_all = Aw, status = Status} = S) ->
    [reply_await_(W, Status) || W <- Aw],
    S#state{awaiting_all = []}.

%% reply_await_({Pid, notify}, Status) ->
%%     notify_(Pid, Status);
reply_await_({Pid, async}, Status) ->
    notify_(Pid, Status);
reply_await_(From, Status) ->
    gen_server:reply(From, Status).

abort_on_deadlock(OID, State) ->
    notify({abort, Reason = {deadlock, OID}}, State),
    error(Reason).

notify_msgs([M|Ms], S) ->
    S1 = notify_msgs(Ms, S),
    notify(M, S1);
notify_msgs([], S) ->
    S.

notify(Msg, #state{notify = Notify} = State) ->
    [notify_(P, Msg) || P <- Notify],
    State.

notify_(P, Msg) ->
    P ! {?MODULE, self(), Msg}.

handle_locks(S) ->
    S#state{handle_locks = true}.

maybe_handle_locks(#state{handle_locks = true} = S) ->
    do_handle_locks(S#state{handle_locks = false});
maybe_handle_locks(S) ->
    S.

do_handle_locks(#state{have_all = true} = State) ->
    %% If we have all locks we've asked for, no need to search for potential
    %% deadlocks - reasonably, we cannot be involved in one.
    State;
do_handle_locks(#state{agents = As} = State) ->
    InvolvedAgents = involved_agents(As),
    case analyse(State) of
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

do_surrender(ShouldSurrender, ToObject, InvolvedAgents, State) ->
    OldLock = get_lock(ToObject, State),
    State1 = delete_lock(OldLock, State),
    %% NewDeadlocks = [{ShouldSurrender, ToObject} | Deadlocks],
    ?costly_event({do_surrender,
                   [{should_surrender, ShouldSurrender},
                    {to_object, ToObject},
                    {involved_agents, lists:sort(InvolvedAgents)}]}),
    State2 = note_deadlock(ShouldSurrender, ToObject, State1),
    if ShouldSurrender == self() ->
            request_surrender(ToObject, OldLock#lock.version, State1),
            send_surrender_info(InvolvedAgents, OldLock),
            Sync1 = [OldLock | State1#state.sync],
            set_status(
              waiting,
              State2#state{sync = Sync1});
       true ->
            State2
    end.

send_indirects(S) ->
    locks_agent_lib:send_indirects(S).

involved_agents(As) ->
    locks_agent_lib:involved_agents(As).

send_surrender_info(Agents, #lock{object = OID, version = V, queue = Q}) ->
    [ A ! {surrendered, self(), OID, V}
      || A <- Agents -- [E#entry.agent || E <- flatten_queue(Q)]].

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

all_locks_status(S) ->
    locks_agent_lib:all_locks_status(S).

%% a lock is outdated if the version number is too old,
%%   i.e. if one of the already received locks is newer
%%
-spec outdated([#lock{}], #lock{}) -> boolean().
outdated([], _) -> false;
outdated([#lock{version = V1}], #lock{version = V2}) ->
    V1 >= V2.

%% -spec waiting_for_ack(#state{}, {_,_}, integer()) -> boolean().
%% waiting_for_ack(#state{sync = Sync}, {OID, Node}, V) ->
%%     [] =/= [L || #lock{object = OIDx, where = Nx, version = Vx} = L <- Sync,
%%                  OID =:= OIDx, Nx =:= Node, Vx >= V].

requests_with_node(Node, R) ->
    ets:foldl(
      fun(#req{nodes = Ns} = Req, Acc) ->
              case lists:member(Node, Ns) of
                  true -> [Req|Acc];
                  false -> Acc
              end
      end, [], R).

move_requests(Rs, From, To) ->
    locks_agent_lib:move_requests(Rs, From, To).

i_add_lock(#state{locks = Ls, sync = Sync} = State,
           #lock{object = Obj} = Lock, Prev) ->
    store_lock_holders(Prev, Lock, State),
    ets_insert(Ls, Lock),
    log_interesting(
      Prev, Lock,
      State#state{sync = lists:keydelete(Obj, #lock.object, Sync)}).

store_lock_holders(Prev, Lock, State) ->
    locks_agent_lib:store_lock_holders(Prev, Lock, State).

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
ets_match_delete(T, P)  -> ets:match_delete(T, P).

lock_holders(Lock) ->
    locks_agent_lib:lock_holders(Lock).

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

analyse(#state{interesting = I, locks = Ls}) ->
    Locks = get_locks(I, Ls),
    locks_agent_lib:analyse(Locks).

get_locks([H|T], Ls) ->
    [L] = ets_lookup(Ls, H),
    [L | get_locks(T, Ls)];
get_locks([], _) ->
    [].

get_lock(OID, S) ->
    locks_agent_lib:get_lock(OID, S).
