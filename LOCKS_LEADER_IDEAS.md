## Idea behind locks_leader

The `locks` application is primarily designed to support hierarchical distributed
read-write locking with active deadlock detection, with close to minimal amount of
messaging overhead. The algorithm is a cooperative fill-in-the-blanks variant, where
locking agents inform each other of lock information that they may need in order to
complete their dependency graph and detect deadlocks. The core algorithm supports
lock surrender, where one agent eventually gets all needed locks without forcing
transaction restarts.

Lock surrender only works if all the needed locks are known in advance. For typical
database transactions where locks are requested based on e.g. lookup results, an
option to abort on deadlock exists.

The idea behind `locks_leader` is that the algorithm could be used for leader election,
where all leader candidates try to grab a leader lock on all relevant nodes. This will
force a deadlock situation, but as the algorithm is capable of resolving deadlocks
through lock surrender, one agent will eventually have the lock on all nodes. The
method is comparatively chatty, but converges extremely quickly, without backoff.

### The merge deadlock

When running a randomized test suite with netsplits being forced frequently, the
implementation will occasionally deadlock. After much debugging, the culprit was
identified as the gen_leader-like path into `become_leader()`, which requests current
state data from the other candidates in order to merge leader states. While healing
from netsplits, given that the network heals asynchronously, there may be transient
instances where two nodes believe they are the leader in a network that is not yet
fully connected. When this happens, the competing leaders may deadlock while
requesting state from each other.

The current rewrite attempts to set a **sync lock** using the `abort_on_deadlock`
option before requesting leader state. If there are competing leaders in the same
connected component, this should lead to all but one aborting and reverting to a
`leader_uncertain` state, instead of deadlocking in application-level merge.

---

## Findings (2026-07, session notes)

### 1. Membership is not global during convergence

This is the central environmental constraint, easy to miss until you watch traces.

There is **no single global live set** while the mesh heals. Each node sees a different
cut of `nodes()` / reachable lockers. With `require = all_alive` on the main leader
lock, **"have all locks" is relative to that node's current alive set**, not to the
intended full cluster.

Consequences:

- Two (or more) candidates can *legitimately* hold The Lock for different partitions
  or partial meshes at the same wall-clock time.
- That is correct multi-leader-per-component behaviour under netsplit, and a *bug*
  only when those components briefly share edges and both still believe they are
  leader **of the same society**, then block in merge.
- Classic peer discovery via **lock queues** couples "who contends for the object"
  with "who is in my election group", so membership visibility lags and skews with
  lock completeness — especially painful because `locks_leader` reacts so quickly.

Speed of convergence is a **feature** (near-instant election, no backoff) if every
step is safe under non-global membership. It is a liability if we assume a global
`nodes()` picture.

### 2. Sync lock is the right *kind* of fix for merge races

Serialize `become_leader_` / state merge among candidates that currently share a
reachable set:

- Use **`all_alive`** (same shape as the main leader lock), not `require = all`
  (which fails as soon as any historical node is down and blocks partition leaders).
- Use **`abort_on_deadlock`** so competing writers abort rather than surrender into a
  half-merged state after the client was already told "have locks".
- **Do not block the leader gen_server** on the sync wait: acquisition runs in a
  helper process; the lock is held across `become_leader_`, then released.
- On abort (agent already dead), never call `end_transaction` blindly — that was
  crashing leaders with `noproc` and failing the structured netsplit tests.

Status after these fixes: structured netsplit / heal tests pass reliably.
`random_netsplits` (ape test) still fails under extreme churn; candidates can thrash
in `leader_uncertain` without reconverging in time. That does **not** mean the sync
lock is wrong; it means recovery after uncertainty under rapid membership change is
still unfinished.

### 3. Complexity has layered on

`locks_leader` now carries several overlapping narratives of leadership:

- main lock agent (truth for contest)
- `#st.leader`, `election_ref`, election `vector`
- `synced` / `synced_workers`
- `leader_uncertain` / `affirm_leader` / `ensure_sync`
- sync lock + process-dict worker

Plus **dual receive paths** (`safe_loop` vs gen_server `handle_*`) that duplicate
message handling. Much of this is scar tissue from debugging without a settled
state machine. The module is denser than the problem needs to be; a simplification
pass should follow a written model, not more tactical patches driven only by the
ape test.

