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

### Strategic choice: rewrite role plane on `gen_statem`

The original `locks_leader` predates `gen_statem`. The dual structure
(`safe_loop` + gen_server `handle_*`, re-entering `safe_loop` when
`leader == undefined`) is a hand-rolled state machine wearing a gen_server hat.

**`gen_statem` is the right OTP behaviour for this problem.** Further investment in
perfecting the dual-loop design has diminishing returns; the next serious step
should be a rewrite of the *role plane* as gen_statem, keeping the external API
and callback module contract.

What gen_statem buys us here (that gen_server + safe_loop cannot cleanly):

| Need | gen_server + safe_loop today | gen_statem |
|------|------------------------------|------------|
| Distinct phases | Encoded in `#st.leader` + which loop is running | Named states |
| One event path | Duplicated / forked handlers | Single callback per state |
| Call before leader exists | Easy to drop or mis-buffer (`send` to `undefined`) | `{keep_state, Data, [{reply,…}]}` / deferred replies |
| **Event in the wrong state** | Handle now with ad-hoc “ignore / buffer / maybe re-queue”, or race | **`postpone`** — redeliver after the next state change |
| “Force activity” timers | Ad-hoc | `state_timeout` / `event_timeout` |
| Tracing / reasoning | Opaque | State name is the log |

#### Postponing events (first-class in gen_statem)

Because election is fast and the mesh is asynchronous, **useful events often arrive in the “wrong” phase**: contest reports `have_all_locks` while we are still applying a society join; `sync_lock_ok` after we already dropped back to candidate; `am_leader` while still `syncing`; a second `have_all` while merge is in flight; client `leader_call` before any leader is known.

Today that becomes hand-rolled logic (`pending_leader` in `buffered`, ignore-in-safe_loop, process-dict workers, etc.). With gen_statem:

- Return **`postpone`** (or `{keep_state, Data, [postpone]}`) for events that are valid *later* but not *now*.
- On transition (e.g. `candidate → syncing → leader`), postponed events are **automatically redelivered** in order against the new state.
- That is a better default than “drop”, “handle incorrectly”, or “park in an ad-hoc list and remember to flush in every enter path.”

Examples of good postpone candidates:

| Event | Wrong state | Why postpone |
|-------|-------------|--------------|
| `{locks_agent,_,{have_all_locks,_}}` | still applying society/node expand | Re-check contest after membership is stable |
| `sync_lock_ok` / `sync_lock_failed` | no longer `syncing` (stale worker) | Or discard if generation mismatch — postpone only if still relevant |
| `am_leader` / `from_leader` | mid-`syncing` | Decide surrender vs conflict after merge attempt settles |
| `leader_call` | `candidate` / `syncing` | Defer reply until `leader` (or forward once following is known) |
| society `join` | `syncing` | Expand set after merge completes or after abort to candidate |

Not everything should be postponed: e.g. contest `waiting` while `leader` should **transition immediately** (completeness lost). The design rule is:

> **Postpone** when the event is still meaningful in a later state and handling it now would race membership/merge.  
> **Transition or drop** when the event invalidates the current state or is stale (wrong `election_ref` / worker pid).

This pairs naturally with **generation checks**: postpone only within the same epoch; drop events tagged with an obsolete generation.

### Near term (stabilize current tree; do not dig the dual-loop hole deeper)

1. Keep sync-lock + `all_alive` + async helper (merge plane).
2. Keep `locks_pg` society discovery (society plane).
3. Keep structured CT as the bar; leave `random_netsplits` quarantined.
4. Fix sharp edges only (e.g. park `leader_call` until a leader is known).
5. Document the gen_statem target (this section) before large new patches.

### Medium term (the real improvement)

1. **Implement `locks_leader` as `gen_statem`** (state functions or handle_event;
   state functions map cleanly to the diagram below).
2. **Inputs** (unchanged conceptually):
   - Society: `locks_pg` join/leave
   - Contest: `{locks_agent, Agent, Status}` / lock_info vector
   - Peers: `am_leader`, `from_leader`, `ensure_sync`, …
   - Merge worker: `sync_lock_ok` / `sync_lock_failed`
3. **Outputs**: callback module (`elected` / `surrendered` / …), client replies.
4. **Delete** `safe_loop`, dual `handle_info_`, and overlapping “who is leader”
   side protocols once state + generation cover them.
5. Optional later: seq-tagged `async_await_all_locks`; thinner agent split.

### Migration sketch

Keep module name and public API (`start_link`, `call`, `leader_call`, `info`,
election opaque type for callbacks). Internally:

```erlang
-behaviour(gen_statem).
%% callback_mode => state_functions  (or handle_event_function)

%% States (role plane):
%%   candidate  — contest incomplete or following unknown
%%   syncing    — contest won; merge mutex in flight
%%   leader     — merge done; handle_leader_call/cast
%%   following  — optional explicit “I accept remote L” (can stay folded into
%%                candidate if preferred for a smaller first cut)
```

Data record holds society, agent, vector, election_ref, mod/mod_state, buffered
calls, sync_worker — **not** a parallel “which loop am I in?” flag.

Suggested first cut (green on `g_local` + `g_2` before larger netsplit groups):

