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
    gdict_all_nodes/1,
    gdict_netsplit/1,
    start_incremental/1
   ]).

-export([patch_net_kernel/0,
         proxy/0,
         connect_nodes/1,
         disconnect_nodes/1,
         unbar_nodes/0,
         leader_nodes/1]).

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
     {group, g_all},
     {group, g_incr}
    ].

groups() ->
    [
     {g_local, [], [local_dict]},
     {g_all, [],   [gdict_all_nodes,
                    gdict_netsplit]},
     {g_incr, [], [start_incremental]}
    ].

suite() ->
    [].

init_per_suite(Config) ->
    compile_dict(),
    application:start(sasl),
    Config.

end_per_suite(_Config) ->
    application:stop(sasl),
    ok.

init_per_group(g_local, Config) ->
    application:start(locks),
    Config;
init_per_group(_Group, Config) ->
    application:start(locks),
    Ns = start_slaves(node_list(5)),
    [{slaves, Ns}|Config].

end_per_group(g_local, _Config) ->
    application:stop(locks);
end_per_group(_Group, Config) ->
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

local_dict(_Config) ->
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

gdict_netsplit(Config) ->
    with_trace(fun gdict_netsplit_/1, Config, "leader_tests_netsplit").

gdict_netsplit_(Config) ->
    Name = [?MODULE, ?LINE],
    [A,B,C,D,E] = Ns = get_slave_nodes(Config),
    proxy_multicall([A,B], ?MODULE, disconnect_nodes, [[C,D,E]]),
    [B] = call_proxy(A, erlang, nodes, []),
    [A] = call_proxy(B, erlang, nodes, []),
    locks_ttb:event(netsplit_ready),
    ok = lists:foreach(
           fun(ok) -> ok end,
           proxy_multicall(Ns, application, start, [locks])),
    Results = proxy_multicall(Ns, gdict, new_opt, [[{resource, Name}]]),
    [Da,Db,Dc,Dd,De] = Dicts = lists:map(fun({ok,Dx}) -> Dx end, Results),
    locks_ttb:event({dicts_created, lists:zip(Ns, Dicts)}),
    ok = ?retry(ok, gdict:store(a, 1, Da)),
    ok = gdict:store(b, 2, Dc),
    {ok, 1} = ?retry({ok,1}, gdict:find(a, Db)),
    error = gdict:find(a, Dc),
    [X,X] = [locks_leader:info(Dx, leader) || Dx <- [Da,Db]],
    locks_ttb:event({leader_consensus, [Da,Db], X}),
    [Y,Y,Y] = [locks_leader:info(Dx, leader) || Dx <- [Dc,Dd,De]],
    locks_ttb:event({leader_consensus, [Dc,Dd,De], Y}),
    true = (X =/= Y),
    {ok, 2} = ?retry({ok,2}, gdict:find(b, Dc)),
    {ok, 2} = ?retry({ok,2}, gdict:find(b, Dd)),
    {ok, 2} = ?retry({ok,2}, gdict:find(b, De)),
    error = gdict:find(b, Da),
    locks_ttb:event(reconnecting),
    proxy_multicall(Ns, ?MODULE, unbar_nodes, []),
    proxy_multicall(Ns, ?MODULE, connect_nodes, [Ns]),
    [B,C,D,E] = lists:sort(call_proxy(A, erlang, nodes, [])),
    [Z,Z,Z,Z,Z] = ?retry([Z,Z,Z,Z,Z],
                         call_proxy(A, ?MODULE, leader_nodes, [Dicts])),
    locks_ttb:event({leader_consensus, Ns, Z}),
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
    maybe_connect(N, Alive),
    ok = rpc:call(N, application, start, [locks]),
    {ok, D} = call_proxy(N, gdict, new_opt, [[{resource, Name}]]),
    ct:log("Dict created on ~p: ~p~n", [N, D]),
    insert_initial(D, Alive),
    NewAlive = [{N, D}|Alive],
    Vals = [{D, ?retry({ok,1}, gdict:find(a, D1))}
            || {_,D1} <- NewAlive],
    ct:log("Values = ~p~n", [Vals]),
    Leaders = [{D1, ?retry_not(undefined, locks_leader:info(D1, leader))}
               || {_, D1} <- NewAlive],
    ct:log("Leaders = ~p~n", [Leaders]),
    start_incremental(Rest, NewAlive, Name).

