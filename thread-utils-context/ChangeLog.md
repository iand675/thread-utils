# Changelog for thread-utils-context

## 0.4.2.0

- Fix a memory-safety bug: a probe that matched a key while its slot was
  being tombstoned could dereference the shared empty-slot sentinel
  as an `IORef a`, yielding garbage values or writing the given value into the
  sentinel reference shared by every map in the running process.
- Values no longer depend on finalizers. Each slot holds a weak pointer
  keyed on the owning thread whose value is the entry's `MutVar#`, so the
  GC that finds a thread gone releases its value directly. The per-thread
  `Weak#` finalizer closure, its run on every thread death, and the
  dependency on `thread-utils-finalizers` are gone, as is the map being
  kept alive by every finalizer that referred to it; a map's finalizer
  now releases the values it holds for threads that outlive it. A map's
  overhead per parked thread drops from about 146 to about 90 bytes.
- Every change to a slot's value cell or attached state is bracketed by a
  CAS of the key into a transient "claiming" state and a store of the
  published key. A slot is only claimed from a state with no attached
  value, so a probe that meets a claim reads it as a miss and never waits;
  a second writer waits (with a yield) rather than claiming over it.
  `detach` and tombstoning are CASes from the observed key (a tombstone is
  then followed by a CAS of the cell), so neither lands on a slot that has
  since changed. Previously `detach` and re-attach were unconditional
  stores, which could overwrite a concurrent writer's key.
- A tombstoned slot is no longer reused by another thread in place. Inserts
  stop at three quarters of the slots, tombstones included, and the table is
  then rehashed. It doubles when at least half the slots hold running
  threads; otherwise (thread churn) it doubles up to 1024 slots and then
  keeps its size. Since a slot's thread ID never changes within a table,
  probes read the key once (with acquire semantics) and then the cell, with
  no retry loop.
- Rehash freezes every slot of the old table before copying it (a fourth
  flag bit that no writer will CAS from), and writers that meet a frozen
  slot wait for the new table, all woken at once. This replaces the copy's
  second pass and the propagation of detach and re-attach to a newer
  table, which could lose a write made during a rehash or bring back an
  entry removed after one. Rehashes copy only entries whose thread is
  still running, so a finished thread's entry goes at the next rehash even
  if its `ThreadId` is still referenced, as it already did under
  `purgeDeadThreads`.
- Store thread IDs in full. GHC's thread IDs are 64-bit, but keys kept only
  their low 32 bits, so after 2^32 forks a thread stopped finding its own
  entry and could be mistaken for a detached entry of the older thread
  sharing its low bits (often the main thread). Keys are now 64 bits on
  every target, with the four flag bits at the top and the ID in the low
  60. 32-bit targets use portable Haskell probes in place of the CMM ones.
  The public API still passes IDs as `Int`/`Word`, so on 32-bit targets
  `getThreadId`, `getCurrentThreadId`, the raw and ref APIs, and
  `storedItems` see only the low 32 bits; the current-thread and
  `ThreadId`-taking functions use the full ID.
- An entry keeps one `IORef` for its thread's whole life in the map:
  `detach` leaves it in place and a later `attach` or `ensureRefFast`
  writes into it, where it used to allocate a new one. Re-attaching
  allocates nothing.
- `purgeDeadThreads` checks each entry against its own thread, read
  through the entry's cell, instead of a `listThreads` snapshot. It no
  longer evicts live threads under the non-moving collector (whose heap
  `listThreads` misses), and the C SIMD membership scan it needed is
  removed. An entry written through `updateRaw` under a key that is not
  the given thread's ID belongs to no thread and is purged.
- `lookupRef` and `ensureRef` use the CMM probe.
- Require GHC 9.6 (`base >= 4.18`), which the CMM's ordered loads already
  did.
- Add regression tests for lost writes during rehash, IDs past 2^32,
  values released at GC for finished threads and dropped maps, the stable
  per-entry `IORef`, and purge contention.
- Mask asynchronous exceptions across a slot claim and across a rehash. A
  thread killed (`killThread`, `timeout`) between claiming a slot and
  publishing it left the slot claiming forever, and the next rehash spun
  on it under the lock with every writer blocked behind it. A thread
  killed during a rehash left the table frozen with no new table to come,
  and every later writer looped on it without a safepoint, which stalled
  every GC in the process. A writer that finds a frozen table with no
  rehash in progress now finishes the rehash itself.
- Rehash kills the cells of the entries it drops, as `purgeDeadThreads`
  does. A finished thread's cell is otherwise kept by the RTS for as long
  as a `ThreadId` for the thread is held, with its value and no slot left
  through which to release it.
- `lookupRaw`, `updateRaw`, `ensureRef` and `lookupRef` reject a thread ID
  of 0 or one with bits above the 60 a key holds, which name no thread.
  Inserting under 0 published a live cell in a slot every probe and the
  rehash treated as empty.

## 0.4.1.1

- Fix `purgeDeadThreads` retaining finished threads and evicting live ones.
- Stop `purgeDeadThreads` from retaining stale TSO pointers after collection.

## 0.4.1.0

- Fix space leak: repeated `attach`/`detach` on long-lived threads no longer
  accumulates `Weak#` objects. Detach marks the slot key with a flag bit
  instead of tombstoning, so re-attach reuses the slot without registering
  a duplicate GC finalizer.
- Fibonacci multiplicative hash for slot assignment spreads sequential
  thread IDs across cache lines, reducing false sharing under multi-core
  contention.
- Detach no longer writes to the GC-traced value array, eliminating
  card-table contention on the detach path.
- Hot-path `lookup`/`adjust`/`lookupRefFast` no longer check for detached
  markers in the value array; the CMM probe reports detach status directly.

## 0.4.0.0

- Replace striped-IntMap internals with a flat open-addressed hash table
  backed by per-thread IORefs. Reads and writes on the hot path are now
  plain IORef operations, with zero CAS and zero contention.
- Add CMM primops (`stg_getCurrentThreadId`, `stg_probeThreadSlot`,
  `stg_probeSlotByKey`) to eliminate ThreadId allocation and FFI overhead
  on the hot path.
- New construction function: `newThreadStorageMapWith` for explicit capacity.
- New `getCurrentThreadId` reads `CurrentTSO.id` directly via CMM.
- New ref-based API for instrumentation hot loops: `ensureRef`,
  `ensureRefFast`, `lookupRef`, `lookupRefFast`, `readRef`, `writeRef`,
  `modifyRef`.
- Remove `containers` dependency.
- Requires `cabal-version: 3.0` (for `cmm-sources`).
- Backwards compatible: all previously exported symbols retain their
  original type signatures.

## 0.3.0.4

- Fix compilation on GHC 8.12

## 0.3.0.3

- Fix compilation of purgeDeadThreads on GHC 9.6

## Unreleased changes
