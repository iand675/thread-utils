{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE UnliftedFFITypes #-}

-- |
-- Thread-local storage for Haskell green threads.
--
-- Associates at most one value of type @a@ with each green thread in a
-- 'ThreadStorageMap'. Values are automatically cleaned up by a GC finalizer
-- when the owning thread dies.
--
-- == Implementation
--
-- Internally, a 'ThreadStorageMap' is a flat open-addressed hash table that
-- resizes automatically when full. Keys (thread IDs) live in a
-- 'MutableByteArray#' with per-slot atomic CAS; values live in a GC-traced
-- 'MutableArray#' of 'IORef's. On resize, a new table is allocated at
-- double the capacity, live entries are copied (cleaning tombstones), and
-- the reference is swapped under an 'MVar' lock that serializes resize
-- operations; at most one thread performs the expensive copy-and-swap at a
-- time while other inserters wait. In-flight readers on the old table are
-- safe because the old arrays remain valid GC objects and the per-thread
-- 'IORef's are shared between old and new tables.
--
-- Reads and writes on the hot path go directly to the per-thread 'IORef',
-- with zero CAS and zero contention. CAS is only used during thread /registration/
-- (once per thread lifetime) and during finalizer-driven cleanup.
--
-- Two CMM primops avoid allocation and FFI overhead on the hot path:
--
--   * @stg_getCurrentThreadId@: reads @StgTSO_id(CurrentTSO)@ directly.
--   * @stg_probeThreadSlot@: fuses thread-ID retrieval with a multiplicative-hash
--     linear probe of the key array and a consistent read of the value slot.
--
-- == Slot hashing
--
-- Slot assignment uses a Fibonacci\/golden-ratio multiplicative hash
-- (@tid * 0x9E3779B97F4A7C15@) rather than a simple bit-mask. This spreads
-- sequential thread IDs (GHC allocates them contiguously) across different
-- cache lines, eliminating false sharing on both the key and value arrays
-- under multi-core contention.
--
-- == Key encoding and slot ownership
--
-- Thread IDs are 32-bit (@StgWord32@) but stored in 64-bit key slots. Two
-- flag bits above the ID encode slot state:
--
-- * Bit 32, /detached/: set by 'detach'. The value slot is left untouched
--   so no 'MutableArray#' card is dirtied; the CMM probe reports the state
--   via its return value, so 'lookup' and 'adjust' never consult the value
--   array for detached slots.
--
-- * Bit 33, /claiming/: set while a thread is in the middle of writing a
--   slot. A key and its value are two separate words, so every write to the
--   value array is bracketed by a CAS of the key into the claiming state
--   and a release-store of the final key. Probes skip claiming keys.
--
-- * Bits 34..62, /version/: a per-slot publication counter, incremented on
--   every publish and preserved across detach, claiming and tombstoning.
--
-- Every (key, value) pair the library reads is snapshotted with a per-slot
-- seqlock in CMM (key, value, key again -- all ordered by acquire loads),
-- so a reader never pairs a key with a value that was not published for it.
-- Because the version is part of the compared word, this holds even if the
-- slot is recycled back to the same thread ID between the two key reads.
--
-- Tombstoning (by a thread's GC finalizer, or by 'purgeDeadThreads') is a
-- CAS of the key from the value that was observed to the tombstone, and
-- only then a CAS of the value slot to this map's dead-slot placeholder.
-- A tombstone therefore never lands on a slot that has since been
-- re-claimed, and a live key is never paired with the placeholder.
--
-- == Choosing an API tier
--
-- This module exposes three tiers of API, from simplest to fastest:
--
-- [High-level] 'attach', 'detach', 'lookup', 'update', 'adjust' and their
-- @…OnThread@ variants. Each call resolves the thread ID internally. Fine
-- when you make only one or two calls per operation.
--
-- [Raw] 'getThreadId' \/ 'lookupRaw' \/ 'updateRaw'. Pre-compute the
-- thread-ID word once, then pass it to several operations on the same
-- thread without repeated FFI calls.
--
-- [Ref-based] 'ensureRefFast' \/ 'lookupRefFast' \/ 'readRef' \/ 'writeRef'
-- \/ 'modifyRef'. On the fast path (thread already registered), the entire
-- lookup is a single CMM call. Subsequent reads and writes are plain
-- 'IORef' operations with no hash-table probe at all. Use this tier in
-- instrumentation hot loops (e.g. tracing spans).
--
-- == Lifecycle
--
-- * A value 'attach'ed to a thread remains reachable at least as long as the
--   thread is alive.
-- * A value may be explicitly removed via 'detach' at any time. The hash-table
--   key is marked with a "detached" bit; the value slot is /not/ overwritten.
--   A subsequent 'attach' on the same thread reuses the slot without
--   registering a duplicate GC finalizer.
-- * After a thread dies, its finalizer tombstones the slot. The 'IORef' (and
--   the value it holds) become eligible for GC once no other references
--   remain.
-- * 'purgeDeadThreads' can be used to eagerly reclaim slots for threads that
--   have exited but whose finalizers have not yet run. (GHC >= 9.6 only.)
--
-- == Concurrency contract
--
-- Every thread may freely operate on its /own/ entry. The @…OnThread@ and
-- raw APIs additionally let a thread operate on another thread's entry;
-- that is safe against the owner's reads and against cleanup, but two
-- threads concurrently /inserting/ for the same key is not serialized
-- beyond last-writer-wins.
module Control.Concurrent.Thread.Storage (
  -- * The map type
  ThreadStorageMap,

  -- * Construction
  newThreadStorageMap,
  newThreadStorageMapWith,

  -- * High-level API
  -- $high-level

  -- ** Lookup
  lookup,
  lookupOnThread,

  -- ** Insert \/ replace
  attach,
  attachOnThread,

  -- ** Remove
  detach,
  detachFromThread,

  -- ** General update
  update,
  updateOnThread,

  -- ** In-place modification
  adjust,
  adjustOnThread,

  -- * Raw API
  -- $raw
  getThreadId,
  getCurrentThreadId,
  lookupRaw,
  updateRaw,

  -- * Ref-based API
  -- $ref-based
  ensureRef,
  ensureRefFast,
  lookupRef,
  lookupRefFast,
  readRef,
  writeRef,
  modifyRef,

  -- * Monitoring
  storedItems,
#if MIN_VERSION_base(4,18,0)
  purgeDeadThreads,
#endif
) where

import Control.Concurrent (MVar, ThreadId, myThreadId, newMVar, withMVar)
import Control.Concurrent.Thread.Finalizers (addThreadFinalizer)
import Control.Monad (void, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits (countLeadingZeros, finiteBitSize, unsafeShiftL, (.&.), (.|.))
import qualified Data.Bits
import Data.IORef
import Foreign.C.Types (CULLong (..))
import Foreign.Storable (sizeOf)
import GHC.Conc (getNumCapabilities)
import GHC.Conc.Sync (ThreadId (..))
import GHC.Exts (Any, Int (..), Int#, ThreadId#, isTrue#, unsafeCoerce#, (==#), (>=#))
import qualified GHC.Exts as Exts
import GHC.IO (IO (..))
#if MIN_VERSION_base(4,18,0)
import GHC.Conc (ThreadStatus (..), listThreads, threadStatus)
#endif
import Prelude hiding (lookup)


---------------------------------------------------------------------------
-- CMM primops
---------------------------------------------------------------------------

foreign import prim "stg_getCurrentThreadId"
  stg_getCurrentThreadId# :: Exts.State# Exts.RealWorld -> (# Exts.State# Exts.RealWorld, Int# #)


-- | Consistent snapshot of one slot's (key, value). See the CMM source for
-- the seqlock discipline.
foreign import prim "stg_readSlot"
  stg_readSlot#
    :: Exts.MutableByteArray# Exts.RealWorld
    -> Exts.MutableArray# Exts.RealWorld (IORef a)
    -> Int#
    -> Exts.State# Exts.RealWorld
    -> (# Exts.State# Exts.RealWorld, Int#, Any #)


-- | Probe for the current thread. Returns @(tid, slot, key, ref)@: @key@
-- is the full key word observed at the matching slot (callers CAS against
-- it), and @ref@ is only meaningful when @slot >= 0@ (attached), being the
-- value read consistently with that key.
foreign import prim "stg_probeThreadSlot"
  stg_probeThreadSlot#
    :: Exts.MutableByteArray# Exts.RealWorld
    -> Exts.MutableArray# Exts.RealWorld (IORef a)
    -> Int#
    -> Exts.State# Exts.RealWorld
    -> (# Exts.State# Exts.RealWorld, Int#, Int#, Int#, Any #)


-- | Probe for an explicit key. Same return encoding as above, minus the tid.
foreign import prim "stg_probeSlotByKey"
  stg_probeSlotByKey#
    :: Exts.MutableByteArray# Exts.RealWorld
    -> Exts.MutableArray# Exts.RealWorld (IORef a)
    -> Int#
    -> Int#
    -> Exts.State# Exts.RealWorld
    -> (# Exts.State# Exts.RealWorld, Int#, Int#, Any #)


-- | The probes return the value slot as 'Any' because 'foreign import prim'
-- cannot name a lifted type. It is always an @IORef a@ from this map's
-- value array (or a don't-care placeholder when the slot is not attached,
-- which callers never inspect).
asRef :: Any -> IORef a
asRef = unsafeCoerce#
{-# INLINE asRef #-}


---------------------------------------------------------------------------
-- Thread ID extraction
---------------------------------------------------------------------------

-- | Read the current green thread's numeric ID directly from @CurrentTSO@.
--
-- This is implemented as a CMM primop, so no 'ThreadId' box is allocated and
-- no FFI call is made. Prefer this over @'getThreadId' =<< 'myThreadId'@
-- whenever you do not need the 'ThreadId' value itself.
getCurrentThreadId :: IO Int
getCurrentThreadId = IO $ \s ->
  case stg_getCurrentThreadId# s of
    (# s', tid# #) -> (# s', I# tid# #)
{-# INLINE getCurrentThreadId #-}


-- | @rts_getThreadId@ takes the TSO pointer behind a 'ThreadId'.
--
-- The argument MUST be declared as 'ThreadId#' rather than coerced to
-- 'Addr#'. A 'ThreadId#' is an ordinary movable heap pointer: GHC's
-- generational collector relocates TSOs when it promotes them. Declaring
-- it as 'ThreadId#' keeps it in a pointer slot, so the collector traces
-- and updates it, and (because the call is @unsafe@) no GC can run
-- between the argument being read and the callee dereferencing it.
--
-- Coercing to 'Addr#' launders the pointer into a non-pointer slot that
-- the collector neither traces nor updates. If a GC lands while the
-- laundered word is live, the callee dereferences a stale TSO address and
-- the process segfaults. This is the same signature @base@ uses in
-- "GHC.Conc.Sync".
foreign import ccall unsafe "rts_getThreadId" c_getThreadId :: ThreadId# -> CULLong


-- | Extract the numeric thread ID from an existing 'ThreadId'.
--
-- This makes a cheap FFI call to @rts_getThreadId@. When you already hold a
-- 'ThreadId' and need its numeric form for 'lookupRaw' or 'updateRaw', use
-- this. Otherwise prefer 'getCurrentThreadId'.
getThreadId :: ThreadId -> Word
getThreadId (ThreadId tid#) = fromIntegral (c_getThreadId tid#)
{-# INLINE getThreadId #-}


getThreadIdInt :: ThreadId -> Int
getThreadIdInt (ThreadId tid#) = fromIntegral (c_getThreadId tid#)
{-# INLINE getThreadIdInt #-}


---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

-- | GHC allocates TSO IDs starting from 1 (@next_thread_id = 1@ in
-- @rts\/Threads.c@), so 0 is safe as the empty-slot sentinel. If a
-- future GHC ever starts IDs from 0, this would silently lose the
-- main thread's entries on resize (where we skip @emptySlot@ keys).
emptySlot :: Int
emptySlot = 0


-- | Bit 63 marks a tombstoned slot; the tid and flag bits are zero but the
-- version bits are preserved. Test with 'isTombstone', never with @==@.
tombstoneBit :: Int
tombstoneBit = minBound


-- | Bit 32, set in a key slot to mark "detached by user".  Thread IDs
-- are 32-bit ('StgWord32'), so this bit is always free.
detachedBit :: Int
detachedBit = 1 `unsafeShiftL` 32


-- | Bit 33, set in a key slot while its owner is between the key CAS and
-- the value write. Probes treat such slots as non-matching, so the
-- half-written pair is never observable. See 'claimAndPublish'.
claimingBit :: Int
claimingBit = 1 `unsafeShiftL` 33


-- | Mask to extract the raw thread ID from a key (strips the flag bits).
keyMask :: Int
keyMask = detachedBit - 1


-- | The tid plus both flag bits: everything that describes a slot's state
-- as opposed to its history.
stateMask :: Int
stateMask = keyMask .|. detachedBit .|. claimingBit


-- | Bits 34..62: a per-slot publication counter. Every 'claimAndPublish'
-- increments it, and tombstoning and claiming preserve it, so a slot's
-- version is monotone over its whole life. The seqlock in the CMM probes
-- compares whole key words; two equal reads therefore mean no publication
-- happened in between -- even if the slot was recycled through the same
-- tid (the ABA case) -- short of 2^29 publications inside one read.
versionMask :: Int
versionMask = maxBound .&. Data.Bits.complement (versionUnit - 1)

versionUnit :: Int
versionUnit = 1 `unsafeShiftL` 34


-- | Is this key word a tombstone (of any version)?
isTombstone :: Int -> Bool
isTombstone k = k .&. Data.Bits.complement versionMask == tombstoneBit
{-# INLINE isTombstone #-}


-- | The tombstone word that preserves @observed@'s version.
tombstoneWord :: Int -> Int
tombstoneWord observed = tombstoneBit .|. (observed .&. versionMask)
{-# INLINE tombstoneWord #-}


-- | Fibonacci / golden-ratio multiplicative hash salt.
-- @2^64 / phi@, truncated.  Interpreted as signed 'Int' but the
-- multiplication wraps modulo @2^64@ regardless of sign.
hashSalt :: Int
hashSalt = fromIntegral (0x9E3779B97F4A7C15 :: Word)


nextPow2 :: Int -> Int
nextPow2 n
  | n <= 1 = 1
  | otherwise = 1 `unsafeShiftL` (finiteBitSize n - countLeadingZeros (n - 1))
{-# INLINE nextPow2 #-}


---------------------------------------------------------------------------
-- Data types
---------------------------------------------------------------------------

-- | The raw hash table arrays. Swapped atomically on resize.
--
-- The last field is this map's /dead-slot placeholder/: the 'IORef' that
-- fills every value slot whose key is empty or tombstoned. It is allocated
-- once per map at the map's own element type, so even if a bug were to hand
-- it to a caller, reading it yields a well-typed error thunk and writing it
-- stores a well-typed value -- never another map's heap object. Identity is
-- tested with 'isDead', which compares the underlying 'Exts.MutVar#', so
-- unpacking the box here (and re-boxing it in 'allocateTable') is harmless.
data Table a = Table
  {-# UNPACK #-} !Int -- capacity (power of 2)
  (Exts.MutableByteArray# Exts.RealWorld) -- keys: Int per slot
  (Exts.MutableArray# Exts.RealWorld (IORef a)) -- values: GC-traced
  {-# UNPACK #-} !(IORef a) -- dead-slot placeholder


-- | A concurrent map from green-thread IDs to values of type @a@.
--
-- Each thread may have at most one associated value. The table starts at
-- an initial capacity (see 'newThreadStorageMap', 'newThreadStorageMapWith')
-- and doubles automatically when full. Resize operations are serialized by
-- an internal 'MVar' lock so that at most one thread performs the expensive
-- copy-and-swap at a time; other threads that discover a full table block
-- on the lock and retry after the resize completes.
--
-- All read paths and ref-based hot-path operations are entirely lock-free.
-- The 'MVar' is only contended during table growth, which happens
-- O(log n) times over the life of the map.
data ThreadStorageMap a = ThreadStorageMap
  !(IORef (Table a))  -- current table (read-hot, lock-free)
  !(MVar ())


---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- | Allocate a map's dead-slot placeholder. The payload is never meant to
-- be read; if it is, the error names the library so the report lands here.
newDeadRef :: IO (IORef a)
newDeadRef = newIORef $ errorWithoutStackTrace
  "thread-utils-context: dereferenced a dead slot's placeholder; this is a bug in thread-utils-context"


-- | Is @ref@ this table's dead-slot placeholder?
--
-- 'Eq' on 'IORef' is @sameMutVar#@ on the underlying 'Exts.MutVar#', which
-- is an exact identity test with none of the tagging or indirection
-- caveats of 'Exts.reallyUnsafePtrEquality#'.
isDead :: IORef a -> IORef a -> Bool
isDead dead ref = dead == ref
{-# INLINE isDead #-}


slotFor :: Int -> Int -> Int
slotFor cap tid = (tid * hashSalt) .&. (cap - 1)
{-# INLINE slotFor #-}


readKey :: Exts.MutableByteArray# Exts.RealWorld -> Int -> IO Int
readKey keys# (I# i#) = IO $ \s ->
  case Exts.atomicReadIntArray# keys# i# s of
    (# s', v# #) -> (# s', I# v# #)
{-# INLINE readKey #-}


writeKey :: Exts.MutableByteArray# Exts.RealWorld -> Int -> Int -> IO ()
writeKey keys# (I# i#) (I# v#) = IO $ \s ->
  case Exts.atomicWriteIntArray# keys# i# v# s of
    s' -> (# s', () #)
{-# INLINE writeKey #-}


casKey :: Exts.MutableByteArray# Exts.RealWorld -> Int -> Int -> Int -> IO Bool
casKey keys# (I# i#) (I# expected#) (I# new#) = IO $ \s ->
  case Exts.casIntArray# keys# i# expected# new# s of
    (# s', old# #) -> (# s', isTrue# (old# ==# expected#) #)
{-# INLINE casKey #-}


writeVal :: Exts.MutableArray# Exts.RealWorld (IORef a) -> Int -> IORef a -> IO ()
writeVal vals# (I# i#) ref = IO $ \s ->
  case Exts.writeArray# vals# i# ref s of
    s' -> (# s', () #)
{-# INLINE writeVal #-}


-- | Pointer compare-and-swap on a value slot. Succeeds only if the slot
-- still holds exactly @expected@.
casVal :: Exts.MutableArray# Exts.RealWorld (IORef a) -> Int -> IORef a -> IORef a -> IO Bool
casVal vals# (I# i#) expected new = IO $ \s ->
  case Exts.casArray# vals# i# expected new s of
    (# s', failed#, _ #) -> (# s', isTrue# (failed# ==# 0#) #)
{-# INLINE casVal #-}


-- | Consistent snapshot of a slot's (key, value) pair.
readSlot :: Exts.MutableByteArray# Exts.RealWorld -> Exts.MutableArray# Exts.RealWorld (IORef a) -> Int -> IO (Int, IORef a)
readSlot keys# vals# (I# i#) = IO $ \s ->
  case stg_readSlot# keys# vals# i# s of
    (# s', k#, ref #) -> (# s', (I# k#, asRef ref) #)
{-# INLINE readSlot #-}


-- | Linear probe that masks the flag bits when comparing keys.
--
-- Returns the slot, the key word /as observed/ (callers CAS against it),
-- and the value read consistently with that key.
probeFind :: Exts.MutableByteArray# Exts.RealWorld -> Exts.MutableArray# Exts.RealWorld (IORef a) -> Int -> Int -> Int -> IO (Maybe (Int, Int, IORef a))
probeFind keys# vals# cap home key = go home 0
  where
    !mask = cap - 1
    go !slot !steps
      | steps >= cap = pure Nothing
      | otherwise = do
          (k, ref) <- readSlot keys# vals# slot
          if (k .&. keyMask) == key
            then pure $! Just (slot, k, ref)
            else if k == emptySlot
              then pure Nothing
              else go ((slot + 1) .&. mask) (steps + 1)
{-# INLINE probeFind #-}


-- | Take exclusive ownership of @slot@, write @ref@, and publish @key@.
--
-- This is the /only/ way a value slot is written. The CAS from @observed@
-- to the claiming state fails if anything changed the key since the caller
-- looked at it (a tombstone, a competing claim), in which case nothing is
-- written and the caller re-reads. While the claiming bit is set no probe
-- matches the slot, so readers see either the previous state or the fully
-- published new pair -- never a key with someone else's value under it.
-- The final 'writeKey' is an @atomicWriteIntArray#@ release-store, and it
-- carries @observed@'s version plus one; only the tid and detached bits of
-- @key@ are used.
claimAndPublish
  :: Exts.MutableByteArray# Exts.RealWorld
  -> Exts.MutableArray# Exts.RealWorld (IORef a)
  -> Int -> Int -> Int -> IORef a -> IO Bool
claimAndPublish keys# vals# slot observed key ref = do
  let !version = observed .&. versionMask
      !state = key .&. (keyMask .|. detachedBit)
      !published = ((version + versionUnit) .&. versionMask) .|. state
  ok <- casKey keys# slot observed (version .|. state .|. claimingBit)
  when ok $ do
    writeVal vals# slot ref
    writeKey keys# slot published
  pure ok
{-# INLINE claimAndPublish #-}


---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

allocateTable :: IORef a -> Int -> IO (Table a)
allocateTable dead requested = IO $ \s0 ->
  let !cap = nextPow2 (max 16 requested)
      !(I# cap#) = cap
      !(I# bytes#) = cap * sizeOf (0 :: Int)
  in case Exts.newByteArray# bytes# s0 of
    (# s1, keys# #) ->
      case Exts.setByteArray# keys# 0# bytes# 0# s1 of
        s2 -> case Exts.newArray# cap# dead s2 of
          (# s3, vals# #) ->
            (# s3, Table cap keys# vals# dead #)


-- | Create a 'ThreadStorageMap' with a default initial capacity derived from
-- the number of runtime capabilities: @max 128 (capabilities * 32)@, rounded
-- up to the next power of two.
--
-- The table resizes automatically when full, so this is a good default for
-- most applications.
newThreadStorageMap :: (MonadIO m) => m (ThreadStorageMap a)
newThreadStorageMap = liftIO $ do
  caps <- getNumCapabilities
  newThreadStorageMapWith (max 128 (caps * 32))
{-# INLINE newThreadStorageMap #-}


-- | Create a 'ThreadStorageMap' with at least the given number of initial
-- slots.
--
-- The actual capacity is rounded up to the next power of two (minimum 16).
-- The table doubles automatically when it runs out of slots. A load factor
-- below 0.7 keeps probe chains short; resizing also cleans tombstones.
newThreadStorageMapWith :: (MonadIO m) => Int -> m (ThreadStorageMap a)
newThreadStorageMapWith requested = liftIO $ do
  dead <- newDeadRef
  table <- allocateTable dead requested
  ref <- newIORef table
  lock <- newMVar ()
  pure (ThreadStorageMap ref lock)
{-# INLINE newThreadStorageMapWith #-}


-- $high-level
--
-- Convenient functions that resolve the current thread's identity internally.
-- Each call obtains the 'ThreadId' (or numeric ID) on your behalf, which is
-- fine for one-shot operations. If you are making multiple calls in sequence
-- for the same thread, consider the [Raw API](#raw) or [Ref-based API](#ref-based)
-- to avoid redundant work.


---------------------------------------------------------------------------
-- High-level API
---------------------------------------------------------------------------

-- | Retrieve the value associated with the current thread, if any.
--
-- Uses the fused CMM probe which reads @CurrentTSO.id@, applies the
-- multiplicative hash, linearly probes the key array and snapshots the
-- value in a single CMM call.  Returns @Nothing@ for both absent and
-- detached entries without touching the value array in the detached case.
lookup :: (MonadIO m) => ThreadStorageMap a -> m (Maybe a)
lookup (ThreadStorageMap tableRef _) = liftIO $ do
  Table _cap keys# vals# dead <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = _cap - 1
    in case stg_probeThreadSlot# keys# vals# mask# s0 of
      (# s1, _tid#, slot#, _key#, any #)
        | isTrue# (slot# >=# 0#), ref <- asRef any ->
            if isDead dead ref
              then (# s1, Nothing #)
              else case readIORef ref of { IO f -> case f s1 of
                     { (# s2, val #) -> (# s2, Just val #) }}
        | otherwise -> (# s1, Nothing #)
{-# INLINE lookup #-}


-- | Retrieve the value associated with a specific thread.
lookupOnThread :: (MonadIO m) => ThreadStorageMap a -> ThreadId -> m (Maybe a)
lookupOnThread tsm tid = liftIO $ lookupRaw tsm (getThreadId tid)
{-# INLINE lookupOnThread #-}


-- | Associate a value with the current thread, replacing any previous value.
--
-- Returns the previous value, or 'Nothing' if the thread had no entry.
-- A GC finalizer is registered on the first call per thread so that the
-- entry is automatically cleaned up when the thread dies.
--
-- On the hot path (value already attached), no 'ThreadId' is allocated and
-- no FFI call is made. 'myThreadId' is only called on the cold first-insert
-- path to register the GC finalizer.
attach :: (MonadIO m) => ThreadStorageMap a -> a -> m (Maybe a)
attach tsm x = update tsm (\prev -> (Just x, prev))
{-# INLINE attach #-}


-- | Like 'attach', but targets a specific thread.
attachOnThread :: (MonadIO m) => ThreadStorageMap a -> ThreadId -> a -> m (Maybe a)
attachOnThread tsm tid x =
  updateOnThread tsm tid (\prev -> (Just x, prev))
{-# INLINE attachOnThread #-}


-- | Remove the value associated with the current thread.
--
-- Returns the removed value, or 'Nothing' if the thread had no entry.
-- The slot key is marked with the detached bit (a single atomic write to
-- unboxed memory with no GC write barrier) so it can be reused by a
-- future 'attach' without registering a duplicate GC finalizer.
detach :: (MonadIO m) => ThreadStorageMap a -> m (Maybe a)
detach tsm = update tsm (\prev -> (Nothing, prev))
{-# INLINE detach #-}


-- | Like 'detach', but targets a specific thread.
detachFromThread :: (MonadIO m) => ThreadStorageMap a -> ThreadId -> m (Maybe a)
detachFromThread tsm tid =
  updateOnThread tsm tid (\prev -> (Nothing, prev))
{-# INLINE detachFromThread #-}


-- | Atomically read and update the value for the current thread.
--
-- The callback receives the current value (or 'Nothing') and returns a pair
-- of the new value to store (or 'Nothing' to remove the entry) and an
-- arbitrary result.
--
-- Uses the fused CMM probe ('stg_probeThreadSlot#').  The probe reports
-- attached\/detached\/absent via its return encoding, so the hot path
-- (attached, updating the value) never checks the detached state at all.
--
-- @
-- -- Increment a counter, inserting 1 if absent:
-- update tsm (\\old -> (Just (maybe 1 (+1) old), ()))
-- @
update :: (MonadIO m) => ThreadStorageMap a -> (Maybe a -> (Maybe a, b)) -> m b
update tsm@(ThreadStorageMap tableRef _) f = liftIO $ do
  Table cap keys# vals# dead <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = cap - 1
    in case stg_probeThreadSlot# keys# vals# mask# s0 of
      (# s1, tid#, rawSlot#, key#, any #)
        | isTrue# (rawSlot# >=# 0#), ref <- asRef any ->
            -- Hot path: attached. A dead placeholder under a live key
            -- cannot happen under the claiming protocol; treated as a
            -- miss rather than dereferenced, belt and braces.
            if isDead dead ref
              then miss s1
              else
                case readIORef ref of { IO readIt -> case readIt s1 of
                  { (# s2, old #) -> case f (Just old) of
                    (Just !new, !b) ->
                      case writeIORef ref new of { IO writeIt -> case writeIt s2 of
                        { (# s3, _ #) -> (# s3, b #) }}
                    (Nothing, !b) ->
                      case updateDetach tsm tableRef cap keys# (I# rawSlot#) (I# key#) (I# tid#) of
                        { IO t -> case t s2 of { (# s3, _ #) -> (# s3, b #) }}
                  }}
        | isTrue# (rawSlot# ==# Exts.negateInt# 1#) -> miss s1
        | otherwise ->
            -- Found but detached: re-attach in place.
            case f Nothing of
              (Nothing, !b) -> (# s1, b #)
              (Just !new, !b) ->
                let slot# = Exts.negateInt# rawSlot# Exts.-# 2#
                in case reattachSlot tsm tableRef cap keys# vals# (I# slot#) (I# key#) (I# tid#) myThreadId new of
                  { IO re -> case re s1 of { (# s2, _ #) -> (# s2, b #) }}
        where
          -- Not found: insert fresh if the callback produces a value.
          miss s = case f Nothing of
            (Nothing, !b) -> (# s, b #)
            (Just !new, !b) ->
              case updateColdInsert tsm (I# tid#) new of
                { IO ins -> case ins s of { (# s', _ #) -> (# s', b #) }}
{-# INLINE update #-}


-- Cold path: mark a slot as detached by setting the detached bit in the
-- key word we observed. Writes only to the key array (MutableByteArray#,
-- no GC write barrier) -- the value slot is left untouched. A CAS rather
-- than a blind store so that a tombstone which landed in the meantime is
-- not undone.
updateDetach
  :: ThreadStorageMap a
  -> IORef (Table a)
  -> Int
  -> Exts.MutableByteArray# Exts.RealWorld
  -> Int -> Int -> Int -> IO ()
updateDetach tsm tableRef cap keys# slot observed tidKey = do
  _ <- casKey keys# slot observed (observed .|. detachedBit)
  Table cap' _ _ _ <- readIORef tableRef
  when (cap' /= cap) $ propagateDetach tsm tidKey
{-# NOINLINE updateDetach #-}


-- Cold path: create a new IORef in a detached slot. No finalizer is
-- registered because the original 'insertNew' already did so.
--
-- If the claim fails the slot was tombstoned between the probe and now
-- (the thread's finalizer cannot have run, but 'purgeDeadThreads' may have
-- raced), so fall back to a fresh insert. @getTid@ is how the caller
-- supplies the owning 'ThreadId' only on that cold path.
reattachSlot
  :: ThreadStorageMap a
  -> IORef (Table a)
  -> Int
  -> Exts.MutableByteArray# Exts.RealWorld
  -> Exts.MutableArray# Exts.RealWorld (IORef a)
  -> Int -> Int -> Int -> IO ThreadId -> a -> IO ()
reattachSlot tsm tableRef origCap keys# vals# slot observed tidKey getTid new = do
  newRef <- newIORef new
  ok <- claimAndPublish keys# vals# slot observed tidKey newRef
  if ok
    then do
      Table cap' _ _ _ <- readIORef tableRef
      when (cap' /= origCap) $ propagateRef tsm tidKey newRef
    else do
      tid <- getTid
      void $ insertNew tsm tid tidKey new
{-# NOINLINE reattachSlot #-}


-- Propagate a detach marker to the current table after a concurrent resize.
propagateDetach :: ThreadStorageMap a -> Int -> IO ()
propagateDetach tsm@(ThreadStorageMap tableRef _) tidKey = do
  Table cap keys# vals# _ <- readIORef tableRef
  let !home = slotFor cap tidKey
  found <- probeFind keys# vals# cap home tidKey
  case found of
    Just (!slot, !k, _) -> do
      when (k .&. (detachedBit .|. claimingBit) == 0) $
        void $ casKey keys# slot k (k .|. detachedBit)
      Table cap' _ _ _ <- readIORef tableRef
      when (cap' /= cap) $ propagateDetach tsm tidKey
    Nothing -> pure ()
{-# NOINLINE propagateDetach #-}


-- Propagate a re-attached IORef to the current table after a concurrent resize.
propagateRef :: ThreadStorageMap a -> Int -> IORef a -> IO ()
propagateRef tsm@(ThreadStorageMap tableRef _) tidKey ref = do
  Table cap keys# vals# _ <- readIORef tableRef
  let !home = slotFor cap tidKey
  found <- probeFind keys# vals# cap home tidKey
  case found of
    Just (!slot, !k, _) ->
      when (k .&. detachedBit /= 0 && k .&. claimingBit == 0) $ do
        ok <- claimAndPublish keys# vals# slot k tidKey ref
        when ok $ do
          Table cap' _ _ _ <- readIORef tableRef
          when (cap' /= cap) $ propagateRef tsm tidKey ref
    Nothing -> pure ()
{-# NOINLINE propagateRef #-}


-- Cold path: first insert for a thread. NOINLINE keeps 'update' small.
updateColdInsert :: ThreadStorageMap a -> Int -> a -> IO ()
updateColdInsert tsm tidKey new = do
  tid <- myThreadId
  _ <- insertNew tsm tid tidKey new
  pure ()
{-# NOINLINE updateColdInsert #-}

-- Cold path: first insert with an already-known ThreadId.
updateColdInsertTid :: ThreadStorageMap a -> ThreadId -> Int -> a -> IO ()
updateColdInsertTid tsm tid tidKey new = do
  _ <- insertNew tsm tid tidKey new
  pure ()
{-# NOINLINE updateColdInsertTid #-}


-- | Like 'update', but targets a specific thread.
--
-- This is the most general function in the high-level API.
-- 'attachOnThread' and 'detachFromThread' are implemented in terms of this.
updateOnThread :: (MonadIO m) => ThreadStorageMap a -> ThreadId -> (Maybe a -> (Maybe a, b)) -> m b
updateOnThread tsm tid f = liftIO $ updateRaw tsm tid (getThreadId tid) f
{-# INLINE updateOnThread #-}


-- | Modify the value for the current thread in place if one is attached.
--
-- Does nothing if the thread has no entry or the entry is detached.
-- The modification is strict ('modifyIORef'').  Uses the fused CMM probe.
adjust :: (MonadIO m) => ThreadStorageMap a -> (a -> a) -> m ()
adjust (ThreadStorageMap tableRef _) f = liftIO $ do
  Table _cap keys# vals# dead <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = _cap - 1
    in case stg_probeThreadSlot# keys# vals# mask# s0 of
      (# s1, _tid#, slot#, _key#, any #)
        | isTrue# (slot# >=# 0#), ref <- asRef any ->
            if isDead dead ref
              then (# s1, () #)
              else case modifyIORef' ref f of { IO g -> g s1 }
        | otherwise -> (# s1, () #)
{-# INLINE adjust #-}


-- | Like 'adjust', but targets a specific thread.
adjustOnThread :: (MonadIO m) => ThreadStorageMap a -> ThreadId -> (a -> a) -> m ()
adjustOnThread (ThreadStorageMap tableRef _) tid f = liftIO $ do
  Table _cap keys# vals# dead <- readIORef tableRef
  let !(I# mask#) = _cap - 1
      !(I# tidKey#) = getThreadIdInt tid
  IO $ \s0 ->
    case stg_probeSlotByKey# keys# vals# mask# tidKey# s0 of
      (# s1, slot#, _key#, any #)
        | isTrue# (slot# >=# 0#), ref <- asRef any ->
            if isDead dead ref
              then (# s1, () #)
              else case modifyIORef' ref f of { IO g -> g s1 }
        | otherwise -> (# s1, () #)
{-# INLINE adjustOnThread #-}


-- $raw
--
-- Pre-compute a thread's numeric ID once and reuse it across several
-- operations, avoiding repeated FFI calls to @rts_getThreadId@.
--
-- @
-- tid <- myThreadId
-- let !tw = 'getThreadId' tid
-- 'lookupRaw' tsm tw >>= \\case ...
-- 'updateRaw' tsm tid tw (\\old -> ...)
-- @
--
-- The 'ThreadId' is still required by 'updateRaw' because it may need to
-- register a GC finalizer on the first insert.


---------------------------------------------------------------------------
-- Raw API
---------------------------------------------------------------------------

-- | Retrieve a value using a pre-computed thread ID (from 'getThreadId').
--
-- Avoids the FFI call to @rts_getThreadId@ that 'lookupOnThread' would
-- make internally. Uses a CMM primop for the key-array probe.
lookupRaw :: (MonadIO m) => ThreadStorageMap a -> Word -> m (Maybe a)
lookupRaw (ThreadStorageMap tableRef _) !tidWord = liftIO $ do
  Table _cap keys# vals# dead <- readIORef tableRef
  let !(I# mask#) = _cap - 1
      !(I# tidKey#) = fromIntegral tidWord :: Int
  IO $ \s0 ->
    case stg_probeSlotByKey# keys# vals# mask# tidKey# s0 of
      (# s1, slot#, _key#, any #)
        | isTrue# (slot# >=# 0#), ref <- asRef any ->
            if isDead dead ref
              then (# s1, Nothing #)
              else case readIORef ref of { IO f -> case f s1 of
                     { (# s2, val #) -> (# s2, Just val #) }}
        | otherwise -> (# s1, Nothing #)
{-# INLINE lookupRaw #-}


-- | Generalized update using a pre-computed thread ID.
--
-- Behaves like 'updateOnThread' but skips the internal 'getThreadId' call.
-- The 'ThreadId' argument is still needed so a GC finalizer can be
-- registered when a new entry is created.  Uses a CMM primop for the
-- key-array probe.
updateRaw :: (MonadIO m) => ThreadStorageMap a -> ThreadId -> Word -> (Maybe a -> (Maybe a, b)) -> m b
updateRaw tsm@(ThreadStorageMap tableRef _) tid !tidWord f = liftIO $ do
  let !tidKey@(I# tidKey#) = fromIntegral tidWord :: Int
  Table cap keys# vals# dead <- readIORef tableRef
  let !(I# mask#) = cap - 1
  IO $ \s0 ->
    case stg_probeSlotByKey# keys# vals# mask# tidKey# s0 of
      (# s1, rawSlot#, key#, any #)
        | isTrue# (rawSlot# >=# 0#), ref <- asRef any ->
            -- Hot path: attached. See 'update' for the dead check.
            if isDead dead ref
              then miss s1
              else
                case readIORef ref of { IO readIt -> case readIt s1 of
                  { (# s2, old #) -> case f (Just old) of
                    (Just !new, !b) ->
                      case writeIORef ref new of { IO writeIt -> case writeIt s2 of
                        { (# s3, _ #) -> (# s3, b #) }}
                    (Nothing, !b) ->
                      case updateDetach tsm tableRef cap keys# (I# rawSlot#) (I# key#) tidKey of
                        { IO t -> case t s2 of { (# s3, _ #) -> (# s3, b #) }}
                  }}
        | isTrue# (rawSlot# ==# Exts.negateInt# 1#) -> miss s1
        | otherwise ->
            case f Nothing of
              (Nothing, !b) -> (# s1, b #)
              (Just !new, !b) ->
                let slot# = Exts.negateInt# rawSlot# Exts.-# 2#
                in case reattachSlot tsm tableRef cap keys# vals# (I# slot#) (I# key#) tidKey (pure tid) new of
                  { IO re -> case re s1 of { (# s2, _ #) -> (# s2, b #) }}
        where
          miss s = case f Nothing of
            (Nothing, !b) -> (# s, b #)
            (Just !new, !b) ->
              case updateColdInsertTid tsm tid tidKey new of
                { IO ins -> case ins s of { (# s', _ #) -> (# s', b #) }}
{-# INLINE updateRaw #-}


-- $ref-based
--
-- The fastest tier. On the hot path (thread already registered), the
-- operations below avoid the hash-table probe entirely by handing you the
-- per-thread 'IORef' directly. Subsequent reads and writes are plain
-- 'IORef' operations.
--
-- Typical usage in a tracing library:
--
-- @
-- -- Once per request (or per thread lifetime):
-- (tid, ref) <- 'ensureRefFast' tsm Nothing
--
-- -- On every span open (hot path, no probe, no CAS):
-- 'writeRef' ref (Just spanContext)
--
-- -- On every span close:
-- ctx <- 'readRef' ref
-- 'writeRef' ref Nothing
-- @
--
-- If you already have a 'ThreadId' and numeric ID, use 'ensureRef' or
-- 'lookupRef'. If you want the absolute fastest path and don't have a
-- 'ThreadId' yet, use 'ensureRefFast' or 'lookupRefFast' which read
-- @CurrentTSO.id@ and probe the key array entirely in CMM.


---------------------------------------------------------------------------
-- Ref-based API
---------------------------------------------------------------------------

-- | Get or create the 'IORef' for a given thread.
--
-- If the thread already has an entry, returns its 'IORef' (read-only probe,
-- no CAS). Otherwise, creates a new 'IORef' initialised to @def@, claims a
-- slot via CAS, and registers a GC finalizer for cleanup.
--
-- The @Int@ argument is the numeric thread ID (e.g. from
-- 'getCurrentThreadId' or @fromIntegral . 'getThreadId'@).
ensureRef :: ThreadStorageMap a -> ThreadId -> Int -> a -> IO (IORef a)
ensureRef tsm@(ThreadStorageMap tableRef _) tid !tidKey def = do
  Table cap keys# vals# dead <- readIORef tableRef
  let !home = slotFor cap tidKey
  result <- probeFind keys# vals# cap home tidKey
  case result of
    Just (slot, k, ref)
      -- Someone else's claim for this key is in flight, or the slot was
      -- tombstoned under us: behave exactly as if absent. 'insertNew' will
      -- CAS its way to a consistent outcome.
      | k .&. claimingBit /= 0 || isDead dead ref -> insertNew tsm tid tidKey def
      | k .&. detachedBit /= 0 -> do
          newRef <- newIORef def
          ok <- claimAndPublish keys# vals# slot k tidKey newRef
          if ok
            then do
              Table cap' _ _ _ <- readIORef tableRef
              when (cap' /= cap) $ propagateRef tsm tidKey newRef
              pure newRef
            else insertNew tsm tid tidKey def
      | otherwise -> pure ref
    Nothing -> insertNew tsm tid tidKey def
{-# INLINE ensureRef #-}


-- | Fused CMM fast path: get or create the 'IORef' for the /current/ thread.
--
-- Returns @(threadId, ref)@.
--
-- __Steady state__ (entry exists): read the table 'IORef', then a single
-- CMM call reads @CurrentTSO.id@, linearly probes the key array and
-- fetches the 'IORef'. No 'ThreadId' allocation, no FFI, no 'Maybe'
-- wrapper.
--
-- __First call per thread__: falls back to 'myThreadId', CAS-inserts a new
-- 'IORef' initialised to @def@, and registers a finalizer.
ensureRefFast :: ThreadStorageMap a -> a -> IO (Int, IORef a)
ensureRefFast tsm@(ThreadStorageMap tableRef _) def = do
  Table _cap keys# vals# dead <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = _cap - 1
    in case stg_probeThreadSlot# keys# vals# mask# s0 of
      (# s1, tid#, rawSlot#, key#, any #)
        | isTrue# (rawSlot# >=# 0#), ref <- asRef any ->
            if isDead dead ref
              then slow s1
              else (# s1, (I# tid#, ref) #)
        | isTrue# (rawSlot# ==# Exts.negateInt# 1#) -> slow s1
        | otherwise ->
            let slot# = Exts.negateInt# rawSlot# Exts.-# 2#
                IO reattach = ensureRefReattach tsm tableRef _cap keys# vals# (I# slot#) (I# key#) (I# tid#) def
            in reattach s1
        where
          IO slow = do
            tid <- myThreadId
            ref <- insertNew tsm tid (I# tid#) def
            pure (I# tid#, ref)
{-# INLINE ensureRefFast #-}


ensureRefReattach
  :: ThreadStorageMap a -> IORef (Table a) -> Int
  -> Exts.MutableByteArray# Exts.RealWorld
  -> Exts.MutableArray# Exts.RealWorld (IORef a) -> Int -> Int -> Int -> a -> IO (Int, IORef a)
ensureRefReattach tsm tableRef origCap keys# vals# slot observed tidKey def = do
  newRef <- newIORef def
  ok <- claimAndPublish keys# vals# slot observed tidKey newRef
  if ok
    then do
      Table cap' _ _ _ <- readIORef tableRef
      when (cap' /= origCap) $ propagateRef tsm tidKey newRef
      pure (tidKey, newRef)
    else do
      tid <- myThreadId
      ref <- insertNew tsm tid tidKey def
      pure (tidKey, ref)
{-# NOINLINE ensureRefReattach #-}


-- | Look up the 'IORef' for the /current/ thread using the fused CMM probe.
--
-- Returns @(threadId, 'Maybe' ('IORef' a))@. The numeric thread ID is
-- returned so you can pass it to 'ensureRef' on the slow path without a
-- second FFI call:
--
-- @
-- (tid, mref) <- 'lookupRefFast' tsm
-- ref <- case mref of
--   Just r  -> pure r
--   Nothing -> do
--     t <- myThreadId
--     'ensureRef' tsm t tid defaultValue
-- @
lookupRefFast :: ThreadStorageMap a -> IO (Int, Maybe (IORef a))
lookupRefFast (ThreadStorageMap tableRef _) = do
  Table _cap keys# vals# dead <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = _cap - 1
    in case stg_probeThreadSlot# keys# vals# mask# s0 of
      (# s1, tid#, slot#, _key#, any #)
        | isTrue# (slot# >=# 0#), ref <- asRef any ->
            if isDead dead ref
              then (# s1, (I# tid#, Nothing) #)
              else (# s1, (I# tid#, Just ref) #)
        | otherwise -> (# s1, (I# tid#, Nothing) #)
{-# INLINE lookupRefFast #-}


-- | Look up the 'IORef' for a thread by its numeric ID (Haskell-side probe).
--
-- Use this when you already have the numeric ID but not necessarily the
-- current thread's TSO (e.g. inspecting another thread's slot).
lookupRef :: ThreadStorageMap a -> Int -> IO (Maybe (IORef a))
lookupRef (ThreadStorageMap tableRef _) !tidKey = do
  Table cap keys# vals# dead <- readIORef tableRef
  result <- probeFind keys# vals# cap (slotFor cap tidKey) tidKey
  pure $! case result of
    Nothing -> Nothing
    Just (_, k, ref)
      | k .&. (detachedBit .|. claimingBit) /= 0 || isDead dead ref -> Nothing
      | otherwise -> Just ref
{-# INLINE lookupRef #-}


-- | Read the value from a per-thread 'IORef'.
--
-- Thin wrapper around 'readIORef'; provided for API symmetry with
-- 'writeRef' and 'modifyRef'.
readRef :: IORef a -> IO a
readRef = readIORef
{-# INLINE readRef #-}


-- | Write a value into a per-thread 'IORef'.
writeRef :: IORef a -> a -> IO ()
writeRef = writeIORef
{-# INLINE writeRef #-}


-- | Strictly modify the value in a per-thread 'IORef'.
--
-- Equivalent to 'modifyIORef''.
modifyRef :: IORef a -> (a -> a) -> IO ()
modifyRef = modifyIORef'
{-# INLINE modifyRef #-}


---------------------------------------------------------------------------
-- Internal: insert / remove / resize
---------------------------------------------------------------------------

insertNew :: ThreadStorageMap a -> ThreadId -> Int -> a -> IO (IORef a)
insertNew tsm@(ThreadStorageMap tableRef resizeLock) tid !tidKey val = do
  ref <- newIORef val
  let go = do
        Table cap keys# vals# _ <- readIORef tableRef
        let !home = slotFor cap tidKey
        success <- claimSlot True keys# vals# cap home tidKey ref
        if success
          then ensureCurrent
          else do
            withMVar resizeLock $ \_ -> do
              Table curCap _ _ _ <- readIORef tableRef
              when (curCap == cap) $ growTable tableRef cap
            go

      -- A resize may have published a new table while we were claiming a
      -- slot in the old one. If our key is not in the current table, redo
      -- the insert there. (A claim that landed after the resizer's first
      -- pass but before publication is picked up by its second pass; see
      -- 'rehashTable'.)
      ensureCurrent = do
        Table cap keys# vals# _ <- readIORef tableRef
        let !home = slotFor cap tidKey
        found <- probeFind keys# vals# cap home tidKey
        case found of
          Just _ -> pure ()
          Nothing -> go
  go
  addThreadFinalizer tid $ removeEntry tsm tidKey
  pure ref


-- | Linear-probe insert. Returns 'False' if the table is full (probe
-- wrapped all the way around without finding an empty, tombstone, or
-- matching slot).
--
-- Every write goes through 'claimAndPublish', so the slot is CAS-owned
-- for the duration of the value write regardless of whether it was empty,
-- tombstoned, or already carried this key. On a failed CAS the same slot
-- is re-read: the key changed under us, so there is always progress.
--
-- With @overwrite = False@ a slot that already carries @key@ (in any
-- state) is left alone and counted as success. 'rehashTable' uses that
-- mode so its second pass never clobbers a value the owner has since
-- replaced in the new table.
claimSlot :: Bool -> Exts.MutableByteArray# Exts.RealWorld -> Exts.MutableArray# Exts.RealWorld (IORef a) -> Int -> Int -> Int -> IORef a -> IO Bool
claimSlot overwrite keys# vals# cap home key ref = go home 0
  where
    !mask = cap - 1
    !rawKey = key .&. keyMask
    go !slot !steps
      | steps >= cap = pure False
      | otherwise = do
          k <- readKey keys# slot
          if k == emptySlot || isTombstone k
            then claimOrRetry slot steps k
            else if (k .&. keyMask) == rawKey
              then if overwrite then claimOrRetry slot steps k else pure True
              else go ((slot + 1) .&. mask) (steps + 1)
    claimOrRetry !slot !steps !k = do
      ok <- claimAndPublish keys# vals# slot k key ref
      if ok then pure True else go slot steps
{-# INLINE claimSlot #-}


-- | Copy live entries into a new table of the given capacity and publish it.
-- MUST be called while holding the resize 'MVar'. Uses plain 'writeIORef'
-- because the lock serializes all resize operations; no CAS needed.
-- Used for both growing (double capacity) and shrinking (after purge).
-- Keys are copied verbatim (including detached bit) so the detached
-- state survives resize.  Home slot computed from the raw thread ID.
--
-- Each (key, value) pair is snapshotted with 'readSlot'. Slots that are
-- empty, tombstoned, or mid-claim are skipped; a claim in flight is
-- completed by its owner, whose 'insertNew' re-checks the current table
-- afterwards. The copy runs twice -- once before and once after
-- publication -- so a claim that lands after the first pass has visited
-- its slot, but whose owner re-checked before publication, is still
-- carried over. The second pass only adds keys that are absent.
--
-- A shrink target is computed from a point-in-time count, so a burst of
-- inserts during the copy can overfill the smaller table; entries that do
-- not fit are dropped and re-inserted lazily by their owners' next write.
rehashTable :: IORef (Table a) -> Int -> Int -> IO ()
rehashTable tableRef !oldCap !newCap = do
  Table _ oldKeys# oldVals# dead <- readIORef tableRef
  newTable@(Table _ newKeys# newVals# _) <- allocateTable dead newCap
  let copyLoop !i
        | i >= oldCap = pure ()
        | otherwise = do
            (k, ref) <- readSlot oldKeys# oldVals# i
            when (k /= emptySlot && not (isTombstone k) && k .&. claimingBit == 0 && not (isDead dead ref)) $ do
              let !home = slotFor newCap (k .&. keyMask)
              void $ claimSlot False newKeys# newVals# newCap home k ref
            copyLoop (i + 1)
  copyLoop 0
  writeIORef tableRef newTable
  copyLoop 0


growTable :: IORef (Table a) -> Int -> IO ()
growTable tableRef !oldCap = rehashTable tableRef oldCap (oldCap * 2)


-- | Tombstone the slot holding @tidKey@, if the key is still exactly what
-- we observed. Key first (so no probe can match the slot from here on),
-- then the value, by CAS from the ref we observed so a claimer who has
-- already replaced it is left alone. Returns 'False' if the key changed
-- under us.
tombstoneSlot
  :: Exts.MutableByteArray# Exts.RealWorld
  -> Exts.MutableArray# Exts.RealWorld (IORef a)
  -> IORef a -> Int -> Int -> IORef a -> IO Bool
tombstoneSlot keys# vals# dead slot observedKey observedRef = do
  ok <- casKey keys# slot observedKey (tombstoneWord observedKey)
  when ok $ void $ casVal vals# slot observedRef dead
  pure ok
{-# INLINE tombstoneSlot #-}


-- | Tombstone an entry by key in the current table. Clears the value
-- slot so the 'IORef' (and its payload) become eligible for GC
-- immediately rather than lingering until the next resize.
-- Retries if the slot changed under us or a resize occurred between the
-- probe and the tombstone.
removeEntry :: ThreadStorageMap a -> Int -> IO ()
removeEntry tsm@(ThreadStorageMap tableRef _) !tidKey = do
  Table cap keys# vals# dead <- readIORef tableRef
  let !home = slotFor cap tidKey
  result <- probeFind keys# vals# cap home tidKey
  case result of
    Nothing -> pure ()
    Just (!slot, !k, ref) -> do
      ok <- tombstoneSlot keys# vals# dead slot k ref
      Table cap' _ _ _ <- readIORef tableRef
      when (not ok || cap' /= cap) $ removeEntry tsm tidKey


---------------------------------------------------------------------------
-- Monitoring
---------------------------------------------------------------------------

-- | Snapshot all live entries as @(threadId, value)@ pairs.
--
-- Intended for monitoring and debugging, e.g. verifying that entries are
-- cleaned up after threads exit. The result is a point-in-time snapshot;
-- concurrent mutations may or may not be reflected.
storedItems :: ThreadStorageMap a -> IO [(Int, a)]
storedItems (ThreadStorageMap tableRef _) = do
  Table cap keys# vals# dead <- readIORef tableRef
  go keys# vals# dead cap 0 []
  where
    go keys# vals# dead cap !i !acc
      | i >= cap = pure (reverse acc)
      | otherwise = do
          (k, ref) <- readSlot keys# vals# i
          if k /= emptySlot && not (isTombstone k) && k .&. (detachedBit .|. claimingBit) == 0 && not (isDead dead ref)
            then do
              v <- readIORef ref
              go keys# vals# dead cap (i + 1) ((k .&. keyMask, v) : acc)
            else go keys# vals# dead cap (i + 1) acc


---------------------------------------------------------------------------
-- SPECIALIZE pragmas
---------------------------------------------------------------------------

{-# SPECIALIZE lookup :: ThreadStorageMap a -> IO (Maybe a) #-}
{-# SPECIALIZE lookupOnThread :: ThreadStorageMap a -> ThreadId -> IO (Maybe a) #-}
{-# SPECIALIZE lookupRaw :: ThreadStorageMap a -> Word -> IO (Maybe a) #-}
{-# SPECIALIZE attach :: ThreadStorageMap a -> a -> IO (Maybe a) #-}
{-# SPECIALIZE attachOnThread :: ThreadStorageMap a -> ThreadId -> a -> IO (Maybe a) #-}
{-# SPECIALIZE detach :: ThreadStorageMap a -> IO (Maybe a) #-}
{-# SPECIALIZE detachFromThread :: ThreadStorageMap a -> ThreadId -> IO (Maybe a) #-}
{-# SPECIALIZE adjust :: ThreadStorageMap a -> (a -> a) -> IO () #-}
{-# SPECIALIZE adjustOnThread :: ThreadStorageMap a -> ThreadId -> (a -> a) -> IO () #-}
{-# SPECIALIZE newThreadStorageMap :: IO (ThreadStorageMap a) #-}
{-# SPECIALIZE newThreadStorageMapWith :: Int -> IO (ThreadStorageMap a) #-}


#if MIN_VERSION_base(4,18,0)

---------------------------------------------------------------------------
-- C-side SIMD batch membership test
---------------------------------------------------------------------------

-- | Lifted wrapper for a temporary 'MutableByteArray#' of @Int@ values.
data MutIntArray = MutIntArray (Exts.MutableByteArray# Exts.RealWorld)


newMutIntArray :: Int -> IO MutIntArray
newMutIntArray n = IO $ \s0 ->
  let !(I# bytes#) = n * sizeOf (0 :: Int)
  in case Exts.newByteArray# bytes# s0 of
    (# s1, arr# #) -> (# s1, MutIntArray arr# #)


readMutInt :: MutIntArray -> Int -> IO Int
readMutInt (MutIntArray arr#) (I# i#) = IO $ \s ->
  case Exts.readIntArray# arr# i# s of
    (# s', v# #) -> (# s', I# v# #)


writeMutInt :: MutIntArray -> Int -> Int -> IO ()
writeMutInt (MutIntArray arr#) (I# i#) (I# v#) = IO $ \s ->
  case Exts.writeIntArray# arr# i# v# s of
    s' -> (# s', () #)


-- | Fill a 'MutIntArray' with the numeric IDs of the threads that can still
-- run, returning how many were written.
--
-- Threads whose 'threadStatus' is 'ThreadFinished' or 'ThreadDied' are
-- skipped. 'listThreads' enumerates the RTS generation thread lists, and a
-- TSO is only unlinked from those by a GC that collects its generation --
-- so a thread that has exited keeps being listed until then, and once it has
-- been promoted, until the next /major/ GC.
--
-- The array is left unsorted; the C side sorts it in place via @qsort@
-- before scanning.
buildLiveSet :: [ThreadId] -> IO (MutIntArray, Int)
buildLiveSet tids = do
  let !n = length tids
  arr <- newMutIntArray (max 1 n)
  let fill [] !i = pure i
      fill (t : ts) !i = do
        status <- threadStatus t
        case status of
          ThreadFinished -> fill ts i
          ThreadDied -> fill ts i
          _ -> do
            writeMutInt arr i (getThreadIdInt t)
            fill ts (i + 1)
  nLive <- fill tids 0
  pure (arr, nLive)


-- | Batch membership scan implemented in C with architecture-dispatched
-- SIMD (NEON on aarch64, SSE2 on x86_64, scalar fallback elsewhere).
-- Sorts @live@ in place via @qsort@ (for binary-search fallback when
-- n > 128).  Returns the count of dead slots.
--
-- Output layout in @dead_out@ (must hold @2 * cap + 1@ elements):
--
-- @
-- dead_out[0]        = total occupied slots before tombstoning
-- dead_out[2i - 1]   = slot index of the i-th dead entry      (1 <= i <= count)
-- dead_out[2i]       = key word observed in that slot
-- @
foreign import ccall unsafe "purge_find_dead"
  c_purge_find_dead
    :: Exts.MutableByteArray# Exts.RealWorld -- keys
    -> Int                                    -- cap
    -> Exts.MutableByteArray# Exts.RealWorld  -- live set (sorted in place)
    -> Int                                    -- n_live
    -> Int                                    -- tombstone bit
    -> Int                                    -- mask selecting everything but the version bits
    -> Int                                    -- key_mask for stripping flag bits
    -> Exts.MutableByteArray# Exts.RealWorld  -- dead_out
    -> IO Int                                 -- count of dead slots


-- | Drop from a 'c_purge_find_dead' result every entry whose key is in a
-- second live set (sorted in place), compacting the array. Returns the
-- remaining count.
foreign import ccall unsafe "purge_filter_live"
  c_purge_filter_live
    :: Exts.MutableByteArray# Exts.RealWorld  -- dead_out (in/out)
    -> Int                                    -- n_dead
    -> Exts.MutableByteArray# Exts.RealWorld  -- live set (sorted in place)
    -> Int                                    -- n_live
    -> Int                                    -- key_mask
    -> IO Int                                 -- remaining count


-- | Tombstone slots belonging to threads that are no longer alive,
-- and shrink the table if the load factor drops below 25%.
--
-- Normally, slots are cleaned up by GC finalizers attached to the owning
-- 'ThreadId'. This function provides an eager alternative: it calls
-- 'GHC.Conc.listThreads', discards the entries that have already finished or
-- died (a 'listThreads' result keeps naming exited threads until a GC unlinks
-- their TSOs), and tombstones any slot whose key is not in what remains.
--
-- Internally builds a flat array of live thread IDs and passes it to a
-- C function that @qsort@s it, then batch-scans the key array using
-- SIMD (NEON / SSE2) linear search for small live sets or branchless
-- binary search (Khuong / Lemire CMOV style) for large ones.  A single
-- @unsafe ccall@ amortises FFI overhead across the full table scan.
--
-- A thread forked /after/ the thread list was taken but /before/ the scan
-- would otherwise look dead, so the candidates are re-checked against a
-- second 'listThreads' snapshot taken after the scan: a thread that
-- attached inside that window and is still running is kept. Tombstoning
-- (key + value slot) is then done on the Haskell side, by CAS from the key
-- observed during the scan, so a slot that has since been re-claimed is
-- never touched; this also maintains GC write barriers.
--
-- After tombstoning, if the number of remaining live entries is less
-- than 1\/4 of the table capacity (and the capacity exceeds the 16-slot
-- minimum), the table is rehashed to a smaller power-of-two size under
-- the resize 'MVar' lock.  This prevents unbounded memory use after
-- bursts of short-lived threads.
--
-- This is a best-effort operation: if a resize occurs concurrently, some
-- dead entries may survive in the new table until the next purge or GC.
--
-- @since base 4.18.0 (GHC 9.6)
{-# SPECIALIZE purgeDeadThreads :: ThreadStorageMap a -> IO () #-}
purgeDeadThreads :: (MonadIO m) => ThreadStorageMap a -> m ()
purgeDeadThreads (ThreadStorageMap tableRef resizeLock) = liftIO $ do
  Table cap keys# vals# dead <- readIORef tableRef
  tids <- listThreads
  (MutIntArray liveArr#, nLive) <- buildLiveSet tids
  deadArr@(MutIntArray deadArr#) <- newMutIntArray (2 * cap + 1)
  candidates <- c_purge_find_dead keys# cap liveArr# nLive tombstoneBit (Data.Bits.complement versionMask) keyMask deadArr#
  deadCount <-
    if candidates == 0
      then pure 0
      else do
        tids2 <- listThreads
        (MutIntArray live2#, nLive2) <- buildLiveSet tids2
        c_purge_filter_live deadArr# candidates live2# nLive2 keyMask
  let tomb !i
        | i > deadCount = pure ()
        | otherwise = do
            slot <- readMutInt deadArr (2 * i - 1)
            kScan <- readMutInt deadArr (2 * i)
            (kNow, ref) <- readSlot keys# vals# slot
            -- Only act if the slot still holds the key the scan saw; the
            -- CAS inside re-checks that atomically, and the paired ref is
            -- the one published for it.
            when (kNow == kScan) $
              void $ tombstoneSlot keys# vals# dead slot kScan ref
            tomb (i + 1)
  tomb 1
  occupied <- readMutInt deadArr 0
  let !liveInTable = occupied - deadCount
      !minCap = 16
      !targetCap = nextPow2 (max minCap (liveInTable * 4))
  when (targetCap < cap) $
    withMVar resizeLock $ \_ -> do
      Table curCap _ _ _ <- readIORef tableRef
      when (curCap == cap) $
        rehashTable tableRef cap targetCap
#endif
