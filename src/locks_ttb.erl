%% -*- erlang-indent-level: 4; indent-tabs-mode: nil -*-
%%
%% Trace helpers for locks. Prefer permanent `event/3` call sites over
%% tracing every MFA: events are cheap enough to leave in production
%% code, give stable narrative markers in multi-node failures, and avoid
%% the truncation storms that come with blanket call tracing.
%%
%% Pretty-printing: raw ttb binary dirs sit next to the generated `.txt`.
%% Use `ttb` tools on the raw dir for ad-hoc queries; use format/1,2 for a
%% full narrative, or format_events/1,2 for a compact event-only timeline
%% (usually what you want when grepping a netsplit failure).
-module(locks_ttb).

-compile([export_all, nowarn_export_all]).
%% pp_term/io_lib_pretty paths are intentionally defensive over arbitrary
%% terms; dialyzer cannot prove local return through pretty-print.
-dialyzer({nowarn_function, [pp_term/1, pp/3, print/7]}).

%% This function is also traced. Can be used to insert markers in the trace
%% log. Leave calls in place as permanent instrumentation.
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
     %% Society plane (pg-based candidate discovery)
     {locks_pg    , join, 2, []},
     {locks_pg    , leave, 2, []},
     {locks_pg    , monitor, 1, []},
     {locks_pg    , get_members, 1, []},
     {?MODULE     , event, 3, []}].

default_flags() ->
    {all, call}.

stop() ->
    {stopped, Dir} = ttb:stop([return_fetch_dir]),
    Dir.

stop_nofetch() ->
    ttb:stop([nofetch]).

%% Full narrative: each event with pretty-printed payload and optional state.
%% Streams a single pass over the raw ttb dir (no intermediate ETS window,
%% so long netsplit runs are not silently truncated at 1000 events).
format(Dir) ->
    format(Dir, standard_io).

format(Dir, Out) ->
    with_out(Out, fun(Fd) ->
                          ok = ttb:format(Dir, [{handler, {fun handler/4, st0(Fd, full)}}])
                  end).

%% Compact timeline of event/3 calls only: relative ms, node, MFA line, event
%% term. State is omitted (still in the raw ttb dump if needed). Ideal for
%% grepping and for large multi-node runs.
format_events(Dir) ->
    format_events(Dir, standard_io).

format_events(Dir, Out) ->
    with_out(Out, fun(Fd) ->
                          ok = ttb:format(Dir, [{handler, {fun handler/4, st0(Fd, events)}}])
                  end).

%% Stock ttb handler opts (legacy / ad-hoc). ttb opens `out` and passes Fd
%% as the first handler argument; we pick it up on the first call.
format_opts() ->
    format_opts(standard_io).

format_opts(OutFile) ->
    [{out, OutFile}, {handler, {fun handler/4, st0(full)}}].

st0(Mode) when Mode =:= full; Mode =:= events ->
    #{mode => Mode, tp => 0, diff => 0, header => false}.

st0(Fd, Mode) ->
    (st0(Mode))#{fd => Fd}.

with_out(standard_io, Fun) ->
    Fun(standard_io),
    ok;
with_out(Fd, Fun) when is_pid(Fd); is_atom(Fd) ->
    Fun(Fd),
    ok;
with_out(OutFile, Fun) when is_list(OutFile); is_binary(OutFile) ->
    {ok, Fd} = file:open(OutFile, [write, {encoding, utf8}]),
    try Fun(Fd)
    after
        file:close(Fd)
    end,
    ok.

handler(TtbFd, Trace, _TraceInfo, St0) ->
    St = case St0 of
             #{fd := _} -> St0;
             _ -> St0#{fd => TtbFd}
         end,
    case Trace of
        {trace_ts, {_, _, Node}, call,
         {Mod, event, [Line, Evt, State]}, TS} when is_integer(Line) ->
            handle_event(Node, Mod, Line, Evt, State, TS, St);
        _ ->
            handle_other(Trace, St)
    end.

handle_event(Node, Mod, Line, Evt, State, TS, #{diff := Diff, tp := Tp} = St) ->
    Tdiff = tdiff(TS, Tp),
    Diff1 = Diff + Tdiff,
    St1 = ensure_header(St),
    print_event(St1, Node, Mod, Line, Evt, State, Diff1),
    maybe_nodes(St1, Evt, State),
    St1#{tp := TS, diff := Diff1}.

handle_other(_Trace, #{mode := events} = St) ->
    %% Event-only mode: skip raw/non-event frames (pg calls, etc.).
    St;
handle_other(Trace, St) ->
    #{fd := Fd} = St1 = ensure_header(St),
    io:fwrite(Fd, "~p~n", [Trace]),
    St1.

ensure_header(#{header := true} = St) ->
    St;
ensure_header(#{fd := Fd, header := false} = St) ->
    io:fwrite(Fd, "%% -*- erlang -*-~n", []),
    St#{header := true}.

print_event(#{fd := Fd, mode := events}, N, Mod, L, E, _St, T) ->
    %% Strictly one line per event (no state). ~0p keeps nested terms on a
    %% single line so timelines stay greppable; depth caps runaway locks
    %% info without dropping the event tag.
    io:fwrite(Fd, "~w - ~w|~w/~w: ~0P~n", [T, N, Mod, L, E, 12]);
print_event(#{fd := Fd, mode := full}, N, Mod, L, E, St, T) ->
    print(Fd, N, Mod, L, E, St, T).

maybe_nodes(#{mode := events}, _, _) ->
    ok;
maybe_nodes(#{fd := Fd}, Evt, State) ->
    case get_pids({Evt, State}, #{}, ttb) of
        M when map_size(M) == 0 ->
            ok;
        Pids ->
            Nodes = [{node_prefix(P), N}
                     || {P, N} <- lists:ukeysort(2, maps:to_list(Pids))],
            io:fwrite(Fd, "    Nodes = ~p~n", [Nodes])
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
    [{put_chars, unicode, [lists:duplicate(Col, $\s), Cs]}, nl].

pp(Term, Col, Mod) ->
    io_lib_pretty:print(pp_term(Term),
                        [{column, Col},
                         {line_length, 80},
                         {depth, -1},
                         {max_chars, ?CHAR_MAX},
                         {record_print_fun, record_print_fun(Mod)}]).

pp_term(D) when element(1, D) == dict ->
    try {'$dict', dict:to_list(D)}
    catch
        error:_ ->
            list_to_tuple(pp_term_l(tuple_to_list(D)))
    end;
pp_term(T) when is_tuple(T) ->
    list_to_tuple(pp_term_l(tuple_to_list(T)));
pp_term(L) when is_list(L) ->
    pp_term_l(L);
pp_term(T) ->
    T.

pp_term_l([H|T]) when is_list(T) ->
    [pp_term(H) | pp_term_l(T)];
pp_term_l([H|T]) ->
    [pp_term(H) | pp_term(T)];
pp_term_l([]) ->
    [].

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
    case re:run(pid_to_list(P), "[^<\\.]+", [{capture, first, list}]) of
        {match, [Pfx]} ->
            Pfx;
        _ ->
            P
    end.
