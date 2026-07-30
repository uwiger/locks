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
    late_join/1,
    random_netsplits/1
   ]).

-export([patch_net_kernel/0,
         proxy/0,
         connect_nodes/1,
         disconnect_nodes/1,
         unbar_nodes/0,
         allow/1,
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
    %% Structured netsplit / heal / incremental tests define "green".
    %% random_netsplits is an ape/exploration suite: run explicitly via
    %% --group random_netsplits (or include that group in a custom suite).
    [
     {group, g_local},
     {group, g_2},
     {group, g_3},
     {group, g_4},
     {group, g_5},
     {group, g_2i},
     {group, g_3i},
     {group, g_4i},
     {group, g_5i}
    ].

groups() ->
    [
     {g_local, [], [local_dict]},
     {g_2, [], [gdict_all_nodes,
                gdict_simple_netsplit]},
     {g_3, [], [gdict_all_nodes,
                gdict_netsplit]},
     {g_4, [], [gdict_all_nodes,
                gdict_netsplit,
                late_join]},
     {g_5, [],   [gdict_all_nodes,
                  gdict_netsplit]},
     {g_2i, [], [start_incremental]},
     {g_3i, [], [start_incremental]},
     {g_4i, [], [start_incremental]},
     {g_5i, [], [start_incremental]},
     %% Quarantined ape test — not in all()/default CI path.
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
    application:start(locks),
    Ns = start_slaves(node_list(2)),
    [{slaves, Ns}|Config];
init_per_group(g_3, Config) ->
    application:start(locks),
    Ns = start_slaves(node_list(3)),
    [{slaves, Ns}|Config];
init_per_group(g_4, Config) ->
    application:start(locks),
    Ns = start_slaves(node_list(4)),
    [{slaves, Ns}|Config];
init_per_group(g_5, Config) ->
    application:start(locks),
    Ns = start_slaves(node_list(5)),
    [{slaves, Ns}|Config];
init_per_group(g_2i, Config) ->
    application:start(locks),
    Ns = start_slaves(node_list(2)),
    [{slaves, Ns}|Config];
init_per_group(g_3i, Config) ->
    application:start(locks),
    Ns = start_slaves(node_list(3)),
    [{slaves, Ns}|Config];
init_per_group(g_4i, Config) ->
    application:start(locks),
    Ns = start_slaves(node_list(4)),
    [{slaves, Ns}|Config];
init_per_group(g_5i, Config) ->
    application:start(locks),
    Ns = start_slaves(node_list(5)),
    [{slaves, Ns}|Config];
init_per_group(random_netsplits, Config) ->
    application:start(locks),
    Ns = start_slaves(node_list(10)),
    [{slaves, Ns}|Config].

end_per_group(g_local, _Config) ->
    application:stop(locks);
end_per_group(_Group, Config) ->
    application:stop(locks),
    stop_slaves(?config(slaves, Config)),
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
    [H|T] = Ns = get_slave_nodes(Config),
    Name = [?MODULE,?LINE],
    ok = call_proxy(H, ?MODULE, connect_nodes, [T]),
    T = call_proxy(H, erlang, nodes, []),
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
           lists:zip(Ns, [?retry({ok,1}, gdict:find(a,D)) || D <- Dicts])),
    [exit(D, kill) || D <- Dicts],
    proxy_multicall(Ns, application, stop, [locks]),
    ok.

gdict_simple_netsplit(Config) ->
    with_trace(fun gdict_simple_netsplit_/1, Config,
               "leader_tests_simple_netsplit").

gdict_simple_netsplit_(Config) ->
    Name = [?MODULE, ?LINE],
    [A, B] = Ns = get_slave_nodes(Config),
    %% Explicit mesh (do not rely on residual connectivity from a prior case).
    proxy_multicall(Ns, ?MODULE, unbar_nodes, []),
    proxy_multicall(Ns, ?MODULE, connect_nodes, [Ns]),
    [B] = call_proxy(A, erlang, nodes, []),
    [A] = call_proxy(B, erlang, nodes, []),
    ok = lists:foreach(
           fun(ok) -> ok end,
           proxy_multicall(Ns, application, start, [locks])),
    Results = proxy_multicall(Ns, gdict, new_opt, [[{resource, Name}]]),
    Dicts = lists:map(fun({ok,D}) -> D end, Results),
    wait_for_dicts(Dicts),
    [X, X] = wait_same_leader(Dicts),
    locks_ttb:event({?LINE, initial_consensus, X}),
    call_proxy(A, erlang, disconnect_node, [B]),
    [] = call_proxy(A, erlang, nodes, []),
    [] = call_proxy(B, erlang, nodes, []),
    locks_ttb:event({?LINE, netsplit_ready}),
    wait_for_dicts(Dicts),
    [L1, L2] = wait_partition_leaders(Dicts),
    true = (L1 =/= L2),
    locks_ttb:event({?LINE, partition_leaders, L1, L2}),
    locks_ttb:event({?LINE, reconnecting}),
    proxy_multicall(Ns, ?MODULE, unbar_nodes, []),
    proxy_multicall(Ns, ?MODULE, connect_nodes, [Ns]),
    [B] = call_proxy(A, erlang, nodes, []),
    [Z, Z] = wait_same_leader_nodes(A, Dicts),
    locks_ttb:event({?LINE, leader_consensus, Ns, Z}),
    proxy_multicall(Ns, application, stop, [locks]),
    ok.

%% leader_nodes/1 via proxy; may return {'EXIT',...} while electing.
wait_same_leader_nodes(Node, Dicts) ->
    retry(fun() ->
                  case call_proxy(Node, ?MODULE, leader_nodes, [Dicts]) of
                      [N|_] = Ns when is_atom(N) ->
                          case lists:usort(Ns) of
                              [_] -> Ns;
                              Other -> error({badmatch, {nodes, Other}})
                          end;
                      Other ->
                          error({badmatch, {leader_nodes, Other}})
                  end
          end, 50).

%% Wait until candidates answer local calls (out of pure bootstrap).
wait_for_dicts(Dicts) ->
    [false = gdict:is_key(no_key, D) || D <- Dicts],
    ok.

%% Wait until all dicts report the same pid leader.
%% retry/2 catches error:{badmatch, {_, Actual}} — tag the payload.
wait_same_leader(Dicts) ->
    retry(fun() ->
                  Ls = [locks_leader:info(D, leader) || D <- Dicts],
                  case lists:usort(Ls) of
                      [L] when is_pid(L) ->
                          true = (length(Ls) =:= length(Dicts)),
                          Ls;
                      Other ->
                          error({badmatch, {leaders, Other}})
                  end
          end, 50).

%% After a split: every dict has some pid leader (possibly different).
wait_partition_leaders(Dicts) ->
    retry(fun() ->
                  Ls = [locks_leader:info(D, leader) || D <- Dicts],
                  case lists:all(fun is_pid/1, Ls) of
                      true  -> Ls;
                      false -> error({badmatch, {leaders, Ls}})
                  end
          end, 50).

gdict_netsplit(Config) ->
    with_trace(fun gdict_netsplit_/1, Config, "leader_tests_netsplit").

gdict_netsplit_(Config) ->
    Name = [?MODULE, ?LINE],
    [A,B|[C|_] = Rest] = Ns = get_slave_nodes(Config),
    %% Explicit mesh setup (do not rely on residual connectivity from a
    %% previous test case). With dist_auto_connect=once, barred links from
    %% earlier disconnects must be cleared before re-connecting.
    proxy_multicall(Ns, ?MODULE, unbar_nodes, []),
    proxy_multicall(Ns, ?MODULE, connect_nodes, [Ns]),
    [begin
         Expected = lists:sort(Ns -- [N]),
         Expected = lists:sort(call_proxy(N, erlang, nodes, []))
     end || N <- Ns],
    proxy_multicall([A,B], ?MODULE, disconnect_nodes, [Rest]),
    proxy_multicall(Rest, ?MODULE, disconnect_nodes, [[A,B]]),
    [B] = call_proxy(A, erlang, nodes, []),
    [A] = call_proxy(B, erlang, nodes, []),
    locks_ttb:event({?LINE, netsplit_ready}),
    ok = lists:foreach(
           fun(ok) -> ok end,
           proxy_multicall(Ns, application, start, [locks])),
    Results = proxy_multicall(Ns, gdict, new_opt, [[{resource, Name}]]),
    [Da,Db|[Dc|_] = DRest] = Dicts = lists:map(fun({ok,Dx}) -> Dx end, Results),
    locks_ttb:event({?LINE, dicts_created, lists:zip(Ns, Dicts)}),
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
    proxy_multicall(Ns, ?MODULE, connect_nodes, [Ns]),
    [B,C|_] = lists:sort(call_proxy(A, erlang, nodes, [])),
    LeaderNodes = wait_same_leader_nodes(A, Dicts),
    [Z] = lists:usort(LeaderNodes),
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

%% Grow membership one node at a time. After each join, require the same
%% pid leader on every live dict (not merely "some leader exists") and that
%% the seeded value is visible everywhere — the trust bar for incremental
%% membership growth.
start_incremental(N, Alive, Rest, Name) ->
    maybe_connect(N, Alive),
    ok = rpc:call(N, application, start, [locks]),
    {ok, D} = call_proxy(N, gdict, new_opt, [[{resource, Name}]]),
    ct:log("Dict created on ~p: ~p~n", [N, D]),
    insert_initial(D, Alive),
    NewAlive = [{N, D}|Alive],
    Dicts = [D1 || {_, D1} <- NewAlive],
    Vals = [{D1, ?retry({ok,1}, gdict:find(a, D1))} || D1 <- Dicts],
    ct:log("Values = ~p~n", [Vals]),
    Leaders = wait_same_leader(Dicts),
    ct:log("Leaders after joining ~p = ~p~n", [N, Leaders]),
    start_incremental(Rest, NewAlive, Name).

%% Scripted late join: stabilize N=3 with shared state, then bring a 4th
%% node online into the live cluster and require consensus + state catch-up.
%% Complements start_incremental (which never has a prior multi-node history
%% before the join) by joining into an already-elected group.
late_join(Config) ->
    with_trace(fun late_join_/1, Config, "leader_tests_late_join").

late_join_(Config) ->
    Name = [?MODULE, ?LINE],
    [A, B, C, D | _] = get_slave_nodes(Config),
    Early = [A, B, C],
    All = [A, B, C, D],
    %% Prior cases in the group leave a residual full mesh. Tear it down so
    %% the late node really is absent until we bring it in. Disconnect bars
    %% peers under dist_auto_connect=once, so unbar again before remeshing.
    proxy_multicall(All, ?MODULE, unbar_nodes, []),
    proxy_multicall(All, ?MODULE, disconnect_nodes, [All]),
    proxy_multicall(Early, ?MODULE, unbar_nodes, []),
    proxy_multicall(Early, ?MODULE, connect_nodes, [Early]),
    [begin
         Expected = lists:sort(Early -- [N]),
         Expected = lists:sort(call_proxy(N, erlang, nodes, []))
     end || N <- Early],
    [] = call_proxy(D, erlang, nodes, []),
    ok = lists:foreach(
           fun(ok) -> ok end,
           proxy_multicall(Early, application, start, [locks])),
    EarlyDicts = lists:map(
                   fun({ok, Dx}) -> Dx end,
                   proxy_multicall(Early, gdict, new_opt, [[{resource, Name}]])),
    wait_for_dicts(EarlyDicts),
    [L0, L0, L0] = wait_same_leader(EarlyDicts),
    locks_ttb:event({?LINE, early_consensus, L0}),
    ok = gdict:store(seed, early, hd(EarlyDicts)),
    [begin
         {ok, early} = ?retry({ok, early}, gdict:find(seed, Dx))
     end || Dx <- EarlyDicts],
    locks_ttb:event({?LINE, early_state_ok}),
    %% Bring the late node into the mesh and start locks_leader there.
    proxy_multicall([D], ?MODULE, unbar_nodes, []),
    proxy_multicall([D], ?MODULE, allow, [Early]),
    proxy_multicall(Early, ?MODULE, allow, [[D]]),
    proxy_multicall([D], ?MODULE, connect_nodes, [Early]),
    proxy_multicall(Early, ?MODULE, connect_nodes, [[D]]),
    ExpectedAll = lists:sort(All),
    [begin
         Expected = lists:sort(ExpectedAll -- [N]),
         Expected = lists:sort(call_proxy(N, erlang, nodes, []))
     end || N <- ExpectedAll],
    ok = call_proxy(D, application, start, [locks]),
    {ok, Dd} = call_proxy(D, gdict, new_opt, [[{resource, Name}]]),
    AllDicts = EarlyDicts ++ [Dd],
    wait_for_dicts(AllDicts),
    [L1, L1, L1, L1] = wait_same_leader(AllDicts),
    locks_ttb:event({?LINE, late_join_consensus, L1}),
    %% Late node must see state written before it joined; early nodes must
    %% see a write originating from the late node.
    {ok, early} = ?retry({ok, early}, gdict:find(seed, Dd)),
    ok = gdict:store(from_late, 1, Dd),
    [begin
         {ok, 1} = ?retry({ok, 1}, gdict:find(from_late, Dx))
     end || Dx <- AllDicts],
    locks_ttb:event({?LINE, late_join_state_ok}),
    [exit(Dx, kill) || Dx <- AllDicts],
    proxy_multicall(All, application, stop, [locks]),
    ok.

random_netsplits(Config) ->
    with_trace(fun random_netsplits_/1, Config, "random_netsplits").

random_netsplits_(Config) ->
    DName = [?MODULE, ?LINE],
    Slaves = get_slave_nodes(Config),
    ct:log("Slaves = ~p", [Slaves]),
    St0 = #{ islands => []
           , idle    => Slaves
           , dict    => DName },
    do_random_splits(St0, Config, 100),
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
    locks_ttb:event({?LINE, split, Arg}),
    ANodes = [N || {N,_} <- A],
    BNodes = [N || {N,_} <- B],
    proxy_multicall(ANodes, ?MODULE, disconnect_nodes, [BNodes]),
    NewIslands = [A, B | Isls -- [I]],
    ct:log("split ~p -> ~p", [Arg, NewIslands]),
    St#{ islands => NewIslands };
perform(rejoin, {A, B} = Arg, #{ islands := Isls } = St) ->
    locks_ttb:event({?LINE, rejoin, Arg}),
    ANodes = [N || {N,_} <- A],
    BNodes = [N || {N,_} <- B],
    proxy_multicall(ANodes, ?MODULE, allow, [BNodes]),
    proxy_multicall(BNodes, ?MODULE, allow, [ANodes]),
    proxy_multicall(ANodes, ?MODULE, connect_nodes, [BNodes]),
    NewIslands = [ A ++ B | (Isls -- [A, B]) ],
    ct:log("rejoined ~p -> ~p", [Arg, NewIslands]),
    %% Let election/sync settle before further splits or checks.
    timer:sleep(1000),
    St#{ islands => NewIslands };
perform(add, {Node, Island} = Arg, #{ islands := Isls
                                    , idle := Idle
                                    , dict := D } = St) ->
    locks_ttb:event({?LINE, add, Arg}),
    INodes = [N || {N,_} <- Island],
    ok = call_proxy(Node, ?MODULE, connect_nodes, [INodes]),
    ok = call_proxy(Node, application, start, [locks]),
    {ok, Dx} = call_proxy(Node, gdict, new_opt, [[{resource, D}]]),
    Island1 = [{Node, Dx}|Island],
    ct:log("add ~p to ~p -> ~p", [Node, Island, Island1]),
    St#{ islands => [Island1 | (Isls -- [Island])]
       , idle => Idle -- [Node] };
