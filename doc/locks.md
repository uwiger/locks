

# Module locks #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)


Official API for the 'locks' system.

<a name="description"></a>

## Description ##



This module contains the supported interface functions for


* starting and stopping a transaction (agent)
* acquiring locks via an agent
* awaiting requested locks
<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#await_all_locks-1">await_all_locks/1</a></td><td>Await the results of all requested locks.</td></tr><tr><td valign="top"><a href="#begin_transaction-0">begin_transaction/0</a></td><td>Equivalent to <a href="#begin_transaction-2"><tt>begin_transaction([], [])</tt></a>.</td></tr><tr><td valign="top"><a href="#begin_transaction-1">begin_transaction/1</a></td><td>Equivalent to <a href="#begin_transaction-2"><tt>begin_transaction(Objects, [])</tt></a>.</td></tr><tr><td valign="top"><a href="#begin_transaction-2">begin_transaction/2</a></td><td>Starts a transaction agent.</td></tr><tr><td valign="top"><a href="#end_transaction-1">end_transaction/1</a></td><td>Terminates the transaction agent, releasing all locks.</td></tr><tr><td valign="top"><a href="#lock-2">lock/2</a></td><td>Equivalent to <a href="#lock-5"><tt>lock(Agent, OID, write, [node()], all)</tt></a>.</td></tr><tr><td valign="top"><a href="#lock-3">lock/3</a></td><td>Equivalent to <a href="#lock-5"><tt>lock(Agent, OID, Mode, [node()], all)</tt></a>.</td></tr><tr><td valign="top"><a href="#lock-4">lock/4</a></td><td>Equivalent to <a href="#lock-5"><tt>lock(Agent, OID, Mode, Nodes, all)</tt></a>.</td></tr><tr><td valign="top"><a href="#lock-5">lock/5</a></td><td>Acquire a lock on object.</td></tr><tr><td valign="top"><a href="#lock_nowait-2">lock_nowait/2</a></td><td>Equivalent to <a href="#lock_nowait-5"><tt>lock_nowait(Agent, OID, write, [node()], all)</tt></a>.</td></tr><tr><td valign="top"><a href="#lock_nowait-3">lock_nowait/3</a></td><td>Equivalent to <a href="#lock_nowait-5"><tt>lock_nowait(Agent, OID, Mode, [node()], all)</tt></a>.</td></tr><tr><td valign="top"><a href="#lock_nowait-4">lock_nowait/4</a></td><td>Equivalent to <a href="#lock_nowait-5"><tt>lock_nowait(Agent, OID, Mode, Nodes, all)</tt></a>.</td></tr><tr><td valign="top"><a href="#lock_objects-2">lock_objects/2</a></td><td>Asynchronously locks several objects at once.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="await_all_locks-1"></a>

### await_all_locks/1 ###


<pre><code>
await_all_locks(Agent::<a href="#type-agent">agent()</a>) -&gt; <a href="#type-lock_result">lock_result()</a>
</code></pre>

<br></br>



Await the results of all requested locks.



This function blocks until all requested locks have been acquired, or it
is determined that they cannot be (and the transaction aborts).


The return value is `{have_all_locks | have_none, Deadlocks}`,
where `Deadlocks` is a list of `{OID, Node}` pairs that were either
surrendered or released as a result of an abort triggered by the deadlock
analysis.
<a name="begin_transaction-0"></a>

### begin_transaction/0 ###


<pre><code>
begin_transaction() -&gt; {<a href="#type-agent">agent()</a>, <a href="#type-lock_result">lock_result()</a>}
</code></pre>

<br></br>


