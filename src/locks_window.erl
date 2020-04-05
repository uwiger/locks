-module(locks_window).

-export([new/1,
         add/2,
         to_list/1]).

-export([log/2,
         fetch_log/1]).

-record(w, {n   = 0,
            max = 10,
            a   = [],
            b   = []}).

new(#{n := N}) when is_integer(N), N > 0 ->
    #w{max = N}.

add(X, #w{n = N0, max = Max, a = A} = W) ->
    A1 = [X|A],
    case N0+1 of
       N1 when N1 > Max ->
            W#w{n = 0, a = [], b = A1};
       N1 ->
            W#w{n = N1, a = A1}
    end.

to_list(#w{a = A, b = B}) ->
    lists:reverse(B) ++ lists:reverse(A).


log(X, Sz) ->
    W = add({erlang:system_time(millisecond), X}, get_log(Sz)),
    put_log(W).

-define(KEY, {?MODULE, w}).

get_log(Sz) ->
    case get(?KEY) of
        undefined ->
            new(#{n => Sz});
        W ->
            W
    end.

put_log(W) ->
    put(?KEY, W).


fetch_log(P) ->
    PI = case w(P) of
             undefined ->
                 undefined;
             Pid when node(Pid) == node() ->
                 process_info(Pid, dictionary);
             Pid when is_pid(Pid) ->
                 rpc:call(node(Pid), erlang, process_info, [Pid, dictionary])
         end,
    fetch_from_info(PI).

fetch_from_info(undefined) ->
    undefined;
fetch_from_info({dictionary, D}) ->
    case lists:keyfind(?KEY, 1, D) of
        false ->
            '$no_debug';
        {_, W} ->
            to_list(W)
    end.

w(P) when is_atom(P) ->
    whereis(P);
w(P) when is_pid(P) ->
    P.