### 4. Test harness lessons (OTP 25+ / peer)

While validating:

- OTP's **`prevent_overlapping_partitions`** (global) tears down intentional
  netsplits; peer nodes need it disabled for these tests.
- **`peer`** replaces deprecated `slave` / `ct_slave`; use `connection => standard_io`
  if the suite must drop/replace the dist link (hidden connect) without killing the
  peer control channel.
- `allow/1` for selective unbar under `dist_auto_connect once` was missing and broke
  rejoin topology.
- Ape tests are excellent for *discovery*, poor as the sole definition of done.

### 5. Related sketch: pg-based discovery (`~/uw/locks`, branch `uw-use-pg`)

An unfinished sketch joins each leader instance to a **`pg` process group**
`{locks_leader, Lock}` (and lock servers to `locks_servers`), instead of inferring
peers only from lock queues. Intuition:

| Plane | Responsibility |
|-------|----------------|
| **Society** | Who is in this election group → `pg` join/leave |
| **Contest** | Who holds The Lock → locks agent (`all_alive`, …) |
| **Role** | Leader belief / announce → derived from contest + merge |
| **Merge** | Serialize state merge → sync lock (or equivalent) |

Benefits: membership becomes an explicit signal for "force activity" (new candidate
joined → re-evaluate), independent of whether their agent has already appeared in a
local lock queue snapshot. Does **not** invent global membership during partition;
does **not** replace the need for a merge mutex when dual leaders meet.

Also on that branch: seq-tagged `async_await_all_locks` (ignore stale agent status),
and an incomplete split of lock ownership into `locks_leader_agent`.

---

## How to proceed

### Near term (keep the gains)

1. **Keep the sync-lock path** as the merge serialiser; keep async helper + safe
   cleanup + `all_alive`.
2. **Keep structured netsplit / heal / incremental tests** as the bar for green.
3. **Demote or quarantine `random_netsplits`**: useful exploratorily / nightly, not
   as the definition of bulletproof. Realistic netsplits are slow relative to message
   processing; pure random churn is a different regime.
4. **WIP-commit** current improvements so the tree is not lost (see git history).

### Medium term (make it robust and simpler)

1. **Write a short state-machine note** (phases, events, invariants) before more
   code:
   - Phases e.g. `candidate → electing/syncing → leader`, with explicit return to
     candidate on lost lock / membership expansion.
   - Membership events: who may join the society; when to extend the lock node set;
     when to invalidate "I was complete."
   - Force activity = recompute from current society + lock status, not broadcast
     storms of `leader_uncertain` alone.

2. **Separate the planes** (whether via `pg` or a cleaner lock-queue discovery):
   - Society membership first-class
   - Contest = locks only
   - Role = derived
   - Merge = mutex

3. **One receive path** — gen_server from the start, or a thin wrapper over a single
   set of handlers (kill `safe_loop` / `handle_info_` duplication).

4. **Port useful bits from `uw-use-pg`**: `locks_pg`, join-driven candidate add,
   seq-tagged await; leave unfinished agent extraction until the model is clear.

5. **Simplify** by deleting overlapping leader-belief mechanisms once the model has
   a single generation / epoch and clear enter-leave rules.

### Invariants worth putting at the top of any rewrite

1. There is no global live set during convergence; every decision must be valid for
   a *local* live set and must be *revisited* when that set changes.
2. Leadership is "leader of the currently lockable component," not "leader of the
   universe," until components merge under a shared contest + merge mutex.
3. Never block the leader process on multi-node lock waits (clients must stay
   responsive during election).
4. Merge is a multi-party protocol: it needs membership and a mutex *for that
   membership*.

---

## Current code state (this branch)

In `src/locks_leader.erl`:

- `become_leader/1` may take an async **sync lock**
  (`[locks_leader, sync, Resource]`, write, `all_alive`, `abort_on_deadlock`)
  before `become_leader_/1`.
- Helper process holds the lock across merge; gen_server stays responsive.
- Failure → `set_leader_uncertain/1` (also cancels pending sync worker).

Tests: peer migration, `prevent_overlapping_partitions false`, mesh setup for
netsplit cases, selective `allow/1`, longer proxy timeout, more patient
`same_leaders` checks. Structured suite green; `random_netsplits` still fails under
stress.
