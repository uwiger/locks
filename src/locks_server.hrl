

-define(LOCKS, locks_server_locks).
-define(AGENTS, locks_server_agents).
-define(ADMIN, locks_server_admin).

-record(st, {tabs = {ets:new(?LOCKS, [public, named_table,
                                      ordered_set, {keypos, 2}]),
		     ets:new(?AGENTS, [public, named_table, ordered_set]),
                     ets:new(?ADMIN, [public, named_table, set])},
	     monitors = #{},
	     notify_as = self()}).

-record(surr, {id, mode, type, client, vsn, lock}).

-define(event(E), event(?LINE, E, none)).
-define(event(E, S), event(?LINE, E, S)).

event(_Line, _Msg, _St) ->
    ok.

