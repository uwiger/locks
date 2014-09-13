-module(locks_leader_tests).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).


run_test_() ->
    {setup,
     fun() ->
	     compile_dict(),
	     application:start(sasl),
	     %% dbg:tracer(),
	     %% dbg:tpl(test_cb,x),
	     %% dbg:tp(locks_leader,x),
	     %% dbg:tpl(gdict,x),
	     %% dbg:p(all,[c]),
	     ok = application:start(locks)
     end,
     fun(_) ->
	     ok = application:stop(locks)
     end,
     {inorder,
      [
       ?_test(local_dict())
      ]}
    }.


compile_dict() ->
    Lib = filename:absname(code:lib_dir(locks)),
    Examples = filename:join(Lib, "examples"),
    io:fwrite(user, "Examples = ~s~n", [Examples]),
    Res = os:cmd(["cd ", Examples, " && rebar clean compile"]),
    io:fwrite(user, "Build examples: ~s~n", [Res]),
    PRes = code:add_path(filename:join(Examples, "ebin")),
    io:fwrite(user, "Add path = ~p~n", [PRes]).



local_dict() ->
    Name = {gdict, ?LINE},
    Dicts = [gdict:new_opt([{resource, Name}]) || _ <- [1,2,3]],
    io:fwrite(user, "Dicts = ~p~n", [Dicts]).
