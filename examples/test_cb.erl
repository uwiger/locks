%% ``The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved via the world wide web at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%-------------------------------------------------------------------
%% Created : 18 Mar 2003 by Ulf Wiger <etxuwig@cbe1066>
%%-------------------------------------------------------------------
%% @author Ulf Wiger <ulf.wiger@ericsson.com>
%% @author Thomas Arts <thomas.arts@ituniv.se>
%%
%% @doc Example callback module for the gen_leader behaviour.
%% <p>This particular callback module implements a global dictionary,
%% and is the back-end for the <code>gdict</code> module.</p>
%% @end
%%
%%
%% @type dictionary() = tuple().
%%   Same as from {@link dict:new(). dict:new()}; used in this module as State.
%%
%% @type info() = function(). Opaque state of the gen_leader behaviour.
%% @type node() = atom(). A node name.
%% @type state() = dictionary().
%%    Internal server state; In the general case, it can be any term.
%% @type broadcast() = term().
%%    Whatever the leader decides to broadcast to the candidates.
%% @type reason()  = term(). Error information.
%% @type commonReply() = {ok, state()} |
%%                       {ok, broadcast(), state()} |
%%                       {stop, reason(), state()}.
%%   Common set of valid replies from most callback functions.
%%

-module(test_cb).

-behaviour(locks_leader).

-export([init/1,
	 elected/3,
	 surrendered/3,
	 handle_DOWN/3,
	 handle_leader_call/4,
	 handle_leader_cast/3,
	 from_leader/3,
	 handle_call/4,
	 handle_cast/3,
	 handle_info/3,
	 terminate/2,
	 code_change/4]).


%% @spec init(Arg::term()) -> {ok, State}
%%
%%   State = state()
%%
%% @doc Equivalent to the init/1 function in a gen_server.
%%
init(Dict) ->
    io:fwrite("init(~p)~n", [Dict]),
    {ok,Dict}.

%% @spec elected(State::state(), I::info(), Cand:pid()) ->
%%   {ok, Broadcast, NState}
%%
%%     Broadcast = broadcast()
%%     NState    = state()
%%
%% @doc Called by the leader it is elected leader, and each time a
%% candidate recognizes the leader.
%% <p>This function is only called in the leader instance, and
%% <code>Broadcast</code> will be sent to all candidates
%% (when the leader is first elected), or to the new candidate that
%% has appeared.</p>
%% <p><code>Broadcast</code> might be the same as <code>NState</code>,
%% but doesn't have to be. This is up to the application.</p>
%% <p>Example:</p>
%% <pre>
%%   elected(Dict, _I) ->
%%       {ok, Dict, Dict}.
%% </pre>
%% @end
%%
elected(Dict, _E, undefined) ->
    io:fwrite("elected(~p)~n", [dict:to_list(Dict)]),
    {ok, Dict, Dict};
elected(Dict, _E, Pid) when is_pid(Pid) ->
    io:fwrite("elected: syncing with ~p (~p)~n", [Pid, dict:to_list(Dict)]),
    {reply, Dict, Dict}.


%% @spec surrendered(State::state(), Synch::broadcast(), I::info()) ->
%%          {ok, NState}
%%
%%    NState = state()
%%
%% @doc Called by each candidate when it recognizes another instance as
%% leader.
%% <p>Strictly speaking, this function is called when the candidate
%% acknowledges a leader and receives a Synch message in return.</p>
%% <p>Example:</p>
%% <pre>
%%  surrendered(_OurDict, LeaderDict, _I) ->
%%      {ok, LeaderDict}.
%% </pre>
%% @end
surrendered(OurDict, LeaderDict, _I) ->
    io:fwrite("surrendered(New:~p, Old:~p)~n", [dict:to_list(OurDict),
						dict:to_list(LeaderDict)]),
    {ok, LeaderDict}.

%% @spec handle_DOWN(Candidate::pid(), State::state(), I::info()) ->
%%    {ok, NState} | {ok, Broadcast, NState}
%%
%%   Broadcast = broadcast()
%%   NState    = state()
%%
%% @doc Called by the leader when it detects loss of a candidate.
%% <p>If the function returns a <code>Broadcast</code> object, this will
%% be sent to all candidates, and they will receive it in the function
%% {@link from_leader/3. from_leader/3}.</p>
%% @end
handle_DOWN(Pid, Dict, _I) ->
    io:fwrite("handle_DOWN(~p,Dict,E)~n", [Pid]),
    {ok, Dict}.

