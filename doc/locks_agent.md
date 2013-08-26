

# Module locks_agent #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`gen_server`](gen_server.md).
<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#await_all_locks-1">await_all_locks/1</a></td><td></td></tr><tr><td valign="top"><a href="#begin_transaction-1">begin_transaction/1</a></td><td></td></tr><tr><td valign="top"><a href="#begin_transaction-2">begin_transaction/2</a></td><td></td></tr><tr><td valign="top"><a href="#end_transaction-1">end_transaction/1</a></td><td></td></tr><tr><td valign="top"><a href="#lock-2">lock/2</a></td><td></td></tr><tr><td valign="top"><a href="#lock-3">lock/3</a></td><td>Equivalent to <a href="#lock-6"><tt>lock(Agent, Obj, Mode, [node()], all, wait)</tt></a>.</td></tr><tr><td valign="top"><a href="#lock-4">lock/4</a></td><td></td></tr><tr><td valign="top"><a href="#lock-5">lock/5</a></td><td></td></tr><tr><td valign="top"><a href="#lock_info-1">lock_info/1</a></td><td></td></tr><tr><td valign="top"><a href="#lock_nowait-2">lock_nowait/2</a></td><td></td></tr><tr><td valign="top"><a href="#lock_nowait-3">lock_nowait/3</a></td><td></td></tr><tr><td valign="top"><a href="#lock_nowait-4">lock_nowait/4</a></td><td></td></tr><tr><td valign="top"><a href="#lock_nowait-5">lock_nowait/5</a></td><td></td></tr><tr><td valign="top"><a href="#lock_objects-2">lock_objects/2</a></td><td></td></tr><tr><td valign="top"><a href="#start-1">start/1</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-1">start_link/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="await_all_locks-1"></a>

### await_all_locks/1 ###


<pre><code>
await_all_locks(Agent::<a href="#type-agent">agent()</a>) -&gt; <a href="#type-lock_result">lock_result()</a>
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
begin_transaction(Objects::<a href="#type-objs">objs()</a>, Opts::<a href="#type-options">options()</a>) -&gt; {<a href="#type-agent">agent()</a>, <a href="#type-lock_result">lock_result()</a>}
</code></pre>

<br></br>



<a name="end_transaction-1"></a>

### end_transaction/1 ###


<pre><code>
end_transaction(Agent::<a href="#type-agent">agent()</a>) -&gt; ok
</code></pre>

<br></br>



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



<a name="start-1"></a>

### start/1 ###

`start(Options0) -> any()`


<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`


<a name="start_link-1"></a>

### start_link/1 ###

`start_link(Options) -> any()`


