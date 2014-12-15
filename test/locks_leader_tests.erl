-module(locks_leader_tests).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

-define(retry(Res, Expr), retry(fun() -> Res = Expr end, 10)).

run_test_() ->
    {timeout, 60,
     {setup,
      fun() ->
	      compile_dict(),
	      application:start(sasl),
	      ok = application:start(locks),
	      Ns = start_slaves([locks_1, locks_2,
				 locks_3, locks_4, locks_5]),
	      rpc:multicall(Ns, application, start, [locks]),
	      Ns
      end,
      fun(Ns) ->
	      stop_slaves(Ns),
	      ok = application:stop(locks)
      end,
      fun(Ns) ->
	      {inorder,
	       [
		?_test(local_dict()),
		?_test(gdict_all_nodes(Ns)),
		?_test(gdict_netsplit(Ns))
	       ]}
      end
     }}.


compile_dict() ->
    Lib = filename:absname(code:lib_dir(locks)),
    Examples = filename:join(Lib, "examples"),
    _ = os:cmd(["cd ", Examples, " && rebar clean compile"]),
    _ = code:add_path(filename:join(Examples, "ebin")),
    ok.

local_dict() ->
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

gdict_all_nodes([H|T] = Ns) ->
    Name = [?MODULE,?LINE],
    ok = call_proxy(H, ?MODULE, connect_nodes, [T]),
    T = call_proxy(H, erlang, nodes, []),
    Results = proxy_multicall(Ns, gdict, new_opt, [[{resource, Name}]]),
    Dicts = lists:map(
	      fun({ok,D}) -> D end, Results),
    ok = gdict:store(a,1,hd(Dicts)),
    [] = lists:filter(
	   fun({_Node,{ok,1}}) -> false;
	      (_) -> true
	   end,
	   lists:zip(Ns, [gdict:find(a,D) || D <- Dicts])),
    [exit(D, kill) || D <- Dicts],
    ok.

gdict_netsplit([A,B,C,D,E] = Ns) ->
    Name = [?MODULE, ?LINE],
    locks_ttb:trace_nodes([node()|Ns], "leader_tests_netsplit"),
    try
    proxy_multicall([A,B], ?MODULE, disconnect_nodes, [[C,D,E]]),
    [B] = call_proxy(A, erlang, nodes, []),
    [A] = call_proxy(B, erlang, nodes, []),
    locks_ttb:event(netsplit_ready),
    Results = proxy_multicall(Ns, gdict, new_opt, [[{resource, Name}]]),
    [Da,Db,Dc,Dd,De] = Dicts = lists:map(fun({ok,Dx}) -> Dx end, Results),
    locks_ttb:event({dicts_created, lists:zip(Ns, Dicts)}),
    ok = ?retry(ok, gdict:store(a, 1, Da)),
    ok = gdict:store(b, 2, Dc),
    {ok, 1} = gdict:find(a, Db),
    error = gdict:find(a, Dc),
    [X,X] = [locks_leader:info(Dx, leader) || Dx <- [Da,Db]],
    locks_ttb:event({leader_consensus, [Da,Db], X}),
    [Y,Y,Y] = [locks_leader:info(Dx, leader) || Dx <- [Dc,Dd,De]],
    locks_ttb:event({leader_consensus, [Dc,Dd,De], Y}),
    true = (X =/= Y),
    {ok, 2} = ?retry({ok,2}, gdict:find(b, Dc)),
    {ok, 2} = gdict:find(b, Dd),
    {ok, 2} = gdict:find(b, De),
    error = gdict:find(b, Da),
    locks_ttb:event(reconnecting),
    proxy_multicall(Ns, ?MODULE, unbar_nodes, []),
    proxy_multicall(Ns, ?MODULE, connect_nodes, [Ns]),
    [B,C,D,E] = lists:sort(call_proxy(A, erlang, nodes, [])),
    [Z,Z,Z,Z,Z] = ?retry([Z,Z,Z,Z,Z],
			 call_proxy(A, ?MODULE, leader_nodes, [Dicts])),
    locks_ttb:event({leader_consensus, Ns, Z}),
    {ok, 1} = ?retry({ok,1}, gdict:find(a, Dc)),
    {ok, 2} = gdict:find(b, Da),
    [exit(Dx, kill) || Dx <- Dicts]
    catch
	error:R ->
	    locks_ttb:stop(),
	    erlang:error(R);
	exit:R ->
	    locks_ttb:stop(),
	    exit(R)
    end,
    locks_ttb:stop_nofetch(),
    ok.

retry(F, N) ->
    retry(F, N, undefined).

retry(F, N, _) when N > 0 ->
    try F()
    catch
	error:{badmatch, Other} ->
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

start_slaves(Ns) ->
    Nodes = [start_slave(N) || N <- Ns],
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
    Node.

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
		    erlang:error(slave_stop_timeout)
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
