%% -*- mode: erlang; indent-tabs-mode: nil; -*-
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
%% <pre>
%% Leader instance:
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
%% @end
-module(locks_leader).
-behaviour(gen_server).
-compile(export_all).

-export([start_link/2, start_link/3, start_link/4,
	 call/2, call/3,
	 cast/2,
	 leader_call/2,
	 leader_cast/2]).

-export([init/1,
	 handle_info/2,
	 handle_cast/2,
	 handle_call/3,
	 terminate/2,
	 code_change/3]).

-export([candidates/1,
	 workers/1,
	 leader/1]).

-export_type([leader_info/0, mod_state/0, msg/0]).


-type mod_state() :: any().
-type msg() :: any().
-type reply() :: any().
-type from() :: {pid(), _Tag :: any()}.
-type reason() :: any().
-opaque leader_info() :: fun( (atom()) -> [atom()] ).
-type server_ref() :: atom() | pid().
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
	  agent,
	  leader,
	  nodes = [],
	  candidates = [],
	  workers = [],
	  gen_server_opts = [],
	  regname,
	  mod,
	  mod_state,
	  buffered = []}).

-include("locks.hrl").

-define(event(E), event(?LINE, E, none)).
-define(event(E, S), event(?LINE, E, S)).

-callback init(any()) -> mod_state().
-callback elected(mod_state(), leader_info(), undefined | pid()) ->
    cb_return() | {reply, msg(), mod_state()}.
-callback surrendered(mod_state(), msg(), leader_info()) -> cb_return().
-callback handle_DOWN(pid(), mod_state(), leader_info()) -> cb_return().
-callback handle_leader_call(msg(), from(), mod_state(), leader_info()) ->
    cb_reply().
-callback handle_leader_cast(msg(), mod_state(), leader_info()) -> cb_return().
-callback from_leader(msg(), mod_state(), leader_info()) -> cb_return().
-callback handle_call(msg(), from(), mod_state(), leader_info()) -> cb_reply().
-callback handle_cast(msg(), mod_state(), leader_info()) -> cb_return().
-callback handle_info(msg(), mod_state(), leader_info()) -> cb_return().

