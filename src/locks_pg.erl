-module(locks_pg).

-define(SCOPE, ?MODULE).

-export([ start_link/0
	, join/2
	, leave/2
	, monitor/1
	, get_members/1 ]).


start_link() ->
    pg:start_link(?SCOPE).

monitor(Group) ->
    pg:monitor(?SCOPE, Group).

join(Group, PidOrPids) ->
    pg:join(?SCOPE, Group, PidOrPids).

leave(Group, PidOrPids) ->
    pg:leave(?SCOPE, Group, PidOrPids).

get_members(Group) ->
    pg:get_members(?SCOPE, Group).
