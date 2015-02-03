

# Module locks_agent #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)


Transaction agent for the locks system.
__Behaviours:__ [`gen_server`](gen_server.md).
<a name="description"></a>

## Description ##



This module implements the recommended API for users of the `locks` system.
While the `locks_server` has a low-level API, the `locks_agent` is the
part that detects and resolves deadlocks.


The agent runs as a separate process from the client, and monitors the
client, terminating immediately if it dies.
<a name="types"></a>

## Data Types ##




### <a name="type-option">option()</a> ###



<pre><code>
option() = {client, pid()} | {abort_on_deadlock, boolean()} | {await_nodes, boolean()} | {notify, boolean()}
</code></pre>





### <a name="type-transaction_status">transaction_status()</a> ###



<pre><code>
transaction_status() = no_locks | {have_all_locks, list()} | waiting | {cannot_serve, list()}
</code></pre>


<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#await_all_locks-1">await_all_locks/1</a></td><td>Waits for all active lock requests to be granted.</td></tr><tr><td valign="top"><a href="#begin_transaction-1">begin_transaction/1</a></td><td>Equivalent to <a href="#begin_transaction-2"><tt>begin_transaction(Objects, [])</tt></a>.</td></tr><tr><td valign="top"><a href="#begin_transaction-2">begin_transaction/2</a></td><td>Starts an agent and requests a number of locks at the same time.</td></tr><tr><td valign="top"><a href="#change_flag-3">change_flag/3</a></td><td></td></tr><tr><td valign="top"><a href="#end_transaction-1">end_transaction/1</a></td><td>Ends the transaction, terminating the agent.</td></tr><tr><td valign="top"><a href="#lock-2">lock/2</a></td><td></td></tr><tr><td valign="top"><a href="#lock-3">lock/3</a></td><td>Equivalent to <a href="#lock-6"><tt>lock(Agent, Obj, Mode, [node()], all, wait)</tt></a>.</td></tr><tr><td valign="top"><a href="#lock-4">lock/4</a></td><td></td></tr><tr><td valign="top"><a href="#lock-5">lock/5</a></td><td></td></tr><tr><td valign="top"><a href="#lock_info-1">lock_info/1</a></td><td></td></tr><tr><td valign="top"><a href="#lock_nowait-2">lock_nowait/2</a></td><td></td></tr><tr><td valign="top"><a href="#lock_nowait-3">lock_nowait/3</a></td><td></td></tr><tr><td valign="top"><a href="#lock_nowait-4">lock_nowait/4</a></td><td></td></tr><tr><td valign="top"><a href="#lock_nowait-5">lock_nowait/5</a></td><td></td></tr><tr><td valign="top"><a href="#lock_objects-2">lock_objects/2</a></td><td></td></tr><tr><td valign="top"><a href="#record_fields-1">record_fields/1</a></td><td></td></tr><tr><td valign="top"><a href="#spawn_agent-1">spawn_agent/1</a></td><td></td></tr><tr><td valign="top"><a href="#start-0">start/0</a></td><td>Equivalent to <a href="#start-1"><tt>start([])</tt></a>.</td></tr><tr><td valign="top"><a href="#start-1">start/1</a></td><td>Starts an agent with options.</td></tr><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td>Equivalent to <a href="#start_link-1"><tt>start_link([])</tt></a>.</td></tr><tr><td valign="top"><a href="#start_link-1">start_link/1</a></td><td>Starts an agent with options, linking to the client.</td></tr><tr><td valign="top"><a href="#surrender_nowait-4">surrender_nowait/4</a></td><td></td></tr><tr><td valign="top"><a href="#transaction_status-1">transaction_status/1</a></td><td>Inquire about the current status of the transaction.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="await_all_locks-1"></a>

### await_all_locks/1 ###


<pre><code>
await_all_locks(Agent::<a href="#type-agent">agent()</a>) -&gt; <a href="#type-lock_result">lock_result()</a>
</code></pre>

<br></br>



Waits for all active lock requests to be granted.


This function will return once all active lock requests have been granted.
If the agent determines that they cannot be granted, or if it has been
instructed to abort, this function will raise an exception.
<a name="begin_transaction-1"></a>

### begin_transaction/1 ###


<pre><code>
begin_transaction(Objects::<a href="#type-objs">objs()</a>) -&gt; {<a href="#type-agent">agent()</a>, <a href="#type-lock_result">lock_result()</a>}
</code></pre>

<br></br>


