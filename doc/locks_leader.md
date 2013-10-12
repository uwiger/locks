

# Module locks_leader #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)


Leader election behavior.
__Behaviours:__ [`gen_server`](gen_server.md).

__This module defines the `locks_leader` behaviour.__
<br></br>
 Required callback functions: `init/1`, `elected/3`, `surrendered/3`, `handle_DOWN/3`, `handle_leader_call/4`, `handle_leader_cast/3`, `from_leader/3`, `handle_call/4`, `handle_cast/3`, `handle_info/3`.
<a name="description"></a>

## Description ##



This behavior is inspired by gen_leader, and offers the same API
except for a few details. The leader election strategy is based on
the `locks` library. The leader election group is identified by the
lock used - by default, `[locks_leader, CallbackModule]`, but configurable
using the option `{resource, Resource}`, in which case the lock name will
be `[locks_leader, Resource]`. The lock corresponding to the leader group
will in the following description be referred to as The Lock.



Each instance is started either as a 'candidate' or a 'worker'.
Candidates all try to claim a write lock on The Lock, and workers merely
monitor it. All candidates and workers will find each other through the
`#locks_info{}` messages. This means that, unlike gen_leader, the
locks_leader dynamically adopts new nodes, candidates and workers. It is
also possible to have multiple candidates and workers on the same node.


The candidate that is able to claim The Lock becomes the leader.

```
Leader instance:
     Mod:elected(ModState, Info, undefined) -> {ok, Sync, ModState1}.
  Other instances:
     Mod:surrendered(ModState, Sync, Info) -> {ok, ModState1}.
```



If a candidate or worker joins the group, the same function is called,
but with the Pid of the new member as third argument. It can then
return either `{reply, Sync, ModState1}`, in which case only the new
member will get the Sync message, or `{ok, Sync, ModState1}`, in which case
all group members will be notified.




## Split brain ##


The `locks_leader` behavior will automatically heal from netsplits and
ensure that there is only one leader. A candidate that was the leader but
is forced to surrender, can detect this e.g. by noting in its own state
when it becomes leader:

```erlang

  surrendered(#state{is_leader = true} = S, Sync, _Info) ->
      %% I was leader; a netsplit has occurred
      {ok, surrendered_after_netsplit(S, Sync, Info)};
  surrendered(S, Sync, _Info) ->
      {ok, normal_surrender(S, Sync, Info)}.
```


