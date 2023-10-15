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
%% @doc Leader election behavior
%%
%% This behavior is inspired by gen_leader, and offers the same API
%% except for a few details. The leader election strategy is based on
%% the `locks' library. The leader election group is identified by the
%% lock used - by default, `[locks_leader, CallbackModule]', but configurable
%% using the option `{resource, Resource}', in which case the lock name will
%% be `[locks_leader, Resource]'. The lock corresponding to the leader group
%% will in the following description be referred to as The Lock.
%%
%% Each instance is started either as a 'candidate' or a 'worker'.
%% Candidates all try to claim a write lock on The Lock, and workers merely
%% monitor it. All candidates and workers will find each other through the
%% `#locks_info{}' messages. This means that, unlike gen_leader, the
%% locks_leader dynamically adopts new nodes, candidates and workers. It is
%% also possible to have multiple candidates and workers on the same node.
%%
%% The candidate that is able to claim The Lock becomes the leader.
%% <pre>Leader instance:
%%    Mod:elected(ModState, Info, undefined) -&gt; {ok, Sync, ModState1}.
%%
%% Other instances:
%%    Mod:surrendered(ModState, Sync, Info) -> {ok, ModState1}.
%% </pre>
%%
%% If a candidate or worker joins the group, the same function is called,
%% but with the Pid of the new member as third argument. It can then
%% return either `{reply, Sync, ModState1}', in which case only the new
%% member will get the Sync message, or `{ok, Sync, ModState1}', in which case
%% all group members will be notified.
%%
%% <h2>Split brain</h2>
%%
%% The `locks_leader' behavior will automatically heal from netsplits and
%% ensure that there is only one leader. A candidate that was the leader but
%% is forced to surrender, can detect this e.g. by noting in its own state
%% when it becomes leader:
%% <pre lang="erlang">
%% surrendered(#state{is_leader = true} = S, Sync, _Info) -&gt;
%%     %% I was leader; a netsplit has occurred
%%     {ok, surrendered_after_netsplit(S, Sync, Info)};
%% surrendered(S, Sync, _Info) -&gt;
%%     {ok, normal_surrender(S, Sync, Info)}.
%% </pre>
%%
%% The newly elected candidate normally doesn't know that a split-brain
%% has occurred, but can sync with other candidates using e.g. the function
%% {@link ask_candidates/2}, which functions rather like a parallel
%% `gen_server:call/2'.
%% @end
-module(locks_leader).
-behaviour(gen_server).

-export([start_link/2, start_link/3, start_link/4,
	 call/2, call/3,
	 cast/2,
	 leader_call/2,
	 leader_call/3,
         leader_reply/2,
	 leader_cast/2,
         info/1, info/2]).

-export([init/1,
	 handle_info/2,
	 handle_cast/2,
	 handle_call/3,
	 terminate/2,
	 code_change/3]).

-export([candidates/1,
         new_candidates/1,
	 workers/1,
	 leader/1,
         leader_node/1]).

-export([reply/2,
         broadcast/2,
         broadcast_to_candidates/2,
         ask_candidates/2]).

-export([record_fields/1]).

-export_type([mod_state/0, msg/0, election/0]).

-type ldr_option() :: {role, candidate | worker}
                    | {resource, any()}.
-type ldr_options() :: [ldr_option()].
-type mod_state() :: any().
-type msg() :: any().
-type reply() :: any().
-type from() :: {pid(), _Tag :: any()}.
-type reason() :: any().
-type server_ref() :: atom() | {atom(), node()} | {global, term()} | {via, module(), term()} | pid().
-type cb_return() ::
	{ok, mod_state()}
      | {ok, msg(), mod_state()}
      | {stop, reason, mod_state()}.
-type cb_reply() ::
	{reply, reply(), mod_state()}
      | {reply, reply(), msg(), mod_state()}
      | {noreply, mod_state()}
      | {stop, reason(), mod_state()}.


-record(st, {
	  role = candidate,
	  %% mode = dynamic,
	  initial = true,
	  lock,
          vector,
	  agent,
	  leader,
          election_ref,
	  nodes = ordsets:new(),
          pg_mref :: reference() | undefined,
	  candidates = [],
	  workers = [],
          synced = [],
          synced_workers = [],
	  gen_server_opts = [],
	  regname,
	  mod,
	  mod_state,
	  buffered = []}).

-include("locks.hrl").
-include("locks_debug.hrl").

-ifdef(LOCKS_DEBUG).
-define(log(X, S), dbg_log(X, S)).
-else.
-define(log(X, S), ?event(X, S)).
-endif.

-define(event(E), event(?LINE, E, none)).
-define(event(E, S), event(?LINE, E, S)).

-opaque election() :: #st{}.

-callback init(any()) -> mod_state().
-callback elected(mod_state(), election(), undefined | pid()) ->
    cb_return() | {reply, msg(), mod_state()}.
-callback surrendered(mod_state(), msg(), election()) -> cb_return().
-callback handle_DOWN(pid(), mod_state(), election()) -> cb_return().
-callback handle_leader_call(msg(), from(), mod_state(), election()) ->
    cb_reply().
-callback handle_leader_cast(msg(), mod_state(), election()) -> cb_return().
-callback from_leader(msg(), mod_state(), election()) -> cb_return().
-callback handle_call(msg(), from(), mod_state(), election()) -> cb_reply().
-callback handle_cast(msg(), mod_state(), election()) -> cb_return().
-callback handle_info(msg(), mod_state(), election()) -> cb_return().

record_fields(st        ) -> record_info(fields, st);
record_fields(lock      ) -> record_info(fields, lock);
record_fields(entry     ) -> record_info(fields, entry);
record_fields(w         ) -> record_info(fields, w);
record_fields(r         ) -> record_info(fields, r);
record_fields(locks_info) -> record_info(fields, locks_info);
record_fields(_) ->
    no.

-spec candidates(election()) -> [pid()].
%% @doc Return the current list of candidates.
%% @end
candidates(#st{candidates = C}) ->
    C.

-spec new_candidates(election()) -> [pid()].
%% @doc Return the current list of candidates that have not yet been synced.
%%
%% This function is mainly indented to be used from within `Mod:elected/3',
%% once a leader has been elected. One possible use is to contact the
%% new candidates to see whether one of them was a leader, which could
%% be the case if the candidates appeared after a healed netsplit.
%% @end
new_candidates(#st{candidates = C, synced = S} = St) ->
    ?event({new_candidates, St}),
    C -- S.

-spec workers(election()) -> [pid()].
%% @doc Return the current list of workers.
%% @end
workers(#st{workers = W}) ->
    W.

-spec leader(election()) -> pid() | undefined.
%% @doc Return the leader pid, or `undefined' if there is no current leader.
%% @end
leader(#st{leader = L}) ->
    L.

-spec leader_node(election()) -> node().
%% @doc Return the node of the current leader.
%%
%% This function is mainly present for compatibility with `gen_leader'.
%% @end
leader_node(#st{leader = L}) when is_pid(L) ->
    node(L);
leader_node(#st{}) ->
    undefined.

-spec reply({pid(), any()}, any()) -> ok.
%% @doc Corresponds to `gen_server:reply/2'.
%%
%% Callback modules should use this function instead in order to be future
%% safe.
%% @end
reply(From, Reply) ->
    ?log({'$reply', From, Reply}),
    gen_server:reply(From, Reply).

-spec broadcast(any(), election()) -> ok.
%% @doc Broadcast `Msg' to all candidates and workers.
%%
%% This function may only be called from the current leader.
%%
%% The message will be processed in the `Mod:from_leader/3' callback.
%% Note: You should not use this function from the `Mod:elected/3' function,
%% since it may cause sequencing issues with the broadcast message that is
%% (normally) sent once the `Mod:elected/3' function returns.
%% @end
broadcast(Msg, #st{leader = L} = S) when L == self() ->
    _ = do_broadcast(S, Msg),
    ok;
broadcast(_, _) ->
    error(not_leader).

-spec broadcast_to_candidates(any(), election()) -> ok.
%% @doc Broadcast `Msg' to all (synced) candidates.
%%
%% This function may only be called from the current leader.
%%
%% The message will be processed in the `Mod:from_leader/3' callback.
%% Note: You should not use this function from the `Mod:elected/3' function,
%% since it may cause sequencing issues with the broadcast message that is
%% (normally) sent once the `Mod:elected/3' function returns.
%% @end
broadcast_to_candidates(Msg, #st{leader = L, synced = Cands,
                                 election_ref = ERef})
  when L == self() ->
    do_broadcast_(Cands, msg(from_leader, ERef, Msg));
broadcast_to_candidates(_, _) ->
    error(not_leader).

%% ==

-spec ask_candidates(any(), election()) ->
                            {GoodReplies, Errors}
                                when GoodReplies :: [{pid(), any()}],
                                     Errors      :: [{pid(), any()}].
%% @doc Send a synchronous request to all candidates.
%%
%% The request `Req' will be processed in `Mod:handle_call/4' and can be
%% handled as any other request. The return value separates the good replies
%% from the failed (the candidate died or couldn't be reached).
%% @end
ask_candidates(Req, #st{candidates = Cands}) ->
    Requests =
        lists:map(
          fun(C) ->
                  MRef = erlang:monitor(process, C),
                  C ! {'$gen_call', {self(), {?MODULE, MRef}}, Req},
                  {C, MRef}
          end, Cands),
    Replies = collect_replies(Requests),
    partition(Replies).

collect_replies([{Pid, MRef}|Reqs] = _L) ->
    receive
        {{?MODULE, MRef}, Reply} ->
            erlang:demonitor(MRef, [flush]),
            [{Pid, true, Reply} | collect_replies(Reqs)];
        {'DOWN', MRef, _, _, Reason} ->
            [{Pid, false, Reason} | collect_replies(Reqs)]
    after 1000 ->
            erlang:demonitor(MRef, [flush]),
            [{Pid, false, timeout} | collect_replies(Reqs)]
    end;
collect_replies([]) ->
    [].

partition(L) ->
    partition(L, [], []).

partition([{P,Bool,R}|L], True, False) ->
    if Bool -> partition(L, [{P,R}|True], False);
       true -> partition(L, True, [{P,R}|False])
    end;
partition([], True, False) ->
    {lists:reverse(True), lists:reverse(False)}.

%% ==

-spec start_link(Module::atom(), St::any()) -> {ok, pid()}.
%% @doc Starts an anonymous locks_leader candidate using `Module' as callback.
%%
%% The leader candidate will sync with all candidates using the same
%% callback module, on all connected nodes.
%% @end
start_link(Module, St) ->
    start_link(Module, St, []).

-spec start_link(Module::atom(), St::any(), ldr_options()) -> {ok, pid()}.
%% @doc Starts an anonymous worker or candidate.
%%
%% The following options are supported:
%%
%% * `{role, candidate | worker}' - A candidate is able to take on the
%% leader role, if elected; a worker simply follows the elections and
%% receives broadcasts from the leader.
%%
%% * `{resource, Resource}' - The name of the lock used for the election
%% is normally `[locks_leader, Module]', but with this option, it can be
%% changed into `[locks_leader, Resource]'. Note that, under the rules of
%% the locks application, a lock name must be a list.
%% @end
start_link(Module, St, Options) ->
    proc_lib:start_link(?MODULE, init, [{Module, St, Options, self()}]).

-spec start_link(Reg::atom(), Module::atom(), St::any(), ldr_options()) ->
                        {ok, pid()}.
%% @doc Starts a locally registered worker or candidate.
%%
%% Note that only one registered instance of the same name (using the
%% built-in process registry) can exist on a given node. However, it is
%% still possible to have multiple instances of the same election group
%% on the same node, either anonymous, or registered under different names.
%%
%% For a description of the options, see {@link start_link/3}.
%%@end
start_link(Reg, Module, St, Options) when is_atom(Reg), is_atom(Module) ->
    proc_lib:start_link(?MODULE, init, [{Reg, Module, St, Options, self()}]).

-spec leader_call(Name::server_ref(), Request::term()) -> term().
%% @doc Make a synchronous call to the leader.
%%
%% This function is similar to `gen_server:call/2', but is forwarded to
%% the leader by the leader candidate `L' (unless, of course, it is the
%% leader, in which case it handles it directly). If the leader should die
%% before responding, this function will raise an `error({leader_died,...})'
%% exception.
%% @end
leader_call(L, Request) ->
    case catch gen_server:call(L, {'$locks_leader_call', Request}) of
	{'$locks_leader_reply',Res} = _R ->
	    ?event({leader_call_return, L, Request, _R}),
	    Res;
	'$leader_died' = _R ->
	    ?event({leader_call_return, L, Request, _R}),
	    error({leader_died, {?MODULE, leader_call, [L, Request]}});
	{'EXIT',Reason} = _R ->
	    ?event({leader_call_return, L, Request, _R}),
	    error({Reason, {?MODULE, leader_call, [L, Request]}})
    end.

-spec leader_call(Name::server_ref(), Request::term(), integer()|infinity) -> term().
%% @doc Make a timeout-guarded synchronous call to the leader.
%%
%% This function is similar to `gen_server:call/3', but is forwarded to
%% the leader by the leader candidate `L' (unless, of course, it is the
%% leader, in which case it handles it directly). If the leader should die
%% before responding, this function will raise an `error({leader_died,...})'
%% exception.
%% @end
leader_call(L, Request, Timeout) ->
    case catch gen_server:call(L, {'$locks_leader_call', Request}, Timeout) of
	{'$locks_leader_reply',Res} = _R ->
	    ?event({leader_call_return, L, Request, _R}),
	    Res;
	'$leader_died' = _R ->
	    ?event({leader_call_return, L, Request, _R}),
	    error({leader_died, {?MODULE, leader_call, [L, Request]}});
	{'EXIT',Reason} = _R ->
	    ?event({leader_call_return, L, Request, _R}),
	    error({Reason, {?MODULE, leader_call, [L, Request]}})
    end.

leader_reply(From, Reply) ->
    reply(From, {'$locks_leader_reply', Reply}).

-spec leader_cast(L::server_ref(), Msg::term()) -> ok.
%% @doc Make an asynchronous cast to the leader.
%%
%% This function is similar to `gen_server:cast/2', but is forwarded to
%% the leader by the leader candidate `L' (unless, of course, it is the
%% leader, in which case it handles it directly). No guarantee is given
%% that the cast actually reaches the leader (i.e. if the leader dies, no
%% attempt is made to resend to the next elected leader).
%% @end
leader_cast(L, Msg) ->
    ?event({leader_cast, L, Msg}),
    gen_server:cast(L, {'$locks_leader_cast', Msg}).

info(L) ->
    ?event({info, L}),
    R = gen_server:call(L, '$locks_leader_info'),
    ?event({info_return, L, R}),
    R.

info(L, Item) ->
    ?event({info, L, Item}),
    R = gen_server:call(L, {'$locks_leader_info', Item}),
    ?event({info_return, L, Item, R}),
    R.

-spec call(L::server_ref(), Request::any()) -> any().
%% @doc Make a `gen_server'-like call to the leader candidate `L'.
%% @end
call(L, Req) ->
    R = gen_server:call(L, Req),
    ?event({call_return, L, Req, R}),
    R.

-spec call(L::server_ref(), Request::any(), integer()|infinity) -> any().
%% @doc Make a timeout-guarded `gen_server'-like call to the leader
%% candidate `L'.
%% @end
call(L, Req, Timeout) ->
    R = gen_server:call(L, Req, Timeout),
    ?event({call_return, L, Req, Timeout, R}),
    R.

-spec cast(L::server_ref(), Msg::any()) -> ok.
%% @doc Make a `gen_server'-like cast to the leader candidate `L'.
%% @end
cast(L, Msg) ->
    ?event({cast, L, Msg}),
    gen_server:cast(L, Msg).

%% @private
init({Reg, Module, St, Options, P}) ->
    register(Reg, self()),
    init_(Module, St, Options, P, Reg);
init({Module, St, Options, P}) ->
    case lists:keyfind(registered_name, 1, Options) of
        {_, Reg} -> register(Reg, self());
        false    -> ok
    end,
    init_(Module, St, Options, P, undefined).

init_(Module, ModSt0, Options, Parent, Reg) ->
    S0 = #st{},
    %% Mode = get_opt(mode, Options, S0#st.mode),
    Role = get_opt(role, Options, S0#st.role),
    Lock = [?MODULE, get_opt(resource, Options,
                             default_lock(Module, Reg))],
    ModSt = try Module:init(ModSt0) of
		{ok, MSt} -> MSt;
		{error, Reason} ->
		    abort_init(Reason, Parent)
            catch
                error:Error:ST ->
		    abort_init({Error, ST}, Parent)
	    end,
    AllNodes = ordsets:from_list([node()|nodes()]),
    Agent =
	case Role of
	    candidate ->
		{ok, A} = locks_agent:start([{notify,true},
                                             {await_nodes, true},
                                             {monitor_nodes, true}]),
		locks_agent:lock_nowait(
		  A, Lock, write, AllNodes, all_alive),
		A;
	    worker ->
		%% watch our own local lock. All candidates will try for it.
		locks_server:watch(Lock, [node()]),
		undefined
	end,
    PgGroup = {?MODULE, Lock},
    {MRef, _} = locks_pg:monitor(PgGroup),
    locks_pg:join(PgGroup, [self()]),
    proc_lib:init_ack(Parent, {ok, self()}),
    S1 = #st{agent = Agent,
             role = Role,
             mod = Module,
             mod_state = ModSt,
             lock = Lock,
             pg_mref = MRef,
             %% mode = Mode,
             nodes = AllNodes,
             regname = Reg},
    case safe_loop(S1) of
	{stop, StopReason, _} ->
	    error(StopReason);
	_ ->
	    {ok, S1}  % we should never get here, but it makes dialyzer happy
    end.

default_lock(Mod, undefined) -> Mod;
default_lock(Mod, Regname)   -> {Mod, Regname}.


abort_init(Reason, Parent) ->
    proc_lib:init_ack(Parent, {error, Reason}),
    exit(Reason).

noreply(#st{leader = undefined} = S) ->
    put('$locks_leader_state', S),
    safe_loop(S);
noreply(#st{initial = false} = S) ->
    put('$locks_leader_state', S),
    {noreply, S};
noreply(#st{initial = true, regname = R, gen_server_opts = Opts} = S) ->
    %% The very first time we're out of the safe_loop() we have to
    %% *become* a gen_server (since we started using only proc_lib).
    %% Set initial = false to ensure it only happens once.
    S1 = S#st{initial = false},
    put('$locks_leader_state', S1),
    if R == undefined -> gen_server:enter_loop(?MODULE, Opts, S1);
       true           -> gen_server:enter_loop(?MODULE, Opts, S1, {local,R})
    end;
noreply(Stop) when element(1, Stop) == stop ->
    Stop.


%% We enter safe_loop/1 as soon as no leader is elected
safe_loop(#st{agent = A} = S) ->
    receive
	{nodeup, N} = Msg ->
            ?log(Msg, S),
	    ?event({nodeup, N, nodes()}, S),
	    noreply(nodeup(N, S));
        {MRef, join, {?MODULE, Rsrc}, Pids} = Msg
          when MRef == S#st.pg_mref, Rsrc == S#st.lock ->
            ?log(Msg, S),
            ?event({joined, Pids}, S),
            noreply(joined(Pids, S));
	{locks_agent, A, Info} = _Msg ->
            ?log(_Msg),
	    ?event(_Msg, S),
	    case Info of
                #locks_info{} ->
                    noreply(locks_info(Info, S));
                {have_all_locks, _} ->
                    noreply(become_leader(S));
                OtherInfo ->
                    ?event(OtherInfo, S),
                    noreply(S)
	    end;
	#locks_info{} = I ->   % if worker - direct from locks_server
            ?log(I, S),
	    ?event(I, S),
	    noreply(locks_info(I, S));
	{?MODULE, am_leader, L, ERef, LeaderMsg} = _Msg ->
            ?log(_Msg, S),
	    ?event(_Msg, S),
	    noreply(leader_announced(L, ERef, LeaderMsg, S));
        {?MODULE, from_leader, L, ERef, LeaderMsg} = _Msg ->
            ?log(_Msg, S),
            ?event(_Msg, S),
            noreply(from_leader(L, ERef, LeaderMsg, S));
	{?MODULE, am_worker, W} = _Msg ->
            ?log(_Msg, S),
	    ?event(_Msg, S),
	    noreply(worker_announced(W, S));
        {?MODULE, leader_uncertain, _L, _Synced, _SyncedWs} = _Msg ->
            ?log(_Msg, S),
            ?event(_Msg, S),
            noreply(S);
        {?MODULE, affirm_leader, L, Ref} = _Msg ->
            ?log(_Msg, S),
            ?event({in_safe_loop, _Msg}, S),
            noreply(leader_affirmed(L, Ref, S));
        {?MODULE, ensure_sync, L, Type, ERef} = _Msg ->
            ?log(_Msg, S),
            ?event({in_safe_loop, _Msg}, S),
            noreply(sync_requested(L, Type, ERef, S));
        {'$gen_call', From, '$locks_leader_debug'} = _Msg ->
            ?log(_Msg, S),
            handle_call('$locks_leader_debug', From, S);
        {'$gen_call', From, '$info'} = _Msg ->
            ?log(_Msg, S),
            handle_call('$locks_leader_info', From, S);
        {'$gen_call', From, {'$locks_leader_info', Item}} = _Msg ->
            ?log(_Msg, S),
            handle_call({'$locks_leader_info', Item}, From, S);
        {'$gen_call', {_, {?MODULE, _Ref}} = From, Req} = _Msg ->
            ?log(_Msg, S),
            %% locks_leader-tagged call; handle also in safe loop
            ?event({safe_call, Req}),
            #st{mod = M, mod_state = MSt} = S,
            noreply(
              callback_reply(M:handle_call(Req, From, MSt, opaque(S)),
                             From, fun unchanged/1, S));
	{'DOWN',_,_,_,_} = DownMsg ->
            ?log(DownMsg, S),
	    ?event(DownMsg, S),
	    noreply(down(DownMsg, S))
    end.

event(_Line, _Event, _State) ->
    ok.

%% @private
handle_info(Msg, S) ->
    ?log(Msg, S),
    handle_info_(Msg, S).

handle_info_({nodeup, N}, #st{role = candidate} = S) ->
    ?event({handle_info, {nodeup, N, nodes()}}, S),
    noreply(nodeup(N, S));
handle_info_({nodedown, N}, #st{nodes = Nodes}  =S) ->
    ?event({nodedown, N}, S),
    noreply(S#st{nodes = ordsets:del_element(N, Nodes)});
handle_info_({'DOWN', _, _, _, _} = Msg, S) ->
    ?event({handle_info, Msg}, S),
    noreply(down(Msg, S));
handle_info_({locks_agent, A, Info} = _Msg, #st{agent = A} = S) ->
    ?event({handle_info, _Msg}, S),
    case Info of
	#locks_info{}      -> noreply(locks_info(Info, S));
        waiting when S#st.leader == self() ->
            ?event(clearing_leader),
            noreply(set_leader_uncertain(S));
        _ ->
            noreply(S)
    end;
handle_info_({?MODULE, leader_uncertain, L, Synced, SyncedWs}, S) ->
    ?event({leader_uncertain, {{L, Synced, SyncedWs}, S#st.leader}}),
    case S#st.leader of
        MyL when MyL == self() ->
            noreply(
              lists:foldl(
                fun({Pid, Type}, Sx) ->
                        maybe_announce_leader(
                          Pid, Type, remove_synced(Pid, Type, Sx))
                end, S,
                [{P,candidate} || P <- [L|Synced]]
                ++ [{P,worker} || P <- SyncedWs]));
        L ->
            locks_agent:change_flag(S#st.agent, notify, true),
            noreply(S#st{leader = undefined,
                         synced = [], synced_workers = []});
        _OtherL ->
            noreply(S)
    end;
handle_info_({?MODULE, affirm_leader, L, ERef} = _Msg, #st{} = S) ->
    ?event(_Msg, S),
    noreply(leader_affirmed(L, ERef, S));
handle_info_({?MODULE, ensure_sync, Pid, Type, _ERef} = _Msg, #st{} = S) ->
    ?event(_Msg, S),
    S1 = case S#st.leader of
             Me when Me == self() ->
                 do_ensure_sync(Pid, Type, S);
             _ ->
                 S
         end,
    noreply(S1);
handle_info_({?MODULE, am_worker, W} = _Msg, #st{} = S) ->
    ?event({handle_info, _Msg}, S),
    noreply(worker_announced(W, S));
handle_info_(#locks_info{lock = #lock{object = Lock}} = I,
             #st{lock = Lock} = S) ->
    noreply(locks_info(I, S));
handle_info_({?MODULE, am_leader, L, ERef, LeaderMsg} = _M, S) ->
    ?event({handle_info, _M}, S),
    noreply(leader_announced(L, ERef, LeaderMsg, S));
handle_info_({?MODULE, from_leader, L, ERef, LeaderMsg} = _M, S) ->
    ?event({handle_info, _M}, S),
    noreply(from_leader(L, ERef, LeaderMsg, S));
handle_info_({MRef, join, {?MODULE, Rsrc}, Pids},
             #st{pg_mref = MRef, lock = Rsrc} = S) ->
    noreply(joined(Pids, S));
handle_info_({Ref, {'$locks_leader_reply', Reply}} = _M,
	    #st{buffered = Buf} = S) ->
    ?event({handle_info, _M}, S),
    case lists:keytake(Ref, 1, Buf) of
	{value, {_, OrigRef}, Buf1} ->
	    reply(OrigRef, {'$locks_leader_reply', Reply}),
	    noreply(S#st{buffered = Buf1});
	false ->
	    noreply(S)
    end;
handle_info_(Msg, #st{mod = M, mod_state = MSt} = S) ->
    ?event({handle_info, Msg}, S),
    noreply(callback(M:handle_info(Msg, MSt, opaque(S)), S)).


%% @private
handle_cast(Msg, S) ->
    ?log({'$cast', Msg}, S),
    handle_cast_(Msg, S).

handle_cast_({'$locks_leader_cast', Msg} = Cast, #st{mod = M, mod_state = MSt,
                                                     leader = L} = S) ->
    if L == self() ->
	    noreply(callback(M:handle_leader_cast(Msg, MSt, opaque(S)), S));
       is_pid(L) ->
	    gen_server:cast(L, Cast),
	    noreply(S);
       true ->
            noreply(S)
    end;
handle_cast_(Msg, #st{mod = M, mod_state = MSt} = St) ->
    noreply(callback(M:handle_cast(Msg, MSt, opaque(St)), St)).


%% @private
handle_call(Req, From, S) ->
    ?log({'$call', Req, From}, S),
    handle_call_(Req, From, S).

handle_call_(Req, {_, {?MODULE, _Ref}} = From,
             #st{mod = M, mod_state = MSt} = S) ->
    noreply(
      callback_reply(M:handle_call(Req, From, MSt, opaque(S)), From,
                    fun unchanged/1, S));
handle_call_('$locks_leader_debug', From, S) ->
    I = [{leader, leader(S)},
         {leader_node, leader_node(S)},
         {candidates, candidates(S)},
         {new_candidates, new_candidates(S)},
         {workers, workers(S)},
         {module, S#st.mod},
         {mod_state, S#st.mod_state},
         {process_info, process_info(self())}],
    reply(From, I),
    noreply(S);
handle_call_('$locks_leader_info', From, S) ->
    I = [{leader, leader(S)},
         {leader_node, leader_node(S)},
         {candidates, candidates(S)},
         {new_candidates, new_candidates(S)},
         {workers, workers(S)},
         {module, S#st.mod},
         {mod_state, S#st.mod_state}],
    reply(From, I),
    noreply(S);
handle_call_({'$locks_leader_info', Item}, From, S) ->
    I = case Item of
            leader -> leader(S);
            leader_node -> leader_node(S);
            candidates  -> candidates(S);
            new_candidates -> new_candidates(S);
            workers        -> workers(S);
            module         -> S#st.mod;
            mod_state      -> S#st.mod_state;
            _ -> undefined
        end,
    reply(From, I),
    noreply(S);
handle_call_({'$locks_leader_call', Req} = Msg, From,
             #st{mod = M, mod_state = MSt, leader = L,
                 buffered = Buf} = S) ->
    if L == self() ->
	    noreply(
	      callback_reply(
		M:handle_leader_call(Req, From, MSt, opaque(S)), From,
		fun(R) -> {'$locks_leader_reply', R} end, S));
       true ->
            MyRef = make_ref(),
	    NewFrom = {self(), MyRef},
	    catch erlang:send(L, {'$gen_call', NewFrom, Msg}, [noconnect]),
	    noreply(S#st{buffered = [{MyRef, From}|Buf]})
    end;
handle_call_(R, F, #st{mod = M, mod_state = MSt} = S) ->
    noreply(
      callback_reply(M:handle_call(R, F, MSt, opaque(S)), F,
                     fun unchanged/1, S)).

unchanged(X) ->
    X.

%% @private
terminate(_, _) ->
    ok.

%% @private
code_change(_, St, _) ->
    {ok, St}.


nodeup(N, #st{nodes = Nodes} = S) ->
    case ordsets:is_element(N, Nodes) of
        true ->
            S;
        false ->
            include_node(N, S)
    end.

joined(Pids, #st{candidates = Cands} = S) ->
    NewCands = Pids -- Cands,
    process_new_cands(NewCands, S).

include_node(N, #st{agent = A, lock = Lock, nodes = Nodes} = S) ->
    ?event({include_node, N}),
    case ordsets:is_element(N, nodes()) of
        true  -> ok;
        false -> asynch_ping(N)
    end,
    locks_agent:lock_nowait(A, Lock, write, [N], all_alive),
    S#st{nodes = ordsets:add_element(N, Nodes)}.

locks_info(#locks_info{lock = #lock{object = Lock} = L,
                       where = Node} = _I, #st{lock = Lock} = S) ->
    lock_info(L, Node, S);
locks_info(_, S) ->
    S.

lock_info(#lock{queue = Q}, Node, #st{} = S) ->
    NewCands = new_cands(Node, Q, S),
    process_new_cands(NewCands, S).

process_new_cands(NewCands, #st{} = S) ->
    lists:foldl(fun(C, #st{nodes = Nodes} = Acc) ->
                        N = node(C),
                        SAcc = case ordsets:is_element(N, Nodes) of
                                   true -> Acc;
                                   false -> include_node(N, Acc)
                               end,
                        add_cand(C, SAcc)
                end, S, NewCands).

new_cands(_Node, Q, #st{candidates = Cands}) ->
    Clients = [C || #w{entries = [#entry{client = C}]} <- Q,
                    C =/= self()],
    Clients -- Cands.

down({'DOWN', Ref, _, Pid, _} = Msg,
     #st{leader = LPid, mod = M, mod_state = MSt} = S) ->
    case erase({?MODULE,monitor,Ref}) of
	undefined ->
	    %% not mine; pass on to callback
	    callback(M:handle_info(Msg, MSt, opaque(S)), S);
	Type ->
	    S1 = if Pid == LPid ->
			 [reply(From,'$leader_died')
			  || {_, From} <- S#st.buffered],
			 S#st{leader = undefined, buffered = [],
                              synced = [], synced_workers = []};
		    true -> S
		 end,
	    maybe_remove_cand(Type, Pid, S1)
    end.

add_cand(Client, S) when Client == self() ->
    S;
add_cand(Client, #st{candidates = Cands, role = Role} = S) ->
    case lists:member(Client, Cands) of
	false ->
            ?event({add_cand, Client}),
            monitor_cand(Client),
            S1 = S#st{candidates = [Client | Cands]},
	    if Role == worker ->
                    snd(Client, {?MODULE, am_worker, self()}),
                    S1;
	       true ->
                    maybe_announce_leader(Client, candidate, S1)
            end;
	true ->
	    S
    end.

monitor_cand(Client) ->
    MRef = erlang:monitor(process, Client),
    put({?MODULE, monitor, MRef}, candidate).

maybe_announce_leader(Pid, Type, #st{leader = L, mod = M,
                                     mod_state = MSt} = S0) ->
    ?event({maybe_announce_leader, Pid, Type}, S0),
    IsSynced = is_synced(Pid, Type, S0),
    ?event({is_synced, Pid, IsSynced}),
    if L == self(), IsSynced == false ->
            S = refresh_vector(S0),
            ERef = S#st.election_ref,
	    ERes = M:elected(MSt, opaque(S), Pid),
            ?event({elected_result, ERes}),
            case ERes of
		{reply, Msg, MSt1} ->
		    snd(Pid, msg(am_leader, ERef, Msg)),
                    mark_as_synced(Pid, Type, S#st{mod_state = MSt1});
		{ok, Msg, MSt1} ->
                    snd(Pid, msg(am_leader, ERef, Msg)),
		    S1 = do_broadcast(S#st{mod_state = MSt1}, Msg),
                    mark_as_synced(Pid, Type, S1);
                {ok, AmLdrMsg, FromLdrMsg, MSt1} ->
                    snd(Pid, msg(am_leader, ERef, AmLdrMsg)),
                    S1 = do_broadcast(S#st{mod_state = MSt1}, FromLdrMsg),
                    mark_as_synced(Pid, Type, S1);
                {surrender, Other, MSt1} ->
                    case lists:member(Other, S#st.candidates) of
                        true ->
                            locks_agent:surrender_nowait(
                              S#st.agent, S#st.lock, Other, S#st.nodes),
                            set_leader_undefined(S#st{mod_state = MSt1});
                        false ->
                            error({cannot_surrender, Other})
                    end
	    end;
       true ->
            ?event({will_not_announce, L, IsSynced}),
	    S0
    end.

set_leader_undefined(#st{} = S) ->
    S#st{leader = undefined,
         synced = [], synced_workers = []}.

is_synced(Pid, worker, #st{synced_workers = Synced}) ->
    lists:member(Pid, Synced);
is_synced(Pid, candidate, #st{synced = Synced}) ->
    lists:member(Pid, Synced).

mark_as_synced(Pid, worker, #st{synced_workers = Synced} = S) ->
    S#st{synced_workers = [Pid|Synced]};
mark_as_synced(Pid, candidate, #st{synced = Synced} = S) ->
    S#st{synced = [Pid|Synced]}.

remove_synced(Pid, worker, #st{synced_workers = Synced} = S) ->
    S#st{synced_workers = Synced -- [Pid]};
remove_synced(Pid, candidate, #st{synced = Synced} = S) ->
    S#st{synced = Synced -- [Pid]}.

maybe_remove_cand(candidate, Pid, #st{candidates = Cs, synced = Synced,
                                      leader = L,
				      mod = M, mod_state = MSt} = S) ->
    S1 = S#st{candidates = Cs -- [Pid], synced = Synced -- [Pid]},
    if L == self() ->
	    callback(M:handle_DOWN(Pid, MSt, opaque(S1)), S1);
       true ->
	    S1
    end;
maybe_remove_cand(worker, Pid, #st{workers = Ws} = S) ->
    S#st{workers = Ws -- [Pid]}.

become_leader(#st{agent = A} = S) ->
    {_, Locks} = LockInfo = locks_agent:lock_info(A),
    ?event({lock_info, LockInfo}),
    S1 = refresh_vector(LockInfo, S),
    ?event({s1_vector, S1#st.vector}),
    S2 = lists:foldl(
           fun(#lock{object = {OID,Node}} = L, Sx) ->
                   lock_info(L#lock{object = OID}, Node, Sx)
           end, S1, Locks),
    ?event({s2_vector, S2#st.vector}),
    case S2#st.vector of
        #{leader := Lv} when Lv =/= A ->
            ?event(vector_questions_leader, S2),
            set_leader_uncertain(S2);
        _ ->
            become_leader_(S2)
    end.

become_leader_(#st{election_ref = {L,_,_}, mod = M, mod_state = MSt,
                   candidates = Cands, synced = Synced,
                   workers = Ws, synced_workers = SyncedWs} = S0)
  when L =:= self() ->
    S = S0#st{leader = self(), election_ref = new_election_ref(S0)},
    ?event(become_leader_again, S),
    send_all(S, {?MODULE, affirm_leader, self(), S#st.election_ref}),
    case {Cands -- Synced, Ws -- SyncedWs} of
        {[], []} -> S;
        _ ->
            {Broadcast, ModSt1} =
                case M:elected(MSt, opaque(S), undefined) of
                    {ok, Msg1, Msg2, MSt1} -> {{Msg1, Msg2}, MSt1};
                    {ok, Msg, MSt1}        -> {{Msg , Msg }, MSt1};
                    {ok, MSt1}             -> {[], MSt1};
                    {error, Reason}        -> error(Reason)
            end,
            S1 = S#st{mod_state = ModSt1},
            case Broadcast of
                [] -> S1;
                {AmLeaderMsg, FromLeaderMsg} ->
                    do_broadcast_new(
                      do_broadcast(S1, FromLeaderMsg), AmLeaderMsg)
            end
    end;
become_leader_(#st{mod = M, mod_state = MSt} = S0) ->
    S = S0#st{election_ref = new_election_ref(S0)},
    ?event(become_leader, S),
    case M:elected(MSt, opaque(S), undefined) of
	{ok, Msg, MSt1} ->
            do_broadcast_new(
              S#st{mod_state = MSt1, leader = self(),
                   synced = [], synced_workers = []}, Msg);
	{error, Reason} ->
	    error(Reason)
    end.

new_election_ref(#st{vector = V}) ->
    {self(), erlang:monotonic_time(microsecond), V}.

msg(from_leader, ERef, Msg) ->
    {?MODULE, from_leader, self(), ERef, Msg};
msg(am_leader, ERef, Msg) ->
    {?MODULE, am_leader, self(), ERef, Msg}.

%% opaque(#st{candidates = Cands, workers = Ws, leader = L}) ->
%%     fun(candidates) -> Cands;
%%        (workers)    -> Ws;
%%        (leader)     -> L
%%     end.
opaque(S) ->
    S.

callback({noreply, MSt}, S) ->
    S#st{mod_state = MSt};
callback({ok, MSt}, S) ->
    S#st{mod_state = MSt};
callback({ok, Msg, MSt}, #st{leader = L} = S) ->
    if L == self() ->
	    do_broadcast(S#st{mod_state = MSt}, Msg);
       true ->
	    error(not_leader)
    end;
callback({stop, Reason, MSt}, S) ->
    {stop, Reason, S#st{mod_state = MSt}}.


callback_reply({reply, Reply, MSt}, From, F, S) ->
    reply(From, F(Reply)),
    S#st{mod_state = MSt};
callback_reply({reply, Reply, Msg, MSt}, From, F, S) ->
    if S#st.leader == self() ->
	    S1 = S#st{mod_state = MSt},
	    do_broadcast(S1, Msg),
	    reply(From, F(Reply)),
	    S1;
       true ->
	    error(not_leader)
    end;
callback_reply({noreply, MSt}, _, _, S) ->
    S#st{mod_state = MSt};
callback_reply({stop, Reason, Reply, MSt}, From, F, S) ->
    reply(From, F(Reply)),
    {stop, Reason, S#st{mod_state = MSt}};
callback_reply({stop, Reason, MSt}, _, _, S) ->
    {stop, Reason, S#st{mod_state = MSt}}.

do_broadcast_new(#st{election_ref = ERef, candidates = Cands, workers = Ws,
                     synced = Synced, synced_workers = SyncedWs} = S, Msg) ->
    NewCands = Cands -- Synced,
    NewWs = Ws -- SyncedWs,
    AmLeader = msg(am_leader, ERef, Msg),
    do_broadcast_(NewCands, AmLeader),
    do_broadcast_(NewWs, AmLeader),
    S#st{synced = Cands, synced_workers = Ws}.

do_broadcast(#st{synced = Synced, synced_workers = SyncedWs} = S, Msg) ->
    FromLeader = msg(from_leader, S#st.election_ref, Msg),
    do_broadcast_(Synced, FromLeader),
    do_broadcast_(SyncedWs, FromLeader),
    S.

send_all(#st{candidates = Cands, workers = Ws}, Msg) ->
    do_broadcast_(Cands, Msg),
    do_broadcast_(Ws, Msg).

do_broadcast_(Pids, Msg) when is_list(Pids) ->
    ?log({'$bcast', Pids, Msg}),
    [P ! Msg || P <- Pids],
    ok.

snd(Pid, Msg) ->
    ?log({'$snd', Pid, Msg}),
    Pid ! Msg.

from_leader(L, ERef, Msg, #st{leader = L, election_ref = ERef,
                              mod = M, mod_state = MSt} = S) ->
    callback(M:from_leader(Msg, MSt, opaque(S)), S);
from_leader(OtherL, ERef, _Msg, S) ->
    ?event({possible_leader_conflict, OtherL, _Msg}, S),
    S1 = refresh_vector(S),
    case S1#st.vector of
        #{leader := Lv} when Lv =/= OtherL ->
            set_leader_uncertain(S1);
        _ ->
            request_sync(OtherL, ERef, S)
    end.

leader_announced(L, ERef, Msg, #st{election_ref = ERef,
                                   mod = M, mod_state = MSt} = S) ->
    callback(M:surrendered(MSt, Msg, opaque(S)),
             S#st{leader = L, synced = [], synced_workers = []});
leader_announced(L, ERef, Msg, #st{mod = M, mod_state = MSt} = S) ->
    #st{vector = V} = S1 = refresh_vector(S),
    {_,_,Vl} = ERef,
    case Vl == V of
        true ->
            ?event({vectors_same, V}),
            S2 = S1#st{leader = L, election_ref = ERef,
                       synced = [], synced_workers = []},
            callback(M:surrendered(MSt, Msg, opaque(S1)), S2);
        false ->
            ?event({vectors_differ, {Vl, V}}),
            set_leader_uncertain(S1)
    end.

leader_affirmed(L, ERef, #st{leader = L, election_ref = ERef} = S) ->
    ?event({leader_affirmed_known, L, ERef}),
    S;
leader_affirmed(_L, _ERef, #st{leader = Me} = S) when Me == self() ->
    ?event({leader_not_affirmed, _L, _ERef}),
    set_leader_uncertain(S);
leader_affirmed(L, ERef, #st{} = S) ->
    %% don't set leader, since we are not yet synced (return to safe_loop)
    ?event({ensuring_sync, L, S#st.role}),
    request_sync(L, ERef, S).

request_sync(L, ERef, S) ->
    snd(L, {?MODULE, ensure_sync, self(), S#st.role, ERef}),
    S#st{leader = undefined, election_ref = ERef}.

sync_requested(Pid, Type, ERef, #st{ leader = undefined
                                   , election_ref = ERef
                                   , vector = #{leader := Me}
                                   , agent = A } = S)
  when Me == self() ->
    %% We were uncertain about whether we're leader, but this is
    %% affirmation from at least one other candidate.
    case locks_agent:transaction_status(A) of
        {have_all_locks, _} ->
            do_ensure_sync(Pid, Type, S#st{leader = self()});
        _ ->
            S
    end;
sync_requested(_, _, _, S) ->
    S.

do_ensure_sync(Pid, Type, S) ->
    maybe_announce_leader(Pid, Type, remove_synced(Pid, Type, S)).

set_leader_uncertain(#st{agent = A} = S) ->
    send_all(S, {?MODULE, leader_uncertain, self(),
                 S#st.synced, S#st.synced_workers}),
    locks_agent:async_await_all_locks(A),
    S#st{leader = undefined}.

worker_announced(W, #st{workers = Workers} = S) ->
    case lists:member(W, Workers) of
        true ->
            S;
        false ->
            Ref = erlang:monitor(process, W),
            put({?MODULE,monitor,Ref}, worker),
            maybe_announce_leader(W, worker, S#st{workers = [W|Workers]})
    end.

get_opt(K, Opts, Default) ->
    case lists:keyfind(K, 1, Opts) of
        {_, V} ->
            V;
        false ->
            Default
    end.

asynch_ping(N) ->
    rpc:cast(N, erlang, is_atom, [true]).

refresh_vector(#st{agent = A} = S) ->
    refresh_vector(locks_agent:lock_info(A), S).

refresh_vector(LockInfo, #st{lock = L} = S) ->
    maybe_refresh_eref(S#st{vector = vector(L, LockInfo)}).

maybe_refresh_eref(#st{election_ref = {Me,_,Ve}, vector = V} = S)
  when Me == self(),
       Ve =/= V ->
    S#st{election_ref = new_election_ref(S)};
maybe_refresh_eref(S) ->
    S.

vector(Lock, {_Pending, Locks}) ->
    %% As a matter of implementation, the list of locks happens to be ordered,
    %% but this is not a documented fact.
    NewVector = lists:sort(
                  [{N, V} || #lock{object = {L, N}, version = V} <- Locks,
                             L =:= Lock]),
    case length(lists:usort([lock_holder(Lx) || Lx <- Locks])) == 1 of
        true ->
            Leader = lock_holder(hd(Locks)),
            #{leader => Leader, vector => NewVector};
        false ->
            #{leader => none, vector => NewVector}
    end.

lock_holder(#lock{queue = [#w{entries = [#entry{agent = A}]}|_]}) ->
    A.

-ifdef(LOCKS_DEBUG).
dbg_log(X, #st{leader = L, vector = V}) ->
    ?event(X, S),
    ?log(#{x => X, l => L, v => V}).
-endif.