Equivalent to [`begin_transaction(Objects, [])`](#begin_transaction-2).
<a name="begin_transaction-2"></a>

### begin_transaction/2 ###


<pre><code>
begin_transaction(Objects::<a href="#type-objs">objs()</a>, Opts::<a href="#type-options">options()</a>) -&gt; {<a href="#type-agent">agent()</a>, <a href="#type-lock_result">lock_result()</a>}
</code></pre>

<br></br>



Starts an agent and requests a number of locks at the same time.



For a description of valid options, see [`start/1`](#start-1).


This function will return once the given lock requests have been granted,
or exit if they cannot be. If no initial lock requests are given, the
function will not wait at all, but return directly.
<a name="change_flag-3"></a>

### change_flag/3 ###

`change_flag(Agent, Option, Bool) -> any()`


<a name="end_transaction-1"></a>

### end_transaction/1 ###


<pre><code>
end_transaction(Agent::<a href="#type-agent">agent()</a>) -&gt; ok
</code></pre>

<br></br>



Ends the transaction, terminating the agent.


All lock requests issued via the agent will automatically be released.
<a name="lock-2"></a>

### lock/2 ###


<pre><code>
lock(Agent::pid(), Obj::<a href="#type-oid">oid()</a>) -&gt; {ok, list()}
</code></pre>

<br></br>



<a name="lock-3"></a>

### lock/3 ###


<pre><code>
lock(Agent::pid(), Obj::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>) -&gt; {ok, list()}
</code></pre>

<br></br>


Equivalent to [`lock(Agent, Obj, Mode, [node()], all, wait)`](#lock-6).
<a name="lock-4"></a>

### lock/4 ###


<pre><code>
lock(Agent::pid(), Obj::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>, Where::[node()]) -&gt; {ok, list()}
</code></pre>

<br></br>



<a name="lock-5"></a>

### lock/5 ###


<pre><code>
lock(Agent::pid(), Obj::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>, Where::[node()], R::<a href="#type-req">req()</a>) -&gt; {ok, list()}
</code></pre>

<br></br>



<a name="lock_info-1"></a>

### lock_info/1 ###

`lock_info(Agent) -> any()`


<a name="lock_nowait-2"></a>

### lock_nowait/2 ###

`lock_nowait(A, O) -> any()`


<a name="lock_nowait-3"></a>

### lock_nowait/3 ###

`lock_nowait(A, O, M) -> any()`


<a name="lock_nowait-4"></a>

### lock_nowait/4 ###

`lock_nowait(A, O, M, W) -> any()`


<a name="lock_nowait-5"></a>

### lock_nowait/5 ###

`lock_nowait(A, O, M, W, R) -> any()`


<a name="lock_objects-2"></a>

### lock_objects/2 ###


<pre><code>
lock_objects(Agent::pid(), Objects::<a href="#type-objs">objs()</a>) -&gt; ok
</code></pre>

<br></br>



<a name="record_fields-1"></a>

### record_fields/1 ###

`record_fields(X1) -> any()`


<a name="spawn_agent-1"></a>

### spawn_agent/1 ###

`spawn_agent(Options) -> any()`


<a name="start-0"></a>

### start/0 ###


<pre><code>
start() -&gt; {ok, pid()}
</code></pre>

<br></br>


Equivalent to [`start([])`](#start-1).
<a name="start-1"></a>

### start/1 ###


<pre><code>
start(Options0::[<a href="#type-option">option()</a>]) -&gt; {ok, pid()}
</code></pre>

<br></br>



Starts an agent with options.



Options are:



* `{client, pid()}` - defaults to `self()`, indicating which process is
the client. The agent will monitor the client, and only accept lock
requests from it (this may be extended in future version).



* `{link, boolean()}` - default: `false`. Whether to link the current
process to the agent. This is normally not required, but will have the
effect that the current process (normally the client) receives an 'EXIT'
signal if the agent aborts.



* `{abort_on_deadlock, boolean()}` - default: `false`. Normally, when
deadlocks are detected, one agent will be picked to surrender a lock.
This can be problematic if the client has already been notified that the
lock has been granted. If `{abort_on_deadlock, true}`, the agent will
abort if it would otherwise have had to surrender, __and__ the client
has been told that the lock has been granted.



* `{await_nodes, boolean()}` - default: `false`. If nodes 'disappear'
(i.e. the locks_server there goes away) and `{await_nodes, false}`,
the agent will consider those nodes lost and may abort if the lock
request(s) cannot be granted without the lost nodes. If `{await_nodes,true}`,
the agent will wait for the nodes to reappear, and reclaim the lock(s) when
they do.


* `{notify, boolean()}` - default: `false`. If `{notify, true}`, the client
will receive `{locks_agent, Agent, Info}` messages, where `Info` is either
a `#locks_info{}` record or `{have_all_locks, Deadlocks}`.
<a name="start_link-0"></a>

### start_link/0 ###


<pre><code>
start_link() -&gt; {ok, pid()}
</code></pre>

<br></br>


Equivalent to [`start_link([])`](#start_link-1).
<a name="start_link-1"></a>

### start_link/1 ###


<pre><code>
start_link(Options::[<a href="#type-option">option()</a>]) -&gt; {ok, pid()}
</code></pre>

<br></br>



Starts an agent with options, linking to the client.



Note that even if `{link, false}` is specified in the Options, this will
be overridden by `{link, true}`, implicit in the function name.



Linking is normally not required, as the agent will always monitor the
client and terminate if the client dies.


See also [`start/1`](#start-1).
<a name="surrender_nowait-4"></a>

### surrender_nowait/4 ###

`surrender_nowait(A, O, OtherAgent, Nodes) -> any()`


<a name="transaction_status-1"></a>

### transaction_status/1 ###


<pre><code>
transaction_status(Agent::<a href="#type-agent">agent()</a>) -&gt; <a href="#type-transaction_status">transaction_status()</a>
</code></pre>

<br></br>


Inquire about the current status of the transaction.
Return values:



<dt><code>no_locks</code></dt>




<dd>No locks have been requested</dd>




<dt><code>{have_all_locks, Deadlocks}</code></dt>




<dd>All requested locks have been claimed, <code>Deadlocks</code> indicates whether
any deadlocks were resolved in the process.</dd>




<dt><code>waiting</code></dt>




<dd>Still waiting for some locks.</dd>




<dt><code>{cannot_serve, Objs}</code></dt>




<dd>Some lock requests cannot be served, e.g. because some nodes are
unavailable.</dd>



