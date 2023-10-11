-module(locks_leader_SUITE).

%% common_test exports
-export(
   [
    all/0, groups/0, suite/0,
    init_per_suite/1, end_per_suite/1,
    init_per_group/2, end_per_group/2,
    init_per_testcase/2, end_per_testcase/2
   ]).

%% test case exports
-export(
   [
    local_dict/1,
    gdict_simple_netsplit/1,
    gdict_all_nodes/1,
    gdict_netsplit/1,
    start_incremental/1,
    random_netsplits/1
   ]).

-export([patch_net_kernel/0,
         proxy/0,
         connect_nodes/1,
         disconnect_nodes/1,
         unbar_nodes/0,
         leader_nodes/1,
         same_leaders/1]).

-include_lib("common_test/include/ct.hrl").
-define(retry_not(Res, Expr), retry(fun() ->
                                            __E = Expr,
                                            {false, _} = {Res == __E, __E},
                                            __E
                                    end, 10)).
-define(retry(Res, Expr), retry(fun() ->
                                        __E = Expr,
                                        {ok, Res} = {ok, __E},
                                        __E
                                end, 10)).
-define(NOT(Expr), {'$not', Expr}).

all() ->
    [
     {group, g_local},
     {group, g_2},
     {group, g_3},
     {group, g_4},
     {group, g_5},
     {group, g_2i},
     {group, g_3i},
     {group, g_4i},
     {group, g_5i},
     {group, random_netsplits}
    ].

groups() ->
    [
     {g_local, [], [local_dict]},
     {g_2, [], [gdict_all_nodes,
                gdict_simple_netsplit]},
     {g_3, [], [gdict_all_nodes,
                gdict_netsplit]},
     {g_4, [], [gdict_all_nodes,
                gdict_netsplit]},
     {g_5, [],   [gdict_all_nodes,
                  gdict_netsplit]},
     {g_2i, [], [start_incremental]},
     {g_3i, [], [start_incremental]},
     {g_4i, [], [start_incremental]},
     {g_5i, [], [start_incremental]},
     {random_netsplits, [], [random_netsplits]}
    ].

suite() ->
    [].

init_per_suite(Config) ->
    application:start(sasl),
    Config.

end_per_suite(_Config) ->
    application:stop(sasl),
    ok.

init_per_group(g_local, Config) ->
    application:start(locks),
    Config;
init_per_group(g_2, Config) ->
    ct:log("group g_2; my pid: ~p", [self()]),
    application:start(locks),
    start_slaves(node_list(2), Config);
init_per_group(g_3, Config) ->
    application:start(locks),
    start_slaves(node_list(3), Config);
init_per_group(g_4, Config) ->
    application:start(locks),
    start_slaves(node_list(4), Config);
init_per_group(g_5, Config) ->
    application:start(locks),
    start_slaves(node_list(5), Config);
init_per_group(g_2i, Config) ->
    application:start(locks),
    start_slaves(node_list(2), Config);
init_per_group(g_3i, Config) ->
    application:start(locks),
    start_slaves(node_list(3), Config);
init_per_group(g_4i, Config) ->
    application:start(locks),
    start_slaves(node_list(4), Config);
init_per_group(g_5i, Config) ->
    application:start(locks),
    start_slaves(node_list(5), Config);
init_per_group(random_netsplits, Config) ->
    application:start(locks),
    start_slaves(node_list(10), Config).

end_per_group(g_local, _Config) ->
    application:stop(locks);
end_per_group(_Group, Config) ->
    application:stop(locks),
    stop_slaves(Config),
    ok.

init_per_testcase(_Case, Config) ->
    Config.

end_per_testcase(Case, Config) when Case==gdict_all_nodes;
                                    Case==gdict_netsplit ->
    proxy_multicall(get_slave_nodes(Config),
                    application, stop, [locks]),
    ok;
end_per_testcase(_Case, _Config) ->
    ok.


%% ============================================================
%% Test cases
%% ============================================================