Equivalent to [`begin_transaction([], [])`](#begin_transaction-2).
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
begin_transaction(Objects::<a href="#type-objs">objs()</a>, Options::<a href="#type-options">options()</a>) -&gt; {<a href="#type-agent">agent()</a>, <a href="#type-lock_result">lock_result()</a>}
</code></pre>

<br></br>



Starts a transaction agent.



Valid options are:


* `{abort_on_deadlock, boolean()}` - default: `false`. Normally, when a
deadlock is detected, the involved agents will resolve it by one agent
surrendering a lock, but this is not always desireable. With this option,
agents will abort if a deadlock is detected.
* `{client, pid()}` - defaults to `self()`. The agent will accept lock
requests only from the designated client.

<a name="end_transaction-1"></a>

### end_transaction/1 ###


<pre><code>
end_transaction(Agent::pid()) -&gt; ok
</code></pre>

<br></br>



Terminates the transaction agent, releasing all locks.


Note that there is no unlock() operation. The way to release locks is
to end the transaction.
<a name="lock-2"></a>

### lock/2 ###


<pre><code>
lock(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>) -&gt; {ok, <a href="#type-deadlocks">deadlocks()</a>}
</code></pre>

<br></br>


Equivalent to [`lock(Agent, OID, write, [node()], all)`](#lock-5).
<a name="lock-3"></a>

### lock/3 ###


<pre><code>
lock(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>) -&gt; {ok, <a href="#type-deadlocks">deadlocks()</a>}
</code></pre>

<br></br>


Equivalent to [`lock(Agent, OID, Mode, [node()], all)`](#lock-5).
<a name="lock-4"></a>

### lock/4 ###


<pre><code>
lock(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>, Nodes::<a href="#type-where">where()</a>) -&gt; {ok, <a href="#type-deadlocks">deadlocks()</a>}
</code></pre>

<br></br>


Equivalent to [`lock(Agent, OID, Mode, Nodes, all)`](#lock-5).
<a name="lock-5"></a>

### lock/5 ###


<pre><code>
lock(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>, Nodes::<a href="#type-where">where()</a>, Req::<a href="#type-req">req()</a>) -&gt; {ok, <a href="#type-deadlocks">deadlocks()</a>}
</code></pre>

<br></br>



Acquire a lock on object.



This operation requires an active transaction agent
(see [`begin_transaction/2`](#begin_transaction-2)).



The object identifier is a non-empty list, where each element represents
a level in a lock tree. For example, in a database `Db`, with tables and
objects, object locks could be given as `[Db, Table, Key]`, table locks
as `[Db, Table]` and schema locks `[Db]`.



`Mode` can be either `read` (shared) or `write` (exclusive). If possible,
read locks will be upgraded to write locks when requested. Specifically,
this can be done if no other agent also hold a read lock, and there are
no waiting agents on the lock (directly or indirectly). If the lock cannot
be upgraded, the read lock will be removed and a write lock request will
be inserted in the lock queue.


The lock request is synchronous, and will return when this and all previous
lock requests have been granted. The return value is `{ok, Deadlocks}`,
where `Deadlocks` is a list of objects that have caused a deadlock.

<a name="lock_nowait-2"></a>

### lock_nowait/2 ###


<pre><code>
lock_nowait(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>) -&gt; ok
</code></pre>

<br></br>


Equivalent to [`lock_nowait(Agent, OID, write, [node()], all)`](#lock_nowait-5).
<a name="lock_nowait-3"></a>

### lock_nowait/3 ###


<pre><code>
lock_nowait(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>) -&gt; ok
</code></pre>

<br></br>


Equivalent to [`lock_nowait(Agent, OID, Mode, [node()], all)`](#lock_nowait-5).
<a name="lock_nowait-4"></a>

### lock_nowait/4 ###


<pre><code>
lock_nowait(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>, Nodes::<a href="#type-where">where()</a>) -&gt; ok
</code></pre>

<br></br>


Equivalent to [`lock_nowait(Agent, OID, Mode, Nodes, all)`](#lock_nowait-5).
<a name="lock_objects-2"></a>

### lock_objects/2 ###


<pre><code>
lock_objects(Agent::<a href="#type-agent">agent()</a>, Objects::<a href="#type-objs">objs()</a>) -&gt; ok
</code></pre>

<br></br>



Asynchronously locks several objects at once.



This function is equivalent to repeatedly calling [`lock_nowait/5`](#lock_nowait-5),
essentially:



```erlang

  lists:foreach(
      fun({OID, Mode}) -> lock_nowait(Agent, OID, Mode);
         ({OID, Mode, Nodes}) -> lock_nowait(Agent, OID, Mode, Nodes);
         ({OID, Mode, Nodes, Req}) -> lock_nowait(Agent,OID,Mode,Nodes,Req)
      end, Objects)
```

