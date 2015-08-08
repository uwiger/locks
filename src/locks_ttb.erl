-module(locks_ttb).

-compile(export_all).


%% This function is also traced. Can be used to insert markers in the trace
%% log.
event(E) ->
    event(?LINE, E, none).

event(_, _, _) ->
    ok.

trace_nodes(Ns, File) ->
    trace_nodes(Ns, default_patterns(), default_flags(), [{file, File}]).

trace_nodes(Ns, Patterns, Flags, Opts) ->
    ttb:start_trace(Ns, Patterns, Flags, Opts).

default_patterns() ->
    [{locks_agent , event, 3, []},
     {locks_leader, event, 3, []},
     {?MODULE     , event, 3, []}].

default_flags() ->
    {all, call}.

stop() ->
    {stopped, Dir} = ttb:stop([return_fetch_dir]),
    Dir.

stop_nofetch() ->
    ttb:stop([nofetch]).

format(Dir) ->
    format(Dir, standard_io).

format(Dir, OutFile) ->
    ttb:format(Dir, format_opts(OutFile)).

format_opts() ->
    format_opts(standard_io).

format_opts(OutFile) ->
    [{out, OutFile}, {handler, {fun handler/4, {0,0}}}].

handler(Fd, Trace, _, {Tp,Diff} = Acc) ->
    if Acc == {0,0} ->
	    io:fwrite(Fd, "%% -*- erlang -*-~n", []);
       true -> ok
    end,
    case Trace of
	{trace_ts,{_, _, Node},
	 call,
	 {Mod, event, [Line, Evt, State]}, TS} when is_integer(Line) ->
	    Tdiff = tdiff(TS, Tp),
	    Diff1 = Diff + Tdiff,
	    print(Fd, Node, Mod, Line, Evt, State, Diff1),
	    case get_pids({Evt, State}) of
		[] -> ok;
		Pids ->
		    io:fwrite(Fd, "    Nodes = ~p~n", [Pids])
	    end,
	    {TS, Diff1};
	_ ->
	    io:fwrite(Fd, "~p~n", [Trace]),
	    {Tp, Diff}
    end.

-define(CHAR_MAX, 60).

print(Fd, N, Mod, L, E, St, T) ->
    Tstr = io_lib:fwrite("~w", [T]),
    Indent = iolist_size(Tstr) + 3,
    Head = io_lib:fwrite(" - ~w|~w/~w: ", [N, Mod, L]),
    EvtCol = iolist_size(Head) + 1,
    EvtCs = pp(E, EvtCol, Mod),
    io:requests(Fd, [{put_chars, unicode, [Tstr, Head, EvtCs]}, nl
		     | print_tail(St, Mod, Indent)]).

print_tail(none, _, _Col) -> [];
print_tail(St, Mod, Col) ->
    Cs = pp(St, Col+1, Mod),
    [{put_chars, unicode, [lists:duplicate(Col,$\s), Cs]}, nl].

pp(Term, Col, Mod) ->
    io_lib_pretty:print(pp_term(Term),
                        [{column, Col},
                         {line_length, 80},
                         {depth, -1},
                         {max_chars, ?CHAR_MAX},
                         {record_print_fun, record_print_fun(Mod)}]).

pp_term(D) when element(1,D) == dict ->
    try {'$dict', dict:to_list(D)}
    catch
        error:_ ->
            list_to_tuple([pp_term(T) || T <- tuple_to_list(D)])
    end;
pp_term(T) when is_tuple(T) ->
    list_to_tuple([pp_term(Trm) || Trm <- tuple_to_list(T)]);
pp_term(L) when is_list(L) ->
    [pp_term(T) || T <- L];
pp_term(T) ->
    T.



tdiff(_, 0) -> 0;
tdiff(TS, T0) ->
    %% time difference in milliseconds
    timer:now_diff(TS, T0) div 1000.

record_print_fun(Mod) ->
    fun(Tag, NoFields) ->
	    try Mod:record_fields(Tag) of
		Fields when is_list(Fields) ->
		    case length(Fields) of
			NoFields -> Fields;
			_ -> no
		    end;
		no -> no
	    catch
		_:_ ->
		    no
	    end
    end.

get_pids(Term) ->
    Pids = dict:to_list(get_pids(Term, dict:new())),
    [{node_prefix(P), N} || {N, P} <- Pids].

get_pids(T, Acc) when is_tuple(T) ->
    get_pids(tuple_to_list(T), Acc);
get_pids(L, Acc) when is_list(L) ->
    get_pids_(L, Acc);
get_pids(P, Acc) when is_pid(P) ->
    try ets:lookup(ttb, P) of
	[{_, _, Node}] ->
	    dict:store(Node, P, Acc);
	_ ->
	    Acc
    catch
	error:_ -> Acc
    end;
get_pids(_, Acc) ->
    Acc.

get_pids_([H|T], Acc) ->
    get_pids_(T, get_pids(H, Acc));
get_pids_(_, Acc) ->
    Acc.


node_prefix(P) ->
    case re:run(pid_to_list(P), "[^<\\.]+", [{capture,first,list}]) of
	{match, [Pfx]} ->
	    Pfx;
	_ ->
	    P
    end.
