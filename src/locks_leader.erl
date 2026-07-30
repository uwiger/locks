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
%% Internally the role plane is a `gen_statem' with states
%% `candidate' | `syncing' | `leader' (see LOCKS_LEADER_IDEAS.md).
%%
%% Each instance is started either as a 'candidate' or a 'worker'.
%% Candidates claim a write lock on The Lock; workers monitor it.
%% Candidates also join a `locks_pg' society group for peer discovery.
%%
%% The candidate that claims The Lock becomes the leader (after a merge
%% mutex / sync lock). Callbacks match the classic gen_leader-style API.
%% @end
-module(locks_leader).
-behaviour(gen_statem).

-export([start_link/2, start_link/3, start_link/4,
         call/2, call/3,
         cast/2,
         leader_call/2,
         leader_call/3,
         leader_reply/2,
         leader_cast/2,
         info/1, info/2]).

-export([callback_mode/0, init/1, terminate/3, code_change/4]).
-export([candidate/3, following/3, syncing/3, leader/3]).

-export([candidates/1,
         new_candidates/1,
         alive/1,
         workers/1,
         leader/1,
         leader_node/1]).

-export([reply/2,
         broadcast/2, broadcast/3,
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
-type server_ref() :: atom() | {atom(), node()} | {global, term()}
                   | {via, module(), term()} | pid().
-type cb_return() ::
        {ok, mod_state()}
      | {ok, msg(), mod_state()}
      | {noreply, mod_state()}
      | {stop, reason(), mod_state()}.
-type cb_reply() ::
        {reply, reply(), mod_state()}
      | {reply, reply(), msg(), mod_state()}
      | {noreply, mod_state()}
      | {stop, reason(), mod_state()}.


-record(st, {
             role = candidate :: candidate | worker,
             lock,
             vector,
             agent,
             leader,         %% pid() | undefined — self() only in leader state
             election_ref,
             nodes = ordsets:new(),
             pg_mref          :: reference() | undefined,
             candidates = [],
             workers = [],
             synced = [],
             synced_workers = [],
             sync_worker      :: pid() | undefined,
             regname,
             mod,
             mod_state,
             buffered = []    :: [{reference(), from()}]
         }).

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

%% ==================================================================
%% Public API (stable)
%% ==================================================================

-spec alive(election()) -> [pid()].
alive(#st{synced = Synced, synced_workers = SyncedWs}) ->
    Synced ++ SyncedWs.

-spec candidates(election()) -> [pid()].
candidates(#st{candidates = C}) -> C.

-spec new_candidates(election()) -> [pid()].
new_candidates(#st{candidates = C, synced = S} = St) ->
    ?event({new_candidates, St}),
    C -- S.

-spec workers(election()) -> [pid()].
workers(#st{workers = W}) -> W.

-spec leader(election()) -> pid() | undefined.
leader(#st{leader = L}) -> L.

-spec leader_node(election()) -> node().
leader_node(#st{leader = L}) when is_pid(L) -> node(L);
leader_node(#st{}) -> undefined.

-spec reply({pid(), any()}, any()) -> ok.
reply(From, Reply) ->
    gen_statem:reply(From, Reply),
    ok.

-spec broadcast(any(), election()) -> ok.
broadcast(Msg, #st{leader = L} = S) when L == self() ->
    _ = do_broadcast(S, Msg),
    ok;
broadcast(_, _) ->
    error(not_leader).

broadcast(Msg, ToPids, #st{ leader = L
                          , synced = Cands
                          , synced_workers = Ws}) when L == self() ->
    case (ToPids -- Cands) -- Ws of
        [] -> ok;
        Pids ->
            _ = do_broadcast_(Pids, Msg)
    end;
broadcast(_, _, _) ->
    error(not_leader).

-spec broadcast_to_candidates(any(), election()) -> ok.
broadcast_to_candidates(Msg, #st{leader = L, synced = Cands,
                                 election_ref = ERef})
  when L == self() ->
    do_broadcast_(Cands, msg(from_leader, ERef, Msg));
broadcast_to_candidates(_, _) ->
    error(not_leader).

-spec ask_candidates(any(), election()) ->
                            {GoodReplies, Errors}
                                when GoodReplies :: [{pid(), any()}],
                                     Errors      :: [{pid(), any()}].
ask_candidates(Req, #st{candidates = Cands}) ->
    Requests =
        lists:map(
          fun(C) ->
                  MRef = erlang:monitor(process, C),
                  C ! {'$gen_call', {self(), {?MODULE, MRef}}, Req},
                  {C, MRef}
          end, Cands),
    partition(collect_replies(Requests)).

collect_replies([{Pid, MRef}|Reqs]) ->
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

-spec start_link(Module::atom(), St::any()) -> {ok, pid()}.
start_link(Module, St) ->
    start_link(Module, St, []).

-spec start_link(Module::atom(), St::any(), ldr_options()) -> {ok, pid()}.
start_link(Module, St, Options) ->
    case lists:keyfind(registered_name, 1, Options) of
        {_, Reg} when is_atom(Reg) ->
            gen_statem:start_link({local, Reg}, ?MODULE,
                                  {Module, St, Options}, []);
        _ ->
            gen_statem:start_link(?MODULE, {Module, St, Options}, [])
    end.

-spec start_link(Reg::atom(), Module::atom(), St::any(), ldr_options()) ->
                        {ok, pid()}.
start_link(Reg, Module, St, Options) when is_atom(Reg), is_atom(Module) ->
    gen_statem:start_link({local, Reg}, ?MODULE,
                          {Module, St, Options}, []).

-spec leader_call(Name::server_ref(), Request::term()) -> term().
leader_call(L, Request) ->
    leader_call(L, Request, 5000).

-spec leader_call(Name::server_ref(), Request::term(), integer()|infinity) ->
                         term().
leader_call(L, Request, Timeout) ->
    case catch gen_statem:call(L, {'$locks_leader_call', Request}, Timeout) of
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
leader_cast(L, Msg) ->
    ?event({leader_cast, L, Msg}),
    gen_statem:cast(L, {'$locks_leader_cast', Msg}).

info(L) ->
    ?event({info, L}),
    R = gen_statem:call(L, '$locks_leader_info'),
    ?event({info_return, L, R}),
    R.

info(L, Item) ->
    ?event({info, L, Item}),
    R = gen_statem:call(L, {'$locks_leader_info', Item}),
    ?event({info_return, L, Item, R}),
    R.

-spec call(L::server_ref(), Request::any()) -> any().
call(L, Req) ->
    R = gen_statem:call(L, Req),
    ?event({call_return, L, Req, R}),
    R.

-spec call(L::server_ref(), Request::any(), integer()|infinity) -> any().
call(L, Req, Timeout) ->
    R = gen_statem:call(L, Req, Timeout),
    ?event({call_return, L, Req, Timeout, R}),
    R.

-spec cast(L::server_ref(), Msg::any()) -> ok.
cast(L, Msg) ->
    ?event({cast, L, Msg}),
    gen_statem:cast(L, Msg).

%% ==================================================================
%% gen_statem
%% ==================================================================

callback_mode() ->
    [state_functions, state_enter].

init({Module, St, Options}) ->
    Reg = case lists:keyfind(registered_name, 1, Options) of
              {_, R} -> R;
              false  -> undefined
          end,
    init_(Module, St, Options, Reg).

init_(Module, ModSt0, Options, Reg) ->
    Defaults = #st{},
    Role = get_opt(role, Options, Defaults#st.role),
    Lock = [?MODULE, get_opt(resource, Options, default_lock(Module, Reg))],
    ModSt = case Module:init(ModSt0) of
                {ok, MSt} -> MSt;
                {error, Reason} -> error(Reason)
            end,
    AllNodes = ordsets:from_list([node()|nodes()]),
    {PgMRef, KnownMembers} =
        case Role of
            candidate ->
                PgGroup = society_group(Lock),
                {MRef, Members} = locks_pg:monitor(PgGroup),
                ok = locks_pg:join(PgGroup, [self()]),
                {MRef, Members -- [self()]};
            worker ->
                {undefined, []}
        end,
    Agent =
        case Role of
            candidate ->
                {ok, A} = locks_agent:start(
                            [{notify, true},
                             {await_nodes, true},
                             {monitor_nodes, true}]),
                locks_agent:lock_nowait(A, Lock, write, AllNodes, all_alive),
                A;
            worker ->
                locks_server:watch(Lock, [node()]),
                undefined
        end,
    Data0 = #st{agent = Agent,
                role = Role,
                mod = Module,
                mod_state = ModSt,
                lock = Lock,
                nodes = AllNodes,
                pg_mref = PgMRef,
                regname = Reg},
    Data1 = society_joined(KnownMembers, Data0),
    {ok, candidate, Data1}.

terminate(_Reason, _State, #st{sync_worker = SW}) ->
    case SW of
        undefined -> ok;
        W when is_pid(W) -> W ! {?MODULE, sync_lock_release, self()}
    end,
    ok.

code_change(_Old, State, Data, _Extra) ->
    {ok, State, Data}.

event(_Line, _Evt, _State) ->
    ok.

%% ------------------------------------------------------------------
%% candidate
%% ------------------------------------------------------------------

candidate(enter, _Old, Data0) ->
    ?event({enter, candidate}, Data0),
    Data = Data0#st{leader = case Data0#st.leader of
                                 Me when Me =:= self() -> undefined;
                                 Other -> Other
                             end},
    %% Brief delay avoids a tight enter→sync→fail→enter loop when the
    %% contest is flapping; still rechecks without waiting for notify.
    {keep_state, Data, [{state_timeout, 20, recheck_contest}]};
candidate(state_timeout, recheck_contest, Data) ->
    %% If contest is already complete (e.g. re-entered after sync abort
    %% while still holding locks), do not wait for a duplicate notify.
    maybe_recheck_contest(Data);

candidate({call, From}, '$locks_leader_debug', Data) ->
    {keep_state, Data, [{reply, From, debug_info(Data)}]};
candidate({call, From}, '$locks_leader_info', Data) ->
    {keep_state, Data, [{reply, From, debug_info(Data)}]};
candidate({call, From}, {'$locks_leader_info', Item}, Data) ->
    {keep_state, Data, [{reply, From, info_item(Item, Data)}]};
candidate({call, _From}, {'$locks_leader_call', _}, Data) ->
    %% No leader yet — redeliver after transition to following/leader.
    {keep_state, Data, [postpone]};
candidate({call, From}, Req, #st{mod = M, mod_state = MSt} = Data) ->
    case apply_cb_reply(M:handle_call(Req, From, MSt, opaque(Data)), From, Data) of
        {stop, Reason, Data1} -> {stop, Reason, Data1};
        Data1 -> {keep_state, Data1}
    end;

candidate(cast, {'$locks_leader_cast', _Msg}, Data) ->
    {keep_state, Data, [postpone]};
candidate(cast, Msg, #st{mod = M, mod_state = MSt} = Data) ->
    case apply_cb(M:handle_cast(Msg, MSt, opaque(Data)), Data) of
        {stop, Reason, Data1} -> {stop, Reason, Data1};
        Data1 -> {keep_state, Data1}
    end;

candidate(info, Msg, Data) ->
    handle_common_info(Msg, candidate, Data).

%% ------------------------------------------------------------------
%% following — accept a remote leader (releases postponed leader_calls)
%% ------------------------------------------------------------------

following(enter, _Old, Data) ->
    ?event({enter, following}, Data),
    {keep_state, Data};

following({call, From}, '$locks_leader_info', Data) ->
    {keep_state, Data, [{reply, From, debug_info(Data)}]};
following({call, From}, {'$locks_leader_info', Item}, Data) ->
    {keep_state, Data, [{reply, From, info_item(Item, Data)}]};
following({call, From}, {'$locks_leader_call', _} = Msg, #st{leader = L} = Data)
  when is_pid(L), L =/= self() ->
    forward_leader_call(Msg, From, L, Data);
following({call, _From}, {'$locks_leader_call', _}, Data) ->
    {keep_state, Data, [postpone]};
following({call, From}, Req, #st{mod = M, mod_state = MSt} = Data) ->
    case apply_cb_reply(M:handle_call(Req, From, MSt, opaque(Data)), From, Data) of
        {stop, Reason, Data1} -> {stop, Reason, Data1};
        Data1 -> {keep_state, Data1}
    end;

following(cast, {'$locks_leader_cast', Msg}, #st{leader = L} = Data)
  when is_pid(L), L =/= self() ->
    gen_statem:cast(L, {'$locks_leader_cast', Msg}),
    {keep_state, Data};
following(cast, {'$locks_leader_cast', _}, Data) ->
    {keep_state, Data, [postpone]};
following(cast, Msg, #st{mod = M, mod_state = MSt} = Data) ->
    case apply_cb(M:handle_cast(Msg, MSt, opaque(Data)), Data) of
        {stop, Reason, Data1} -> {stop, Reason, Data1};
        Data1 -> {keep_state, Data1}
    end;

following(info, Msg, Data) ->
    handle_common_info(Msg, following, Data).
%% ------------------------------------------------------------------
%% syncing — contest won; merge mutex in flight
%% ------------------------------------------------------------------

syncing(enter, _Old, Data) ->
    ?event({enter, syncing}, Data),
    %% Escape hatch if the sync worker dies without replying.
    {keep_state, Data, [{state_timeout, 5000, sync_timeout}]};

syncing(state_timeout, sync_timeout, Data) ->
    ?event(sync_timeout, Data),
    Data1 = cancel_sync_worker(Data),
    {next_state, candidate, set_leader_uncertain(Data1)};

syncing({call, From}, '$locks_leader_info', Data) ->
    {keep_state, Data, [{reply, From, debug_info(Data)}]};
syncing({call, From}, {'$locks_leader_info', Item}, Data) ->
    {keep_state, Data, [{reply, From, info_item(Item, Data)}]};
syncing({call, _From}, {'$locks_leader_call', _}, Data) ->
    %% Become leader (or fall back) soon — redeliver then.
    {keep_state, Data, [postpone]};
syncing({call, From}, Req, #st{mod = M, mod_state = MSt} = Data) ->
    case apply_cb_reply(M:handle_call(Req, From, MSt, opaque(Data)), From, Data) of
        {stop, Reason, Data1} -> {stop, Reason, Data1};
        Data1 -> {keep_state, Data1}
    end;

syncing(cast, {'$locks_leader_cast', _}, Data) ->
    {keep_state, Data, [postpone]};
syncing(cast, Msg, #st{mod = M, mod_state = MSt} = Data) ->
    case apply_cb(M:handle_cast(Msg, MSt, opaque(Data)), Data) of
        {stop, Reason, Data1} -> {stop, Reason, Data1};
        Data1 -> {keep_state, Data1}
    end;

syncing(info, {?MODULE, sync_lock_ok, Worker}, Data) ->
    case do_sync_lock_acquired(Worker, Data) of
        {leader, Data1} ->
            {next_state, leader, Data1};
        {candidate, Data1} ->
            {next_state, candidate, Data1}
    end;
syncing(info, {?MODULE, sync_lock_failed, Worker}, Data) ->
    Data1 = do_sync_lock_aborted(Worker, Data),
    {next_state, candidate, Data1};
syncing(info, {'DOWN', _MRef, process, Worker, _Reason},
        #st{sync_worker = Worker} = Data) ->
    ?event({sync_worker_down, Worker}, Data),
    {next_state, candidate,
     set_leader_uncertain(Data#st{sync_worker = undefined})};
syncing(info, {locks_agent, A, waiting}, #st{agent = A} = Data) ->
    %% Lost completeness while merging — abort sync.
    Data1 = cancel_sync_worker(Data),
    Data2 = set_leader_uncertain(Data1),
    {next_state, candidate, Data2};
syncing(info, {locks_agent, A, {have_all_locks, _}}, #st{agent = A} = Data) ->
    %% Still complete; ignore duplicate while syncing.
    {keep_state, Data};
syncing(info, Msg, Data) ->
    handle_common_info(Msg, syncing, Data).

%% ------------------------------------------------------------------
%% leader
%% ------------------------------------------------------------------

leader(enter, _Old, Data) ->
    ?event({enter, leader}, Data),
    {keep_state, Data#st{leader = self()}};

leader({call, From}, '$locks_leader_info', Data) ->
    {keep_state, Data, [{reply, From, debug_info(Data)}]};
leader({call, From}, {'$locks_leader_info', Item}, Data) ->
    {keep_state, Data, [{reply, From, info_item(Item, Data)}]};
leader({call, From}, {'$locks_leader_call', Req},
       #st{mod = M, mod_state = MSt} = Data) ->
    case apply_cb_reply(
           M:handle_leader_call(Req, From, MSt, opaque(Data)), From, Data,
           fun(R) -> {'$locks_leader_reply', R} end) of
        {stop, Reason, Data1} -> {stop, Reason, Data1};
        Data1 -> {keep_state, Data1}
    end;
leader({call, From}, Req, #st{mod = M, mod_state = MSt} = Data) ->
    case apply_cb_reply(M:handle_call(Req, From, MSt, opaque(Data)), From, Data) of
        {stop, Reason, Data1} -> {stop, Reason, Data1};
        Data1 -> {keep_state, Data1}
    end;

leader(cast, {'$locks_leader_cast', Msg}, #st{mod = M, mod_state = MSt} = Data) ->
    case apply_cb(M:handle_leader_cast(Msg, MSt, opaque(Data)), Data) of
        {stop, Reason, Data1} -> {stop, Reason, Data1};
        Data1 -> {keep_state, Data1}
    end;
leader(cast, Msg, #st{mod = M, mod_state = MSt} = Data) ->
    case apply_cb(M:handle_cast(Msg, MSt, opaque(Data)), Data) of
        {stop, Reason, Data1} -> {stop, Reason, Data1};
        Data1 -> {keep_state, Data1}
    end;

leader(info, {locks_agent, A, waiting}, #st{agent = A} = Data) ->
    ?event(clearing_leader, Data),
    Data1 = set_leader_uncertain(Data),
    {next_state, candidate, Data1};
leader(info, {locks_agent, A, {have_all_locks, _}}, #st{agent = A} = Data) ->
    {keep_state, Data};
leader(info, {?MODULE, sync_lock_ok, Worker}, Data) ->
    %% Stale — release and ignore.
    Worker ! {?MODULE, sync_lock_release, self()},
    {keep_state, Data};
leader(info, {?MODULE, sync_lock_failed, _Worker}, Data) ->
    {keep_state, Data};
leader(info, Msg, Data) ->
    handle_common_info(Msg, leader, Data).

%% ==================================================================
%% Common info handling (returns gen_statem result tuple)
%% ==================================================================

handle_common_info({nodeup, N}, State, Data)
  when State =/= leader ->
    %% Workers also track nodes; candidates expand the contest.
    Data1 = nodeup(N, Data),
    keep_or_recheck(State, Data1);
handle_common_info({nodeup, N}, leader, Data) ->
    %% Expanding the lock set will typically drop completeness → waiting.
    Data1 = nodeup(N, Data),
    keep_or_recheck(leader, Data1);
handle_common_info({nodedown, N}, State, #st{nodes = Nodes, leader = L} = Data) ->
    Data1 = Data#st{nodes = ordsets:del_element(N, Nodes)},
    case L of
        Pid when is_pid(Pid), node(Pid) =:= N ->
            %% Lost contact with current leader (or self-node impossible).
            Data2 = set_leader_uncertain(Data1#st{leader = undefined}),
            {next_state, candidate, Data2};
        _ when State =:= leader ->
            %% Partition: agent will report waiting then have_all for remainder.
            keep_or_recheck(State, Data1);
        _ ->
            keep_or_recheck(State, Data1)
    end;
handle_common_info({'DOWN', _, _, _, _} = Msg, State, Data) ->
    %% down/2 returns {#st{}, lost_leader} | #st{} | {stop, reason(), #st{}}
    %% (the latter via apply_cb on untracked monitors / handle_info).
    case down(Msg, Data) of
        {Data1, lost_leader} ->
            Data2 = set_leader_uncertain(Data1),
            {next_state, candidate, Data2};
        {stop, Reason, Data1} ->
            {stop, Reason, Data1};
        Data1 when is_record(Data1, st) ->
            keep_or_recheck(State, Data1)
    end;
handle_common_info({locks_agent, A, Info}, State, #st{agent = A} = Data) ->
    handle_agent_info(Info, State, Data);
handle_common_info({MRef, join, {?MODULE, Lock}, Pids}, State,
                   #st{pg_mref = MRef, lock = Lock} = Data) ->
    ?event({society_join, Pids}, Data),
    Data1 = society_joined(Pids, Data),
    keep_or_recheck(State, Data1);
handle_common_info({MRef, leave, {?MODULE, Lock}, Pids}, State,
                   #st{pg_mref = MRef, lock = Lock} = Data) ->
    ?event({society_leave, Pids}, Data),
    keep_or_recheck(State, society_left(Pids, Data));
handle_common_info({?MODULE, leader_uncertain, L, Synced, SyncedWs},
                   State, Data) ->
    Data1 = on_leader_uncertain(L, Synced, SyncedWs, Data),
    next_if_lost_self(State, Data1);
handle_common_info({?MODULE, affirm_leader, L, ERef}, State, Data) ->
    Data1 = leader_affirmed(L, ERef, Data),
    next_if_lost_self(State, Data1);
handle_common_info({?MODULE, ensure_sync, Pid, Type, ERef}, State, Data) ->
    Data1 = on_ensure_sync(Pid, Type, ERef, Data),
    keep_or_recheck(State, Data1);
handle_common_info({?MODULE, am_worker, W}, State, Data) ->
    keep_or_recheck(State, worker_announced(W, Data));
handle_common_info(#locks_info{lock = #lock{object = Lock}} = I, State,
                   #st{lock = Lock} = Data) ->
    keep_or_recheck(State, locks_info(I, Data));
handle_common_info({?MODULE, am_leader, L, ERef, LeaderMsg}, State, Data) ->
    Data1 = leader_announced(L, ERef, LeaderMsg, Data),
    case Data1#st.leader of
        Me when Me =:= self() ->
            keep_or_recheck(State, Data1);
        Rem when is_pid(Rem), Rem =/= self() ->
            %% Enter following so postponed leader_calls are redelivered.
            {next_state, following, Data1};
        _ ->
            keep_or_recheck(State, Data1)
    end;
handle_common_info({?MODULE, from_leader, L, ERef, LeaderMsg}, State, Data) ->
    Data1 = from_leader(L, ERef, LeaderMsg, Data),
    next_if_lost_self(State, Data1);
handle_common_info({Ref, {'$locks_leader_reply', Reply}}, State,
                   #st{buffered = Buf} = Data) ->
    case lists:keytake(Ref, 1, Buf) of
        {value, {_, OrigFrom}, Buf1} ->
            reply(OrigFrom, {'$locks_leader_reply', Reply}),
            {keep_state, Data#st{buffered = Buf1}};
        false ->
            keep_or_recheck(State, Data)
    end;
handle_common_info(Msg, State, #st{mod = M, mod_state = MSt} = Data) ->
    case apply_cb(M:handle_info(Msg, MSt, opaque(Data)), Data) of
        {stop, Reason, Data1} -> {stop, Reason, Data1};
        Data1 -> keep_or_recheck(State, Data1)
    end.

handle_agent_info(#locks_info{} = Info, State, Data) ->
    keep_or_recheck(State, locks_info(Info, Data));
handle_agent_info({have_all_locks, _}, State, Data)
  when State =:= candidate; State =:= following ->
    case try_enter_syncing(Data) of
        {syncing, Data1} -> {next_state, syncing, Data1};
        {candidate, Data1} -> {next_state, candidate, Data1}
    end;
handle_agent_info({have_all_locks, _}, syncing, Data) ->
    {keep_state, Data};
handle_agent_info({have_all_locks, _}, leader, Data) ->
    {keep_state, Data};
handle_agent_info(waiting, leader, Data) ->
    ?event(clearing_leader, Data),
    {next_state, candidate, set_leader_uncertain(Data)};
handle_agent_info(waiting, following, Data) ->
    %% Contest incomplete (e.g. peer island gone); drop remote belief.
    {next_state, candidate, set_leader_uncertain(Data)};
handle_agent_info(waiting, State, Data) ->
    keep_or_recheck(State, Data);
handle_agent_info(_, State, Data) ->
    keep_or_recheck(State, Data).

keep_or_recheck(_State, Data) ->
    {keep_state, Data}.

next_if_lost_self(leader, #st{leader = L} = Data) when L =/= self() ->
    case L of
        undefined -> {next_state, candidate, Data};
        _ when is_pid(L) -> {next_state, following, Data};
        _ -> {next_state, candidate, Data}
    end;
next_if_lost_self(following, #st{leader = undefined} = Data) ->
    {next_state, candidate, Data};
next_if_lost_self(State, Data) ->
    keep_or_recheck(State, Data).

%% ==================================================================
%% Contest → syncing → leader
%% ==================================================================

maybe_recheck_contest(#st{agent = undefined} = Data) ->
    {keep_state, Data};
maybe_recheck_contest(#st{agent = A, role = candidate} = Data) ->
    case locks_agent:transaction_status(A) of
        {have_all_locks, _} ->
            case try_enter_syncing(Data) of
                {syncing, Data1} -> {next_state, syncing, Data1};
                {candidate, Data1} -> {keep_state, Data1}
            end;
        _ ->
            {keep_state, Data}
    end;
maybe_recheck_contest(Data) ->
    {keep_state, Data}.

try_enter_syncing(#st{agent = A, role = candidate} = S) ->
    {_, Locks} = LockInfo = locks_agent:lock_info(A),
    S1 = refresh_vector(LockInfo, S),
    S2 = lists:foldl(
           fun(#lock{object = {OID, Node}} = Lx, Sx) ->
                   lock_info(Lx#lock{object = OID}, Node, Sx)
           end, S1, Locks),
    %% Clear any stale remote leader belief before taking the merge mutex.
    S3 = S2#st{leader = undefined},
    case S3#st.vector of
        #{leader := Lv} when is_pid(Lv), Lv =/= A ->
            %% Another agent uniquely holds the lock on the visible set.
            ?event(vector_questions_leader, S3),
            {candidate, set_leader_uncertain(S3)};
        _ ->
            %% sole holder is us, or `none` (split view) — take merge mutex.
            {syncing, start_sync_lock(S3)}
    end;
try_enter_syncing(S) ->
    {candidate, S}.

start_sync_lock(#st{lock = Lock, nodes = Nodes,
                    sync_worker = undefined} = St) ->
    Me = self(),
    {Worker, MRef} =
        spawn_monitor(fun() -> sync_lock_proc(Me, Lock, Nodes) end),
    put({?MODULE, sync_worker_mref}, MRef),
    St#st{sync_worker = Worker};
start_sync_lock(St) ->
    St.

sync_lock_proc(Leader, Lock, Nodes) ->
    [?MODULE, Resource] = Lock,
    SyncLock = [?MODULE, sync, Resource],
    try
        {ok, Agent} = locks:spawn_agent([{abort_on_deadlock, true},
                                         {await_nodes, false}]),
        try locks:lock(Agent, SyncLock, write, Nodes, all_alive) of
            {ok, _} ->
                Leader ! {?MODULE, sync_lock_ok, self()},
                receive
                    {?MODULE, sync_lock_release, Leader} -> ok
                after 60000 ->
                        ok
                end
        after
            case is_process_alive(Agent) of
                true  -> _ = (catch locks:end_transaction(Agent));
                false -> ok
            end
        end
    catch
        _:_ ->
            Leader ! {?MODULE, sync_lock_failed, self()}
    end.

do_sync_lock_acquired(Worker, #st{sync_worker = Worker} = St) ->
    case erase({?MODULE, sync_worker_mref}) of
        undefined -> ok;
        MRef -> erlang:demonitor(MRef, [flush])
    end,
    try
        St1 = become_leader_(St#st{sync_worker = undefined}),
        {leader, St1}
    after
        Worker ! {?MODULE, sync_lock_release, self()}
    end;
do_sync_lock_acquired(Worker, St) ->
    Worker ! {?MODULE, sync_lock_release, self()},
    {candidate, St}.

do_sync_lock_aborted(Worker, #st{sync_worker = Worker} = St) ->
    case erase({?MODULE, sync_worker_mref}) of
        undefined -> ok;
        MRef -> erlang:demonitor(MRef, [flush])
    end,
    set_leader_uncertain(St#st{sync_worker = undefined});
do_sync_lock_aborted(_Worker, St) ->
    St.

cancel_sync_worker(#st{sync_worker = undefined} = S) ->
    S;
cancel_sync_worker(#st{sync_worker = W} = S) when is_pid(W) ->
    case erase({?MODULE, sync_worker_mref}) of
        undefined -> ok;
        MRef -> erlang:demonitor(MRef, [flush])
    end,
    W ! {?MODULE, sync_lock_release, self()},
    S#st{sync_worker = undefined}.

become_leader_(#st{election_ref = {L, _, _}, mod = M, mod_state = MSt,
                   candidates = Cands, synced = Synced,
                   workers = Ws, synced_workers = SyncedWs} = S0)
  when L =:= self() ->
    S = S0#st{leader = self(), election_ref = new_election_ref(S0)},
    ?event(become_leader_again, S),
    send_all(S, {?MODULE, affirm_leader, self(), S#st.election_ref}),
    case {Cands -- Synced, Ws -- SyncedWs} of
        {[], []} ->
            S;
        _ ->
            {Broadcast, ModSt1} =
                case M:elected(MSt, opaque(S), undefined) of
                    {ok, Msg1, Msg2, MSt1} -> {{Msg1, Msg2}, MSt1};
                    {ok, Msg, MSt1}        -> {{Msg, Msg}, MSt1};
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

%% ==================================================================
%% Society / candidates / nodes
%% ==================================================================

society_group(Lock) ->
    {?MODULE, Lock}.

default_lock(Mod, undefined) -> Mod;
default_lock(Mod, Regname)   -> {Mod, Regname}.

society_joined(Pids, S) ->
    lists:foldl(fun society_add_member/2, S, Pids).

society_add_member(Pid, S) when Pid =:= self() ->
    S;
society_add_member(Pid, #st{role = candidate} = S) ->
    N = node(Pid),
    S1 = case ordsets:is_element(N, S#st.nodes) of
             true  -> S;
             false -> include_node(N, S)
         end,
    add_cand(Pid, S1);
society_add_member(_Pid, S) ->
    S.

society_left(Pids, S) ->
    lists:foldl(fun(P, Sx) -> maybe_remove_cand(candidate, P, Sx) end, S, Pids).

nodeup(N, #st{nodes = Nodes} = S) ->
    case ordsets:is_element(N, Nodes) of
        true  -> S;
        false -> include_node(N, S)
    end.

include_node(N, #st{agent = undefined, nodes = Nodes} = S) ->
    S#st{nodes = ordsets:add_element(N, Nodes)};
include_node(N, #st{agent = A, lock = Lock, nodes = Nodes} = S) ->
    ?event({include_node, N}),
    case ordsets:is_element(N, nodes()) of
        true  -> ok;
        false -> asynch_ping(N)
    end,
    locks_agent:lock_nowait(A, Lock, write, [N], all_alive),
    S#st{nodes = ordsets:add_element(N, Nodes)}.

locks_info(#locks_info{lock = #lock{object = Lock} = L, where = Node},
           #st{lock = Lock} = S) ->
    lock_info(L, Node, S);
locks_info(_, S) ->
    S.

lock_info(#lock{queue = Q}, _Node, #st{} = S) ->
    NewCands = new_cands(Q, S),
    lists:foldl(
      fun(C, Acc) ->
              N = node(C),
              SAcc = case ordsets:is_element(N, Acc#st.nodes) of
                         true  -> Acc;
                         false -> include_node(N, Acc)
                     end,
              add_cand(C, SAcc)
      end, S, NewCands).

new_cands(Q, #st{candidates = Cands}) ->
    Clients = [C || #w{entries = [#entry{client = C}]} <- Q, C =/= self()],
    Clients -- Cands.

down({'DOWN', Ref, _, Pid, _} = Msg,
     #st{leader = LPid, mod = M, mod_state = MSt, buffered = Buf} = S) ->
    case erase({?MODULE, monitor, Ref}) of
        undefined ->
            apply_cb(M:handle_info(Msg, MSt, opaque(S)), S);
        Type ->
            S1 =
                if Pid == LPid ->
                        _ = [reply(From, '$leader_died') || {_, From} <- Buf],
                        S#st{leader = undefined, buffered = [],
                             synced = [], synced_workers = []};
                   true ->
                        S
                end,
            S2 = maybe_remove_cand(Type, Pid, S1),
            if Pid == LPid -> {S2, lost_leader};
               true -> S2
            end
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
    IsSynced = is_synced(Pid, Type, S0),
    if L == self(), IsSynced == false ->
            S = refresh_vector(S0),
            ERef = S#st.election_ref,
            case M:elected(MSt, opaque(S), Pid) of
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
            S0
    end.

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
                                      leader = L, mod = M,
                                      mod_state = MSt} = S) ->
    S1 = S#st{candidates = Cs -- [Pid], synced = Synced -- [Pid]},
    if L == self() ->
            apply_cb(M:handle_DOWN(Pid, MSt, opaque(S1)), S1);
       true ->
            S1
    end;
maybe_remove_cand(worker, Pid, #st{workers = Ws} = S) ->
    S#st{workers = Ws -- [Pid]}.

worker_announced(W, #st{workers = Workers} = S) ->
    case lists:member(W, Workers) of
        true ->
            S;
        false ->
            Ref = erlang:monitor(process, W),
            put({?MODULE, monitor, Ref}, worker),
            maybe_announce_leader(W, worker, S#st{workers = [W|Workers]})
    end.

%% ==================================================================
%% Peer protocol
%% ==================================================================

on_leader_uncertain(L, Synced, SyncedWs, #st{leader = MyL} = S) ->
    case MyL of
        Me when Me == self() ->
            lists:foldl(
              fun({Pid, Type}, Sx) ->
                      maybe_announce_leader(
                        Pid, Type, remove_synced(Pid, Type, Sx))
              end, S,
              [{P, candidate} || P <- [L|Synced]]
              ++ [{P, worker} || P <- SyncedWs]);
        L ->
            case S#st.agent of
                undefined -> ok;
                A -> locks_agent:change_flag(A, notify, true)
            end,
            S#st{leader = undefined, synced = [], synced_workers = []};
        _ ->
            S
    end.

leader_affirmed(L, ERef, #st{leader = L, election_ref = ERef} = S) ->
    S;
leader_affirmed(_L, _ERef, #st{leader = Me} = S) when Me == self() ->
    set_leader_uncertain(S);
leader_affirmed(L, ERef, #st{} = S) ->
    request_sync(L, ERef, S).

on_ensure_sync(Pid, Type, _ERef, #st{leader = Me} = S) when Me == self() ->
    do_ensure_sync(Pid, Type, S);
on_ensure_sync(Pid, Type, ERef, S) ->
    sync_requested(Pid, Type, ERef, S).

sync_requested(Pid, Type, ERef,
               #st{leader = undefined, election_ref = ERef,
                   vector = #{leader := Ag}, agent = A} = S)
  when Ag == A, A =/= undefined ->
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

request_sync(L, ERef, S) ->
    snd(L, {?MODULE, ensure_sync, self(), S#st.role, ERef}),
    S#st{leader = undefined, election_ref = ERef}.

from_leader(L, ERef, Msg, #st{leader = L, election_ref = ERef,
                              mod = M, mod_state = MSt} = S) ->
    apply_cb(M:from_leader(Msg, MSt, opaque(S)), S);
from_leader(OtherL, _ERef, _Msg, S) ->
    S1 = refresh_vector(S),
    case S1#st.vector of
        #{leader := Lv} when Lv =/= OtherL ->
            set_leader_uncertain(S1);
        _ ->
            request_sync(OtherL, _ERef, S)
    end.

leader_announced(L, ERef, Msg, #st{election_ref = ERef,
                                   mod = M, mod_state = MSt} = S) ->
    apply_cb(M:surrendered(MSt, Msg, opaque(S)),
             S#st{leader = L, synced = [], synced_workers = []});
leader_announced(L, ERef, Msg, #st{mod = M, mod_state = MSt} = S) ->
    #st{vector = V} = S1 = refresh_vector(S),
    {_, _, Vl} = ERef,
    case Vl == V of
        true ->
            S2 = S1#st{leader = L, election_ref = ERef,
                       synced = [], synced_workers = []},
            apply_cb(M:surrendered(MSt, Msg, opaque(S1)), S2);
        false ->
            set_leader_uncertain(S1)
    end.

set_leader_uncertain(#st{agent = A} = S) ->
    S1 = cancel_sync_worker(S),
    send_all(S1, {?MODULE, leader_uncertain, self(),
                  S1#st.synced, S1#st.synced_workers}),
    case A of
        undefined -> ok;
        _ -> locks_agent:async_await_all_locks(A)
    end,
    S1#st{leader = undefined, sync_worker = undefined,
          synced = [], synced_workers = []}.

set_leader_undefined(#st{} = S) ->
    S#st{leader = undefined, synced = [], synced_workers = []}.

%% ==================================================================
%% Calls / callbacks helpers
%% ==================================================================

forward_leader_call(Msg, From, L, #st{buffered = Buf} = Data) ->
    MyRef = make_ref(),
    catch erlang:send(L, {'$gen_call', {self(), MyRef}, Msg}, [noconnect]),
    {keep_state, Data#st{buffered = [{MyRef, From}|Buf]}}.

debug_info(S) ->
    [{leader, leader(S)},
     {leader_node, leader_node(S)},
     {candidates, candidates(S)},
     {new_candidates, new_candidates(S)},
     {workers, workers(S)},
     {module, S#st.mod},
     {mod_state, S#st.mod_state}].

info_item(leader, S) -> leader(S);
info_item(leader_node, S) -> leader_node(S);
info_item(candidates, S) -> candidates(S);
info_item(new_candidates, S) -> new_candidates(S);
info_item(workers, S) -> workers(S);
info_item(module, S) -> S#st.mod;
info_item(mod_state, S) -> S#st.mod_state;
info_item(_, _) -> undefined.

apply_cb({noreply, MSt}, S) -> S#st{mod_state = MSt};
apply_cb({ok, MSt}, S) -> S#st{mod_state = MSt};
apply_cb({ok, Msg, MSt}, #st{leader = L} = S) when L == self() ->
    do_broadcast(S#st{mod_state = MSt}, Msg);
apply_cb({ok, _Msg, _MSt}, _S) ->
    error(not_leader);
apply_cb({stop, Reason, MSt}, S) ->
    {stop, Reason, S#st{mod_state = MSt}}.

apply_cb_reply(CBRes, From, S) ->
    apply_cb_reply(CBRes, From, S, fun(X) -> X end).

apply_cb_reply({reply, Reply, MSt}, From, S, F) ->
    reply(From, F(Reply)),
    S#st{mod_state = MSt};
apply_cb_reply({reply, Reply, Msg, MSt}, From, #st{leader = L} = S, F)
  when L == self() ->
    S1 = do_broadcast(S#st{mod_state = MSt}, Msg),
    reply(From, F(Reply)),
    S1;
apply_cb_reply({reply, _Reply, _Msg, _MSt}, _From, _S, _F) ->
    error(not_leader);
apply_cb_reply({noreply, MSt}, _From, S, _F) ->
    S#st{mod_state = MSt};
apply_cb_reply({stop, Reason, Reply, MSt}, From, S, F) ->
    reply(From, F(Reply)),
    {stop, Reason, S#st{mod_state = MSt}};
apply_cb_reply({stop, Reason, MSt}, _From, S, _F) ->
    {stop, Reason, S#st{mod_state = MSt}}.

%% ==================================================================
%% Broadcast / vector
%% ==================================================================

new_election_ref(#st{vector = V}) ->
    {self(), erlang:monotonic_time(microsecond), V}.

msg(from_leader, ERef, Msg) ->
    {?MODULE, from_leader, self(), ERef, Msg};
msg(am_leader, ERef, Msg) ->
    {?MODULE, am_leader, self(), ERef, Msg}.

opaque(S) ->
    S.

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
    [P ! Msg || P <- Pids],
    ok.

snd(Pid, Msg) ->
    Pid ! Msg.

get_opt(K, Opts, Default) ->
    case lists:keyfind(K, 1, Opts) of
        {_, V} -> V;
        false  -> Default
    end.

asynch_ping(N) ->
    rpc:cast(N, erlang, is_atom, [true]).

refresh_vector(#st{agent = A} = S) ->
    refresh_vector(locks_agent:lock_info(A), S).

refresh_vector(LockInfo, #st{lock = L} = S) ->
    maybe_refresh_eref(S#st{vector = vector(L, LockInfo)}).

maybe_refresh_eref(#st{election_ref = {Me, _, Ve}, vector = V} = S)
  when Me == self(), Ve =/= V ->
    S#st{election_ref = new_election_ref(S)};
maybe_refresh_eref(S) ->
    S.

vector(Lock, {_Pending, Locks}) ->
    NewVector = lists:sort(
                  [{N, V} || #lock{object = {L, N}, version = V} <- Locks,
                             L =:= Lock]),
    case length(lists:usort([lock_holder(Lx) || Lx <- Locks])) == 1 of
        true ->
            #{leader => lock_holder(hd(Locks)), vector => NewVector};
        false ->
            #{leader => none, vector => NewVector}
    end.

lock_holder(#lock{queue = [#w{entries = [#entry{agent = A}]}|_]}) ->
    A;
lock_holder(_) ->
    none.
