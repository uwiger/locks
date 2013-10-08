

# The locks application #

__Authors:__ Ulf Wiger ([`ulf@wiger.net`](mailto:ulf@wiger.net)), Thomas Arts ([`thomas@quviq.com`](mailto:thomas@quviq.com)).

Scalable deadlock-resolving locking system


## locks ##

A scalable, deadlock-resolving resource locker

This application is based on an algorithm designed by Ulf Wiger 1993,
and later model-checked (and refined) by Thomas Arts.

Compared to the implementation verified by Thomas Arts, 'locks' has
included a hierarchical lock structure and has both read and write locks.
It is also distributed, supporting multi-node locks and quorum ('majority').

The algorithm is based on computing potential indirect dependencies and
informing dependent transactions in a 'fill-in-the-blanks' manner.

Eventually, one transaction will have enough information to detect a
deadlock, even though no central dependency graph or dependency probes
are used. Resolution happens with a (at least close to) minimal number of
messages, making the algorithm unusually scalable. Since it uses deadlock
detection instead of deadlock prevention, there are no phantom deadlocks.

Note: Unlock has not (yet) been implemented. Once the transaction ends, all
locks held by it are released automatically.


## Resolving deadlocks ##

Deadlocks can be resolved by one agent surrendering a lock to another agent.
The surrendering agent will be put last in the lock queue.

Note that this is a bad idea if the surrendering agent's client has already
acted on the lock. Optionally, the agent can abort whenever it would otherwise
have had to surrender a lock. This might be preferrable in some cases, and
will still only happen if there is an actual deadlock. It is usually possible
to design a system so that deadlocks will not occur during normal operation.

The agent that is told to surrender will do so unless the client has asked
for the transaction to be aborted AND the lock being surrendered has been
reported as held to the client. That is, the `abort_on_deadlock` option
when starting an agent may still allow some surrenders to take place - only
not on locks that the client already thinks it has. See the `locks_leader`
for an example of an application where `abort_on_deadlock=false` is the
desired mode of operation.


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


## Verification ##

The following text describes the implementation verified by Thomas Arts
during 1999-2000. It contains several explanations of the algorithm,
identifying a number of alternative design choices as unsafe. There are also
some hints regarding optimization potential.

A few comparisons with the current implementation:

* When Arts talks about 'the object' and 'the client', these correspond to
the object_server (which handles all locks on the node) and the agent
respectively.

* The implementation also served read and write requests on the object.
This has been removed, and it is up to the client to ensure that it does
not operate on a resource requiring a lock, without first acquiring the lock.

* Canceling a lock request is not yet implemented.

* Lock update messages do not contain the requesting agent. Instead, a
separate message from the locks_server acknowledges a surrender request,
and the agent will ignore any lock updates for that lock, which precede
the 'surrendered' message.