perform(update, Arg, St) ->
    locks_ttb:event({?LINE, update, Arg}),
    ct:log("update ~p - ignored", [Arg]),
    St;
perform(check, [{N,_}|_] = I, St) ->
    ct:log("check: I = ~p", [I]),
    Dicts = [D || {_,D} <- I],
    %% Patient retry: after rejoins, candidates may still be in safe_loop /
    %% leader_uncertain while re-electing. same_leaders uses info calls that
    %% are answered even in safe_loop (unlike arbitrary gdict ops).
    true = retry(fun() ->
                         case call_proxy(N, ?MODULE, same_leaders, [Dicts]) of
                             true -> true;
                             Other -> error({badmatch, {false, Other}})
                         end
                 end, 50),
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
    Ns = get_slave_nodes(Config),
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
    ttb_stop(),
    ok.

ttb_stop() ->
    Dir = locks_ttb:stop(),
    ct:log("Dir = ~p", [Dir]),
    Base = filename:join(filename:dirname(Dir), filename:basename(Dir)),
    Out = Base ++ ".txt",
    %% Compact event timeline for grepping; raw ttb dir remains for
    %% locks_ttb:format/2 (full state) or ad-hoc ttb queries.
    locks_ttb:format_events(Dir, Out),
    ct:log("Event timeline in ~s (raw dir ~s)~n", [Out, Dir]).