1. Scaffold gen_statem with `candidate` / `syncing` / `leader`.
2. Port contest + sync-lock transitions.
3. Port society join/leave.
4. Port client call/cast and callback surface.
5. Delete safe_loop path; run full structured suite.

### Invariants (any implementation)

1. No global live set during convergence; decisions are for a *local* live set and
   must be *revisited* when it changes.
2. Leadership is “leader of the currently lockable component,” not “of the universe,”
   until components share contest + merge mutex.
3. Never block the role process on multi-node lock waits.
4. Merge is multi-party: membership + mutex for that membership.
5. **Role is a state machine** — implement it as one (gen_statem), not as
   gen_server control flow with a second private receive loop.

---

## Target state machine

Four planes (keep them separate in code and in your head):

| Plane | Truth source | Responsibility |
|-------|--------------|----------------|
| **Society** | `pg` group `{locks_leader, Lock}` (candidates) | Who is in this election instance |
| **Contest** | Main write lock, `all_alive` | Who currently holds The Lock for the local alive set |
| **Role** | **gen_statem state** (+ generation / election_ref) | candidate / syncing / leader; announce/surrender |
| **Merge** | Sync lock on reachable society nodes | Serialize `elected` / state merge while in `syncing` |

### States (role plane → gen_statem)

```
          society join / lock waiting
                    │
                    v
              ┌───────────┐
   ┌─────────▶│ candidate │◀────────────┐
   │          └─────┬─────┘             │
   │                │ have_all_locks    │ lost lock / membership grew
   │                │ (contest won)     │ / sync merge aborted
   │                v                   │
   │          ┌───────────┐             │
   │          │  syncing  │─────────────┤  (async sync lock in flight)
   │          └─────┬─────┘             │
   │                │ sync_lock_ok      │
   │                v                   │
   │          ┌───────────┐             │
   └──────────│  leader   │─────────────┘
              └───────────┘
```

| State | gen_statem responsibilities |
|-------|------------------------------|
| `candidate` | Track society; drive contest; park or reject leader_calls; accept `am_leader` |
| `syncing` | Wait for merge mutex result; stay responsive to society/contest loss |
| `leader` | `handle_leader_call` / cast; leave on `waiting` or vector conflict |

Invariants:

1. Enter **syncing** only when contest says have_all for the current alive set
   *and* vector does not name another agent as sole lock holder.
2. Enter **leader** only after merge mutex (sync lock) acquired; hold mutex across
   `elected` / announce.
3. Any expansion of society that extends the lock set must drop completeness →
   contest goes waiting → leave **leader** if held.
4. No global live set: decisions are valid only for the local society ∩ alive
   lockers; revisit on society or contest change.

### Events that force activity

| Event | Action |
|-------|--------|
| `pg` join (new candidate) | Add to society; `include_node`; re-lock; if leader, expect waiting → candidate |
| `pg` leave / DOWN | Remove from society; clean synced lists |
| `have_all_locks` | candidate → syncing (if vector ok) |
| `waiting` while leader | leader → candidate; re-await contest |
| Sync lock fail / vector conflict | → candidate; async re-await contest |
| `am_leader` / `from_leader` | Follow generation rules; surrender or request sync |
| `leader_call` in candidate | **Postpone** or hold reply until `leader` / known remote leader |
| Stale or out-of-order peer msgs | **Postpone** if still same generation; **drop** if generation mismatch |

### Why not “just unify handle_info_ on gen_server”?

Unifying the dispatch list (already partly done) removes duplication but **does not**
remove the deeper problem: the process still has two control regimes (pre-loop vs
enter_loop, and re-entry to `safe_loop` when leader is cleared). gen_statem makes
“I am not leader” a first-class state instead of a side effect of `#st.leader` plus
which receive loop is on the stack.

---

## Current code state (this branch)

**Role plane is `gen_statem`** (state functions + `state_enter`):

| State | Meaning |
|-------|---------|
| `candidate` | No accepted leader yet; contest in progress |
| `following` | Accepted a remote leader (releases postponed `leader_call`s) |
| `syncing` | Contest won; merge mutex (sync lock) in flight |
| `leader` | Self is leader after merge |

Also in place:

- Async **sync lock** (`all_alive`, `abort_on_deadlock`) while in `syncing`.
- **Society**: `locks_pg` join/leave → candidate add/remove / node expand.
- **`postpone`** for `leader_call` / leader cast in `candidate` and `syncing`.
- Public API uses `gen_statem:call/cast`; callback module contract unchanged.
- `locks_ttb:default_patterns/0` includes `locks_pg` MFA.

Tests (structured suite): **all 13 green** (local, all_nodes, simple/multi netsplit,
incremental). `random_netsplits` remains quarantined as an ape/exploration group.

Notable gen_statem-era fixes that completed the machine:

- States: `candidate` | `following` | `syncing` | `leader` with `postpone` for
  early `leader_call`s.
- Vector `leader => none` no longer blocks entering `syncing` (only a *pid* other
  than our agent does).
- Enter `candidate` rechecks contest via delayed `state_timeout` (not illegal
  `next_state` from enter).
- nodedown of the leader’s node drops belief and re-elects; sync worker always
  reports ok/failed (and is monitored).
- Suite waits for consensus with retries that match `retry/2`’s catch shape.

**Next (optional):** seq-tagged agent await; reduce overlapping peer protocols;
bring back random netsplits only as non-gating stress.
