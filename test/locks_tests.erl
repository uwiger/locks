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
     fun() -> application:start(locks) end,
     fun(_) -> application:stop(locks) end,
     [
      ?_test(simple_lock())
      , ?_test(one_lock_two_clients())
      , ?_test(two_clients_direct_deadlock())
      , ?_test(three_clients_deadlock())
      , ?_test(two_clients_hierarchical_deadlock())
      , ?_test(two_clients_abort_on_deadlock())
      , {setup,
         fun() ->
                 start_slaves([locks_1, locks_2]),
                 Nodes = nodes(),
                 io:fwrite(user, "Nodes = ~p~n", [Nodes]),
                 rpc:multicall(Nodes, application, start, [locks]),
                 Nodes
         end,
         fun(_Ns) ->
                 ok
         end,
         fun(Ns) ->
                 {inorder,
                  [
                   ?_test(d_simple_lock_all(Ns))
                   , ?_test(d_simple_lock_majority(Ns))
                   , ?_test(d_simple_lock_any(Ns))
                  ]}
         end}
     ]}.

-define(LA, locks_agent).

simple_lock() ->
    script([1], [{1, ?LINE, ?LA, lock, ['$agent', [a]], match({ok,[]})},
                 {1, ?LINE, ?LA, end_transaction, ['$agent'], match(ok)},
                 {1, ?LINE, erlang, is_process_alive, ['$agent'], match(false)},
                 {1, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

one_lock_two_clients() ->
    script([1,2],
           [{1, ?LINE, ?LA, lock, ['$agent', [a]], match({ok,[]})},
            {2, ?LINE, ?LA, lock, ['$agent', [a]], 100, match(timeout, timeout)},
            {2, ?LINE, ?MODULE, client_waits, [], match(true)},
            {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
            {2, ?LINE, ?MODULE, client_result, [], match({ok, []})},
            {2, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

two_clients_direct_deadlock() ->
    script([1,2],
           [{1, ?LINE, ?LA, lock, ['$agent', [a]], match({ok,[]})},
            {2, ?LINE, ?LA, lock, ['$agent', [b]], match({ok,[]})},
            {1, ?LINE, ?LA, lock, ['$agent', [b]], 100, match(timeout,timeout)},
            {2, ?LINE, ?LA, lock, ['$agent', [a]], 100, match(timeout,timeout)},
            {1, ?LINE, ?MODULE, client_result, [],
             fun(normal, {ok, [_]}, St) -> St end},
            {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
            {2, ?LINE, ?MODULE, client_result, [],
             fun(normal, {ok, [_]}, St) -> St end},
            {2, ?LINE, ?MODULE, kill_client, [], match(ok)}
           ]).

three_clients_deadlock() ->
    script(
      [1,2,3],
      [{1, ?LINE, ?LA, lock, ['$agent', [a]], match({ok, []})},
       {2, ?LINE, ?LA, lock, ['$agent', [b]], match({ok, []})},
       {3, ?LINE, ?LA, lock, ['$agent', [c]], match({ok, []})},
       {1, ?LINE, ?LA, lock, ['$agent', [c]], 100, match(timeout,timeout)},
       {2, ?LINE, ?LA, lock, ['$agent', [a]], 100, match(timeout,timeout)},
       {3, ?LINE, ?LA, lock, ['$agent', [b]], 100, match(timeout,timeout)},
       {1, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_|_]}, St) -> St end},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
       %% Client 2 was not involved in the lock that was surrendered,
       %% but should still be informed, as the surrendering agent knew of 2.
       {2, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_|_]}, St) -> St end},
       {2, ?LINE, ?MODULE, kill_client, [], match(ok)},
       {3, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_|_]}, St) -> St end},
       {3, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

two_clients_hierarchical_deadlock() ->
    script(
      [1,2],
      [{1, ?LINE, ?LA, lock, ['$agent', [a]], match({ok, []})},
       {2, ?LINE, ?LA, lock, ['$agent', [b]], match({ok, []})},
       {1, ?LINE, ?LA, lock, ['$agent', [b,1]], 100, match(timeout, timeout)},
       {2, ?LINE, ?LA, lock, ['$agent', [a,1]], 100, match(timeout, timeout)},
       {1, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_|_]}, St) -> St end},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
       {2, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, [_|_]}, St) -> St end},
       {2, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

two_clients_abort_on_deadlock() ->
    script(
      [1, {2, [{abort_on_deadlock, true},{link,false}]}],
      [{1, ?LINE, ?LA, lock, ['$agent', [a]], match({ok, []})},
       {2, ?LINE, ?LA, lock, ['$agent', [b]], match({ok, []})},
       {1, ?LINE, ?LA, lock, ['$agent', [b]], 100, match(timeout,timeout)},
       {2, ?LINE, ?LA, lock, ['$agent', [a]], match(error, '_')},
       {1, ?LINE, ?MODULE, client_result, [],
        fun(normal, {ok, _}, St) -> St end},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)},
       {2, ?LINE, ?MODULE, kill_client, [], match(ok)}
       ]).