%% candidates(F) when is_function(F, 1) ->
%%     F(candidates).
candidates(#st{candidates = C}) ->
    C.

%% workers(F) when is_function(F, 1) ->
%%     F(workers).
workers(#st{workers = W}) ->
    W.

%% leader(F) when is_function(F, 1) ->
%%     F(leader).
leader(#st{leader = L}) ->
    L.

start_link(Module, St) ->
    start_link(Module, St, []).

start_link(Module, St, Options) ->
    proc_lib:start_link(?MODULE, init, [{Module, St, Options, self()}]).

start_link(Reg, Module, St, Options) when is_atom(Reg), is_atom(Module) ->
    proc_lib:start_link(?MODULE, init, [{Reg, Module, St, Options, self()}]).

-spec leader_call(Name::server_ref(), Request::term()) -> term().
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

leader_cast(L, Msg) ->
    ?event({leader_cast, L, Msg}),
    gen_server:cast(L, {'$leader_cast', Msg}).

call(L, Req) ->
    R = gen_server:call(L, Req),
    ?event({call_return, L, Req, R}),
    R.

call(L, Req, Timeout) ->
    R = gen_server:call(L, Req, Timeout),
    ?event({call_return, L, Req, Timeout, R}),
    R.

cast(L, Msg) ->
    ?event({cast, L, Msg}),
    gen_server:cast(L, Msg).

init({Reg, Module, St, Options, P}) ->
    register(Reg, self()),
    init_(Module, St, Options, P, Reg);
init({Module, St, Options, P}) ->
    init_(Module, St, Options, P, undefined).

init_(Module, ModSt0, Options, Parent, Reg) ->
    S0 = #st{},
    %% Mode = get_opt(mode, Options, S0#st.mode),
    Role = get_opt(role, Options, S0#st.role),
    Lock = [?MODULE, get_opt(resource, Options, Module)],
    ModSt = try Module:init(ModSt0) of
		{ok, MSt} -> MSt;
		{error, Reason} ->
		    abort_init(Reason, Parent)
	    catch
		error:Error ->
		    abort_init(Error, Parent)
	    end,
    AllNodes = [node()|nodes()],
    Agent =
	case Role of
	    candidate ->
		net_kernel:monitor_nodes(true),
		{ok, A} = locks_agent:start([{notify,true}]),
		locks_agent:lock_nowait(
		  A, Lock, write, AllNodes, majority_alive),
		A;
	    worker ->
		%% watch our own local lock. All candidates will try for it.
		locks_server:watch(Lock, [node()]),
		undefined
	end,
    proc_lib:init_ack(Parent, {ok, self()}),
    case safe_loop(#st{agent = Agent,
		       role = Role,
		       mod = Module,
		       mod_state = ModSt,
		       lock = Lock,
		       %% mode = Mode,
		       nodes = AllNodes,
		       regname = Reg}) of
	{stop, StopReason, _} ->
	    error(StopReason);
	_ ->
	    ok
    end.

abort_init(Reason, Parent) ->
    proc_lib:init_ack(Parent, {error, Reason}),
    exit(Reason).

noreply(#st{leader = undefined} = S) ->
    safe_loop(S);
noreply(#st{initial = false} = S) ->
    {noreply, S};
noreply(#st{initial = true, regname = R, gen_server_opts = Opts} = S) ->
    if R == undefined -> gen_server:enter_loop(?MODULE, Opts, S);
       true           -> gen_server:enter_loop(?MODULE, Opts, S, R)
    end;
noreply(Stop) when element(1, Stop) == stop ->
    Stop.


%% We enter safe_loop/1 as soon as no leader is elected
safe_loop(#st{agent = A} = S) ->
    receive
	{nodeup, N} ->
	    ?event({nodeup, N}, S),
	    noreply(nodeup(N, S));
	{locks_agent, A, Info} = _Msg ->
	    ?event(_Msg, S),
	    case Info of
		{have_all_locks,_} -> noreply(become_leader(S));
		#locks_info{}      -> noreply(locks_info(Info, S))
	    end;
	#locks_info{} = I ->   % if worker - direct from locks_server
	    ?event(I, S),
	    noreply(locks_info(I, S));
	{?MODULE, am_leader, L, LeaderMsg} = _Msg ->
	    ?event(_Msg, S),
	    noreply(leader_announced(L, LeaderMsg, S));
	{?MODULE, am_worker, W} = _Msg ->
	    ?event(_Msg, S),
	    noreply(worker_announced(W, S));
	{'DOWN',_,_,_,_} = DownMsg ->
	    ?event(DownMsg, S),
	    noreply(down(DownMsg, S))
    end.

event(_Line, _Event, _State) ->
    ok.

handle_info({nodeup, N} = _Msg, #st{role = candidate} = S) ->
    ?event({handle_info, _Msg}, S),
    noreply(nodeup(N, S));
handle_info({'DOWN', _, _, _, _} = Msg, S) ->
    ?event({handle_info, Msg}, S),
    noreply(down(Msg, S));
handle_info({locks_agent, A, Info} = _Msg, #st{agent = A} = S) ->
    ?event({handle_info, _Msg}, S),
    case Info of
	{have_all_locks,_} -> noreply(become_leader(S));
	#locks_info{}      -> noreply(locks_info(Info, S))
    end;
handle_info({?MODULE, am_worker, W} = _Msg, #st{} = S) ->
    ?event({handle_info, _Msg}, S),
    noreply(worker_announced(W, S));
handle_info(#locks_info{lock = #lock{object = Lock}} = I,
	    #st{lock = Lock} = S) ->
    {noreply, locks_info(I, S)};
handle_info({?MODULE, am_leader, L, LeaderMsg} = _M, S) ->
    ?event({handle_info, _M}, S),
    noreply(leader_announced(L, LeaderMsg, S));
handle_info({Ref, {'$locks_leader_reply', Reply}} = _M,
	    #st{buffered = Buf} = S) ->
    ?event({handle_info, _M}, S),
    case lists:keytake(Ref, 2, Buf) of
	{value, {_, OrigRef}, Buf1} ->
	    gen_server:reply(OrigRef, {'$locks_leader_reply', Reply}),
	    noreply(S#st{buffered = Buf1});
	false ->
	    noreply(S)
    end;
handle_info(Msg, #st{mod = M, mod_state = MSt} = S) ->
    ?event({handle_info, Msg}, S),
    noreply(callback(M:handle_info(Msg, MSt, opaque(S)), S)).

handle_cast({'$locks_leader_cast', Msg} = Cast, #st{mod = M, mod_state = MSt,
						    leader = L} = S) ->
    if L == self() ->
	    noreply(callback(M:handle_leader_cast(Msg, MSt, opaque(S)), S));
       true ->
	    gen_server:cast(L, Cast),
	    noreply(S)
    end;
handle_cast(Msg, #st{mod = M, mod_state = MSt} = St) ->
    noreply(callback(M:handle_cast(Msg, MSt, opaque(St)), St)).

handle_call({'$locks_leader_call', Req} = Msg, From,
	    #st{mod = M, mod_state = MSt, leader = L,
		buffered = Buf} = S) ->
    if L == self() ->
	    noreply(
	      callback_reply(
		M:handle_leader_call(Req, From, MSt, opaque(S)), From,
		fun(R) -> {'$locks_leader_reply', R} end, S));
       true ->
	    NewFrom = {self(), make_ref()},
	    catch erlang:send(L, {'$gen_call', NewFrom, Msg}, [noconnect]),
	    noreply(S#st{buffered = [{NewFrom, From}|Buf]})
    end;
handle_call(R, F, #st{mod = M, mod_state = MSt} = S) ->
    noreply(
      callback_reply(M:handle_call(R, F, MSt, opaque(S)), F,
		     fun(R1) -> R1 end, S)).

terminate(_, _) ->
    ok.

code_change(_, St, _) ->
    {ok, St}.


nodeup(N, #st{agent = A, candidates = Cands, lock = Lock} = S) ->
    case [true || P <- Cands, node(P) == N] of
	[_|_] ->
	    ok;
	[] ->
	    locks_agent:lock_nowait(A, Lock, write, [N], majority_alive)
    end,
    S.

locks_info(#locks_info{lock = #lock{object = Lock, queue = Q}},
	   #st{lock = Lock} = S) ->
    lists:foldl(fun(#r{entries = _}, _Acc) ->
			error(illegal_read_lock);
		   (#w{entry = #entry{client = C}}, Acc) ->
			add_cand(C, Acc)
		end, S, Q);
locks_info(_, S) ->
    S.

down({'DOWN', Ref, Pid, _, _} = Msg,
     #st{leader = LPid, mod = M, mod_state = MSt} = S) ->
    case erase({?MODULE,monitor,Ref}) of
	undefined ->
	    %% not mine; pass on to callback
	    callback(M:handle_info(Msg, MSt, opaque(S)), S);
	Type ->
	    S1 = if Pid == LPid ->
			 [gen_server:reply(From,'$leader_died')
			  || {_, From} <- S#st.buffered],
			 S#st{leader = undefined, buffered = []};
		    true -> S
		 end,
	    maybe_remove_cand(Type, Pid, S1)
    end.

add_cand(Client, S) when Client == self() ->
    S;
add_cand(Client, #st{candidates = Cands, role = Role} = S) ->
    case lists:member(Client, Cands) of
	false ->
	    if Role == worker ->
		    Client ! {?MODULE, am_worker, self()};
	       true ->
		    ok
	    end,
	    maybe_announce_leader(
	      Client, S#st{candidates = [Client | Cands]});
	true ->
	    S
    end.

maybe_announce_leader(Pid, #st{leader = L, mod = M, mod_state = MSt} = S) ->
    if L == self() ->
	    case M:elected(MSt, opaque(S), Pid) of
		{reply, Msg, MSt1} ->
		    Pid ! {?MODULE, am_leader, L, Msg},
		    S#st{mod_state = MSt1};
		{ok, MSt1} ->
		    S#st{mod_state = MSt1};
		{ok, Msg, MSt1} ->
		    broadcast(S#st{mod_state = MSt1},
			      {?MODULE, am_leader, L, Msg})
	    end;
       true ->
	    S
    end.

maybe_remove_cand(candidate, Pid, #st{candidates = Cs, leader = L,
				      mod = M, mod_state = MSt} = S) ->
    S1 = S#st{candidates = Cs -- [Pid]},
    if L == self() ->
	    callback(M:handle_DOWN(Pid, MSt, opaque(S1)), S1);
       true ->
	    S1
    end;
maybe_remove_cand(worker, Pid, #st{workers = Ws} = S) ->
    S#st{workers = Ws -- [Pid]}.


become_leader(#st{leader = L} = S) when L == self() ->
    S;
become_leader(#st{mod = M, mod_state = MSt} = S) ->
    ?event(become_leader, S),
    case M:elected(MSt, opaque(S), undefined) of
	{ok, Msg, MSt1} ->
	    broadcast(S#st{mod_state = MSt1, leader = self()},
		      {?MODULE, am_leader, self(), Msg});
	{error, Reason} ->
	    error(Reason)
    end.

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
	    broadcast(S#st{mod_state = MSt}, Msg);
       true ->
	    error(not_leader)
    end;
callback({stop, Reason, MSt}, S) ->
    {stop, Reason, S#st{mod_state = MSt}}.


callback_reply({reply, Reply, MSt}, From, F, S) ->
    gen_server:reply(From, F(Reply)),
    S#st{mod_state = MSt};
callback_reply({reply, Reply, Msg, MSt}, From, F, S) ->
    if S#st.leader == self() ->
	    S1 = S#st{mod_state = MSt},
	    broadcast(S1, Msg),
	    gen_server:reply(From, F(Reply)),
	    S1;
       true ->
	    error(not_leader)
    end;
callback_reply({noreply, MSt}, _, _, S) ->
    S#st{mod_state = MSt};
callback_reply({stop, Reason, Reply, MSt}, From, F, S) ->
    gen_server:reply(From, F(Reply)),
    {stop, Reason, S#st{mod_state = MSt}};
callback_reply({stop, Reason, MSt}, _, _, S) ->
    {stop, Reason, S#st{mod_state = MSt}}.

broadcast(#st{candidates = Cands, workers = Ws} = S, Msg) ->
    [P ! Msg || P <- Cands],
    [P ! Msg || P <- Ws],
    S.

from_leader(Msg, #st{mod = M, mod_state = MSt} = S) ->
    callback(M:from_leader(Msg, MSt, opaque(S)), S).

leader_announced(L, Msg, #st{leader = L, mod = M, mod_state = MSt} = S) ->
    callback(M:surrendered(MSt, Msg, opaque(S)), S);
leader_announced(L, Msg, #st{leader = OldLeader,
			     mod = M, mod_state = MSt} = S) ->
    Ref = erlang:monitor(process, L),
    put({?MODULE,monitor,Ref}, candidate),
    if OldLeader == self() ->
	    %% split brain
	    io:fwrite("Split brain detected! (leader = ~p)~n", [L]);
       true ->
	    ok
    end,
    S1 = S#st{leader = L},
    callback(M:surrendered(MSt, Msg, opaque(S1)), S1).

worker_announced(W, #st{workers = Workers} = S) ->
    case lists:member(W, Workers) of
	true ->
	    S;
	false ->
	    Ref = erlang:monitor(process, W),
	    put({?MODULE,monitor,Ref}, worker),
	    maybe_announce_leader(W, S#st{workers = [W|Workers]})
    end.

get_opt(K, Opts) ->
    case lists:keyfind(K, 1, Opts) of
	{_, Val} ->
	    Val;
	false ->
	    error({required, K})
    end.

get_opt(K, Opts, Default) ->
    case lists:keyfind(K, 1, Opts) of
	{_, V} ->
	    V;
	false ->
	    Default
    end.