local_dict(Config) ->
    with_trace(fun local_dict_/1, Config, "leader_test_local_dict").

local_dict_(_Config) ->
    dbg:tracer(),
    dbg:tpl(locks_leader, x),
    dbg:p(all,[c]),
    Name = {gdict, ?LINE},
    Dicts = lists:map(
              fun(_) ->
                      {ok,D} = gdict:new_opt([{resource, Name}]),
                      D
              end, [1,2,3]),
    lists:foreach(fun(D) ->
                          ok = gdict:store(a, 17, D),
                          {ok,17} = gdict:find(a, D)
                  end, Dicts),
    _ = [begin unlink(D), exit(D,kill) end || D <- Dicts],
    ok.

gdict_all_nodes(Config) ->
    with_trace(fun gdict_all_nodes_/1, Config, "leader_tests_all_nodes").

gdict_all_nodes_(Config) ->
    ct:log("gdict_all_nodes(); my pid: ~p", [self()]),
    [H|T] = Ns = get_slave_nodes(Config),
    OtherNodes = [N || #{node := N} <- T],
    Name = [?MODULE,?LINE],
    ct:log("OtherNodes = ~p", [OtherNodes]),
    ok = call_proxy(H, ?MODULE, connect_nodes, [OtherNodes]),
    OtherNodes = call_proxy(H, erlang, nodes, []),
    ok = lists:foreach(
           fun(ok) -> ok end,
           proxy_multicall(Ns, application, start, [locks])),
    Results = proxy_multicall(Ns, gdict, new_opt, [[{resource, Name}]]),
    Dicts = lists:map(
              fun({ok,D}) -> D end, Results),
    ok = gdict:store(a,1,hd(Dicts)),
    [] = lists:filter(
           fun({_Node,{ok,1}}) -> false;
              (_) -> true
           end,
           lists:zip(nodes_of(Ns),
		     [?retry({ok,1}, gdict:find(a,D)) || D <- Dicts])),
    [exit(D, kill) || D <- Dicts],
    proxy_multicall(Ns, application, stop, [locks]),
    ok.

gdict_simple_netsplit(Config) ->
    with_trace(fun gdict_simple_netsplit_/1, Config,
               "leader_tests_simple_netsplit").

gdict_simple_netsplit_(Config) ->
    Name = [?MODULE, ?LINE],
    [A, B] = Ns = get_slave_nodes(Config),
    NodeB = node_of(B),
    ok = lists:foreach(
           fun(ok) -> ok end,
           proxy_multicall(Ns, application, start, [locks])),
    Results = proxy_multicall(Ns, gdict, new_opt, [[{resource, Name}]]),
    Dicts = lists:map(fun({ok,D}) -> D end, Results),
    wait_for_dicts(Dicts),
    [X, X] = [locks_leader:info(Dx, leader) || Dx <- Dicts],
    locks_ttb:event({?LINE, initial_consensus}),
    call_proxy(A, erlang, disconnect_node, [NodeB]),
    [] = call_proxy(A, erlang, nodes, []),
    [] = call_proxy(B, erlang, nodes, []),
    locks_ttb:event({?LINE, netsplit_ready}),
    wait_for_dicts(Dicts),
    [L1,L2] = [locks_leader:info(Dx, leader) || Dx <- Dicts],
    true = (L1 =/= L2),
    locks_ttb:event({?LINE, reconnecting}),
    proxy_multicall(Ns, ?MODULE, unbar_nodes, []),
    proxy_multicall(Ns, ?MODULE, connect_nodes, [nodes_of(Ns)]),
    [NodeB] = call_proxy(A, erlang, nodes, []),
    [Z,Z] = ?retry([Z,Z], call_proxy(A, ?MODULE, leader_nodes, [Dicts])),
    locks_ttb:event({?LINE, leader_consensus, Ns, Z}),
    proxy_multicall(Ns, application, stop, [locks]),
    ok.

node_of(#{node := N}) ->
    N;
node_of(N) when is_atom(N) ->
    N.

nodes_of(Ns) ->
    lists:map(fun(#{node := N}) -> N end, Ns).

dicts_of(Ns) ->
    lists:map(fun(#{dict := D}) -> D end, Ns).

%% wait for leaders to get out of safe loop
wait_for_dicts(Dicts) ->
    [false = gdict:is_key(no_key, D) || D <- Dicts],
    ok.

gdict_netsplit(Config) ->
    with_trace(fun gdict_netsplit_/1, Config, "leader_tests_netsplit").

gdict_netsplit_(Config) ->
    Name = [?MODULE, ?LINE],
    [A,B|[C|_] = Rest] = Ns = get_slave_nodes(Config),
    [NodeA, NodeB, NodeC] = [node_of(X) || X <- [A,B,C]],
    proxy_multicall([A,B], ?MODULE, disconnect_nodes, [nodes_of(Rest)]),
    [NodeB] = call_proxy(A, erlang, nodes, []),
    [NodeA] = call_proxy(B, erlang, nodes, []),
    locks_ttb:event({?LINE, netsplit_ready}),
    ok = lists:foreach(
           fun(ok) -> ok end,
           proxy_multicall(Ns, application, start, [locks])),
    Results = proxy_multicall(Ns, gdict, new_opt, [[{resource, Name}]]),
    [Da,Db|[Dc|_] = DRest] = Dicts = lists:map(fun({ok,Dx}) -> Dx end, Results),
    locks_ttb:event({?LINE, dicts_created, lists:zip(nodes_of(Ns), Dicts)}),
    ok = ?retry(ok, gdict:store(a, 1, Da)),
    ok = gdict:store(b, 2, Dc),
    {ok, 1} = ?retry({ok,1}, gdict:find(a, Db)),
    error = gdict:find(a, Dc),
    [X,X] = [locks_leader:info(Dx, leader) || Dx <- [Da,Db]],
    locks_ttb:event({?LINE, leader_consensus, [Da,Db], X}),
    RestLeaders = [locks_leader:info(Dx, leader) || Dx <- DRest],
    [Y] = lists:usort(RestLeaders),
    locks_ttb:event({?LINE, leader_consensus, DRest, Y}),
    true = (X =/= Y),
    lists:foreach(
      fun(Dx) ->
              {ok, 2} = ?retry({ok,2}, gdict:find(b, Dx))
      end, DRest),
    error = gdict:find(b, Da),
    locks_ttb:event({?LINE, reconnecting}),
    proxy_multicall(Ns, ?MODULE, unbar_nodes, []),
    proxy_multicall(Ns, ?MODULE, connect_nodes, [nodes_of(Ns)]),
    [NodeB,NodeC|_] = lists:sort(call_proxy(A, erlang, nodes, [])),
    [Z] = ?retry([_],
                lists:usort(call_proxy(A, ?MODULE, leader_nodes, [Dicts]))),
    locks_ttb:event({?LINE, leader_consensus, Ns, Z}),
    {ok, 1} = ?retry({ok,1}, gdict:find(a, Dc)),
    {ok, 2} = ?retry({ok,2}, gdict:find(b, Da)),
    [exit(Dx, kill) || Dx <- Dicts],
    proxy_multicall(Ns, application, stop, [locks]),
    ok.

start_incremental(Config) ->
    with_trace(fun start_incremental_/1, Config, "leader_tests_incr").

start_incremental_(Config) ->
    Name = [?MODULE, ?LINE],
    Ns = get_slave_nodes(Config),
    start_incremental(Ns, [], Name).

start_incremental([], _, _) ->
    ok;
start_incremental([N|Ns], Alive, Name) ->
    start_incremental(N, Alive, Ns, Name).

start_incremental(N, Alive, Rest, Name) ->
    ct:log("start_incremental, N = ~p, Alive = ~p", [N, Alive]),
    ConnectRes = maybe_connect(N, Alive),
    ct:log("ConnectRes = ~p", [ConnectRes]),
    ok = call_proxy(N, application, start, [locks]),
    ct:log("locks started on ~p", [node_of(N)]),
    {ok, D} = call_proxy(N, gdict, new_opt, [[{resource, Name}]]),
    ct:log("Dict created on ~p: ~p~n", [N, D]),
    insert_initial(D, Alive),
    NewAlive = [{node_of(N), D}|Alive],
    Vals = [{D, ?retry({ok,1}, gdict:find(a, D1))}
            || {_,D1} <- NewAlive],
    ct:log("Values = ~p~n", [Vals]),
    Leaders = [{D1, ?retry_not(undefined, locks_leader:info(D1, leader))}
               || {_, D1} <- NewAlive],
    ct:log("Leaders = ~p~n", [Leaders]),
    start_incremental(Rest, NewAlive, Name).

random_netsplits(Config) ->
    with_trace(fun random_netsplits_/1, Config, "random_netsplits").

random_netsplits_(Config) ->
    DName = [?MODULE, ?LINE],
    Slaves = get_slave_nodes(Config),
    ct:log("Slaves = ~p", [Slaves]),
    St0 = #{ islands => []
           , idle    => Slaves
           , dict    => DName },
    do_random_splits(St0, Config, 1000),
    ok.

do_random_splits(St, Config, N) when N > 0 ->
    case next_cmd(St) of
        stop ->
            ok;
        {Cmd, Args} ->
            St1 = perform(Cmd, Args, St),
            do_random_splits(St1, Config, N-1)
    end;
do_random_splits(_, _, _) ->
    ok.

perform(split, {I, A, B} = Arg, #{ islands := Isls } = St) ->
    ct:log("split ~p", [{nodes_of(I), nodes_of(A), nodes_of(B)}]),
    locks_ttb:event({?LINE, split, Arg}),
    BNodes = nodes_of(B),
    proxy_multicall(A, ?MODULE, disconnect_nodes, [BNodes]),
    NewIslands = [A, B | Isls -- [I]],
    ct:log("split -> ~p", [[nodes_of(Ni) || Ni <- NewIslands]]),
    St#{ islands => NewIslands };
perform(rejoin, {A, B} = Arg, #{ islands := Isls } = St) ->
    locks_ttb:event({?LINE, rejoin, Arg}),
    ANodes = nodes_of(A),
    BNodes = nodes_of(B),
    proxy_multicall(A, ?MODULE, allow, [BNodes]),
    proxy_multicall(B, ?MODULE, allow, [ANodes]),
    proxy_multicall(A, ?MODULE, connect_nodes, [BNodes]),
    NewIslands = [ A ++ B | (Isls -- [A, B]) ],
    ct:log("rejoined ~p -> ~p", [{nodes_of(A), nodes_of(B)}, [nodes_of(I) || I <- NewIslands]]),
    St#{ islands => NewIslands };
perform(add, {Node, Island} = Arg, #{ islands := Isls
                                    , idle := Idle
                                    , dict := D } = St) ->
    locks_ttb:event({?LINE, add, Arg}),
    INodes = nodes_of(Island),
    ok = call_proxy(Node, ?MODULE, connect_nodes, [INodes]),
    ok = call_proxy(Node, application, start, [locks]),
    {ok, Dx} = call_proxy(Node, gdict, new_opt, [[{resource, D}]]),
    Island1 = [Node#{dict => Dx}|Island],
    ct:log("add ~p to ~p -> ~p", [node_of(Node), nodes_of(Island), nodes_of(Island1)]),
    St#{ islands => [Island1 | (Isls -- [Island])]
       , idle => Idle -- [Node] };
perform(update, Arg, St) ->
    locks_ttb:event({?LINE, update, Arg}),
    ct:log("update - ignored", []),
    St;
perform(check, [N|_] = I, St) ->
    ct:log("check: I = ~p", [nodes_of(I)]),
    Dicts = dicts_of(I),
    true = ?retry(true, call_proxy(N, ?MODULE, same_leaders, [Dicts])),
    St.

next_cmd(St) ->
    case cmds(St) of
        [] ->
            ct:log("No possible cmd. St = ~p", [St]),
            stop;
        [_|_] = Cmds ->
            Cmd = oneof(Cmds),
            {Cmd, cmd_args(Cmd, St)}
    end.

cmds(#{ islands := Isls, idle := Idle }) ->
    [ split || [I || I <- Isls,
                     length(I) > 1] =/= [] ]
        ++ [ rejoin || length(Isls) > 1 ]
        ++ [ update || Isls =/= [] ]
        ++ [ add    || Idle =/= [] ]
        ++ [ check  || Isls =/= [] ].

cmd_args(split, #{ islands := Isls }) ->
    I = oneof([I || I <- Isls,
                    length(I) > 1]),
    {A, B} = divide(I),
    {I, A, B};
cmd_args(rejoin, #{ islands := Isls }) ->
    I1 = oneof(Isls),
    I2 = oneof(Isls -- [I1]),
    {I1, I2};
cmd_args(update, #{ islands := Isls }) ->
    oneof(Isls);
cmd_args(add, #{ islands := Isls, idle := Idle }) ->
    Island = case Isls of
                 []    -> [];
                 [_|_] -> oneof(Isls)
             end,
    {oneof(Idle), Island};
cmd_args(check, #{ islands := Isls }) ->
    oneof(Isls).

oneof(L) ->
    lists:nth(rand:uniform(length(L)), L).

divide(L) ->
    N = rand:uniform(length(L) - 1),
    pick_n(N, L).

pick_n(N, L) ->
    pick_n(N, L, []).

pick_n(N, L, Acc) when N > 0 ->
    X = oneof(L),
    pick_n(N-1, L -- [X], [X|Acc]);
pick_n(_, Rest, Acc) ->
    {lists:reverse(Acc), Rest}.


%% ============================================================
%% Support code
%% ============================================================

with_trace(F, Config, Name) ->
    Ns = nodes_of(get_slave_nodes(Config)),
    ct:log("with_trace: Ns = ~p", [Ns]),
    Pats = [{test_cb, event, 3, []}|locks_ttb:default_patterns()],
    Flags = locks_ttb:default_flags(),
    Nodes = [node() | Ns],
    Opts = [{file, Name}],
    locks_ttb:trace_nodes(Nodes, Pats, Flags, Opts),
    try F([{locks_ttb, #{ pats => Pats
                        , flags => Flags
                        , opts => Opts
                        , nodes => Nodes }} | Config])
    catch
        error:R:Stack ->
            ttb_stop(),
            ct:log("Error ~p; Stack = ~p~n", [R, Stack]),
            erlang:error(R);
        exit:R ->
            ttb_stop(),
            exit(R)
    end,
    %% locks_ttb:stop_nofetch(),
    locks_ttb:stop(),
    ok.

ttb_stop() ->
    Dir = locks_ttb:stop(),
    ct:log("Dir = ~p", [Dir]),
    Out = filename:join(filename:dirname(Dir),
                        filename:basename(Dir) ++ ".txt"),
    ct:log("Out = ~p", [Out]),
    locks_ttb:format(Dir, Out),
    ct:log("Formatted trace log in ~s~n", [Out]).


maybe_connect(_, []) ->
    empty;
maybe_connect(N, [{N1, _}|_]) ->
    call_proxy(N, net_kernel, connect_node, [N1]).

insert_initial(D, []) ->
    gdict:store(a, 1, D);
insert_initial(_, _) ->
    ok.

node_list(N) when is_integer(N), N > 0, N < 10 ->
    lists:sublist(node_list(10), 1, N);
node_list(10) ->
    [ locks_1, locks_2, locks_3, locks_4, locks_5
    , locks_6, locks_7, locks_8, locks_9, locks_10 ].

retry(F, N) ->
    retry(F, N, undefined).

retry(F, N, _) when N > 0 ->
    try F()
    catch
        error:{badmatch, {_, Other}} ->
            timer:sleep(100),
            retry(F, N-1, Other)
    end;
retry(_, _, Last) ->
    Last.

disconnect_nodes(Ns) ->
    [{true,_} = {erlang:disconnect_node(node_of(N)), N} || N <- Ns, node_of(N) =/= node()],
    ok.

unbar_nodes() ->
    gen_server:call(net_kernel, unbar_all).

connect_nodes(Ns) ->
    [{true,_} = {net_kernel:connect_node(node_of(N)), N} || N <- Ns, node_of(N) =/= node()],
    ok.

leader_nodes(Ds) ->
    wait_for_dicts(Ds),
    [node(locks_leader:info(D, leader)) || D <- Ds].

same_leaders(Ds) ->
    Nodes = leader_nodes(Ds),
    case lists:usort(Nodes) of
        [_] -> true;
        _   -> false
    end.

-define(PROXY, locks_leader_test_proxy).

proxy() ->
    process_flag(trap_exit, true),
    proxy_loop().

proxy_loop() ->
    receive
        {From, Ref, apply, M, F, A} ->
            From ! {Ref, (catch apply(M,F,A))};
	{From, Ref, apply, F} when is_function(F, 0) ->
	    From ! {Ref, (catch F())};
        _ ->
            ok
    end,
    proxy_loop().

proxy_multicall(Ns, M, F, A) ->
    [call_proxy(N, M, F, A) || N <- Ns].

call_proxy(#{node := N, proxy := Proxy, peer := Peer}, M, F, A) ->
    Ref = erlang:monitor(process, Proxy),
    Proxy ! {self(), Ref, apply, M, F, A},
    receive
        {'DOWN', Ref, _, _, Reason} ->
            error({proxy_died, N, Reason});
        {Ref, Result} ->
            Result
    after 5000 ->
	    ct:log("Timeout calling apply(~p, ~p, ~p) on ~p", [M, F, A, N]),
	    ct:log("Peer status: ~p", [peer:get_state(Peer)]),
            error(proxy_call_timeout)
    end.

call_proxy(P, F) when is_pid(P), is_function(F, 0) ->
    call_proxy(P, F, 5000).

call_proxy(P, F, Timeout) when is_pid(P), is_function(F, 0) ->
    Ref = erlang:monitor(process, P),
    P ! {self(), Ref, apply, F},
    receive
	{'DOWN', Ref, _, _, Reason} ->
	    error({proxy_died, P, Reason});
	{Ref, Result} ->
	    Result
    after Timeout ->
	    error(proxy_call_timeout)
    end.

get_slave_nodes(Config) ->
    proplists:get_value(slaves, Config, []).

start_slaves(Ns, Config) ->
    case proplists:get_value(peer_proxy, Config) of
	undefined ->
	    %% Create a local proxy with spawn() (not spawn_link())
	    %% which is meant to survive across multiple tests
	    LocalProxy = spawn(fun proxy/0),
	    start_slaves_(LocalProxy, Ns, Config);
	Proxy ->
	    start_slaves_(Proxy, Ns, Config)
    end.

start_slaves_(LocalProxy, Ns, Config) ->
    Nodes = call_proxy(LocalProxy, fun() -> do_start_slaves(Ns) end, 10000),
    [{slaves, Nodes}, {peer_proxy, LocalProxy} | Config].

do_start_slaves(Ns) ->
    Nodes = [start_slave(N) || N <- Ns],
    ct:log("start_slaves() -> ~p~n", [Nodes]),
    Nodes.

start_slave(Name) ->
    case node() of
        nonode@nohost ->
            os:cmd("epmd -daemon"),
            {ok, _} = net_kernel:start([locks_master, shortnames]);
        _ ->
            ok
    end,
    {Pa, Pz} = paths(),
    PathsA = lists:foldr(
	       fun(P, Acc) ->
		       ["-pa", P | Acc]
	       end, [], Pa),
    PathsZ = lists:foldr(
	       fun(P, Acc) ->
		       ["-pz", P | Acc]
	       end, [], Pz),
    Paths = ["-pa", "./", "-pz", "../ebin" | PathsA] ++ PathsZ,
    Arg = ["-kernel", "dist_auto_connect", "once",
	   "-kernel", "prevent_overlapping_partitions", "false"],
    {ok, Peer, Node} = ?CT_PEER(#{name => Name,
				  peer_down => continue,
				  connection => 0, % alt conn, auto-port
				  args => Arg ++ Paths}),
    {module,net_kernel} = peer:call(Peer, ?MODULE, patch_net_kernel, []),
    true = net_kernel:hidden_connect_node(Node),
    Node = rpc:call(Node, erlang, node, []),  %% just checking liveness
    Proxy = spawn(Node, ?MODULE, proxy, []),
    #{node => Node, peer => Peer, proxy => Proxy}.

stop_slaves(Config) ->
    case proplists:get_value(peer_proxy, Config) of
	undefined ->
	    ct:log("No peer proxy", []),
	    Slaves = proplists:get_value(slaves, Config, []),
	    [ok = stop_slave(N) || N <- Slaves];
	Proxy ->
	    Slaves = proplists:get_value(slaves, Config, []),
	    call_proxy(Proxy, fun() ->
				      [ok = stop_slave(N)
				       || N <- Slaves]
			      end)
    end,
    ok.

stop_slave(#{peer := Peer}) ->
    peer:stop(Peer).
    %% try erlang:monitor_node(N, true) of
    %%     true ->
    %%         rpc:call(N, erlang, halt, []),
    %%         receive
    %%             {nodedown, N} -> ok
    %%         after 10000 ->
    %%                 os:cmd("kill -9 " ++ Pid),
    %%                 ok
    %%         end
    %% catch
    %%     error:badarg ->
    %%         ok
    %% end.

paths() ->
    Path = code:get_path(),
    {ok, [[Root]]} = init:get_argument(root),
    {Pas, Rest} = lists:splitwith(fun(P) ->
                                          not lists:prefix(Root, P)
                                  end, Path),
    Pzs = lists:filter(fun(P) ->
                               not lists:prefix(Root, P)
                       end, Rest),
    {Pas, Pzs}.

patch_net_kernel() ->
    NetKernel = code:which(net_kernel),
    {ok, {_,[{abstract_code,
              {raw_abstract_v1,
               [{attribute,_,file,_}|Forms]}}]}} =
        beam_lib:chunks(NetKernel, [abstract_code]),
    NewForms = xform_net_kernel(Forms),
    try
    {ok,net_kernel,Bin} = compile:forms(NewForms, [binary]),
    code:unstick_dir(filename:dirname(NetKernel)),
    {module, _Module} = Res = code:load_binary(net_kernel, NetKernel, Bin),
    locks_ttb:event({?LINE, net_kernel, NewForms}),
    Res
    catch
        error:What:ST ->
            io:fwrite(user, "~p: ERROR:~p~n", [?LINE, What]),
            error({What, ST})
    end.


xform_net_kernel({function,L,handle_call,3,Clauses}) ->
    {function,L,handle_call,3,
     [{clause,L,[{atom,L,unbar_all},{var,L,'From'},{var,L,'State'}], [],
       [{call,L,{remote,L,{atom,L,ets},{atom,L,match_delete}},
         [
          {atom,L,sys_dist},
          {record,L,barred_connection,
           [{record_field,L,{var,L,'_'},{atom,L,'_'}}]}
         ]},
        {call,L,{atom,L,async_reply},
         [{tuple,L,[{atom,L,reply},{atom,L,true},{var,L,'State'}]},
          {var,L,'From'}]}
       ]} | Clauses]};
xform_net_kernel(T) when is_tuple(T) ->
    list_to_tuple(xform_net_kernel(tuple_to_list(T)));
xform_net_kernel([H|T]) ->
    [xform_net_kernel(H) | xform_net_kernel(T)];
xform_net_kernel(Other) ->
    Other.
