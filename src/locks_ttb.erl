-module(locks_ttb).

-compile([export_all, nowarn_export_all]).
-dialyzer({nowarn_function, pp_term/1}).

-record(h1, { tab = ets:new(h1, [ordered_set])
            , n   = 1
            , max = 1000
            , first_ts }).

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
     {locks_server, event, 3, []},
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
    %% ttb:format(Dir, format_opts(OutFile)).
    #h1{tab = T} = H1 = #h1{},
    ok = ttb:format(Dir, [{handler, {fun handler1/4, H1}}]),
    TS = fetch_ts(T),
    PMap = fetch_pmap(T),
    try to_file(OutFile, TS, PMap, T)
    after
        ets:delete(T)
    end.

format_opts() ->
    format_opts(standard_io).

format_opts(OutFile) ->
    [{out, OutFile}, {handler, {fun handler/4, {0,0}}}].

to_file(OutFile, TS0, PMap, Tab) ->
    {ok, Fd} = file:open(OutFile, [write]),
    if TS0 > 0 ->
            io:fwrite(Fd, "%% -*- erlang -*-~n", []);
       true ->
            ok
    end,
    try
        ets:foldl(
          fun({_, {Trace, TraceInfo}}, Acc) ->
                  handler(Fd, Trace, TraceInfo, Acc)
          end, {TS0,0,PMap}, Tab)
    after
        file:close(Fd)
    end.
                          
handler1(_Fd, Trace, TraceInfo, #h1{ first_ts = undefined } = S)
  when element(1, Trace) == trace_ts ->
    log_ts(Trace, S),
    log_pids(Trace, S),
    log({Trace, TraceInfo}, S#h1{ first_ts = Trace });
handler1(_Fd, Trace, TraceInfo, S) ->
    log_pids(Trace, S),
    log({Trace, TraceInfo}, S).

log_ts(TraceTs, #h1{ tab = T }) ->
    TS = element(tuple_size(TraceTs), TraceTs),
    ets:insert(T, {ts, TS}).

log_pids(Trace, #h1{ tab = T }) ->
    PMap = get_pmap(T),
    PMap1 = get_pids(Trace, #{}, ttb),
    ets:insert(T, {pmap, maps:merge(PMap, PMap1)}).

get_pmap(T) ->
    case ets:lookup(T, pmap) of
        [] ->
            #{};
        [{_, M}] ->
            M
    end.

fetch_pmap(T) ->
    M = get_pmap(T),
    ets:delete(T, pmap),
    M.

fetch_ts(T) ->
    case ets:lookup(T, ts) of
        [] ->
            0;
        [{_, TS}] ->
            ets:delete(T, ts),
            TS
    end.

log(X, #h1{ tab = T, n = N, max = Max } = S) ->
    ets:insert(T, {N, X}),
    if N > Max ->
            ets:delete(T, ets:first(T));
       true ->
            ok
    end,
    S#h1{ n = N+1 }.

handler(Fd, Trace, _, {Tp,Diff,PMap} = Acc) ->
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
	    case get_pids({Evt, State}, PMap) of
		M when map_size(M) == 0 -> ok;
		Pids ->
                    Nodes = [{node_prefix(P), N}
                             || {P, N} <- lists:ukeysort(
                                            2, maps:to_list(Pids))],
		    io:fwrite(Fd, "    Nodes = ~p~n", [Nodes])
	    end,
	    {TS, Diff1,PMap};
	_ ->
	    io:fwrite(Fd, "~p~n", [Trace]),
	    {Tp, Diff,PMap}
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
pp_term([H|T]) ->
    [pp_term(H) | pp_term(T)];
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

get_pids(Term, Ref) ->
    get_pids(Term, #{}, Ref).

%% get_pids(Term, M) ->
%%     get_pids(Term, Dict)),
%%     [{node_prefix(P), N} || {N, P} <- Pids].

get_pids(T, Acc, Ref) when is_tuple(T) ->
    get_pids(tuple_to_list(T), Acc, Ref);
get_pids(L, Acc, Ref) when is_list(L) ->
    get_pids_(L, Acc, Ref);
get_pids(P, Acc, Ref) when is_pid(P) ->
    case check_ref(P, Ref) of
        {ok, N} ->
                    Acc#{P => N};
	_ ->
	    Acc
    end;
get_pids(_, Acc, _) ->
    Acc.

check_ref(P, ttb) ->
    try ets:lookup(ttb, P) of
        [{_, _, Node}] ->
            {ok, Node};
        _ ->
            error
    catch
        error:_ -> error
    end;
check_ref(P, Map) when is_map(Map) ->
    maps:find(P, Map).

get_pids_([H|T], Acc, Ref) ->
    get_pids_(T, get_pids(H, Acc, Ref), Ref);
get_pids_(_, Acc, _) ->
    Acc.


node_prefix(P) ->
    case re:run(pid_to_list(P), "[^<\\.]+", [{capture,first,list}]) of
	{match, [Pfx]} ->
	    Pfx;
	_ ->
	    P
    end.