* The verification did not deal with 'hierarchical' locks (e.g. table and
object locks). The current implementation treats all locks as part of a
hierarchy, and introduces the notion of an 'indirect' lock. Indirect locks
are only of concern to the locks_server; the agents only need to know that
they are waiting for another agent that holds the lock - whether the lock
is held directly or indirectly is of no concern. To wit, if an agent A takes
a lock on [a, b], and it is granted, it will indirectly lock [a]. If another
agent B tries to lock [a, b, c] while A holds [a, b], the locks_server will
infer that A also indirectly locks [a, b, c]. This indirect lock is created
as-needed (if no one tries to lock [a, b, c], no indirect lock needs to be
created - indeed must not, as the domain of potential children is unbounded.

* Multi-node locks are not considered below. The current implementation treats
each lock on each node as an individual lock. For example, locking [a] on
nodes [N1, N2] will result in two lock requests, {[a], N1} and {[a], N2}.
The agent keeps track of which locks belonged to the same request, viz.
we may consider the lock granted only when we have a lock on [a] on all,
or a majority, of the requested nodes. If some of the requested nodes are
not available, the lock may still be considered held if a majority of them
can be claimed. The exact semantics are specified when requesting the lock.
Note also that this introduces the risk of deadlock within a single lock:
If agent A and B both try to claim [a] on [N1, N2], and A gets the lock on N1,
while B gets the lock on N2, this will be a deadlock. However, if the lock
is still considered pending by the agent which needs to surrender, the client
will not notice this, and the conflict will be resolved automatically.

* Even with the above differences, the dependency analysis and deadlock-
related decision-making is the same as in Arts's version - only modified
to accomodate the slightly different data representation.


### Description of the algorithm and some implementation issues. ###

Basically the algorithm consists of two entities, viz. one for the
object and one for the client. These entities are best seen as interfaces
that arrange for the client to get access to an object, and ensure
that the object is only accessed by clients which are allowed to do
so.

The algorithm implementing the object interface should provide read
and write functionality, but also guarantee that such read or write is
guaranteed to be done by a client that has the right to do so
(i.e. holds the lock).

The algorithm implementing the client interface keeps track of the
objects that need to be locked for a read and/or write operation.
The client interface is actively asking the objects for read/write
permission (a lock) and waits for the results supplied by the objects.
The information is gathered, combined with consecutive information
provided by the objects and competing clients and action is taken upon
the received information. The client interface can either conclude that
it has obtained read/write access to all required objects, or, by absence
of all information, wait for more information and/or send information to
competing clients.

In the following we describe the algorithms for both entities in more
detail and motivate the different design decisions. The design seems
optimal within the setting we have in mind, however, other settings
are plausible candidates for practical applications as well.
Therefore, we first describe the setting we work in and sketch alternative
design possibilities for situations that we think are of additional
practical interest.


### The Setting ###

We assume computers to run in a distributed environment, connected with a
communication network of which the speed is slow compared to the computation
speed of the individual computers in the net.

Clients and objects have a unique reference and a total order exists among
these references. The uniqueness of the reference is guaranteed. However,
the set of possible references is finite.

No strong assumption is therefore made about the relationship between
creating a client or object and the assigned reference. As a heuristic we
assume a client that is created later in time has a larger reference than
the earlier created clients (w.r.t. the order on references). This heuristic
is, though, violated now and then and therefore we do not consider it a rule.

We assume enough memory available to store all information about the
relationship between locks and objects of interest to us. Moreover, we assume
the existence of a sequence of numbers as long as we need to attach version
numbers to messages, such that within the lifetime of an object, we do not
run out of numbers.


### The Object Algorithm ###

The algorithm implementing the interface to the object stores requests from
clients for access to certain locks. The requests are stored in a waiting
queue in order of arrival. The first element of the queue is considered to
have granted access to the object. Upon arrival of a request from a client,
it is put at the end of the queue and all clients in the queue are notified
about the new situation of the queue.

Clients are also allowed to cancel their request, in which case they are just
removed from the queue. Again, all clients remaining in the queue are
notified. A cancel request always arrives when a client processes is
somehow killed or unreachable.

The client that holds the lock on the object, i.e., is the first in the
waiting queue may request to surrender, i.e., it is no longer the first in
the queue. Upon a surrender request, the requesting client is placed last
in the queue and all clients are again notified about the new order in
the queue.

Placing a surrendering client at the end of the queue is the only safe
general way of implementing a surrender action. It is not safe to just swap
with the client directly behind it. Moreover, the object cannot oversee what
other place would be safe to surrender to. In some cases the client, however,
could obtain so much information that it would be able to compute  a safe
place in the queue to surrender to.

Nevertheless, having the client ask to surrender to a certain place is
in general unsafe.

Every notification to the clients of the updated state of the queue is
supplied with a version number. The version number is increased after
every change in the queue. Moreover, the notifications are also carrying
the identity of the client that induced the notification to be sent, i.e.
the client that requested access, canceled or surrendered. Both are necessary
items for the client in order to have a safe execution.

The algorithm also implements a read and write operation on the object,
where the read and write are only allowed whenever the requesting client
holds the lock for the object (i.e., is first in the queue).

In case the references assigned to clients reflect their creation, viz.
the reference gets bigger the later a client is created (e.g. absolute
time as reference), the above object can be optimized by having the tail
of the waiting queue (i.e. all elements except for the first one) sorted
with respect to the total order on the references. However, this is unsafe
in case of a finite set of references. One can work around this unsafe
situation in case the set of references is big enough and timeout primitives
are used to deal with starvation.

This alternative implementation method is not optimally efficient in general,
but may be more efficient in cases were negotiation about objects is
relatively fast compared with the time it takes to run out of references.
Clients that do not get served in time, should however restart their
requests, which may take severe overhead for some individual clients,
whereas the other clients are served much faster.


### The Client Algorithm ###

The interface for the client gets activated whenever a client needs some
objects to perform an operation on. Access to the objects is requested
by the client interface and after all objects have been locked, the client
is notified that the operation may take place. After performing the operation,
the client interface is addressed by the client and the interface releases
the locks on all the objects it has acquired for the client.

The communication between client interface and object interface is
already described in the object part. A lock can be requested, surrendered
or a request can be canceled.

The client interface is constantly updated when the queue of an object that
it has requested changes. This information is stored by the client interface,
and as such, the client interface detects easily when all objects are
assigned to it.

The queue information that the object provides has a version number and the
identity of a client attached to it. The client keeps track of this version
information and whenever information is received with a version number
smaller than a version number of earlier received information, this
information is ignored. It is unsafe to disregard the version information,
since because of delays in the network, information could arrive in the
wrong order and the client could cause a deadlock by acting wrongly on the
old information.

The attached client information in the deadlock is used by the client as an
acknowledgment on a surrender request. Whenever the client sends a surrender
request, it should ignore all information coming from the surrendered object,
until it carries its own client identity. The latter is necessary to ensure
a safe operation in case the client surrenders and outdated information
arrives stating that the client just received access again.

Whenever the information about the queues of the objects is such that not
(yet) all the objects are assigned, the client interface computes the
so-called wait-for graph; the graph expressing which client waits for which
other client to get access to an object.

If this graph contains a cycle, then a deadlock situation exists.
The client interface checks for cycles in the graph and if such a cycle exists,
it computes which of the clients in this cycle that holds the lock for an
object has the largest reference (since there exists a total order of the
references, this is uniquely defined). If the client interface does not
represent this largest reference itself, it waits for more object
information to come.

If, however, the client interface represents this largest reference, it
sends a surrender message to the object it holds that caused the deadlock
situation. Note that it is important to select this particular client among
the ones that indeed hold a lock.

In order to be able to surrender only one object, one needs to store
the relation between the object and the clients waiting for that particular
object. It should be clear which object is waited for in the deadlock
situation, since the client that surrenders may very well hold other
objects, which are not involved in a deadlock situation.

In case of only little memory available, one might choose for not storing
all information but surrender all objects the client holds. This is a safe
strategy, but inefficient.

Instead of having the client with largest reference surrendering, one could
also demand the smallest client to surrender. In our setting, the largest is
more optimal, since the reference contains information about the time the
client asked for the object. The smaller the reference, the longer the client
is waiting for the object.

In special circumstances a client interface could compute that surrendering
to the end of the queue is not the most efficient. However, such a
computation needs extra information from the application that the algorithm
is used for. For example, if it is known that every client is at most
claiming three objects at a time, this information could very well be used
to compute more optimal surrendering positions.

When a client interface does not encounter a cycle in the graph, it
reports the graph information to other clients. Note that all clients
only have part of the information of the "global" wait-for graph. By
spreading the information to other clients, one ensures in the end that
at least one client obtains the "global" wait-for graph as its local graph.
Here one has several possibilities in spreading the information around.

The efficiency and optimality of the strategy of which client is sending
this information to which other client(s) depends on the way the objects
and clients relate (how many clients are demanding the same object, how
many objects are demanded by the clients, etc.).

The most naive way of spreading the information is that a client sends its
wait-for graph to all clients that occur in this graph. Optimally a client
only sends part of the graph to another client, if that client does not have
that information and is not getting it from another client.

The latter can partly be achieved by clients only sending information to
clients that have a smaller reference, or alternatively, only to those that
have a bigger reference.

Another strategy which reduces the number of messages sent, and therefore
is efficient when computation is much cheaper than sending (as in our setting)
is that clients only send to clients that it is waiting for and only send
the information of the clients that wait for it.

Analogous to this, the client could send the clients that wait for it,
the information of the clients it is waiting for.

Any of the above spreading strategies can even be improved by computing
which information the client one wants to send something to should already
have, such that no superfluous information is sent if avoidable.

The wait-for graph is easily implemented by using standard data structures
and computing cycles in such a graph is a well known operation for which
several algorithms exist in literature.

Specific for the client interface algorithm is that nodes in the graph
contain both client identity, the object that the client is locking,and
whether the client has obtained the lock to this object. An arc is drawn
from one node to another if the client in this triple is waiting for the
client in the other node. Note here that not all clients need be presented
in the graph, but only those that hold a lock. However, the relation that
expresses a client waiting for another client takes all known clients into
account.

Whenever a cycle is detected, from the nodes on this cycle the client
with largest reference surrenders the object it locks.


## Modules ##


<table width="100%" border="0" summary="list of modules">
<tr><td><a href="locks.md" class="module">locks</a></td></tr>
<tr><td><a href="locks_agent.md" class="module">locks_agent</a></td></tr>
<tr><td><a href="locks_leader.md" class="module">locks_leader</a></td></tr>
<tr><td><a href="locks_server.md" class="module">locks_server</a></td></tr></table>

