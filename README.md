locks
=====

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
are used. Resolution happens with a (I believe) minimal number of messages,
making the algorithm unusually scalable.
