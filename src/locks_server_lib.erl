-module(locks_server_lib).

-export([
         new_vsn/1
       , remove_agent/2
       , remove_agent_from_lock/3
       , related_locks/2
       , split_related/2
       , in_queue/3
       , into_queue/3
       , notify/3
        ]).
-include("locks.hrl").
-include("locks_server.hrl").

new_vsn(Tab) ->
    ets:update_counter(Tab, version, {2, 1}, {version, 1}).

notify([#lock{queue = Q, watchers = W} = H|T], Me, Note) ->
    ?event({notify, Q, W}),
    Msg = #locks_info{lock = H, note = Note},
    _ = [send(A, Msg) || A <- queue_agents(Q)],
    _ = [send(P, Msg) || P <- W],
    notify(T, Me, Note);
notify([], _, _) ->
    ok.

send(Pid, Msg) when is_pid(Pid) ->
    ?event({send, Pid, Msg}),
    Pid ! Msg.
%% send({Agent,_} = _A, Msg) when is_pid(Agent) ->
%%     ?event({send, Agent, Msg}),
%%     Agent ! Msg.

%% In the case of agents waiting for lock upgrade, there may be
%% more than one entry from a given agent. Since the agent performs
%% considerable work on each lock info, it's much cheaper if we avoid
%% sending duplicate notifications for a given lock.
queue_agents(Q) ->
    lists:usort([A || #entry{agent = A} <- queue_entries(Q)]).

queue_entries(Q) ->
    Res = queue_entries_(Q),
    ?event({queue_entries, Q, Res}),
    Res.

queue_entries_([#r{entries = Es}|Q]) ->
    Es ++ queue_entries_(Q);
queue_entries_([#w{entries = Es}|Q]) ->
    Es ++ queue_entries_(Q);
queue_entries_([]) ->
    [].

in_queue([H|T], A, Mode) ->
    case in_queue_(H, A, Mode) of
	false -> in_queue(T, A, Mode);
	true  -> true
    end;
in_queue([], _, _) ->
    false.

in_queue_(#r{entries = Entries}, A, read) ->
    lists:keymember(A, #entry.agent, Entries);
in_queue_(#w{entries = Es}, A, M) when M==read; M==write ->
    lists:keymember(A, #entry.agent, Es);
in_queue_(_, _, _) ->
    false.

into_queue(read, [#r{entries = Entries}] = Q, Entry) ->
    %% No pending write locks
    case lists:keymember(Entry#entry.agent, #entry.agent, Entries) of
	true -> Q;
	false ->
	    [#r{entries = [Entry|Entries]}]
    end;
into_queue(read,  [], Entry) ->
    [#r{entries = [Entry]}];
into_queue(write, [], Entry) ->
    [#w{entries = [Entry]}];
into_queue(write, [#r{entries = [Er]} = H], Entry) ->
    if Entry#entry.agent == Er#entry.agent ->
	    %% upgrade to write lock
	    [#w{entries = [Entry]}];
       true ->
	    [H, #w{entries = [Entry]}]
    end;
into_queue(write, [#w{entries = [#entry{agent = A}]}],
           #entry{agent = A, type = direct} = Entry) ->
    %% Refresh and ensure it's a direct lock
    [#w{entries = [Entry]}];
into_queue(Type, [H|T], #entry{agent = A, type = direct} = Entry) ->
    case H of
        #w{entries = [_,_|_]} ->
            %% This means that there are multiple exclusive write locks at
            %% a lower level; they can co-exist, but neither has an exclusive
            %% claim at this level. Queue request
            [H | into_queue(Type, T, Entry)];
        #w{entries = Es} when Type == write; Type == read ->
            %% If a matching entry exists, we set to new version and
            %% set type to direct. This means we might get a direct write
            %% lock even though we asked for a read lock.
            maybe_refresh(Es, H, T, Type, A, Entry);
        #r{entries = Es} when Type == read ->
            maybe_refresh(Es, H, T, Type, A, Entry);
        #r{entries = Es} when Type == write ->
            %% A special case is when all agents holding read entries have
            %% asked for an upgrade.
            case lists:all(fun(#entry{agent = A1}) when A1 == A -> true;
                              (#entry{agent = A1}) -> in_queue(T, A1, write)
                           end, Es) of
                true ->
                    %% discard all read entries
                    into_queue(write, T, Entry);
                false ->
                    [H | into_queue(Type, T, Entry)]
            end;
        _ ->
            [H | into_queue(Type, T, Entry)]
    end;
into_queue(Type, [H|T] = Q, Entry) ->
    case in_queue_(H, Entry#entry.agent, Type) of
	false ->
	    [H|into_queue(Type, T, Entry)];
	true ->
	    Q
    end.

remove_agent(A, {Locks, Agents, Admin}) ->
    case ets_select(Agents, [{ {{A,'$1'}}, [], [{{A,'$1'}}] }]) of
        [] ->
            [];
        [_|_] = Found ->
            ?event([{removing_agent, A}, {found, Found}]),
            ets:select_delete(Agents, [{ {{A,'_'}}, [], [true] }]),
            NewVsn = new_vsn(Admin),
            remove_agent_(Found, Locks, NewVsn, [])
    end.

remove_agent_([{A, ID}|T], Locks, Vsn, Acc) ->
    case ets_lookup(Locks, ID) of
	[] ->
	    remove_agent_(T, Locks, Vsn, Acc);
	[#lock{} = L] ->
            case remove_agent_from_lock(A, L, Vsn) of
                #lock{queue = [], watchers = []} ->
                    ets_delete(Locks, ID),
                    remove_agent_(T, Locks, Vsn, Acc);
                #lock{} = L1 ->
                    remove_agent_(T, Locks, Vsn, [L1|Acc])
            end
    end;
remove_agent_([], Locks, _Vsn, Acc) ->
    ets_insert(Locks, [L || #lock{queue = Q,
				  watchers = Ws} = L <- Acc,
			    Q =/= [] orelse Ws =/= []]),
    Acc.

remove_agent_from_lock(A, #lock{queue = Q, watchers = Ws} = L, Vsn) ->
    Q1 = trivial_lock_upgrade(
           lists:foldr(
             fun(#r{entries = [#entry{agent = Ax}]}, Acc1) when Ax == A ->
                     Acc1;
                (#r{entries = Es}, Acc1) ->
                     case lists:keydelete(A, #entry.agent, Es) of
                         [] -> Acc1;
                         Es1 ->
                             [#r{entries = Es1} | Acc1]
                     end;
                (#w{entries = Es}, Acc1) ->
                     case lists:keydelete(A, #entry.agent, Es) of
                         [] -> Acc1;
                         Es1 ->
                             [#w{entries = Es1} | Acc1]
                     end;
                (E, Acc1) ->
                     [E|Acc1]
             end, [], Q)),
    L#lock{version = Vsn, queue = Q1,
           watchers = Ws -- [A]}.

trivial_lock_upgrade([#r{entries = [#entry{agent = A}]} |
                      [#w{entries = [#entry{agent = A}]} | _] = T]) ->
    T;
trivial_lock_upgrade([#r{entries = Es}|[_|_] = T] = Q) ->
    %% Not so trivial, perhaps
    case lists:all(fun(#entry{agent = A}) ->
                           in_queue(T, A, write)
                   end, Es) of
        true ->
            %% All agents holding the read lock are also waiting for an upgrade
            trivial_lock_upgrade(T);
        false ->
            Q
    end;
trivial_lock_upgrade(Q) ->
    Q.

maybe_refresh(Es, H, T, Type, A, Entry) ->
    case lists:keyfind(A, #entry.agent, Es) of
        #entry{} = E ->
            Es1 = lists:keyreplace(A, #entry.agent, Es,
                                   E#entry{type = Entry#entry.type,
                                           version = Entry#entry.version}),
            case H of
                #w{} -> [H#w{entries = Es1} | T];
                #r{} -> [H#r{entries = Es1} | T]
            end;
        false ->
            [H | into_queue(Type, T, Entry)]
    end.

related_locks(ID, T) ->
    Pats = make_patterns(ID),
    ets_select(T, Pats).

make_patterns(ID) ->
    make_patterns(ID, []).

make_patterns([H|T], Acc) ->
    ID = Acc ++ [H],
    [{ #lock{object = ID, _ = '_'}, [], ['$_'] }
     | make_patterns(T, ID)];
make_patterns([], Acc) ->
    [{ #lock{object = Acc ++ '_', _ = '_'}, [], ['$_'] }].

split_related(Related, ID) ->
    case length(ID) of
	1 ->
	    case Related of
		[#lock{object = [_]} = Mine|Ch] -> {[], Mine, Ch};
		Ch -> {[], [], Ch}
	    end;
	2 -> split2(Related, ID);
	3 -> split3(Related, ID);
	4 -> split4(Related, ID);
	L -> split(Related, L, ID)
    end.

%%% =====

%% Generic split, will call length/1 on each ID
split(Locks, Len, ID) ->
    {Parents, Locks1} = split_ps(Locks, Len, []),
    split_(Locks1, ID, Parents).

split_ps([#lock{object = I}=H|T], Len, Acc) when length(I) < Len ->
    split_ps(T, Len, [H|Acc]);
split_ps(L, _, Acc) ->
    {lists:reverse(Acc), L}.

split_([#lock{object = ID} = Mine|Ch], ID, Parents) ->
    {Parents, Mine, Ch};
split_(Ch, ID, Parents) ->
    {Parents, #lock{object = ID}, Ch}.

%% Optimized split for ID length 2
split2([#lock{object = [_]} = H|T], ID) -> split2(T, [H], ID);
split2(L, ID) -> split2(L, [], ID).

split2([#lock{object = ID} = Mine|Ch], Ps, ID) -> {Ps, Mine, Ch};
split2(Ch, Ps, _ID) -> {Ps, [], Ch}.

%% Optimized split for ID length 3
split3(L, ID) ->
    case L of
	[#lock{object = [_]} = P1, #lock{object = [_,_]} = P2|T] ->
	    split3(T, [P1,P2], ID);
	[#lock{object = [_]} = P1|T] ->
	    split3(T, [P1], ID);
	[#lock{object = [_,_]} = P2|T] ->
	    split3(T, [P2], ID);
	[#lock{object = ID} = Mine|T] ->
	    {[], Mine, T};
	[_|_] ->
	    {[], [], L}
    end.

split3([#lock{object = ID} = Mine|Ch], Ps, ID) -> {Ps, Mine, Ch};
split3(Ch, Ps, _ID) -> {Ps, [], Ch}.

split4(L, ID) ->
    {Ps, L1} = split4_ps(L, []),
    split4(L1, Ps, ID).

split4_ps([#lock{object = [_]} = H|T], Acc) -> split4_ps(T, [H|Acc]);
split4_ps([#lock{object = [_,_]} = H|T], Acc) -> split4_ps(T, [H|Acc]);
split4_ps([#lock{object = [_,_,_]} = H|T], Acc) -> split4_ps(T, [H|Acc]);
split4_ps(L, Acc) -> {lists:reverse(Acc), L}.

split4([#lock{object = [_,_,_,_]} = Mine|Ch], Ps, _) -> {Ps, Mine, Ch};
split4(Ch, Ps, _ID) -> {Ps, [], Ch}.

ets_insert(T, Data) -> ets:insert(T, Data).
ets_lookup(T, K)    -> ets:lookup(T, K).
ets_select(T, Pat)  -> ets:select(T, Pat).
ets_delete(T, K)    -> ets:delete(T, K).
