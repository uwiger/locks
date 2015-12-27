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
-module(locks_tests).

-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

-import(lists,[map/2]).

run_test_() ->
    {setup,
     fun() ->
             ok = application:start(locks)
     end,
     fun(_) ->
             ok = application:stop(locks)
     end,
     {inorder,
      [
       ?_test(simple_lock())
       , ?_test(one_lock_two_clients())
       , ?_test(one_lock_wrr_clients())
       , ?_test(lock_merge())
       , ?_test(lock_upgrade1())
       , ?_test(lock_upgrade2())
       , ?_test(lock_upgrade3())
       , ?_test(two_w_locks_parent_read())
       , ?_test(two_w_locks_parent_read_deadlock())
       , ?_test(two_clients_direct_deadlock())
       , ?_test(three_clients_deadlock())
       , ?_test(two_clients_hierarchical_deadlock())
       , ?_test(two_clients_abort_on_deadlock())
       , {setup,
          fun() ->
                  stop_slaves([locks_1, locks_2]),
                  start_slaves([locks_1, locks_2]),
                  Nodes = nodes(),
                  io:fwrite(user, "Nodes = ~p~n", [Nodes]),
                  rpc:multicall(Nodes, application, start, [locks]),
                  Nodes
          end,
          fun(Ns) ->
                  stop_slaves(Ns),
                  ok
          end,
          fun(Ns) ->
                  {inorder,
                   [
                    ?_test(d_simple_lock_all(Ns))
                    , ?_test(d_simple_lock_majority(Ns))
                    , ?_test(d_simple_lock_any(Ns))
                    , ?_test(d_simple_read_lock(Ns))
                    %% , ?_test(d_lock_surrender(Ns))
                    %% , ?_test(d_lock_node_dies(Ns))
                   ]}
          end}
      ]}
      }.


