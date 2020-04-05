

# Module test_cb #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)


Example callback module for the locks_leader behaviour.
__Behaviours:__ [`locks_leader`](/Users/uwiger/FL/git/locks/./doc/locks_leader.md).

__Authors:__ Ulf Wiger ([`ulf.wiger@feuerlabs.com`](mailto:ulf.wiger@feuerlabs.com)), Thomas Arts ([`thomas.arts@quviq.com`](mailto:thomas.arts@quviq.com)).
<a name="description"></a>

## Description ##

This particular callback module implements a global dictionary,
and is the back-end for the `gdict` module.

<a name="types"></a>

## Data Types ##




### <a name="type-broadcast">broadcast()</a> ###



<pre><code>
broadcast() = term()
</code></pre>



Whatever the leader decides to broadcast to the candidates.



### <a name="type-commonReply">commonReply()</a> ###



<pre><code>
commonReply() = {ok, <a href="#type-state">state()</a>} | {ok, <a href="#type-broadcast">broadcast()</a>, <a href="#type-state">state()</a>} | {stop, <a href="#type-reason">reason()</a>, <a href="#type-state">state()</a>}
</code></pre>



Common set of valid replies from most callback functions.




### <a name="type-dictionary">dictionary()</a> ###



<pre><code>
dictionary() = tuple()
</code></pre>



Same as from [dict:new()](dict.md#type-new); used in this module as State.




### <a name="type-info">info()</a> ###



<pre><code>
info() = term()
</code></pre>



Opaque state of the gen_leader behaviour.



### <a name="type-reason">reason()</a> ###



<pre><code>
reason() = term()
</code></pre>



Error information.



### <a name="type-state">state()</a> ###



<pre><code>
state() = <a href="#type-dictionary">dictionary()</a>
</code></pre>



Internal server state; In the general case, it can be any term.
<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#code_change-4">code_change/4</a></td><td>Similar to <code>code_change/3</code> in a gen_server callback module, with
the exception of the added argument.</td></tr><tr><td valign="top"><a href="#elected-3">elected/3</a></td><td>Called by the leader when it is elected leader, and each time a
candidate recognizes the leader.</td></tr><tr><td valign="top"><a href="#from_leader-3">from_leader/3</a></td><td>Called by each candidate in response to a message from the leader.</td></tr><tr><td valign="top"><a href="#handle_DOWN-3">handle_DOWN/3</a></td><td>Called by the leader when it detects loss of a candidate.</td></tr><tr><td valign="top"><a href="#handle_call-4">handle_call/4</a></td><td>Equivalent to <code>Mod:handle_call/3</code> in a gen_server.</td></tr><tr><td valign="top"><a href="#handle_cast-3">handle_cast/3</a></td><td>Equivalent to <code>Mod:handle_call/3</code> in a gen_server, except
(<b>NOTE</b>) for the possible return values.</td></tr><tr><td valign="top"><a href="#handle_info-3">handle_info/3</a></td><td>Equivalent to <code>Mod:handle_info/3</code> in a gen_server,
except (<b>NOTE</b>) for the possible return values.</td></tr><tr><td valign="top"><a href="#handle_leader_call-4">handle_leader_call/4</a></td><td>Called by the leader in response to a
<a href="/Users/uwiger/FL/git/locks/./doc/locks_leader.md#leader_call-2">leader_call()</a>.</td></tr><tr><td valign="top"><a href="#handle_leader_cast-3">handle_leader_cast/3</a></td><td>Called by the leader in response to a <a href="/Users/uwiger/FL/git/locks/./doc/locks_leader.md#leader_cast-2">  leader_cast()</a>.</td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td>Equivalent to the init/1 function in a gen_server.</td></tr><tr><td valign="top"><a href="#surrendered-3">surrendered/3</a></td><td>Called by each candidate when it recognizes another instance as
leader.</td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td>Equivalent to <code>terminate/2</code> in a gen_server callback
module.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="code_change-4"></a>

### code_change/4 ###


<pre><code>
code_change(FromVsn::string(), OldState::term(), I::<a href="#type-info">info()</a>, Extra::term()) -&gt; {ok, NState}
</code></pre>

<ul class="definitions"><li><code>NState = <a href="#type-state">state()</a></code></li></ul>

Similar to `code_change/3` in a gen_server callback module, with
the exception of the added argument.
<a name="elected-3"></a>

### elected/3 ###


<pre><code>
elected(State::<a href="#type-state">state()</a>, I::<a href="#type-info">info()</a>, Cand::pid() | undefined) -&gt; {ok, Broadcast, NState} | {reply, Msg, NState} | {ok, AmLeaderMsg, FromLeaderMsg, NState} | {error, term()}
</code></pre>

<ul class="definitions"><li><code>Broadcast = <a href="#type-broadcast">broadcast()</a></code></li><li><code>NState = <a href="#type-state">state()</a></code></li></ul>


Called by the leader when it is elected leader, and each time a
candidate recognizes the leader.



This function is only called in the leader instance, and `Broadcast`
will be sent to all candidates (when the leader is first elected),
or to the new candidate that has appeared.



`Broadcast` might be the same as `NState`, but doesn't have to be.
This is up to the application.



If `Cand == undefined`, it is possible to obtain a list of all new
candidates that we haven't synced with (in the normal case, this will be
all known candidates, but if our instance is re-elected after a netsplit,
the 'new' candidates will be the ones that haven't yet recognized us as
leaders). This gives us a chance to talk to them before crafting our
broadcast message.



