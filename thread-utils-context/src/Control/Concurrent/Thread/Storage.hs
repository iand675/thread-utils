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
--     linear probe of the key array.
--
-- == Slot hashing
--
-- Slot assignment uses a Fibonacci\/golden-ratio multiplicative hash
-- (@tid * 0x9E3779B97F4A7C15@) rather than a simple bit-mask. This spreads
-- sequential thread IDs (GHC allocates them contiguously) across different
-- cache lines, eliminating false sharing on both the key and value arrays
-- under multi-core contention.
--
-- == Detach encoding
--
-- Thread IDs are 32-bit (@StgWord32@) but stored in 64-bit key slots.
-- Bit 32 serves as a "detached" flag. When a context is detached via
-- 'detach', the flag is set in the key array (a single atomic write to
-- unboxed memory — no GC write barrier, no card-table contention). The
-- value slot is left untouched so no 'MutableArray#' card is dirtied.
-- The CMM probe reports detach status via its return value, so the
-- Haskell hot path for 'lookup' and 'adjust' never checks the value
-- array for detached markers at all.
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
-- lookup is a single CMM call plus an 'IORef' dereference. Subsequent reads
-- and writes are plain 'IORef' operations with no hash-table probe at all.
-- Use this tier in instrumentation hot loops (e.g. tracing spans).
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
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits (countLeadingZeros, finiteBitSize, unsafeShiftL, (.&.), (.|.))
import Data.IORef
import Foreign.C.Types (CULLong (..))
import Foreign.Storable (sizeOf)
import GHC.Conc (getNumCapabilities, yield)
import GHC.Conc.Sync (ThreadId (..))
import GHC.Exts (Int (..), Int#, ThreadId#, isTrue#, unsafeCoerce#, (==#), (>=#))
import qualified GHC.Exts as Exts
import GHC.IO (IO (..))
import System.IO.Unsafe (unsafePerformIO)
#if MIN_VERSION_base(4,18,0)
import GHC.Conc (ThreadStatus (..), listThreads, threadStatus)
#endif
import Prelude hiding (lookup)


---------------------------------------------------------------------------
-- CMM primops
---------------------------------------------------------------------------

foreign import prim "stg_getCurrentThreadId"
  stg_getCurrentThreadId# :: Exts.State# Exts.RealWorld -> (# Exts.State# Exts.RealWorld, Int# #)


foreign import prim "stg_probeThreadSlot"
  stg_probeThreadSlot#
    :: Exts.MutableByteArray# Exts.RealWorld
    -> Int#
    -> Exts.State# Exts.RealWorld
    -> (# Exts.State# Exts.RealWorld, Int#, Int# #)


foreign import prim "stg_probeSlotByKey"
  stg_probeSlotByKey#
    :: Exts.MutableByteArray# Exts.RealWorld
    -> Int#
    -> Int#
    -> Exts.State# Exts.RealWorld
    -> (# Exts.State# Exts.RealWorld, Int# #)


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

tombstone :: Int
tombstone = minBound


-- | Sentinel for uninitialized value-array slots. A single global CAF so
-- that 'isSentinel' can detect it via pointer identity.  The value is
-- never read; only the pointer matters.
{-# NOINLINE sentinelRef #-}
sentinelRef :: IORef ()
sentinelRef = unsafePerformIO (newIORef ())


-- | Cast the sentinel to any @IORef a@ for use in value arrays.
toSentinel :: IORef a
toSentinel = unsafeCoerce# sentinelRef
{-# INLINE toSentinel #-}


-- | Pointer-identity check against the module-level sentinel.
--
-- 'Exts.reallyUnsafePtrEquality#' may return a false negative on GC
-- boundaries, but never a false positive. A false negative in 'growTable'
-- just causes one extra spin iteration, which is harmless.
isSentinel :: IORef a -> Bool
isSentinel ref = isTrue# (Exts.reallyUnsafePtrEquality# (unsafeCoerce# ref :: IORef ()) sentinelRef)
{-# INLINE isSentinel #-}


-- | Bit 32, set in a key slot to mark "detached by user".  Thread IDs
-- are 32-bit ('StgWord32'), so this bit is always free.
detachedBit :: Int
detachedBit = 1 `unsafeShiftL` 32


-- | Mask to extract the raw thread ID from a key (strips detached bit).
keyMask :: Int
keyMask = detachedBit - 1


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
data Table a = Table
  {-# UNPACK #-} !Int -- capacity (power of 2)
  (Exts.MutableByteArray# Exts.RealWorld) -- keys: Int per slot
  (Exts.MutableArray# Exts.RealWorld (IORef a)) -- values: GC-traced


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


readVal :: Exts.MutableArray# Exts.RealWorld (IORef a) -> Int -> IO (IORef a)
readVal vals# (I# i#) = IO $ \s ->
  Exts.readArray# vals# i# s
{-# INLINE readVal #-}


writeVal :: Exts.MutableArray# Exts.RealWorld (IORef a) -> Int -> IORef a -> IO ()
writeVal vals# (I# i#) ref = IO $ \s ->
  case Exts.writeArray# vals# i# ref s of
    s' -> (# s', () #)
{-# INLINE writeVal #-}


-- | Linear probe that masks the detached bit when comparing keys.
probeFind :: Exts.MutableByteArray# Exts.RealWorld -> Exts.MutableArray# Exts.RealWorld (IORef a) -> Int -> Int -> Int -> IO (Maybe (Int, IORef a))
probeFind keys# vals# cap home key = go home 0
  where
    !mask = cap - 1
    go !slot !steps
      | steps >= cap = pure Nothing
      | otherwise = do
          k <- readKey keys# slot
          if (k .&. keyMask) == key
            then do
              ref <- readVal vals# slot
              pure $! Just (slot, ref)
            else if k == emptySlot
              then pure Nothing
              else go ((slot + 1) .&. mask) (steps + 1)
{-# INLINE probeFind #-}


---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

allocateTable :: Int -> IO (Table a)
allocateTable requested = IO $ \s0 ->
  let !cap = nextPow2 (max 16 requested)
      !(I# cap#) = cap
      !(I# bytes#) = cap * sizeOf (0 :: Int)
  in case Exts.newByteArray# bytes# s0 of
    (# s1, keys# #) ->
      case Exts.setByteArray# keys# 0# bytes# 0# s1 of
        s2 -> case Exts.newArray# cap# toSentinel s2 of
          (# s3, vals# #) ->
            (# s3, Table cap keys# vals# #)


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
  table <- allocateTable requested
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
-- multiplicative hash, and linearly probes the key array in a single
-- CMM call.  Returns @Nothing@ for both absent and detached entries
-- without touching the value array in the detached case.
lookup :: (MonadIO m) => ThreadStorageMap a -> m (Maybe a)
lookup (ThreadStorageMap tableRef _) = liftIO $ do
  Table _cap keys# vals# <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = _cap - 1
    in case stg_probeThreadSlot# keys# mask# s0 of
      (# s1, _tid#, slot# #)
        | isTrue# (slot# >=# 0#) ->
            case Exts.readArray# vals# slot# s1 of
              (# s2, ref #) ->
                case readIORef ref of { IO f -> case f s2 of
                  { (# s3, val #) -> (# s3, Just val #) }}
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
  Table cap keys# vals# <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = cap - 1
    in case stg_probeThreadSlot# keys# mask# s0 of
      (# s1, tid#, rawSlot# #)
        | isTrue# (rawSlot# >=# 0#) ->
            -- Hot path: attached
            case Exts.readArray# vals# rawSlot# s1 of
              (# s2, ref #) ->
                case readIORef ref of { IO readIt -> case readIt s2 of
                  { (# s3, old #) -> case f (Just old) of
                    (Just !new, !b) ->
                      case writeIORef ref new of { IO writeIt -> case writeIt s3 of
                        { (# s4, _ #) -> (# s4, b #) }}
                    (Nothing, !b) ->
                      case updateDetach tsm tableRef cap keys# (I# rawSlot#) (I# tid#) of
                        { IO t -> case t s3 of { (# s4, _ #) -> (# s4, b #) }}
                  }}
        | otherwise ->
            -- Not found or detached
            case f Nothing of
              (Nothing, !b) -> (# s1, b #)
              (Just !new, !b)
                | isTrue# (rawSlot# ==# Exts.negateInt# 1#) ->
                    case updateColdInsert tsm (I# tid#) new of
                      { IO ins -> case ins s1 of { (# s2, _ #) -> (# s2, b #) }}
                | otherwise ->
                    let slot# = Exts.negateInt# rawSlot# Exts.-# 2#
                    in case reattachSlot tsm tableRef cap keys# vals# (I# slot#) (I# tid#) new of
                      { IO re -> case re s1 of { (# s2, _ #) -> (# s2, b #) }}
{-# INLINE update #-}


-- Cold path: mark a slot as detached by ORing the detached bit into
-- the key.  Writes only to the key array (MutableByteArray#, no GC
-- write barrier) — the value slot is left untouched.
updateDetach
  :: ThreadStorageMap a
  -> IORef (Table a)
  -> Int
  -> Exts.MutableByteArray# Exts.RealWorld
  -> Int -> Int -> IO ()
updateDetach tsm tableRef cap keys# slot tidKey = do
  writeKey keys# slot (tidKey .|. detachedBit)
  Table cap' _ _ <- readIORef tableRef
  when (cap' /= cap) $ propagateDetach tsm tidKey
{-# NOINLINE updateDetach #-}


-- Cold path: create a new IORef in a detached slot. No finalizer is
-- registered because the original 'insertNew' already did so.
-- Writes the value BEFORE clearing the detached bit (release barrier
-- via writeKey) so concurrent readers see a consistent state.
reattachSlot
  :: ThreadStorageMap a
  -> IORef (Table a)
  -> Int
  -> Exts.MutableByteArray# Exts.RealWorld
  -> Exts.MutableArray# Exts.RealWorld (IORef a)
  -> Int -> Int -> a -> IO ()
reattachSlot tsm tableRef origCap keys# vals# slot tidKey new = do
  newRef <- newIORef new
  writeVal vals# slot newRef
  writeKey keys# slot tidKey
  Table cap' _ _ <- readIORef tableRef
  when (cap' /= origCap) $ propagateRef tsm tidKey newRef
{-# NOINLINE reattachSlot #-}


-- Propagate a detach marker to the current table after a concurrent resize.
propagateDetach :: ThreadStorageMap a -> Int -> IO ()
propagateDetach tsm@(ThreadStorageMap tableRef _) tidKey = do
  Table cap keys# vals# <- readIORef tableRef
  let !home = slotFor cap tidKey
  found <- probeFind keys# vals# cap home tidKey
  case found of
    Just (!slot, _) -> do
      writeKey keys# slot (tidKey .|. detachedBit)
      Table cap' _ _ <- readIORef tableRef
      when (cap' /= cap) $ propagateDetach tsm tidKey
    Nothing -> pure ()
{-# NOINLINE propagateDetach #-}


-- Propagate a re-attached IORef to the current table after a concurrent resize.
propagateRef :: ThreadStorageMap a -> Int -> IORef a -> IO ()
propagateRef tsm@(ThreadStorageMap tableRef _) tidKey ref = do
  Table cap keys# vals# <- readIORef tableRef
  let !home = slotFor cap tidKey
  found <- probeFind keys# vals# cap home tidKey
  case found of
    Just (!slot, _) -> do
      k <- readKey keys# slot
      when (k .&. detachedBit /= 0) $ do
        writeVal vals# slot ref
        writeKey keys# slot tidKey
        Table cap' _ _ <- readIORef tableRef
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
  Table _cap keys# vals# <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = _cap - 1
    in case stg_probeThreadSlot# keys# mask# s0 of
      (# s1, _tid#, slot# #)
        | isTrue# (slot# >=# 0#) ->
            case Exts.readArray# vals# slot# s1 of
              (# s2, ref #) ->
                case modifyIORef' ref f of { IO g -> g s2 }
        | otherwise -> (# s1, () #)
{-# INLINE adjust #-}


-- | Like 'adjust', but targets a specific thread.
adjustOnThread :: (MonadIO m) => ThreadStorageMap a -> ThreadId -> (a -> a) -> m ()
adjustOnThread (ThreadStorageMap tableRef _) tid f = liftIO $ do
  Table _cap keys# vals# <- readIORef tableRef
  let !(I# mask#) = _cap - 1
      !(I# tidKey#) = getThreadIdInt tid
  IO $ \s0 ->
    case stg_probeSlotByKey# keys# mask# tidKey# s0 of
      (# s1, slot# #)
        | isTrue# (slot# >=# 0#) ->
            case Exts.readArray# vals# slot# s1 of
              (# s2, ref #) ->
                case modifyIORef' ref f of { IO g -> g s2 }
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
  Table _cap keys# vals# <- readIORef tableRef
  let !(I# mask#) = _cap - 1
      !(I# tidKey#) = fromIntegral tidWord :: Int
  IO $ \s0 ->
    case stg_probeSlotByKey# keys# mask# tidKey# s0 of
      (# s1, slot# #)
        | isTrue# (slot# >=# 0#) ->
            case Exts.readArray# vals# slot# s1 of
              (# s2, ref #) ->
                case readIORef ref of { IO f -> case f s2 of
                  { (# s3, val #) -> (# s3, Just val #) }}
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
  Table cap keys# vals# <- readIORef tableRef
  let !(I# mask#) = cap - 1
  IO $ \s0 ->
    case stg_probeSlotByKey# keys# mask# tidKey# s0 of
      (# s1, rawSlot# #)
        | isTrue# (rawSlot# >=# 0#) ->
            -- Hot path: attached
            case Exts.readArray# vals# rawSlot# s1 of
              (# s2, ref #) ->
                case readIORef ref of { IO readIt -> case readIt s2 of
                  { (# s3, old #) -> case f (Just old) of
                    (Just !new, !b) ->
                      case writeIORef ref new of { IO writeIt -> case writeIt s3 of
                        { (# s4, _ #) -> (# s4, b #) }}
                    (Nothing, !b) ->
                      case updateDetach tsm tableRef cap keys# (I# rawSlot#) tidKey of
                        { IO t -> case t s3 of { (# s4, _ #) -> (# s4, b #) }}
                  }}
        | otherwise ->
            case f Nothing of
              (Nothing, !b) -> (# s1, b #)
              (Just !new, !b)
                | isTrue# (rawSlot# ==# Exts.negateInt# 1#) ->
                    case updateColdInsertTid tsm tid tidKey new of
                      { IO ins -> case ins s1 of { (# s2, _ #) -> (# s2, b #) }}
                | otherwise ->
                    let slot# = Exts.negateInt# rawSlot# Exts.-# 2#
                    in case reattachSlot tsm tableRef cap keys# vals# (I# slot#) tidKey new of
                      { IO re -> case re s1 of { (# s2, _ #) -> (# s2, b #) }}
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
  Table cap keys# vals# <- readIORef tableRef
  let !home = slotFor cap tidKey
  result <- probeFind keys# vals# cap home tidKey
  case result of
    Just (slot, ref) -> do
      k <- readKey keys# slot
      if k .&. detachedBit /= 0
        then do
          newRef <- newIORef def
          writeVal vals# slot newRef
          writeKey keys# slot tidKey
          Table cap' _ _ <- readIORef tableRef
          when (cap' /= cap) $ propagateRef tsm tidKey newRef
          pure newRef
        else pure ref
    Nothing -> insertNew tsm tid tidKey def
{-# INLINE ensureRef #-}


-- | Fused CMM fast path: get or create the 'IORef' for the /current/ thread.
--
-- Returns @(threadId, ref)@.
--
-- __Steady state__ (entry exists): read the table 'IORef', then a single
-- CMM call reads @CurrentTSO.id@ and linearly probes the key array, then
-- one @readArray#@ fetches the 'IORef'. No 'ThreadId' allocation, no FFI,
-- no 'Maybe' wrapper.
--
-- __First call per thread__: falls back to 'myThreadId', CAS-inserts a new
-- 'IORef' initialised to @def@, and registers a finalizer.
ensureRefFast :: ThreadStorageMap a -> a -> IO (Int, IORef a)
ensureRefFast tsm@(ThreadStorageMap tableRef _) def = do
  Table _cap keys# vals# <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = _cap - 1
    in case stg_probeThreadSlot# keys# mask# s0 of
      (# s1, tid#, rawSlot# #)
        | isTrue# (rawSlot# >=# 0#) ->
            case Exts.readArray# vals# rawSlot# s1 of
              (# s2, ref #) -> (# s2, (I# tid#, ref) #)
        | isTrue# (rawSlot# ==# Exts.negateInt# 1#) ->
            let IO slow = do
                  tid <- myThreadId
                  ref <- insertNew tsm tid (I# tid#) def
                  pure (I# tid#, ref)
            in slow s1
        | otherwise ->
            let slot# = Exts.negateInt# rawSlot# Exts.-# 2#
                IO slow = ensureRefReattach tsm tableRef _cap keys# vals# (I# slot#) (I# tid#) def
            in slow s1
{-# INLINE ensureRefFast #-}


ensureRefReattach
  :: ThreadStorageMap a -> IORef (Table a) -> Int
  -> Exts.MutableByteArray# Exts.RealWorld
  -> Exts.MutableArray# Exts.RealWorld (IORef a) -> Int -> Int -> a -> IO (Int, IORef a)
ensureRefReattach tsm tableRef origCap keys# vals# slot tidKey def = do
  newRef <- newIORef def
  writeVal vals# slot newRef
  writeKey keys# slot tidKey
  Table cap' _ _ <- readIORef tableRef
  when (cap' /= origCap) $ propagateRef tsm tidKey newRef
  pure (tidKey, newRef)
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
  Table _cap keys# vals# <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = _cap - 1
    in case stg_probeThreadSlot# keys# mask# s0 of
      (# s1, tid#, slot# #)
        | isTrue# (slot# >=# 0#) ->
            case Exts.readArray# vals# slot# s1 of
              (# s2, ref #) -> (# s2, (I# tid#, Just ref) #)
        | otherwise -> (# s1, (I# tid#, Nothing) #)
{-# INLINE lookupRefFast #-}


-- | Look up the 'IORef' for a thread by its numeric ID (Haskell-side probe).
--
-- Use this when you already have the numeric ID but not necessarily the
-- current thread's TSO (e.g. inspecting another thread's slot).
lookupRef :: ThreadStorageMap a -> Int -> IO (Maybe (IORef a))
lookupRef (ThreadStorageMap tableRef _) !tidKey = do
  Table cap keys# vals# <- readIORef tableRef
  result <- probeFind keys# vals# cap (slotFor cap tidKey) tidKey
  case result of
    Nothing -> Nothing <$ pure ()
    Just (slot, ref) -> do
      k <- readKey keys# slot
      pure $! if k .&. detachedBit /= 0 then Nothing else Just ref
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
        Table cap keys# vals# <- readIORef tableRef
        let !home = slotFor cap tidKey
        success <- claimSlot keys# vals# cap home tidKey ref
        if success
          then ensureCurrent
          else do
            withMVar resizeLock $ \_ -> do
              Table curCap _ _ <- readIORef tableRef
              when (curCap == cap) $ growTable tableRef cap
            go

      ensureCurrent = do
        Table cap keys# vals# <- readIORef tableRef
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
-- The key CAS must happen /before/ writing the value to avoid a race where
-- two threads targeting the same empty slot both write their IORef,
-- clobbering each other. Only the CAS winner writes the value.
--
-- After writing the value, a release-semantics re-write of the key
-- (@writeKey@, which uses @atomicWriteIntArray#@) ensures the value is
-- visible to any reader that acquires the key.
claimSlot :: Exts.MutableByteArray# Exts.RealWorld -> Exts.MutableArray# Exts.RealWorld (IORef a) -> Int -> Int -> Int -> IORef a -> IO Bool
claimSlot keys# vals# cap home key ref = go home 0
  where
    !mask = cap - 1
    go !slot !steps
      | steps >= cap = pure False
      | otherwise = do
          k <- readKey keys# slot
          if k == emptySlot || k == tombstone
            then do
              success <- casKey keys# slot k key
              if success
                then do
                  writeVal vals# slot ref
                  writeKey keys# slot key
                  pure True
                else go slot steps
            else if k == key
              then do
                writeVal vals# slot ref
                writeKey keys# slot key
                pure True
              else go ((slot + 1) .&. mask) (steps + 1)
{-# INLINE claimSlot #-}


-- | Copy live entries into a new table of the given capacity and publish it.
-- MUST be called while holding the resize 'MVar'. Uses plain 'writeIORef'
-- because the lock serializes all resize operations; no CAS needed.
-- Used for both growing (double capacity) and shrinking (after purge).
-- Keys are copied verbatim (including detached bit) so the detached
-- state survives resize.  Home slot computed from the raw thread ID.
rehashTable :: IORef (Table a) -> Int -> Int -> IO ()
rehashTable tableRef !oldCap !newCap = do
  Table _ oldKeys# oldVals# <- readIORef tableRef
  newTable@(Table _ newKeys# newVals#) <- allocateTable newCap
  let copyLoop !i
        | i >= oldCap = pure ()
        | otherwise = do
            k <- readKey oldKeys# i
            if k /= emptySlot && k /= tombstone
              then do
                oldRef <- readVal oldVals# i
                if isSentinel oldRef
                  then do
                    yield
                    copyLoop i
                  else do
                    let !rawKey = k .&. keyMask
                        !home = slotFor newCap rawKey
                    _ <- claimSlot newKeys# newVals# newCap home k oldRef
                    copyLoop (i + 1)
              else copyLoop (i + 1)
  copyLoop 0
  writeIORef tableRef newTable


growTable :: IORef (Table a) -> Int -> IO ()
growTable tableRef !oldCap = rehashTable tableRef oldCap (oldCap * 2)


-- | Tombstone an entry by key in the current table. Clears the value
-- slot so the 'IORef' (and its payload) become eligible for GC
-- immediately rather than lingering until the next resize.
-- Retries if a resize occurred between the probe and the tombstone.
removeEntry :: ThreadStorageMap a -> Int -> IO ()
removeEntry tsm@(ThreadStorageMap tableRef _) !tidKey = do
  Table cap keys# vals# <- readIORef tableRef
  let !home = slotFor cap tidKey
  result <- probeFind keys# vals# cap home tidKey
  case result of
    Nothing -> pure ()
    Just (!slot, _) -> do
      writeVal vals# slot toSentinel
      writeKey keys# slot tombstone
      Table cap' _ _ <- readIORef tableRef
      when (cap' /= cap) $ removeEntry tsm tidKey


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
  Table cap keys# vals# <- readIORef tableRef
  go keys# vals# cap 0 []
  where
    go keys# vals# cap !i !acc
      | i >= cap = pure (reverse acc)
      | otherwise = do
          k <- readKey keys# i
          if k /= emptySlot && k /= tombstone && k .&. detachedBit == 0
            then do
              ref <- readVal vals# i
              if isSentinel ref
                then go keys# vals# cap (i + 1) acc
                else do
                  v <- readIORef ref
                  go keys# vals# cap (i + 1) ((k, v) : acc)
            else go keys# vals# cap (i + 1) acc


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
-- The array is left unsorted; the C-side 'c_purge_find_dead' sorts it
-- in place via @qsort@ before scanning.
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
-- Output layout in @dead_out@ (must hold @cap + 1@ elements):
--
-- @
-- dead_out[0]          = total occupied slots before tombstoning
-- dead_out[1 .. count] = indices of dead slots
-- @
foreign import ccall unsafe "purge_find_dead"
  c_purge_find_dead
    :: Exts.MutableByteArray# Exts.RealWorld -- keys
    -> Int                                    -- cap
    -> Exts.MutableByteArray# Exts.RealWorld  -- live set (sorted in place)
    -> Int                                    -- n_live
    -> Int                                    -- tombstone value
    -> Int                                    -- key_mask for stripping detached bit
    -> Exts.MutableByteArray# Exts.RealWorld  -- dead_out
    -> IO Int                                 -- count of dead slots


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
-- Tombstoning (key + value slot) is done on the Haskell side to
-- maintain GC write barriers.
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
  Table cap keys# vals# <- readIORef tableRef
  tids <- listThreads
  (MutIntArray liveArr#, nLive) <- buildLiveSet tids
  deadArr@(MutIntArray deadArr#) <- newMutIntArray (cap + 1)
  deadCount <- c_purge_find_dead keys# cap liveArr# nLive tombstone keyMask deadArr#
  let tomb !i
        | i > deadCount = pure ()
        | otherwise = do
            slot <- readMutInt deadArr i
            writeVal vals# slot toSentinel
            writeKey keys# slot tombstone
            tomb (i + 1)
  tomb 1
  occupied <- readMutInt deadArr 0
  let !liveInTable = occupied - deadCount
      !minCap = 16
      !targetCap = nextPow2 (max minCap (liveInTable * 4))
  when (targetCap < cap) $
    withMVar resizeLock $ \_ -> do
      Table curCap _ _ <- readIORef tableRef
      when (curCap == cap) $
        rehashTable tableRef cap targetCap
#endif
