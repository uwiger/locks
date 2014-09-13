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
-module(bench).

-export([simple_locks/1, simple_locks/2]).

simple_locks(N) ->
    simple_locks(1, N).

simple_locks(Begin, End) ->
    application:start(locks),
    T = ets:new(t, [ordered_set]),
    simple_locks(Begin, End, 10, 10, T).

simple_locks(Begin, End, Iter, Iter0, Tab) when Iter > 0 ->
    simple_locks_i(Begin, End, Tab),
    simple_locks(Begin, End, Iter-1, Iter0, Tab);
simple_locks(_, _, 0, Iter0, Tab) ->
    lists:map(
      fun({N, T}) ->
	      {N, T/Iter0}
      end, ets:tab2list(Tab)).

simple_locks_i(Begin, End, Tab) ->
    {A, {ok,[]}} = locks:begin_transaction(),
    loop(Begin, End,
	 fun(N1) ->
		 {Time, {ok,[]}} =
		     timer:tc(locks, lock, [A, [?MODULE, N1], write]),
		 Time
	 end, Tab),
    locks:end_transaction(A),
    erlang:garbage_collect().

loop(N, End, F, Tab) when N =< End ->
    T = F(N),
    update_counter(Tab, N, T),
    loop(N+1, End, F, Tab);
loop(_, _, _, _) ->
    ok.

update_counter(Tab, K, V) ->
    try ets:update_counter(Tab, K, {2, V})
    catch
	error:_ ->
	    ets:insert(Tab, {K, V})
    end.
