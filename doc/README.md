

# The locks application #

__Authors:__ Ulf Wiger ([`ulf@wiger.net`](mailto:ulf@wiger.net)), Thomas Arts ([`thomas@quviq.com`](mailto:thomas@quviq.com)).

Scalable deadlock-resolving locking system


## locks ##

A scalable, deadlock-resolving resource locker

This application is based on an algorithm designed by Ulf Wiger 1993,
and later model-checked (and refined) by Thomas Arts.

Compared to the implementation verified by Thomas Arts, 'locks' has
included a hierarchical lock structure and has both read and write locks.
It is also distributed (although this is not yet being tested).

The algorithm is based on computing potential indirect dependencies and
informing dependent transactions in a 'fill-in-the-blanks' manner.

Eventually, one transaction will have enough information to detect a
deadlock, even though no central dependency graph or dependency probes
are used. Resolution happens with a (at least close to) minimal number of
messages, making the algorithm unusually scalable. Since it uses deadlock
detection instead of deadlock prevention, there are no fantom deadlocks.

Deadlocks can be resolved by one agent surrendering a lock to another agent.
Note that this is a bad idea if the surrendering agent's client has already
acted on the lock. Optionally, the agent can abort whenever it would otherwise
have had to surrender a lock. This might be preferrable in some cases, and
will still only happen if there is an actual deadlock. It is usually possible
to design a system so that deadlocks will not occur during normal operation.


## Using 'locks' ##

Call `application:start(locks)` on each node that needs to participate in
locking.


## Structure of locks ##

The lock identifiers used by 'locks' are non-empty lists of key elements.

The lock table is viewed as a tree, and e.g. `[a]` implicitly locks `[a,1]`,
`[a,2]`, etc. Locks can be `read` (shared) or `write` (exclusive). Shared locks
are automatically upgraded to exclusive locks if requested (and if possible).

Using 'locks' in a database system, one might use a lock naming scheme like
`[DbInstance, Table, Lock]`, where `[DbInstance]` would be equivalent to a
schema lock, `[DbInstance, Table]` a table lock, etc.

There is only one lock table per Erlang node, so use prefixed keys, or a
unique top-level key.


## Agents ##

While it is possible to use the `locks_server` API directly to lock single
objects, distributed locking and deadlock detection is done by `locks_agent`.

The official API to use is `locks`.

Agents are started e.g. using `locks_agent:begin_transaction(...)`, and are
separate state machines (processes). The `locks_server` informs agents via
`#locks_info{}` messages (containing not only the ID of the agent that holds
a lock, but also of any agents waiting for one), and each agent keeps track
of a dependency graph. Agents inform each other ('younger' agents inform
'older' agents) of indirect dependencies, using an algorithm that guarantees
that one involved agent will eventually have enough data to detect any deadlock.

If a deadlock is detected, the 'oldest' agent must yield its lock. This is
either done as a 'surrender', where the agent yields the lock and is placed
last in the lock's wait queue, or by aborting. Which behavior is used is
controlled by the option `{abort_on_deadlock, bool()}`, given at the beginning
of the transaction.


## Distributed locking ##

Using the function `locks:lock(Agent, LockID, Mode, Nodes, Req)`, a lock
can be acquired on several nodes at once.

```erlang

Agent  :: pid().
LockID :: [any()].
Mode   :: read | write.
Nodes  :: [node()].
Req    :: all | any | majority.

```
The agent monitors the lock servers on each node. If it determines that too
few lock servers are available to fulfill the lock requirement, it will abort.

## Modules ##


<table width="100%" border="0" summary="list of modules">
<tr><td><a href="locks.md" class="module">locks</a></td></tr>
<tr><td><a href="locks_agent.md" class="module">locks_agent</a></td></tr>
<tr><td><a href="locks_server.md" class="module">locks_server</a></td></tr></table>