maybe_connect(_, []) ->
    ok;
maybe_connect(N, [{N1,_}|_]) ->
    call_proxy(N, net_kernel, connect, [N1]).

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
    _ = [erlang:disconnect_node(N) || N <- Ns, N =/= node()],
    ok.

unbar_nodes() ->
    gen_server:call(net_kernel, unbar_all).

%% Clear barred-connection entries for the given nodes (dist_auto_connect once).
%% Only unbar the named peers so other intentional islands stay isolated.
allow(Ns) ->
    _ = [ets:match_delete(sys_dist, {barred_connection, N}) || N <- Ns],
    ok.

connect_nodes(Ns) ->
    [{true,_} = {net_kernel:connect_node(N), N} || N <- Ns, N =/= node()],
    ok.

leader_nodes(Ds) ->
    wait_for_dicts(Ds),
    [case locks_leader:info(D, leader) of
         L when is_pid(L) -> node(L);
         Other -> error({badmatch, Other})
     end || D <- Ds].

same_leaders(Ds) ->
    Leaders = [locks_leader:info(D, leader) || D <- Ds],
    case lists:usort(Leaders) of
        [L] when is_pid(L) -> true;
        _ -> false
    end.

-define(PROXY, locks_leader_test_proxy).

proxy() ->
    register(?PROXY, self()),
    process_flag(trap_exit, true),
    proxy_loop().

