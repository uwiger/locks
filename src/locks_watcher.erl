%% @private
%%
-module(locks_watcher).
-compile(debug_info).  % important

-export([parse_transform/2]).
-export([locks_watcher/1]).  % to avoid compiler warning

parse_transform(Forms, _) ->
    transform(Forms).

%% This is the logic that needs to be abstracted and inserted in place of
%% a (pseudo-)call to locks_watcher(self()).
%%
%% The parse transform extracts the function body (only one clause) of the
%% locks_watcher/1 function and passes them to erl_eval:exprs().
%% Local calls are inlined and 'anonymized' as
%% (fun(A1,..., An) -> ... end)(A1, ..., An)
%%
%% Variable names are fetched from the function head, so no pattern-matching
%% in the head.
locks_watcher(Agent) ->
    case whereis(locks_server) of
	undefined ->
	    A = fun(A1) ->
			try register(locks_watcher, self()),
			     B = fun(B1,Ws) ->
					 watcher(B1,Ws,Agent)
				 end,
			     B(B, [Agent])
			catch
			    error:_ ->
				another_watcher(A1, Agent)
			end
		end,
	    A(A);
	_Server ->
	    Agent ! {locks_running, node()}
    end.

watcher(Cont,Ws,Agent) ->
    receive
	{From, watch_for_me, P} ->
	    From ! {locks_watcher,ok},
	    if node(P) == node(Agent) ->
		    Cont(Cont,Ws);
	       true ->
		    Cont(Cont, [P|Ws])
	    end;
	locks_running ->
	    [P ! {locks_running,node()} || P <- Ws]
    end.

another_watcher(Cont, Agent) ->
    try locks_watcher ! {self(),watch_for_me,Agent},
	 receive
	     {locks_watcher,ok} ->
		 ok
	 after 500 ->
		 Cont(Cont)
	 end
    catch
	error:_ ->
	    Cont(Cont)
    end.

%% Parse transform code

transform([{call,L,{atom,L,locks_watcher},Args}|T]) ->
    Arity = length(Args),
    {Vars, Exprs} = get_exprs(locks_watcher, Arity),
    Form =
	case length(Vars) of
	    Arity ->
		%% We must create an abstract representation of the
		%% bindings list.
		Bindings = mk_cons(
			     lists:zipwith(
			       fun(A, B) ->
				       {tuple,L,[A,B]}
			       end, [{atom,L,V} || V <- Vars], Args), L),
		%% The actual call to erl_eval:exprts(Exprs) must be in
		%% abstract form, but Exprs must be abstract abstract form,
		%% since it shall be abstract at run-time.
		{tuple,L,[{atom,L,erl_eval},
			  {atom,L,exprs},
			  {cons,L,
			   erl_parse:abstract(Exprs,L),
			   {cons,L,Bindings,{nil,L}}}]};
	    _ ->
		{error, {L, ?MODULE, bad_arity}}
	end,
    [Form | transform(T)];
transform([H|T]) when is_tuple(H) ->
    [list_to_tuple(transform(tuple_to_list(H)))
     | transform(T)];
transform([H|T]) when is_list(H) ->
    [transform(H) | transform(T)];
transform([H|T]) ->
    [H | transform(T)];
transform([]) ->
    [].

mk_cons([H|T], L) ->
    {cons, L, H, mk_cons(T, L)};
mk_cons([], L) ->
    {nil, L}.

get_exprs(Function, Arity) ->
    {ok, {_, [{abstract_code,
	       {raw_abstract_v1, Forms}}]}} =
	beam_lib:chunks(code:which(?MODULE), [abstract_code]),
    [Clauses] = [Cs || {function,_,F,A,Cs} <- Forms,
	  F =:= Function, A =:= Arity],
    [{clause,_,Vars,[], Body}] = Clauses,
    VarNames = lists:map(fun({var,_,V}) -> V end, Vars),
    {VarNames, inline(Body, Forms)}.

inline([{call,L,{atom,_,F},Args}|T], Fs) ->
    Arity = length(Args),
    Args1 = inline(Args, Fs),
    case erlang:is_builtin(erlang,F,Arity) of
	true ->
	    [{call,L,{atom,L,F},Args1}|inline(T, Fs)];
	false ->
	    case [Cs || {function,_,F1,Arity1,Cs} <- Fs,
		 F1 =:= F, Arity1 =:= Arity] of
		[] ->
		    [{error,L,{undef,{F,Arity}}}];
		[Clauses] ->
		    [{call,L,{'fun',L,{clauses,Clauses}},Args1}
		     | inline(T,Fs)]
	    end
    end;
inline([H|T], Fs) when is_list(H) ->
    [inline(H, Fs) | inline(T, Fs)];
inline([H|T], Fs) when is_tuple(H) ->
    [list_to_tuple(inline(tuple_to_list(H), Fs)) | inline(T, Fs)];
inline([H|T], Fs) ->
    [H|inline(T, Fs)];
inline([], _) ->
    [].