simple_lock() ->
    L = [?MODULE,?LINE],
    script([1], [{1, ?LINE, locks, lock, ['$agent', L], match({ok,[]})},
                 {1, ?LINE, locks, end_transaction, ['$agent'], match(ok)},
                 {1, ?LINE, erlang, is_process_alive, ['$agent'], match(false)},
                 {1, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

one_lock_two_clients() ->
    L = [?MODULE, ?LINE],
    script([1,2],
           [{1, ?LINE, locks, lock, ['$agent', L], match({ok,[]})},
            {2, ?LINE, locks, lock, ['$agent', L], 100,
             match(timeout, timeout)},
            {2, ?LINE, ?MODULE, client_waits, [], match(true)},
            {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
            {2, ?LINE, ?MODULE, client_result, [], match({ok, []})},
            {2, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

one_lock_wrr_clients() ->
    L = [?MODULE, ?LINE],
    script([1,2,3],
           [
            {1, ?LINE, locks, lock, ['$agent', L, write], match({ok,[]})},
            {2, ?LINE, locks, lock_nowait, ['$agent', L, read], match(ok)},
            {3, ?LINE, locks, lock_nowait, ['$agent', L, read], match(ok)},
            {1, ?LINE, locks, end_transaction, ['$agent'], match(ok)},
            {2, ?LINE, locks, await_all_locks, ['$agent'],
             match({have_all_locks, []})},
            {3, ?LINE, locks, await_all_locks, ['$agent'],
             match({have_all_locks, []})},
            {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
            {2, ?LINE, ?MODULE, kill_client, [], match(ok)},
            {3, ?LINE, ?MODULE, kill_client, [], match(ok)}
           ]).

lock_merge() ->
    L1 = [?MODULE, ?LINE],
    L2 = L1 ++ [1],
    L3 = L1 ++ [2],
    script([1],
           [
            {1, ?LINE, locks, lock, ['$agent', L2, read], match({ok, []})},
            {1, ?LINE, locks, lock, ['$agent', L3, write], match({ok, []})},
            {1, ?LINE, locks, lock, ['$agent', L1, write], match({ok, []})},
            {1, ?LINE, ?MODULE, kill_client, [], match(ok)}
           ]).

lock_upgrade1() ->
    L1 = [?MODULE, ?LINE],
    L2 = L1 ++ [1],
    script([1,2],
           [
            {1, ?LINE, locks, lock, ['$agent', L1, read], match({ok, []})},
            {1, ?LINE, locks, lock, ['$agent', L1, write], match({ok, []})},
            {2, ?LINE, locks, lock, ['$agent', L2,read], 100,
             match(timeout, timeout)},
            {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
            {2, ?LINE, ?MODULE, client_result, [], match({ok, []})},
            {2, ?LINE, ?MODULE, kill_client, [], match(ok)}
           ]).

lock_upgrade2() ->
    L1 = [?MODULE, ?LINE],
    L2 = L1 ++ [1],
    script([1,2],
           [
            {1, ?LINE, locks, lock, ['$agent', L1, read], match({ok, []})},
            {2, ?LINE, locks, lock, ['$agent', L2, read], match({ok,[]})},
            {1, ?LINE, locks, lock, ['$agent', L1, write], 100,
             match(timeout, timeout)},
            {2, ?LINE, ?MODULE, kill_client, [], match(ok)},
            {1, ?LINE, ?MODULE, client_result, [], match({ok, []})},
            {1, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

lock_upgrade3() ->
    L = [?MODULE, ?LINE],
    %% This match pattern succeeds for both 'ok' and for timeout, since we
    %% don't know which agent succeeds first
    Match = fun(normal, {have_all_locks,_}) -> ok;
               (timeout, timeout ) -> ok
            end,
    script([1,2],
           [
            {1, ?LINE, locks, lock, ['$agent', L, read], match({ok,[]})},
            {2, ?LINE, locks, lock, ['$agent', L, read], match({ok,[]})},
            {1, ?LINE, locks, lock_nowait, ['$agent', L, write], match(ok)},
            {2, ?LINE, locks, lock_nowait, ['$agent', L, write], match(ok)},
            {1, ?LINE, locks, await_all_locks, ['$agent'], 100, Match},
            %% The next command must not get the same result as the previous.
            {2, ?LINE, locks, await_all_locks, ['$agent'], 100,
             'ALL'([Match, 'NEQ'('V'(-1))])},
            {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
            {2, ?LINE, locks, await_all_locks, ['$agent'],
             fun(normal, {have_all_locks, _}) -> ok end},
            {2, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

two_w_locks_parent_read() ->
    L0 = [?MODULE, ?LINE],
    L1 = L0 ++ [1],
    L2 = L0 ++ [2],
    script(
      [1,2],
      [
       {1,?LINE, locks,lock, ['$agent',L1,write], match({ok,[]})},
       {2,?LINE, locks,lock, ['$agent',L2,write], match({ok,[]})},
       {1,?LINE, locks,lock, ['$agent',L0,read], 100, match(timeout,timeout)},
       {2,?LINE, ?MODULE, kill_client, [], match(ok)},
       {1,?LINE, ?MODULE, client_result, [], match({ok,[]})},
       {1,?LINE, ?MODULE, kill_client, [], match(ok)}
      ]).

two_w_locks_parent_read_deadlock() ->
    L0 = [?MODULE, ?LINE],
    L1 = L0 ++ [1],
    L2 = L0 ++ [2],
    script(
      [1,2],
      [
       {1,?LINE, locks,lock, ['$agent',L1,write], match({ok,[]})},
       {2,?LINE, locks,lock, ['$agent',L2,write], match({ok,[]})},
       {1,?LINE, locks,lock, ['$agent',L0,read], 100, match(timeout,timeout)},
       {2,?LINE, locks,lock, ['$agent',L0,read], 100, match(timeout,timeout)},
       {1, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_,_,_]}) -> ok end},
       {1,?LINE, ?MODULE, kill_client, [], match(ok)},
       {2, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_,_,_]}) -> ok end},
       {2,?LINE, ?MODULE, kill_client, [], match(ok)}
      ]).

two_clients_direct_deadlock() ->
    A = [?MODULE, ?LINE],
    B = [?MODULE, ?LINE],
    script([1,2],
           [{1, ?LINE, locks, lock, ['$agent', A], match({ok,[]})},
            {2, ?LINE, locks, lock, ['$agent', B], match({ok,[]})},
            {1, ?LINE, locks, lock, ['$agent', B], 100, match(timeout,timeout)},
            {2, ?LINE, locks, lock, ['$agent', A], 100, match(timeout,timeout)},
            {1, ?LINE, ?MODULE, client_result, [],
             fun(normal, {ok, [_]}) -> ok end},
            {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
            {2, ?LINE, ?MODULE, client_result, [],
             fun(normal, {ok, [_]}) -> ok end},
            {2, ?LINE, ?MODULE, kill_client, [], match(ok)}
           ]).

three_clients_deadlock() ->
    script(
      [1,2,3],
      [{1, ?LINE, locks, lock, ['$agent', [a]], match({ok, []})},
       {2, ?LINE, locks, lock, ['$agent', [b]], match({ok, []})},
       {3, ?LINE, locks, lock, ['$agent', [c]], match({ok, []})},
       {1, ?LINE, locks, lock, ['$agent', [c]], 100, match(timeout,timeout)},
       {2, ?LINE, locks, lock, ['$agent', [a]], 100, match(timeout,timeout)},
       {3, ?LINE, locks, lock, ['$agent', [b]], 100, match(timeout,timeout)},
       {1, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_|_]}) -> ok end},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
       %% Client 2 was not involved in the lock that was surrendered,
       %% but should still be informed, as the surrendering agent knew of 2.
       {2, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_|_]}) -> ok end},
       {2, ?LINE, ?MODULE, kill_client, [], match(ok)},
       {3, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_|_]}) -> ok end},
       {3, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

two_clients_hierarchical_deadlock() ->
    A = [?MODULE, ?LINE],
    A1 = A ++ [1],
    B = [?MODULE, ?LINE],
    B1 = B ++ [1],
    script(
      [1,2],
      [{1, ?LINE, locks, lock, ['$agent', A], match({ok, []})},
       {2, ?LINE, locks, lock, ['$agent', B], match({ok, []})},
       {1, ?LINE, locks, lock, ['$agent', B1], 100, match(timeout, timeout)},
       {2, ?LINE, locks, lock, ['$agent', A1], 100, match(timeout, timeout)},
       {1, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_|_]}) -> ok end},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
       {2, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_|_]}) -> ok end},
       {2, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

two_clients_abort_on_deadlock() ->
    A = [?MODULE, ?LINE],
    B = [?MODULE, ?LINE],
    script(
      [1, {2, [{abort_on_deadlock, true},{link,false}]}],
      [{1, ?LINE, locks, lock, ['$agent', A], match({ok, []})},
       {2, ?LINE, locks, lock, ['$agent', B], match({ok, []})},
       {1, ?LINE, locks, lock, ['$agent', B], 100, match(timeout,timeout)},
       {2, ?LINE, info, "Expect crash to follow", []},
       {2, ?LINE, locks, lock, ['$agent', A], match(error, '_')},
       {1, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, _}) -> ok end},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
       {2, ?LINE, ?MODULE, kill_client, [], match(ok)}
       ]).