proxy_loop() ->
    receive
        {From, Ref, apply, M, F, A} ->
            From ! {Ref, (catch apply(M,F,A))};
        _ ->
            ok
    end,
    proxy_loop().

proxy_multicall(Ns, M, F, A) ->
    [call_proxy(N, M, F, A) || N <- Ns].

call_proxy(N, M, F, A) ->
    Ref = erlang:monitor(process, {?PROXY, N}),
    {?PROXY, N} ! {self(), Ref, apply, M, F, A},
    receive
        {'DOWN', Ref, _, _, Reason} ->
            error({proxy_died, N, Reason});
        {Ref, Result} ->
            Result
    after 10000 ->
            %% Generous timeout: same_leaders/wait_for_dicts may block on
            %% gen_server calls while leaders re-elect after netsplits.
            error({proxy_call_timeout, N, M, F})
    end.

get_slave_nodes(Config) ->
    [N || {N,_} <- proplists:get_value(slaves, Config, [])].

start_slaves(Ns) ->
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
    Args = lists:append(
             [["-pa", "./"], ["-pz", "../ebin"]]
             ++ [["-pa", Path] || Path <- Pa]
             ++ [["-pz", Path] || Path <- Pz]
             ++ [%% OTP 25+: global disconnects nodes that would form
                 %% overlapping partitions. That fights intentional netsplit
                 %% tests, so disable it on peers.
                 ["-kernel", "dist_auto_connect", "once"],
                 ["-kernel", "prevent_overlapping_partitions", "false"]]),
    %% standard_io control connection so we can drop/replace the dist
    %% link (hidden connect) without peer killing the node.
    {ok, Peer, Node} = peer:start(#{name => Name,
                                    args => Args,
                                    connection => standard_io}),
    {module,net_kernel} = rpc:call(Node, ?MODULE, patch_net_kernel, []),
    _ = erlang:disconnect_node(Node),
    true = net_kernel:hidden_connect_node(Node),
    spawn(Node, ?MODULE, proxy, []),
    {Node, Peer}.

stop_slaves(Ns) ->
    [ok = stop_slave(N) || N <- Ns],
    ok.

stop_slave({N, Peer}) when is_pid(Peer) ->
    try peer:stop(Peer)
    catch
        _:_ ->
            stop_slave_halt(N)
    end;
stop_slave({N, _OsPid}) ->
    stop_slave_halt(N).

stop_slave_halt(N) ->
    try erlang:monitor_node(N, true) of
        true ->
            rpc:call(N, erlang, halt, []),
            receive
                {nodedown, N} -> ok
            after 10000 ->
                    ok
            end
    catch
        error:badarg ->
            ok
    end.

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


host() ->
    [_Name, Host] = re:split(atom_to_list(node()), "@", [{return, list}]),
    list_to_atom(Host).


patch_net_kernel() ->
    NetKernel = code:which(net_kernel),
    {ok, {_,[{abstract_code,
              {raw_abstract_v1,
               [{attribute,{1,1},file,_}|Forms]}}]}} =
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