We can also choose a different message for the new candidates and for
the ones that already see us as master. This would be accomplished by
returning `{ok, AmLeaderMsg, FromLeaderMsg, NewState}`, where
`AmLeaderMsg` is sent to the new candidates (and processed in
[`surrendered/3`](#surrendered-3), and `FromLeaderMsg` is sent to the old
(and processed in [`from_leader/3`](#from_leader-3)).



If `Cand == Pid`, a new candidate has connected. If this affects our state
such that all candidates need to be informed, we can return `{ok, Msg, NSt}`.
If, on the other hand, we only need to get the one candidate up to speed,
we can return `{reply, Msg, NSt}`, and only the candidate will get the
message. In either case, the candidate (`Cand`) will receive the message
in [`surrendered/3`](#surrendered-3). In the former case, the other candidates will
receive the message in [`from_leader/3`](#from_leader-3).



Example:



```erlang

    elected(#st{dict = Dict} = St, _I, undefined) ->
        {ok, Dict, St};
    elected(#st{dict = Dict} = St, _I, Pid) when is_pid(Pid) ->
        %% reply only to Pid
        {reply, Dict, St}.
```

<a name="from_leader-3"></a>

### from_leader/3 ###


<pre><code>
from_leader(Msg::term(), State::<a href="#type-state">state()</a>, I::<a href="#type-info">info()</a>) -&gt; {ok, NState}
</code></pre>

<ul class="definitions"><li><code>NState = <a href="#type-state">state()</a></code></li></ul>


Called by each candidate in response to a message from the leader.


In this particular module, the leader passes an update function to be
applied to the candidate's state.
<a name="handle_DOWN-3"></a>

### handle_DOWN/3 ###


<pre><code>
handle_DOWN(Candidate::pid(), State::<a href="#type-state">state()</a>, I::<a href="#type-info">info()</a>) -&gt; {ok, NState} | {ok, Broadcast, NState}
</code></pre>

<ul class="definitions"><li><code>Broadcast = <a href="#type-broadcast">broadcast()</a></code></li><li><code>NState = <a href="#type-state">state()</a></code></li></ul>


Called by the leader when it detects loss of a candidate.


If the function returns a `Broadcast` object, this will be sent to all
candidates, and they will receive it in the function [`from_leader/3`](#from_leader-3).
<a name="handle_call-4"></a>

### handle_call/4 ###


<pre><code>
handle_call(Request::term(), From::<a href="#type-callerRef">callerRef()</a>, State::<a href="#type-state">state()</a>, I::<a href="#type-info">info()</a>) -&gt; {reply, Reply, NState} | {noreply, NState} | {stop, Reason, Reply, NState} | <a href="#type-commonReply">commonReply()</a>
</code></pre>

<br></br>



Equivalent to `Mod:handle_call/3` in a gen_server.



Note the difference in allowed return values. `{ok,NState}` and
`{noreply,NState}` are synonymous.


`{noreply,NState}` is allowed as a return value from `handle_call/3`,
since it could arguably add some clarity, but mainly because people are
used to it from gen_server.
<a name="handle_cast-3"></a>

### handle_cast/3 ###


<pre><code>
handle_cast(Msg::term(), State::<a href="#type-state">state()</a>, I::<a href="#type-info">info()</a>) -&gt; {noreply, NState} | <a href="#type-commonReply">commonReply()</a>
</code></pre>

<br></br>


Equivalent to `Mod:handle_call/3` in a gen_server, except
(__NOTE__) for the possible return values.

<a name="handle_info-3"></a>

### handle_info/3 ###


<pre><code>
handle_info(Msg::term(), State::<a href="#type-state">state()</a>, I::<a href="#type-info">info()</a>) -&gt; {noreply, NState} | <a href="#type-commonReply">commonReply()</a>
</code></pre>

<br></br>



Equivalent to `Mod:handle_info/3` in a gen_server,
except (__NOTE__) for the possible return values.


This function will be called in response to any incoming message
not recognized as a call, cast, leader_call, leader_cast, from_leader
message, internal leader negotiation message or system message.
<a name="handle_leader_call-4"></a>

### handle_leader_call/4 ###


<pre><code>
handle_leader_call(Msg::term(), From::<a href="#type-callerRef">callerRef()</a>, State::<a href="#type-state">state()</a>, I::<a href="#type-info">info()</a>) -&gt; {reply, Reply, NState} | {reply, Reply, Broadcast, NState} | {noreply, <a href="#type-state">state()</a>} | {stop, Reason, Reply, NState} | <a href="#type-commonReply">commonReply()</a>
</code></pre>

<ul class="definitions"><li><code>Broadcast = <a href="#type-broadcast">broadcast()</a></code></li><li><code>NState = <a href="#type-state">state()</a></code></li></ul>


Called by the leader in response to a
[leader_call()](/Users/uwiger/FL/git/locks/./doc/locks_leader.md#leader_call-2).



If the return value includes a `Broadcast` object, it will be sent to all
candidates, and they will receive it in the function [`from_leader/3`](#from_leader-3).

Example:



```erlang

    handle_leader_call({store,F}, From, #st{dict = Dict} = S, E) ->
        NewDict = F(Dict),
        {reply, ok, {store, F}, S#st{dict = NewDict}};
    handle_leader_call({leader_lookup,F}, From, #st{dict = Dict} = S, E) ->
        Reply = F(Dict),
        {reply, Reply, S}.
```


In this particular example, `leader_lookup` is not actually supported
from the [gdict](gdict.md) module, but would be useful during
complex operations, involving a series of updates and lookups. Using
`leader_lookup`, all dictionary operations are serialized through the
leader; normally, lookups are served locally and updates by the leader,
which can lead to race conditions.
<a name="handle_leader_cast-3"></a>

### handle_leader_cast/3 ###


<pre><code>
handle_leader_cast(Msg::term(), State::term(), I::<a href="#type-info">info()</a>) -&gt; <a href="#type-commonReply">commonReply()</a>
</code></pre>

<br></br>


Called by the leader in response to a [  leader_cast()](/Users/uwiger/FL/git/locks/./doc/locks_leader.md#leader_cast-2).
<a name="init-1"></a>

### init/1 ###


<pre><code>
init(Arg::term()) -&gt; {ok, State}
</code></pre>

<ul class="definitions"><li><code>State = <a href="#type-state">state()</a></code></li></ul>

Equivalent to the init/1 function in a gen_server.

<a name="surrendered-3"></a>

### surrendered/3 ###


<pre><code>
surrendered(State::<a href="#type-state">state()</a>, Synch::<a href="#type-broadcast">broadcast()</a>, I::<a href="#type-info">info()</a>) -&gt; {ok, NState}
</code></pre>

<ul class="definitions"><li><code>NState = <a href="#type-state">state()</a></code></li></ul>


Called by each candidate when it recognizes another instance as
leader.



Strictly speaking, this function is called when the candidate
acknowledges a leader and receives a Synch message in return.



Example:



```erlang

   surrendered(_OurDict, LeaderDict, _I) ->
       {ok, LeaderDict}.
```

<a name="terminate-2"></a>

### terminate/2 ###


<pre><code>
terminate(Reason::term(), State::<a href="#type-state">state()</a>) -&gt; Void
</code></pre>

<br></br>


Equivalent to `terminate/2` in a gen_server callback
module.