d_simple_lock_all(Ns) ->
    A = [?MODULE, ?LINE],
    script(
      [1],
      [{1, ?LINE, locks, lock, ['$agent', A, write, [node()|Ns], all],
        match({ok, []})},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

d_simple_lock_majority(Ns) ->
    A = [?MODULE, ?LINE],
    [_, Host] = re:split(atom_to_list(node()), "@", [{return, list}]),
    Dead = list_to_atom("dead_1@" ++ Host),
    script(
      [1],
      [{1, ?LINE, locks, lock, ['$agent', A, write, [Dead|Ns], majority],
        match({ok, []})},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

d_simple_lock_any(Ns) ->
    A = [?MODULE, ?LINE],
    [_, Host] = re:split(atom_to_list(node()), "@", [{return, list}]),
    Dead = list_to_atom("dead_1@" ++ Host),
    script(
      [1],
      [{1, ?LINE, locks, lock, ['$agent', A, write, [Dead,hd(Ns)], any],
        match({ok, []})},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

d_simple_read_lock(Ns) ->
    A = [?MODULE, ?LINE],
    [N1, N2|_] = Ns,
    script(
      [{N1, 1}, {N2, 2}],
      [{1, ?LINE, locks, lock, ['$agent', A, read, [N1, N2], all],
        match({ok, []})},
       {2, ?LINE, locks, lock, ['$agent', A, read, [N1, N2], all],
        match({ok, []})},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
       {2, ?LINE, ?MODULE, kill_client, [], match(ok)}
      ]).

script(Agents, S) ->
    AgentPids = [spawn_agent(A) || A <- Agents],
    io:fwrite(user, "=== Agent pids: ~p~n", [AgentPids]),
    try eval_script(S, AgentPids)
    after
        dbg:stop_clear(),
        [kill_client(C) || {_, C, _, _} <- AgentPids]
    end.

spawn_agent({N, A}) when is_atom(N) ->
    spawn_agent(A, N);
spawn_agent(A) ->
    spawn_agent(A, node()).

spawn_agent(A, N) when is_integer(A) ->
    {ok, Pid, APid} = spawn_client(N),
    {A, Pid, APid, []};
spawn_agent({A, [_|_] = Opts}, N) when is_integer(A) ->
    {ok, Pid, APid} = spawn_client(N, Opts),
    {A, Pid, APid, []};
spawn_agent({A, [_|_] = Opts, St0}, N) when is_integer(A) ->
    {ok, Pid, APid} = spawn_client(N, Opts),
    {A, Pid, APid, St0}.


spawn_client(N) ->
    spawn_client(N, []).

spawn_client(N, Opts) ->
    Me = self(),
    P = spawn_link(N, fun() ->
                              {ok, A} = locks_agent:start(Opts),
                              Me ! {self(), ok, A},
                              client_loop(A)
                      end),
    receive
        {P, ok, A} ->
            {ok, P, A}
    end.

client_waits(P) ->
    timer:sleep(500),
    {dictionary, D} = process_info(P, dictionary),
    io:fwrite(user, "client dictionary: ~p~n", [D]),
    {normal, lists:keymember(client_call, 1, D)}.

ask_client(C, M, F, A) ->
    ask_client(C, M, F, A, infinity).

kill_client(C) ->
    Ref = erlang:monitor(process, C),
    unlink(C),
    exit(C, kill),
    receive
        {'DOWN', Ref, _, _, _} ->
            {normal, ok}
    end.

ask_client(C, ?MODULE, kill_client, [], _) ->
    kill_client(C);
ask_client(C, ?MODULE, client_waits, [], _) ->
    client_waits(C);
ask_client(C, M, F, A, Timeout) ->
    C ! {self(), apply, M, F, A},
    client_result(C, Timeout).

client_result(P) ->
    client_result(P, infinity).

client_result(P, Timeout) ->
    receive
        {P, Res} ->
            Res
    after Timeout ->
            {timeout, timeout}
    end.

client_loop(A) ->
    receive
        {From, apply, M, F, Args} ->
            Res = client_apply(M, F, repl_agent(A, Args)),
            From ! {self(), Res},
            client_loop(A)
    end.

client_apply(M, F, A) ->
    put(client_call, {M, F, A}),
    try {normal, apply(M, F, A)}
    catch
        C:R ->
            {C, R}
    after
        erase(client_call)
    end.

eval_script(Scr, Agents) ->
    eval_script(Scr, Agents, []).

eval_script([E|S], Agents, Acc) ->
    {Res, Agents1} =
        try  ask_agent(E, Agents, Acc)
        catch
            error:Reason ->
                Stack = erlang:get_stacktrace(),
                io:fwrite(user, ("ERROR: ~p~n"
                                 "Script: ~p~n"
                                 "Trace: ~p~n"),
                          [Reason,
                           lists:reverse([{E, {'EXIT', Reason}}|Acc]), Stack]),
                error(Reason)
        end,
    eval_script(S, Agents1, [{E, Res}|Acc]);

eval_script([], Agents, Acc) ->
    Remain = [A || {_, Pid, _, _} = A <- Agents,
                   process_alive(Pid)],
    case Remain of
        [] -> ok;
        [_|_] ->
            io:fwrite(user, ("REMAINING: ~p~n"
                             "Script: ~p~n"), [Remain, lists:reverse(Acc)]),
            error({remaining, Remain})
    end.

process_alive(P) when node(P) == node() ->
    is_process_alive(P);
process_alive(P) ->
    rpc:call(node(P), erlang, is_process_alive, [P]).

ask_agent({call, L, M, F, A, Match} = _E, Agents, Acc) ->
    io:fwrite(user, "ask_agent(~p)~n", [_E]),
    {C, Res} = try {normal, apply(M, F, A)}
               catch
                   error:E -> {error, E}
               end,
    io:fwrite(user, "~p -> ~p:~p~n", [_E, C, Res]),
    _ = try_match(Match, C, Res, undefined, L, Acc),
    {{C,Res}, Agents};
ask_agent({trace_locks_server, _L, Bool}, Agents, _Acc) ->
    if Bool ->
            io:fwrite(user,
                      "Trace on locks_server:~n~p~n",
                      [[dbg:tracer(),
                        dbg:tpl(locks_server, x),
                        dbg:p(locks_server, [c,m])]]);
       true ->
            dbg:ctpl(locks_server)
    end,
    {{normal,ok}, Agents};
ask_agent({A, _L, trace, Bool}, Agents, _Acc) ->
    {_, Pid, APid, _} = lists:keyfind(A, 1, Agents),
    if Bool ->
            io:fwrite(user,
                      "Trace on ~p:~n~p~n",
                      [A, [dbg:tracer(),
                           dbg:tpl(locks_agent, x),
                           dbg:p(Pid, [c,m]),
                           dbg:p(APid, [c,m])]]);
       true ->
            dbg:ctpl(locks_agent)
    end,
    {{normal,ok}, Agents};
ask_agent({A, _L, info, Fmt, Args}, Agents, _Acc) ->
    {_, Pid, APid, _} = lists:keyfind(A, 1, Agents),
    ?debugFmt("(INFO ~p/~p): " ++ Fmt, [Pid,APid|Args]),
    {{normal,ok}, Agents};
ask_agent({A, L, M, F, Args, Match}, Agents, Acc) ->
    ask_agent({A, L, M, F, Args, infinity, Match}, Agents, Acc);
ask_agent({A, L, M, F, Args, Timeout, Match} = _E, Agents, Acc) ->
    io:fwrite(user, "ask_agent(~p)~n", [_E]),
    {_, Pid, APid, St} = lists:keyfind(A, 1, Agents),
    {C, Res} = ask_client(Pid, M, F, subst(Args, Agents), Timeout),
    io:fwrite(user, "~p -> ~p:~p~n", [_E, C, Res]),
    St1 = try_match(Match, C, Res, St, L, Acc),
    {{C,Res}, lists:keyreplace(A, 1, Agents, {A, Pid, APid, St1})}.

try_match(Match, C, Res, St, _L, _Acc) when is_function(Match, 2) ->
    Match(C, Res),
    {C, Res, St};
try_match(Match, C, Res, St, L, _Acc) when is_function(Match, 4) ->
    Match(C, Res, St, L);
try_match(Match, C, Res, St, L, Acc) when is_function(Match, 5) ->
    Match(C, Res, St, L, Acc).

repl_agent(Pid, Args) ->
    lists:map(fun('$agent') -> Pid;
                 (X) -> X
              end, Args).

subst(Args, Agents) ->
    lists:map(fun({'$agent',N}) ->
                      {_, _, APid, _} = lists:keyfind(N, 1, Agents),
                      APid;
                 (Other) ->
                      Other
              end, Args).

match(Const) ->
    match(normal, Const).

match(Catch, Const) ->
    if Const == '_' ->
            fun(Ca, Co, St, _) when Ca == Catch ->
                    {Ca, Co, St};
               (C, Res, St, L) ->
                    error({mismatch,
                           [{line, L},
                            {pattern, '_'},
                            {result, Res},
                            {state, St}]
                           ++ [{caught, C} || C =/= normal]})
            end;
       true ->
            fun(Ca, Co, St, _) when Ca == Catch, Co == Const ->
                    {Ca, Co, St};
               (Ca, Co, St, L) ->
                    error({mismatch,
                           [{line, L},
                            {pattern, Const},
                            {result, Co},
                            {state, St}]
                           ++ [{caught, Ca} || Ca =/= normal]})
            end
    end.

'ALL'(Funs) when is_list(Funs) ->
    fun(C, Res, St, L, Acc) ->
            [try_match(X, C, Res, St, L, Acc) || X <- Funs]
    end.

'NEQ'(Match) ->
    fun(C, Res, St, L, Acc) ->
            case try_match(Match, C, Res, St, L, Acc) of
                {C, Res, _} ->
                    error({neq_failed, {L, {C, Res}}});
                _ ->
                    {C, Res, St}
            end
    end.

'V'(N) when N < 0 ->
    %% relative reference
    fun(_C, _Res, St, _L, Acc) ->
            {_, {C1, Res1}} = lists:nth(-N, Acc),
            {C1, Res1, St}
    end;
'V'(N) ->
    fun(_C, _Res, St, L, Acc) ->
            case [R || {E, R} <- Acc,
                       element(2, E) == N] of
                [{C1,Res1}] ->
                    {C1, Res1, St};
                Other ->
                    error({v_failed, {L, Other}})
            end
    end.

%% ==== slave setup

start_slaves(Ns) ->
    [H|T] = Nodes = [start_slave(N) || N <- Ns],
    _ = [rpc:call(H, net_adm, ping, [N]) || N <- T],
    Nodes.

stop_slaves(Ns) ->
    [ok = stop_slave(N) || N <- Ns],
    ok.

stop_slave(N) ->
    try erlang:monitor_node(N, true) of
	true ->
	    rpc:call(N, erlang, halt, []),
	    receive
		{nodedown, N} -> ok
	    after 10000 ->
		    erlang:error(timeout)
	    end
    catch
	error:badarg ->
	    ok
    end.

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
    {ok, Node} = slave:start(host(), Name, Paths),
    %% io:fwrite(user, "Slave node: ~p~n", [Node]),
    Node.

paths() ->
    Path = code:get_path(),
    {ok, [[Root]]} = init:get_argument(root),
    {Pas, Rest} = lists:splitwith(fun(P) ->
					  not lists:prefix(Root, P)
				  end, Path),
    {_, Pzs} = lists:splitwith(fun(P) ->
				       lists:prefix(Root, P)
			       end, Rest),
    {Pas, Pzs}.


host() ->
    [_Name, Host] = re:split(atom_to_list(node()), "@", [{return, list}]),
    list_to_atom(Host).