The newly elected candidate normally doesn't know that a split-brain
has occurred, but can sync with other candidates using e.g. the function
[`ask_candidates/2`](#ask_candidates-2), which functions rather like a parallel
`gen_server:call/2`.
<a name="types"></a>

## Data Types ##




### <a name="type-election">election()</a> ###


__abstract datatype__: `election()`




### <a name="type-ldr_options">ldr_options()</a> ###



<pre><code>
ldr_options() = [<a href="#type-option">option()</a>]
</code></pre>





### <a name="type-leader_info">leader_info()</a> ###


__abstract datatype__: `leader_info()`




### <a name="type-mod_state">mod_state()</a> ###



<pre><code>
mod_state() = any()
</code></pre>





### <a name="type-msg">msg()</a> ###



<pre><code>
msg() = any()
</code></pre>





### <a name="type-option">option()</a> ###



<pre><code>
option() = {role, candidate | worker} | {resource, any()}
</code></pre>





### <a name="type-server_ref">server_ref()</a> ###



<pre><code>
server_ref() = atom() | pid()
</code></pre>


<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#ask_candidates-2">ask_candidates/2</a></td><td>Send a synchronous request to all candidates.</td></tr><tr><td valign="top"><a href="#broadcast-2">broadcast/2</a></td><td>Broadcast <code>Msg</code> to all candidates and workers.</td></tr><tr><td valign="top"><a href="#broadcast_to_candidates-2">broadcast_to_candidates/2</a></td><td>Broadcast <code>Msg</code> to all (synced) candidates.</td></tr><tr><td valign="top"><a href="#call-2">call/2</a></td><td>Make a <code>gen_server</code>-like call to the leader candidate <code>L</code>.</td></tr><tr><td valign="top"><a href="#call-3">call/3</a></td><td>Make a timeout-guarded <code>gen_server</code>-like call to the leader
candidate <code>L</code>.</td></tr><tr><td valign="top"><a href="#candidates-1">candidates/1</a></td><td>Return the current list of candidates.</td></tr><tr><td valign="top"><a href="#cast-2">cast/2</a></td><td>Make a <code>gen_server</code>-like cast to the leader candidate <code>L</code>.</td></tr><tr><td valign="top"><a href="#leader-1">leader/1</a></td><td>Return the leader pid, or <code>undefined</code> if there is no current leader.</td></tr><tr><td valign="top"><a href="#leader_call-2">leader_call/2</a></td><td>Make a synchronous call to the leader.</td></tr><tr><td valign="top"><a href="#leader_cast-2">leader_cast/2</a></td><td>Make an asynchronous cast to the leader.</td></tr><tr><td valign="top"><a href="#leader_node-1">leader_node/1</a></td><td>Return the node of the current leader.</td></tr><tr><td valign="top"><a href="#new_candidates-1">new_candidates/1</a></td><td>Return the current list of candidates that have not yet been synced.</td></tr><tr><td valign="top"><a href="#reply-2">reply/2</a></td><td>Corresponds to <code>gen_server:reply/2</code>.</td></tr><tr><td valign="top"><a href="#start_link-2">start_link/2</a></td><td>Starts an anonymous locks_leader candidate using <code>Module</code> as callback.</td></tr><tr><td valign="top"><a href="#start_link-3">start_link/3</a></td><td>Starts an anonymous worker or candidate.</td></tr><tr><td valign="top"><a href="#start_link-4">start_link/4</a></td><td>Starts a locally registered worker or candidate.</td></tr><tr><td valign="top"><a href="#workers-1">workers/1</a></td><td>Return the current list of workers.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="ask_candidates-2"></a>

### ask_candidates/2 ###


<pre><code>
ask_candidates(Req::any(), St::<a href="#type-election">election()</a>) -&gt; {GoodReplies, Errors}
</code></pre>

<ul class="definitions"><li><code>GoodReplies = [{pid(), any()}]</code></li><li><code>Errors = [{pid(), any()}]</code></li></ul>


Send a synchronous request to all candidates.


The request `Req` will be processed in `Mod:handle_call/4` and can be
handled as any other request. The return value separates the good replies
from the failed (the candidate died or couldn't be reached).
<a name="broadcast-2"></a>

### broadcast/2 ###


<pre><code>
broadcast(Msg::any(), St::<a href="#type-election">election()</a>) -&gt; ok
</code></pre>

<br></br>



Broadcast `Msg` to all candidates and workers.



This function may only be called from the current leader.


The message will be processed in the `Mod:from_leader/3` callback.
Note: You should not use this function from the `Mod:elected/3` function,
since it may cause sequencing issues with the broadcast message that is
(normally) sent once the `Mod:elected/3` function returns.
<a name="broadcast_to_candidates-2"></a>

### broadcast_to_candidates/2 ###


<pre><code>
broadcast_to_candidates(Msg::any(), St::<a href="#type-election">election()</a>) -&gt; ok
</code></pre>

<br></br>



Broadcast `Msg` to all (synced) candidates.



This function may only be called from the current leader.


The message will be processed in the `Mod:from_leader/3` callback.
Note: You should not use this function from the `Mod:elected/3` function,
since it may cause sequencing issues with the broadcast message that is
(normally) sent once the `Mod:elected/3` function returns.
<a name="call-2"></a>

### call/2 ###


<pre><code>
call(L::<a href="#type-server_ref">server_ref()</a>, Request::any()) -&gt; any()
</code></pre>

<br></br>


Make a `gen_server`-like call to the leader candidate `L`.
<a name="call-3"></a>

### call/3 ###


<pre><code>
call(L::<a href="#type-server_ref">server_ref()</a>, Request::any(), Timeout::integer() | infinity) -&gt; any()
</code></pre>

<br></br>


Make a timeout-guarded `gen_server`-like call to the leader
candidate `L`.
<a name="candidates-1"></a>

### candidates/1 ###


<pre><code>
candidates(St::<a href="#type-election">election()</a>) -&gt; [pid()]
</code></pre>

<br></br>


Return the current list of candidates.
<a name="cast-2"></a>

### cast/2 ###


<pre><code>
cast(L::<a href="#type-server_ref">server_ref()</a>, Msg::any()) -&gt; ok
</code></pre>

<br></br>


Make a `gen_server`-like cast to the leader candidate `L`.
<a name="leader-1"></a>

### leader/1 ###


<pre><code>
leader(St::<a href="#type-election">election()</a>) -&gt; pid() | undefined
</code></pre>

<br></br>


Return the leader pid, or `undefined` if there is no current leader.
<a name="leader_call-2"></a>

### leader_call/2 ###


<pre><code>
leader_call(Name::<a href="#type-server_ref">server_ref()</a>, Request::term()) -&gt; term()
</code></pre>

<br></br>



Make a synchronous call to the leader.


This function is similar to `gen_server:call/2`, but is forwarded to
the leader by the leader candidate `L` (unless, of course, it is the
leader, in which case it handles it directly). If the leader should die
before responding, this function will raise an `error({leader_died,...})`
exception.
<a name="leader_cast-2"></a>

### leader_cast/2 ###


<pre><code>
leader_cast(L::<a href="#type-server_ref">server_ref()</a>, Msg::term()) -&gt; ok
</code></pre>

<br></br>



Make an asynchronous cast to the leader.


This function is similar to `gen_server:cast/2`, but is forwarded to
the leader by the leader candidate `L` (unless, of course, it is the
leader, in which case it handles it directly). No guarantee is given
that the cast actually reaches the leader (i.e. if the leader dies, no
attempt is made to resend to the next elected leader).
<a name="leader_node-1"></a>

### leader_node/1 ###


<pre><code>
leader_node(St::<a href="#type-election">election()</a>) -&gt; node()
</code></pre>

<br></br>



Return the node of the current leader.


This function is mainly present for compatibility with `gen_leader`.
<a name="new_candidates-1"></a>

### new_candidates/1 ###


<pre><code>
new_candidates(St::<a href="#type-election">election()</a>) -&gt; [pid()]
</code></pre>

<br></br>



Return the current list of candidates that have not yet been synced.


This function is mainly indented to be used from within `Mod:elected/3`,
once a leader has been elected. One possible use is to contact the
new candidates to see whether one of them was a leader, which could
be the case if the candidates appeared after a healed netsplit.
<a name="reply-2"></a>

### reply/2 ###


<pre><code>
reply(From::{pid(), any()}, Reply::any()) -&gt; ok
</code></pre>

<br></br>



Corresponds to `gen_server:reply/2`.


Callback modules should use this function instead in order to be future
safe.
<a name="start_link-2"></a>

### start_link/2 ###


<pre><code>
start_link(Module::atom(), St::any()) -&gt; {ok, pid()}
</code></pre>

<br></br>



Starts an anonymous locks_leader candidate using `Module` as callback.


The leader candidate will sync with all candidates using the same
callback module, on all connected nodes.
<a name="start_link-3"></a>

### start_link/3 ###


<pre><code>
start_link(Module::atom(), St::any(), Options::<a href="#type-ldr_options">ldr_options()</a>) -&gt; {ok, pid()}
</code></pre>

<br></br>



Starts an anonymous worker or candidate.



The following options are supported:



* `{role, candidate | worker}` - A candidate is able to take on the
leader role, if elected; a worker simply follows the elections and
receives broadcasts from the leader.


* `{resource, Resource}` - The name of the lock used for the election
is normally `[locks_leader, Module]`, but with this option, it can be
changed into `[locks_leader, Resource]`. Note that, under the rules of
the locks application, a lock name must be a list.
<a name="start_link-4"></a>

### start_link/4 ###


<pre><code>
start_link(Reg::atom(), Module::atom(), St::any(), Options::<a href="#type-ldr_options">ldr_options()</a>) -&gt; {ok, pid()}
</code></pre>

<br></br>



Starts a locally registered worker or candidate.



Note that only one registered instance of the same name (using the
built-in process registry) can exist on a given node. However, it is
still possible to have multiple instances of the same election group
on the same node, either anonymous, or registered under different names.


For a description of the options, see [`start_link/3`](#start_link-3).
<a name="workers-1"></a>

### workers/1 ###


<pre><code>
workers(St::<a href="#type-election">election()</a>) -&gt; [pid()]
</code></pre>

<br></br>


Return the current list of workers.
