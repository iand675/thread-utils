# Changelog for thread-utils-context

## 0.4.2.0

- Fix a memory-safety bug: a probe that matched a key while its slot was
  being tombstoned could dereference the shared empty-slot sentinel
  as an `IORef a`, yielding garbage values or writing the given value into the
  sentinel reference shared by every map in the running process.
- The dead-slot placeholder is now allocated upon construction of the map as an
  error call of the map's element type, so unsafe access is well-typed (panics)
  instead of being a failed `unsafeCoerce#`; identity is tested `sameMutVar#`
  via `IORef`'s `Eq` instance now, instead of `reallyUnsafePtrEquality#`.
- Every write to the value array is now bracketed by a CAS of the key into
  a transient "claiming" state (bit 33) that's skipped by the probe, so a key
  can never be observed as corresponding to a different key's value.
  Tombstoning is a CAS from the observed key, then a CAS of the value, so the
  tombstone never ends up in a slot that has since been re-claimed.
- `rehashTable` no longer spins on a half-written slot; instead, it skips them
  and runs a second pass after publishing the new table to carry claims over.
- Add pure-C coverage for the purge scan.

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
