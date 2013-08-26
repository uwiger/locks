

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


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#await_all_locks-1">await_all_locks/1</a></td><td></td></tr><tr><td valign="top"><a href="#begin_transaction-0">begin_transaction/0</a></td><td></td></tr><tr><td valign="top"><a href="#begin_transaction-1">begin_transaction/1</a></td><td></td></tr><tr><td valign="top"><a href="#begin_transaction-2">begin_transaction/2</a></td><td></td></tr><tr><td valign="top"><a href="#end_transaction-1">end_transaction/1</a></td><td></td></tr><tr><td valign="top"><a href="#lock-2">lock/2</a></td><td></td></tr><tr><td valign="top"><a href="#lock-3">lock/3</a></td><td></td></tr><tr><td valign="top"><a href="#lock-4">lock/4</a></td><td></td></tr><tr><td valign="top"><a href="#lock-5">lock/5</a></td><td></td></tr><tr><td valign="top"><a href="#lock_nowait-2">lock_nowait/2</a></td><td></td></tr><tr><td valign="top"><a href="#lock_nowait-3">lock_nowait/3</a></td><td></td></tr><tr><td valign="top"><a href="#lock_nowait-4">lock_nowait/4</a></td><td></td></tr><tr><td valign="top"><a href="#lock_objects-2">lock_objects/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="await_all_locks-1"></a>

### await_all_locks/1 ###


<pre><code>
await_all_locks(Agent::<a href="#type-agent">agent()</a>) -&gt; <a href="#type-lock_result">lock_result()</a>
</code></pre>

<br></br>



<a name="begin_transaction-0"></a>

### begin_transaction/0 ###


<pre><code>
begin_transaction() -&gt; {<a href="#type-agent">agent()</a>, <a href="#type-lock_result">lock_result()</a>}
</code></pre>

<br></br>



<a name="begin_transaction-1"></a>

### begin_transaction/1 ###


<pre><code>
begin_transaction(Objects::<a href="#type-objs">objs()</a>) -&gt; {<a href="#type-agent">agent()</a>, <a href="#type-lock_result">lock_result()</a>}
</code></pre>

<br></br>



<a name="begin_transaction-2"></a>

### begin_transaction/2 ###


<pre><code>
begin_transaction(Objects::<a href="#type-objs">objs()</a>, Options::<a href="#type-options">options()</a>) -&gt; {<a href="#type-agent">agent()</a>, <a href="#type-lock_result">lock_result()</a>}
</code></pre>

<br></br>



<a name="end_transaction-1"></a>

### end_transaction/1 ###


<pre><code>
end_transaction(Agent::pid()) -&gt; ok
</code></pre>

<br></br>



<a name="lock-2"></a>

### lock/2 ###


<pre><code>
lock(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>) -&gt; {ok, <a href="#type-deadlocks">deadlocks()</a>}
</code></pre>

<br></br>



<a name="lock-3"></a>

### lock/3 ###


<pre><code>
lock(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>) -&gt; {ok, <a href="#type-deadlocks">deadlocks()</a>}
</code></pre>

<br></br>



<a name="lock-4"></a>

### lock/4 ###


<pre><code>
lock(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>, Nodes::<a href="#type-where">where()</a>) -&gt; {ok, <a href="#type-deadlocks">deadlocks()</a>}
</code></pre>

<br></br>



<a name="lock-5"></a>

### lock/5 ###


<pre><code>
lock(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>, Nodes::<a href="#type-where">where()</a>, Req::<a href="#type-req">req()</a>) -&gt; {ok, <a href="#type-deadlocks">deadlocks()</a>}
</code></pre>

<br></br>



<a name="lock_nowait-2"></a>

### lock_nowait/2 ###


<pre><code>
lock_nowait(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>) -&gt; ok
</code></pre>

<br></br>



<a name="lock_nowait-3"></a>

### lock_nowait/3 ###


<pre><code>
lock_nowait(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>) -&gt; ok
</code></pre>

<br></br>



<a name="lock_nowait-4"></a>

### lock_nowait/4 ###


<pre><code>
lock_nowait(Agent::<a href="#type-agent">agent()</a>, OID::<a href="#type-oid">oid()</a>, Mode::<a href="#type-mode">mode()</a>, Nodes::<a href="#type-where">where()</a>) -&gt; ok
</code></pre>

<br></br>



<a name="lock_objects-2"></a>

### lock_objects/2 ###


<pre><code>
lock_objects(Agent::<a href="#type-agent">agent()</a>, Objects::<a href="#type-objs">objs()</a>) -&gt; ok
</code></pre>

<br></br>