d_simple_lock_all(Ns) ->
    script(
      [1],
      [{1, ?LINE, ?LA, lock, ['$agent', [a], write, [node()|Ns], all],
        match({ok, []})},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

d_simple_lock_majority(Ns) ->
    [_, Host] = re:split(atom_to_list(node()), "@", [{return, list}]),
    Dead = list_to_atom("dead_1@" ++ Host),
    script(
      [1],
      [{1, ?LINE, ?LA, lock, ['$agent', [a], write, [Dead|Ns], majority],
        match({ok, []})},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

d_simple_lock_any(Ns) ->
    [_, Host] = re:split(atom_to_list(node()), "@", [{return, list}]),
    Dead = list_to_atom("dead_1@" ++ Host),
    script(
      [1],
      [{1, ?LINE, ?LA, lock, ['$agent', [a], write, [Dead,hd(Ns)], any],
        match({ok, []})},
       {1, ?LINE, ?MODULE, kill_client, [], match(ok)}]).

script(Agents, S) ->
    AgentPids = [spawn_agent(A) || A <- Agents],
    eval_script(S, AgentPids).

spawn_agent(A) when is_atom(A); is_integer(A) ->
    {ok, Pid} = spawn_client(),
    {A, Pid, []};
spawn_agent({A, [_|_] = Opts}) when is_atom(A); is_integer(A) ->
    {ok, Pid} = spawn_client(Opts),
    {A, Pid, []};
spawn_agent({A, [_|_] = Opts, St0}) when is_atom(A); is_integer(A) ->
    {ok, Pid} = spawn_client(Opts),
    {A, Pid, St0}.

spawn_client() ->
    spawn_client([]).

spawn_client(Opts) ->
    Me = self(),
    P = spawn_link(fun() ->
                           {ok, A} = locks_agent:start(Opts),
                           Me ! {self(), ok},
                           client_loop(A)
                   end),
    receive
        {P, ok} ->
            {ok, P}
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

eval_script([E|S], Agents) ->
    Agents1 = ask_agent(E, Agents),
    eval_script(S, Agents1);
eval_script([], Agents) ->
    Remain = [A || {_, Pid, _} = A <- Agents,
                   is_process_alive(Pid)],
    [] = Remain,
    ok.

ask_agent({A, L, M, F, Args, Match}, Agents) ->
    ask_agent({A, L, M, F, Args, infinity, Match}, Agents);
ask_agent({A, _, M, F, Args, Timeout, Match} = _E, Agents) ->
    io:fwrite(user, "ask_agent(~p)~n", [_E]),
    {_, Pid, St} = lists:keyfind(A, 1, Agents),
    {C, Res} = ask_client(Pid, M, F, Args, Timeout),
    io:fwrite(user, "~p -> ~p:~p~n", [_E, C, Res]),
    St1 = Match(C, Res, St),
    lists:keyreplace(A, 1, Agents, {A, Pid, St1}).

repl_agent(Pid, Args) ->
    lists:map(fun('$agent') -> Pid;
                 (X) -> X
              end, Args).

match(Const) ->
    match(normal, Const).

match(Catch, Const) ->
    if Const == '_' ->
            fun(Ca, _, St) when Ca == Catch ->
                    St
            end;
       true ->
            fun(Ca, Co, St) when Ca == Catch, Co == Const ->
                    St
            end
    end.


%% ==== slave setup

start_slaves(Ns) ->
    [H|T] = Nodes = [start_slave(N) || N <- Ns],
    _ = [rpc:call(H, net_adm, ping, [N]) || N <- T],
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