%% ============================================================
%% Support code
%% ============================================================

with_trace(F, Config, Name) ->
    Ns = get_slave_nodes(Config),
    Pats = [{test_cb, event, 3, []}|locks_ttb:default_patterns()],
    Flags = locks_ttb:default_flags(),
    locks_ttb:trace_nodes([node()|Ns], Pats, Flags, [{file, Name}]),
    try F(Config)
    catch
        error:R ->
            ttb_stop(),
            Stack = erlang:get_stacktrace(),
            ct:log("Error ~p; Stack = ~p~n", [R, Stack]),
            erlang:error(R);
        exit:R ->
            ttb_stop(),
            exit(R)
    end,
    locks_ttb:stop_nofetch(),
    ok.

ttb_stop() ->
    Dir = locks_ttb:stop(),
    Out = filename:join(filename:dirname(Dir),
                        filename:basename(Dir) ++ ".txt"),
    locks_ttb:format(Dir, Out),
    ct:log("Formatted trace log in ~s~n", [Out]).


compile_dict() ->
    Lib = filename:absname(code:lib_dir(locks)),
    Examples = filename:join(Lib, "examples"),
    _ = os:cmd(["cd ", Examples, " && rebar clean compile"]),
    _ = code:add_path(filename:join(Examples, "ebin")),
    ok.

maybe_connect(_, []) ->
    ok;
maybe_connect(N, [{N1,_}|_]) ->
    call_proxy(N, net_kernel, connect, [N1]).

insert_initial(D, []) ->
    gdict:store(a, 1, D);
insert_initial(_, _) ->
    ok.

node_list(5) ->
    [locks_1, locks_2, locks_3, locks_4, locks_5].

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
    [{true,_} = {erlang:disconnect_node(N), N} || N <- Ns, N =/= node()],
    ok.

unbar_nodes() ->
    gen_server:call(net_kernel, unbar_all).

connect_nodes(Ns) ->
    [{true,_} = {net_kernel:connect_node(N), N} || N <- Ns, N =/= node()],
    ok.

leader_nodes(Ds) ->
    [node(locks_leader:info(D, leader)) || D <- Ds].

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
    after 1000 ->
            error(proxy_call_timeout)
    end.

get_slave_nodes(Config) ->
    [N || {N,_} <- ?config(slaves, Config)].

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
    Paths = "-pa ./ -pz ../ebin" ++
        lists:flatten([[" -pa " ++ Path || Path <- Pa],
                       [" -pz " ++ Path || Path <- Pz]]),
    Arg = " -kernel dist_auto_connect once",
    {ok, Node} = ct_slave:start(host(), Name, [{erl_flags, Paths ++ Arg}]),
    {module,net_kernel} = rpc:call(Node, ?MODULE, patch_net_kernel, []),
    disconnect_node(Node),
    true = net_kernel:hidden_connect(Node),
    spawn(Node, ?MODULE, proxy, []),
    {Node, rpc:call(Node, os, getpid, [])}.

stop_slaves(Ns) ->
    [ok = stop_slave(N) || N <- Ns],
    ok.

stop_slave({N, Pid}) ->
    try erlang:monitor_node(N, true) of
        true ->
            rpc:call(N, erlang, halt, []),
            receive
                {nodedown, N} -> ok
            after 10000 ->
                    os:cmd("kill -9 " ++ Pid),
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
               [{attribute,1,file,_}|Forms]}}]}} =
        beam_lib:chunks(NetKernel, [abstract_code]),
    NewForms = xform_net_kernel(Forms),
    try
    {ok,net_kernel,Bin} = compile:forms(NewForms, [binary]),
    code:unstick_dir(filename:dirname(NetKernel)),
    {module, _Module} = Res = code:load_binary(net_kernel, NetKernel, Bin),
    locks_ttb:event({net_kernel, NewForms}),
    Res
    catch
        error:What ->
            io:fwrite(user, "~p: ERROR:~p~n", [?LINE, What]),
            error({What, erlang:get_stacktrace()})
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