%% @spec handle_leader_call(Msg::term(), From::callerRef(), State::state(),
%%                          I::info()) ->
%%    {reply, Reply, NState} |
%%    {reply, Reply, Broadcast, NState} |
%%    {noreply, state()} |
%%    {stop, Reason, Reply, NState} |
%%    commonReply()
%%
%%   Broadcast = broadcast()
%%   NState    = state()
%%
%% @doc Called by the leader in response to a
%% {@link gen_leader:leader_call/2. leader_call()}.
%% <p>If the return value includes a <code>Broadcast</code> object, it will
%% be sent to all candidates, and they will receive it in the function
%% {@link from_leader/3. from_leader/3}.</p>
%% <p>Example:</p>
%% <pre>
%%   handle_leader_call({store,F}, From, Dict, E) ->
%%       NewDict = F(Dict),
%%       {reply, ok, {store, F}, NewDict};
%%   handle_leader_call({leader_lookup,F}, From, Dict, E) ->
%%       Reply = F(Dict),
%%       {reply, Reply, Dict}.
%% </pre>
%% <p>In this particular example, <code>leader_lookup</code> is not
%% actually supported from the {@link gdict. gdict} module, but would
%% be useful during complex operations, involving a series of updates
%% and lookups. Using <code>leader_lookup</code>, all dictionary operations
%% are serialized through the leader; normally, lookups are served locally
%% and updates by the leader, which can lead to race conditions.</p>
%% @end
handle_leader_call({store,F} = Op, _From, Dict, _I) ->
    io:fwrite("handle_leader_call(~p, _From, Dict, I)~n", [Op]),
    NewDict = F(Dict),
    {reply, ok, {store, F}, NewDict};
handle_leader_call({leader_lookup,F} = Op, _From, Dict, _I) ->
    io:fwrite("handle_leader_call(~p, From, Dict, I)~n", [Op]),
    Reply = F(Dict),
    {reply, Reply, Dict}.


%% @spec handle_leader_cast(Msg::term(), State::term(), I::info()) ->
%%   commonReply()
%%
%% @doc Called by the leader in response to a {@link gen_leader:leader_cast/2.
%% leader_cast()}.
%% <p><b>BUG:</b> This has not yet been implemented.</p>
%% @end
handle_leader_cast(_Msg, Dict, _I) ->
    io:fwrite("handle_leader_cast(~p, Dict, I)~n", [_Msg]),
    {ok, Dict}.

%% @spec from_leader(Msg::term(), State::state(), I::info()) ->
%%    {ok, NState}
%%
%%   NState = state()
%%
%% @doc Called by each candidate in response to a message from the leader.
%% <p>In this particular module, the leader passes an update function to be
%% applied to the candidate's state.</p>
from_leader({store,F} = Op, Dict, I) ->
    io:fwrite("from_leader(~p, Dict, ~p)~n", [Op, I]),
    NewDict = F(Dict),
    {ok, NewDict}.


%% @spec handle_call(Request::term(), From::callerRef(), State::state(),
%%                   I::info()) ->
%%    {reply, Reply, NState} |
%%    {noreply, state()} |
%%    {stop, Reason, Reply, NState} |
%%    commonReply()
%%
%% @doc Equivalent to <code>Mod:handle_call/3</code> in a gen_server.
%% <p>Note the difference in allowed return values. <code>{ok,NState}</code>
%% and <code>{noreply,NState}</code> are synonymous.
%% <code>{noreply,NState}</code> is allowed as a return value from
%% <code>handle_call/3</code>, since it could arguably add some clarity,
%% but it has been disallowed from <code>handle_cast/2</code> and
%% <code>handle_info/2</code></p>
%% @end
%%
handle_call({lookup, F}, _From, Dict, _I) ->
    Reply = F(Dict),
    {reply, Reply, Dict}.

%% @spec handle_cast(Msg::term(), State::state(), I::info()) ->
%%    commonReply()
%%
%% @doc Equivalent to <code>Mod:handle_call/3</code> in a gen_server,
%% except (<b>NOTE</b>) for the possible return values.
%%
handle_cast(_Msg, Dict, _I) ->
    {noreply, Dict}.

%% @spec handle_info(Msg::term(), State::state(), I::info()) -> commonReply()
%%
%% @doc Equivalent to <code>Mod:handle_info/3</code> in a gen_server,
%% except (<b>NOTE</b>) for the possible return values.
%% <p>This function will be called in response to any incoming message
%% not recognized as a call, cast, leader_call, leader_cast, from_leader
%% message, internal leader negotiation message or system message.</p>
%%
handle_info(_Msg, Dict, _I) ->
    {noreply, Dict}.

%% @spec code_change(FromVsn::string(), OldState::term(),
%%                   I::info(), Extra::term()) ->
%%       {ok, NState}
%%
%%    NState = state()
%%
%% @doc Similar to code_change/3 in a gen_server callback module, with
%% the exception of the added argument.
%%
code_change(_FromVsn, Dict, _I, _Extra) ->
    {ok, Dict}.

%% @spec terminate(Reason::term(), State::state()) -> Void
%%
%% @doc Equivalent to <code>terminate/2</code> in a gen_server callback
%% module.
%%
terminate(_Reason, _Dict) ->
    ok.
