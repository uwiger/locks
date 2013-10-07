

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

<a name="types"></a>

## Data Types ##




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





### <a name="type-server_ref">server_ref()</a> ###



<pre><code>
server_ref() = atom() | pid()
</code></pre>


<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#call-2">call/2</a></td><td></td></tr><tr><td valign="top"><a href="#call-3">call/3</a></td><td></td></tr><tr><td valign="top"><a href="#candidates-1">candidates/1</a></td><td></td></tr><tr><td valign="top"><a href="#cast-2">cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#code_change-3">code_change/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#leader-1">leader/1</a></td><td></td></tr><tr><td valign="top"><a href="#leader_call-2">leader_call/2</a></td><td></td></tr><tr><td valign="top"><a href="#leader_cast-2">leader_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-2">start_link/2</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-3">start_link/3</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-4">start_link/4</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr><tr><td valign="top"><a href="#workers-1">workers/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="call-2"></a>

### call/2 ###

`call(L, Req) -> any()`


<a name="call-3"></a>

### call/3 ###

`call(L, Req, Timeout) -> any()`


<a name="candidates-1"></a>

### candidates/1 ###

`candidates(St) -> any()`


<a name="cast-2"></a>

### cast/2 ###

`cast(L, Msg) -> any()`


<a name="code_change-3"></a>

### code_change/3 ###

`code_change(X1, St, X3) -> any()`


<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Msg, From, St) -> any()`


<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Cast, St) -> any()`


<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Msg, St) -> any()`


<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`


<a name="leader-1"></a>

### leader/1 ###

`leader(St) -> any()`


<a name="leader_call-2"></a>

### leader_call/2 ###


<pre><code>
leader_call(Name::<a href="#type-server_ref">server_ref()</a>, Request::term()) -&gt; term()
</code></pre>

<br></br>



<a name="leader_cast-2"></a>

### leader_cast/2 ###

`leader_cast(L, Msg) -> any()`


<a name="start_link-2"></a>

### start_link/2 ###

`start_link(Module, St) -> any()`


<a name="start_link-3"></a>

### start_link/3 ###

`start_link(Module, St, Options) -> any()`


<a name="start_link-4"></a>

### start_link/4 ###

`start_link(Reg, Module, St, Options) -> any()`


<a name="terminate-2"></a>

### terminate/2 ###

`terminate(X1, X2) -> any()`


<a name="workers-1"></a>

### workers/1 ###

`workers(St) -> any()`


