

# Module locks_server #
* [Function Index](#index)
* [Function Details](#functions)


<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#code_change-3">code_change/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#lock-2">lock/2</a></td><td></td></tr><tr><td valign="top"><a href="#lock-3">lock/3</a></td><td></td></tr><tr><td valign="top"><a href="#lock-4">lock/4</a></td><td></td></tr><tr><td valign="top"><a href="#remove_agent-1">remove_agent/1</a></td><td></td></tr><tr><td valign="top"><a href="#remove_agent-2">remove_agent/2</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-0">start_link/0</a></td><td></td></tr><tr><td valign="top"><a href="#surrender-2">surrender/2</a></td><td></td></tr><tr><td valign="top"><a href="#surrender-3">surrender/3</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="code_change-3"></a>

### code_change/3 ###

`code_change(FromVsn, S, Extra) -> any()`


<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Req, From, S) -> any()`


<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(X1, St) -> any()`


<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Msg, St) -> any()`


<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`


<a name="lock-2"></a>

### lock/2 ###

`lock(LockID, Mode) -> any()`


<a name="lock-3"></a>

### lock/3 ###

`lock(LockID, Nodes, Mode) -> any()`


<a name="lock-4"></a>

### lock/4 ###

`lock(LockID, Nodes, TID, Mode) -> any()`


<a name="remove_agent-1"></a>

### remove_agent/1 ###

`remove_agent(Nodes) -> any()`


<a name="remove_agent-2"></a>

### remove_agent/2 ###

`remove_agent(Nodes, Agent) -> any()`


<a name="start_link-0"></a>

### start_link/0 ###

`start_link() -> any()`


<a name="surrender-2"></a>

### surrender/2 ###

`surrender(LockID, Node) -> any()`


<a name="surrender-3"></a>

### surrender/3 ###

`surrender(LockID, Node, TID) -> any()`


<a name="terminate-2"></a>

### terminate/2 ###

`terminate(X1, X2) -> any()`


