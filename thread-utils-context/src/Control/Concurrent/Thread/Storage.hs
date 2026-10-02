{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UnboxedSums #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE UnliftedFFITypes #-}

-- |
-- Thread-local storage for Haskell green threads.
--
-- Associates at most one value of type @a@ with each green thread in a
-- 'ThreadStorageMap'. A value is released by the garbage collector once
-- its owning thread is gone; no finalizer has to run.
--
-- == Implementation
--
-- Internally, a 'ThreadStorageMap' is a flat open-addressed hash table.
-- Keys (thread IDs) live in a 'MutableByteArray#' with per-slot atomic
-- CAS; values live in a GC-traced 'MutableArray#' of /cells/. A cell is a
-- weak pointer keyed on the owning thread whose value is the 'IORef''s
-- underlying 'MutVar#'. While the thread is alive the cell keeps the value
-- alive; once the thread's TSO is unreachable, the GC that notices it
-- drops the value, without any finalizer or extra pass. The slot itself is
-- reclaimed the next time the table is rehashed or 'purgeDeadThreads'
-- runs.
--
-- Reads and writes on the hot path go directly to the per-thread
-- 'MutVar#', with zero CAS and zero contention. CAS is only used when a
-- thread's entry is created, detached or re-attached, and during cleanup.
--
-- Two CMM primops avoid allocation and FFI overhead on the hot path:
--
--   * @stg_getCurrentThreadId@: reads @StgTSO_id(CurrentTSO)@ directly.
--   * @stg_probeThreadSlot@: fuses thread-ID retrieval with a multiplicative-hash
--     linear probe of the key array and a read of the slot's cell.
--
-- == Slot hashing
--
-- Slot assignment uses a Fibonacci\/golden-ratio multiplicative hash
-- (@tid * 0x9E3779B97F4A7C15@) rather than a simple bit-mask. This spreads
-- sequential thread IDs (GHC allocates them contiguously) across different
-- cache lines, eliminating false sharing on both the key and cell arrays
-- under multi-core contention.
--
-- == Key encoding and slot ownership
--
-- Each key slot is 64 bits on every target. The top four bits are flags;
-- the low 60 hold the thread ID (see 'keyMask'). GHC's thread IDs are a
-- 64-bit counter, so in practice they are stored in full.
--
-- * Bit 63, /tombstone/: the whole key word once the slot's entry is
--   removed. Tombstones are never reused in place; only a rehash reclaims
--   them.
--
-- * Bit 62, /claiming/: set while a thread is in the middle of writing a
--   slot. Every write that changes a slot's cell or re-attaches it is
--   bracketed by a CAS of the key into the claiming state and a CAS back
--   to the published key. A slot is only claimed from a state with no
--   attached value, so probes read a claim in flight as a miss and never
--   wait; a writer that meets one yields until it finishes.
--
-- * Bit 61, /detached/: set by 'detach'. The cell is left untouched so no
--   'MutableArray#' card is dirtied; the CMM probe reports the state via
--   its return value, so 'lookup' and 'adjust' never consult the cell
--   array for detached slots.
--
-- * Bit 60, /frozen/: set on every slot of a table being rehashed. No
--   writer CASes from a frozen word, so a frozen table never changes again
--   and the copy cannot miss a write; a writer that meets a frozen slot
--   waits for the rehash and retries on the new table.
--
-- Within one table, a slot's thread ID never changes once it is claimed.
-- A reader that sees a thread's key (with an acquire load) therefore
-- finds one of that thread's own cells or a dead one in the cell slot,
-- never another thread's, and needs no retry loop. A live cell is never
-- killed while its key is still in place, so a dead cell under an
-- unchanged key means the thread is gone.
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
-- * Each thread's entry has one 'IORef' for its whole life in the map. A
--   value may be removed via 'detach' at any time; the key is marked with
--   a "detached" bit and the 'IORef' is kept, so a later 'attach' writes
--   into the same 'IORef' and allocates nothing.
-- * Once a thread's TSO is unreachable, the GC drops the value. The slot is
--   reclaimed at the next rehash (which an insert into a full table
--   triggers) or by 'purgeDeadThreads'. Both also drop the entry of a
--   thread that has finished but whose 'ThreadId' is still referenced, so
--   the @…OnThread@ functions stop finding a finished thread's value at
--   some point after it finishes.
-- * When a 'ThreadStorageMap' itself becomes unreachable, a finalizer
--   releases the values it still holds for threads that are alive.
--
-- == Concurrency contract
--
-- Every thread may freely operate on its /own/ entry. The @…OnThread@ and
-- raw APIs additionally let a thread operate on another thread's entry;
-- that is safe against the owner's reads and against cleanup, but two
-- threads concurrently /writing/ the same key are not serialized
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
  purgeDeadThreads,
) where

import Control.Concurrent (MVar, ThreadId, myThreadId, newMVar, readMVar, withMVar, yield)
import Control.Monad (void, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Bits (complement, countLeadingZeros, finiteBitSize, unsafeShiftL, (.&.), (.|.))
import Data.IORef
import Data.Word (Word64)
import Foreign.C.Types (CULLong (..))
import Foreign.Storable (sizeOf)
import GHC.Conc (getNumCapabilities)
import GHC.Conc.Sync (ThreadId (..))
import GHC.Exts (Int (..), Int#, Int64#, MutVar#, RealWorld, ThreadId#, Weak#, isTrue#, (==#), (>=#))
import qualified GHC.Exts as Exts
import GHC.Int (Int64 (..))
import GHC.IO (IO (..))
import GHC.IORef (IORef (..))
import GHC.STRef (STRef (..))
import Prelude hiding (lookup)

#include "MachDeps.h"


---------------------------------------------------------------------------
-- Cells
---------------------------------------------------------------------------

-- | A slot's value: a weak pointer keyed on the owning thread's TSO whose
-- value is the entry's 'MutVar#'. See the module header.
type Cell a = Weak# (MutVar# RealWorld a)

-- | A freshly made cell together with its 'MutVar#', so a writer can make
-- one before it claims a slot (nothing may allocate inside a claim).
data NewCell a = NewCell (Cell a) (MutVar# RealWorld a)

newCell :: ThreadId -> a -> IO (NewCell a)
newCell (ThreadId t#) val = IO $ \s0 ->
  case Exts.newMutVar# val s0 of
    (# s1, var #) -> case Exts.mkWeakNoFinalizer# t# var s1 of
      (# s2, cell #) -> (# s2, NewCell cell var #)
{-# INLINE newCell #-}

-- | Kill a cell so the RTS stops retaining it and its 'MutVar#'. Used for
-- cells that are removed from a table, or made and never published.
killCell :: Cell a -> IO ()
killCell cell = IO $ \s ->
  case Exts.finalizeWeak# cell s of
    (# s', _, _ #) -> (# s', () #)
{-# INLINE killCell #-}

-- | The 'MutVar#' behind a cell, if the cell is still alive.
cellVar :: Cell a -> IO (Maybe (IORef a))
cellVar cell = IO $ \s ->
  case Exts.deRefWeak# cell s of
    (# s', alive#, var #)
      | isTrue# (alive# ==# 1#) -> (# s', Just (toRef var) #)
      | otherwise -> (# s', Nothing #)
{-# INLINE cellVar #-}

toRef :: MutVar# RealWorld a -> IORef a
toRef var = IORef (STRef var)
{-# INLINE toRef #-}

-- | The cell that fills empty and tombstoned slots: already dead, so
-- every read of it is a miss.
newDeadCell :: IO (CellRef a)
newDeadCell = IO $ \s0 ->
  case Exts.newMutVar# (errorWithoutStackTrace "thread-utils-context: dead cell") s0 of
    (# s1, var #) -> case Exts.mkWeakNoFinalizer# var var s1 of
      (# s2, cell #) -> case Exts.finalizeWeak# cell s2 of
        (# s3, _, _ #) -> (# s3, CellRef cell #)


---------------------------------------------------------------------------
-- Slot probes
---------------------------------------------------------------------------

foreign import prim "stg_getCurrentThreadId"
  stg_getCurrentThreadId# :: Exts.State# RealWorld -> (# Exts.State# RealWorld, Int# #)


-- Keys are 64-bit on every target. On 64-bit targets the probes below are
-- CMM primops that read a key with one word-sized acquire load. 32-bit
-- targets have no such load for a 64-bit key, so they use the portable
-- Haskell probes further down, which read keys by CAS. Defining
-- THREAD_UTILS_PORTABLE_PROBES selects the portable probes on any target,
-- so that path can be tested on 64-bit hardware.
#if WORD_SIZE_IN_BITS < 64 || defined(THREAD_UTILS_PORTABLE_PROBES)
#define PORTABLE_PROBES 1
#endif


#if !defined(PORTABLE_PROBES)
-- | Read one slot's (key, cell). See the CMM source for why a single pass
-- suffices.
foreign import prim "stg_readSlot"
  readSlot#
    :: Exts.MutableByteArray# RealWorld
    -> Exts.MutableArray# RealWorld (Cell a)
    -> Int#
    -> Exts.State# RealWorld
    -> (# Exts.State# RealWorld, Int64#, Cell a #)


-- | Probe for the current thread. Returns @(tid, slot, key, var)@: @tid@
-- is the current thread's key (see 'toKey'), @key@ is the key word
-- observed at the matching slot (callers CAS against it), and @var@ is
-- the entry's 'MutVar#' when an entry was found (@slot >= 0@ attached,
-- @slot <= -2@ detached), its cell being alive. A slot mid-claim reads as
-- a miss (see the CMM source); the probe never waits.
foreign import prim "stg_probeThreadSlot"
  probeThreadSlot#
    :: Exts.MutableByteArray# RealWorld
    -> Exts.MutableArray# RealWorld (Cell a)
    -> Int#
    -> Exts.State# RealWorld
    -> (# Exts.State# RealWorld, Int64#, Int#, Int64#, MutVar# RealWorld a #)


-- | Probe for an explicit key. Same return encoding as above, minus the tid.
foreign import prim "stg_probeSlotByKey"
  probeSlotByKey#
    :: Exts.MutableByteArray# RealWorld
    -> Exts.MutableArray# RealWorld (Cell a)
    -> Int#
    -> Int64#
    -> Exts.State# RealWorld
    -> (# Exts.State# RealWorld, Int#, Int64#, MutVar# RealWorld a #)


#else

-- | Portable 'readSlot#': the CAS in 'readKey' is a full barrier, so the
-- cell read after it is at least as new as the key.
readSlot#
  :: Exts.MutableByteArray# RealWorld
  -> Exts.MutableArray# RealWorld (Cell a)
  -> Int#
  -> Exts.State# RealWorld
  -> (# Exts.State# RealWorld, Int64#, Cell a #)
readSlot# keys# cells# i# s0 = case readKey keys# (I# i#) of
  IO readIt -> case readIt s0 of
    (# s1, I64# k# #) -> case Exts.readArray# cells# i# s1 of
      (# s2, cell #) -> (# s2, k#, cell #)


-- | Portable 'probeThreadSlot#'. Reads the current thread's full 64-bit ID
-- through 'myThreadId#' and @rts_getThreadId@.
probeThreadSlot#
  :: Exts.MutableByteArray# RealWorld
  -> Exts.MutableArray# RealWorld (Cell a)
  -> Int#
  -> Exts.State# RealWorld
  -> (# Exts.State# RealWorld, Int64#, Int#, Int64#, MutVar# RealWorld a #)
probeThreadSlot# keys# cells# mask# s0 = case Exts.myThreadId# s0 of
  (# s1, t# #) ->
    let !(I64# tid#) = toKey (fromIntegral (c_getThreadId t#))
    in case probeSlotByKey# keys# cells# mask# tid# s1 of
      (# s2, slot#, key#, var #) -> (# s2, tid#, slot#, key#, var #)


-- | Portable 'probeSlotByKey#', with the same encoding and the same
-- handling of dead cells as the CMM probe.
probeSlotByKey#
  :: forall a. Exts.MutableByteArray# RealWorld
  -> Exts.MutableArray# RealWorld (Cell a)
  -> Int#
  -> Int64#
  -> Exts.State# RealWorld
  -> (# Exts.State# RealWorld, Int#, Int64#, MutVar# RealWorld a #)
probeSlotByKey# keys# cells# mask# tid# s0 = go home s0
  where
    !mask = I# mask#
    !tid = I64# tid#
    !home = slotFor (mask + 1) tid
    -- Like the CMM probe, misses return the key array as a don't-care
    -- placeholder; callers never use it.
    placeholder :: MutVar# RealWorld a
    placeholder = Exts.unsafeCoerce# keys#
    miss :: Exts.State# RealWorld -> (# Exts.State# RealWorld, Int#, Int64#, MutVar# RealWorld a #)
    miss s = (# s, -1#, Exts.intToInt64# 0#, placeholder #)
    go :: Int -> Exts.State# RealWorld -> (# Exts.State# RealWorld, Int#, Int64#, MutVar# RealWorld a #)
    go !slot s = case readKey keys# slot of
      IO readIt -> case readIt s of
        (# s1, k@(I64# k#) #)
          | k .&. keyMask == tid ->
              if k .&. claimingBit /= 0
                then miss s1
                else let !(I# i#) = slot in case Exts.readArray# cells# i# s1 of
                  (# s2, cell #) -> case Exts.deRefWeak# cell s2 of
                    (# s3, alive#, var #)
                      | isTrue# (alive# ==# 1#) ->
                          if k .&. detachedBit /= 0
                            then let !(I# r#) = negate slot - 2 in (# s3, r#, k#, var #)
                            else (# s3, i#, k#, var #)
                      | otherwise -> case readKey keys# slot of
                          IO again -> case again s3 of
                            (# s4, k' #)
                              | k' /= k -> go slot s4
                              | otherwise -> miss s4
          | k == emptySlot || k == frozenBit -> miss s1
          | otherwise ->
              let !next = (slot + 1) .&. mask
              in if next == home then miss s1 else go next s1

#endif


---------------------------------------------------------------------------
-- Thread ID extraction
---------------------------------------------------------------------------

-- | Read the current green thread's numeric ID directly from @CurrentTSO@.
--
-- This is implemented as a CMM primop, so no 'ThreadId' box is allocated and
-- no FFI call is made. Prefer this over @'getThreadId' =<< 'myThreadId'@
-- whenever you do not need the 'ThreadId' value itself.
--
-- GHC's thread IDs are 64-bit. On 32-bit targets this returns the low 32
-- bits, as do 'getThreadId', 'ensureRefFast' and 'lookupRefFast'; an API
-- taking such an ID ('lookupRaw', 'updateRaw', 'ensureRef', 'lookupRef')
-- then names a different entry from the thread's own once IDs pass 2^32.
-- The 'ThreadId'-taking and current-thread functions always use the full ID.
getCurrentThreadId :: IO Int
getCurrentThreadId = IO $ \s ->
  case stg_getCurrentThreadId# s of
    (# s', tid# #) -> (# s', I# tid# #)
{-# INLINE getCurrentThreadId #-}


-- | @rts_getThreadId@ takes the TSO pointer behind a 'ThreadId'.
--
-- The argument MUST be declared as 'ThreadId#' rather than coerced to
-- 'Exts.Addr#'. A 'ThreadId#' is an ordinary movable heap pointer: GHC's
-- generational collector relocates TSOs when it promotes them. Declaring
-- it as 'ThreadId#' keeps it in a pointer slot, so the collector traces
-- and updates it, and (because the call is @unsafe@) no GC can run
-- between the argument being read and the callee dereferencing it.
--
-- Coercing to 'Exts.Addr#' launders the pointer into a non-pointer slot
-- that the collector neither traces nor updates. If a GC lands while the
-- laundered word is live, the callee dereferences a stale TSO address and
-- the process segfaults. This is the same signature @base@ uses in
-- "GHC.Conc.Sync".
foreign import ccall unsafe "rts_getThreadId" c_getThreadId :: ThreadId# -> CULLong


-- | Extract the numeric thread ID from an existing 'ThreadId'.
--
-- This makes a cheap FFI call to @rts_getThreadId@. When you already hold a
-- 'ThreadId' and need its numeric form for 'lookupRaw' or 'updateRaw', use
-- this. Otherwise prefer 'getCurrentThreadId'. Truncated to 32 bits on
-- 32-bit targets; see 'getCurrentThreadId'.
getThreadId :: ThreadId -> Word
getThreadId (ThreadId tid#) = fromIntegral (c_getThreadId tid#)
{-# INLINE getThreadId #-}


-- | A thread's full ID in the form stored in key slots (see 'toKey').
threadKey :: ThreadId -> Key
threadKey (ThreadId tid#) = toKey (fromIntegral (c_getThreadId tid#))
{-# INLINE threadKey #-}


---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

-- | A key slot's contents: 64 bits on every target, so a thread ID is never
-- truncated however many threads the process has forked.
type Key = Int64


-- | GHC allocates TSO IDs starting from 1 (@next_thread_id = 1@ in
-- @rts\/Threads.c@), so 0 is safe as the empty-slot sentinel.
emptySlot :: Key
emptySlot = 0


-- | Bit 63 marks a tombstoned slot; the whole key is exactly this (plus
-- 'frozenBit' once its table is being rehashed).
tombstoneBit :: Key
tombstoneBit = minBound


-- | Bit 62, set in a key slot while a writer is between the key CAS and
-- the publish. Probes for that thread wait it out, so the half-written
-- slot is never observable. See 'claimAndPublish'.
claimingBit :: Key
claimingBit = 1 `unsafeShiftL` 62


-- | Bit 61, set in a key slot to mark "detached by user".
detachedBit :: Key
detachedBit = 1 `unsafeShiftL` 61


-- | Bit 60, set on every slot of a table that is being rehashed.
frozenBit :: Key
frozenBit = 1 `unsafeShiftL` 60


-- | Mask to extract the thread ID from a key (strips the flag bits): the
-- 60 bits below the flags. GHC's thread IDs are a 64-bit counter starting
-- at 1; reaching 2^60 would take 36 years at a billion forks per second.
keyMask :: Key
keyMask = frozenBit - 1


-- | A thread ID in the form stored in key slots: the identity for every ID
-- below 2^60.
toKey :: Int64 -> Key
toKey tid = tid .&. keyMask
{-# INLINE toKey #-}


-- | The key for an ID passed in through the 'Word' or 'Int' API.
wordKey :: Word -> Key
wordKey = toKey . fromIntegral
{-# INLINE wordKey #-}


intKey :: Int -> Key
intKey = toKey . fromIntegral
{-# INLINE intKey #-}


-- | A key's thread ID as the 'Int' the public API hands out (truncated on
-- 32-bit targets).
keyInt :: Key -> Int
keyInt = fromIntegral
{-# INLINE keyInt #-}


-- | Does this key word hold an entry (attached or detached, frozen or not)?
-- Thread IDs start at 1, so empty and tombstoned words have no ID bits.
hasEntry :: Key -> Bool
hasEntry k = k .&. keyMask /= 0
{-# INLINE hasEntry #-}


-- | Fibonacci / golden-ratio multiplicative hash salt: @2^w / phi@,
-- truncated, for the word size @w@. Interpreted as signed 'Int' but the
-- multiplication wraps modulo @2^w@ regardless of sign. Must match
-- @HASH_SALT@ in @cbits/threadId.cmm@. Only the low word of a key is
-- hashed, so on 32-bit targets IDs @2^32@ apart share a probe chain; they
-- are still told apart by the full key comparison.
hashSalt :: Int
hashSalt
  | finiteBitSize (0 :: Int) == 64 = fromIntegral (0x9E3779B97F4A7C15 :: Word64)
  | otherwise = fromIntegral (0x9E3779B9 :: Word64)


nextPow2 :: Int -> Int
nextPow2 n
  | n <= 1 = 1
  | otherwise = 1 `unsafeShiftL` (finiteBitSize n - countLeadingZeros (n - 1))
{-# INLINE nextPow2 #-}


---------------------------------------------------------------------------
-- Data types
---------------------------------------------------------------------------

-- | The raw hash table arrays. Replaced as a whole on rehash.
--
-- The key array holds @capacity + 1@ elements: one per slot, then the
-- count of slots ever claimed from empty (see 'readUsed'). The last field
-- is this map's dead cell, which fills every cell slot whose key is empty
-- or tombstoned.
data Table a = Table
  {-# UNPACK #-} !Int -- capacity (power of 2)
  (Exts.MutableByteArray# RealWorld) -- keys: one 64-bit 'Key' per slot
  (Exts.MutableArray# RealWorld (Cell a)) -- cells: GC-traced
  (Cell a) -- dead cell


-- | A concurrent map from green-thread IDs to values of type @a@.
--
-- Each thread may have at most one associated value. The table starts at
-- an initial capacity (see 'newThreadStorageMap', 'newThreadStorageMapWith')
-- and is rehashed when three quarters of its slots are used. Rehashes are
-- serialized by an internal 'MVar' lock; other threads that need to write
-- a slot of a table being rehashed wait on the lock and retry afterwards.
--
-- All read paths and ref-based hot-path operations are entirely lock-free.
data ThreadStorageMap a = ThreadStorageMap
  !(IORef (Table a))  -- current table (read-hot, lock-free)
  !(MVar ())          -- held for a whole rehash, from first freeze to publish


---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- | Has a rehash published a different table since @keys#@ was read from
-- the map? Compares array identity rather than capacity, because a rehash
-- that only clears tombstones keeps the capacity.
tableMoved :: IORef (Table a) -> Exts.MutableByteArray# RealWorld -> IO Bool
tableMoved tableRef keys# = do
  Table _ keys'# _ _ <- readIORef tableRef
  pure $! not (isTrue# (Exts.sameMutableByteArray# keys# keys'#))
{-# INLINE tableMoved #-}


-- | Wait for the rehash that froze a slot we tried to write. The rehasher
-- holds the lock from its first freeze until the new table is published,
-- so once the lock is full again the current table is the new one.
-- 'readMVar' wakes every waiter at once; taking the lock in turn would
-- hand it from one blocked writer to the next.
awaitRehash :: ThreadStorageMap a -> IO ()
awaitRehash (ThreadStorageMap _ lock) = () <$ readMVar lock


-- | Home slot for a key. Hashes the key's low word, matching the CMM probes.
slotFor :: Int -> Key -> Int
slotFor cap tid = (fromIntegral tid * hashSalt) .&. (cap - 1)
{-# INLINE slotFor #-}


-- | Acquire-read a key. 32-bit targets have no 64-bit atomic read on byte
-- arrays, so with the portable probes it is a CAS that cannot change the
-- slot (it replaces 0 with 0); that is also a full barrier.
readKey :: Exts.MutableByteArray# RealWorld -> Int -> IO Key
#if !defined(PORTABLE_PROBES)
readKey keys# (I# i#) = IO $ \s ->
  case Exts.atomicReadIntArray# keys# i# s of
    (# s', v# #) -> (# s', I64# (Exts.intToInt64# v#) #)
#else
readKey keys# (I# i#) = IO $ \s ->
  let !(I64# zero#) = 0
  in case Exts.casInt64Array# keys# i# zero# zero# s of
    (# s', v# #) -> (# s', I64# v# #)
#endif
{-# INLINE readKey #-}


casKey :: Exts.MutableByteArray# RealWorld -> Int -> Key -> Key -> IO Bool
casKey keys# (I# i#) expected@(I64# expected#) (I64# new#) = IO $ \s ->
  case Exts.casInt64Array# keys# i# expected# new# s of
    (# s', old# #) -> (# s', I64# old# == expected #)
{-# INLINE casKey #-}


-- | CAS a key on behalf of a writer: never succeeds from a frozen word, so
-- a slot cannot change after a rehash has copied it.
casLive :: Exts.MutableByteArray# RealWorld -> Int -> Key -> Key -> IO Bool
casLive keys# slot observed new
  | observed .&. frozenBit /= 0 = pure False
  | otherwise = casKey keys# slot observed new
{-# INLINE casLive #-}


-- | Plain key write, for a table no other thread can see yet.
writeKeyPrivate :: Exts.MutableByteArray# RealWorld -> Int -> Key -> IO ()
writeKeyPrivate keys# (I# i#) (I64# v#) = IO $ \s ->
  case Exts.writeInt64Array# keys# i# v# s of
    s' -> (# s', () #)
{-# INLINE writeKeyPrivate #-}


-- | Release a slot this thread holds claimed, writing @new@. No other
-- writer CASes from a claiming key (they wait, or skip the slot), so on
-- 64-bit targets an atomic store does: it is ordered after the writes made
-- under the claim, and saves a CAS. 32-bit targets have no 64-bit atomic
-- store primop, so they CAS from the claimed word, which cannot fail.
publishKey :: Exts.MutableByteArray# RealWorld -> Int -> Key -> Key -> IO ()
#if !defined(PORTABLE_PROBES)
publishKey keys# (I# i#) _claimed (I64# v#) = IO $ \s ->
  case Exts.atomicWriteIntArray# keys# i# (Exts.int64ToInt# v#) s of
    s' -> (# s', () #)
#else
publishKey keys# slot claimed new = void (casKey keys# slot claimed new)
#endif
{-# INLINE publishKey #-}


-- | A cell in a box, for code that passes it around in 'IO'.
data CellRef a = CellRef (Cell a)

readCellRef :: Exts.MutableArray# RealWorld (Cell a) -> Int -> IO (CellRef a)
readCellRef cells# (I# i#) = IO $ \s ->
  case Exts.readArray# cells# i# s of
    (# s', cell #) -> (# s', CellRef cell #)
{-# INLINE readCellRef #-}


writeCell :: Exts.MutableArray# RealWorld (Cell a) -> Int -> Cell a -> IO ()
writeCell cells# (I# i#) cell = IO $ \s ->
  case Exts.writeArray# cells# i# cell s of
    s' -> (# s', () #)
{-# INLINE writeCell #-}


-- | Pointer compare-and-swap on a cell slot. Succeeds only if the slot
-- still holds exactly @expected@.
casCell :: Exts.MutableArray# RealWorld (Cell a) -> Int -> Cell a -> Cell a -> IO Bool
casCell cells# (I# i#) expected new = IO $ \s ->
  case Exts.casArray# cells# i# expected new s of
    (# s', failed#, _ #) -> (# s', isTrue# (failed# ==# 0#) #)
{-# INLINE casCell #-}


-- | Read a slot's (key, cell) pair. See the note in the CMM source for
-- why no retry is needed.
readSlot :: Exts.MutableByteArray# RealWorld -> Exts.MutableArray# RealWorld (Cell a) -> Int -> IO (Key, CellRef a)
readSlot keys# cells# (I# i#) = IO $ \s ->
  case readSlot# keys# cells# i# s of
    (# s', k#, cell #) -> (# s', (I64# k#, CellRef cell) #)
{-# INLINE readSlot #-}


-- | Linear probe that masks the flag bits when comparing keys, waiting out
-- an in-flight claim on @key@'s slot.
--
-- Returns the slot and the key word /as observed/ (callers CAS against
-- it), as an unboxed sum so a hit allocates nothing.
probeFind
  :: Exts.MutableByteArray# RealWorld -> Int -> Key
  -> Exts.State# RealWorld -> (# Exts.State# RealWorld, (# (# #) | (# Int#, Int64# #) #) #)
probeFind keys# cap key = go (slotFor cap key) 0
  where
    !mask = cap - 1
    go !slot !steps s0
      | steps >= cap = (# s0, (# (# #) | #) #)
      | otherwise = case readKey keys# slot of
          IO readIt -> case readIt s0 of
            (# s1, k@(I64# k#) #)
              | (k .&. keyMask) == key ->
                  if k .&. claimingBit /= 0
                    then go slot steps (Exts.yield# s1)
                    else let !(I# i#) = slot in (# s1, (# | (# i#, k# #) #) #)
              | k == emptySlot || k == frozenBit -> (# s1, (# (# #) | #) #)
              | otherwise -> go ((slot + 1) .&. mask) (steps + 1) s1
{-# INLINE probeFind #-}


-- | Take exclusive ownership of @slot@, run @write@, and publish @key@.
--
-- This is the /only/ way a slot's cell or attached state changes. The CAS
-- from @observed@ to the claiming state fails if anything changed the key
-- since the caller looked at it (a tombstone, a competing claim, a
-- freeze), in which case nothing is written and the caller re-reads. While
-- the claiming bit is set, probes for the key wait, so readers see either
-- the previous state or the fully published new one. @write@ must not
-- allocate, so that the window has no safepoint and the wait stays short;
-- every caller passes a primop write. It reports whether it took effect,
-- so a caller can make its write conditional on the cell it inspected
-- before claiming (a claim and publish can restore the very same key
-- word, so the key alone does not prove nothing changed).
--
-- The publish is a store over the claiming state we own ('publishKey'):
-- nothing else CASes from a claiming key, and the store orders @write@
-- before the key. It publishes @key@'s tid and detached bits if the write
-- took effect, and restores @observed@ if it did not.
claimAndPublish :: Exts.MutableByteArray# RealWorld -> Int -> Key -> Key -> IO Bool -> IO Claim
claimAndPublish keys# slot observed key write = do
  let !published = key .&. (keyMask .|. detachedBit)
      !claimed = published .|. claimingBit
  ok <- casLive keys# slot observed claimed
  if not ok
    then pure NotClaimed
    else do
      wrote <- write
      publishKey keys# slot claimed (if wrote then published else observed)
      pure $! if wrote then Wrote else Declined
{-# INLINE claimAndPublish #-}


data Claim = NotClaimed | Wrote | Declined


---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

-- | The key array holds @cap + 1@ elements: one per slot, then the count
-- of used slots (see 'readUsed'). Everything starts at zero.
allocateTable :: Cell a -> Int -> IO (Table a)
allocateTable dead requested = IO $ \s0 ->
  let !cap = nextPow2 (max 16 requested)
      !(I# cap#) = cap
      !(I# bytes#) = (cap + 1) * sizeOf (0 :: Key)
  in case Exts.newByteArray# bytes# s0 of
    (# s1, keys# #) ->
      case Exts.setByteArray# keys# 0# bytes# 0# s1 of
        s2 -> case Exts.newArray# cap# dead s2 of
          (# s3, cells# #) ->
            (# s3, Table cap keys# cells# dead #)


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
-- The table is rehashed once three quarters of its slots are used,
-- tombstones included; the rehash drops dead threads' slots and doubles
-- the capacity only if more than half the slots are still live.
newThreadStorageMapWith :: (MonadIO m) => Int -> m (ThreadStorageMap a)
newThreadStorageMapWith requested = liftIO $ do
  CellRef dead <- newDeadCell
  table <- allocateTable dead requested
  ref <- newIORef table
  lock <- newMVar ()
  -- Cells of threads that outlive the map would otherwise keep their
  -- values until those threads die. The finalizer only refers to the map
  -- through the weak pointer's key, so it does not keep the map alive.
  _ <- mkWeakIORef ref (readIORef ref >>= releaseAll)
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
-- multiplicative hash, linearly probes the key array and reads the slot's
-- cell in a single CMM call.  Returns @Nothing@ for both absent and
-- detached entries without touching the cell array in the detached case.
lookup :: (MonadIO m) => ThreadStorageMap a -> m (Maybe a)
lookup (ThreadStorageMap tableRef _) = liftIO $ do
  Table cap keys# cells# _ <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = cap - 1
    in case probeThreadSlot# keys# cells# mask# s0 of
      (# s1, _, slot#, _, var #)
        | isTrue# (slot# >=# 0#) -> case Exts.readMutVar# var s1 of
            (# s2, val #) -> (# s2, Just val #)
        | otherwise -> (# s1, Nothing #)
{-# INLINE lookup #-}


-- | Retrieve the value associated with a specific thread.
lookupOnThread :: (MonadIO m) => ThreadStorageMap a -> ThreadId -> m (Maybe a)
lookupOnThread tsm tid = liftIO $ lookupKey tsm (threadKey tid)
{-# INLINE lookupOnThread #-}


-- | Associate a value with the current thread, replacing any previous value.
--
-- Returns the previous value, or 'Nothing' if the thread had no entry.
--
-- On the hot path (value already attached), no 'ThreadId' is allocated and
-- no FFI call is made. 'myThreadId' is only called on the cold path that
-- creates or re-attaches the entry.
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
-- unboxed memory with no GC write barrier) so a later 'attach' can reuse
-- the entry's 'IORef'.
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
-- Uses the fused CMM probe ('probeThreadSlot#').  The probe reports
-- attached\/detached\/absent via its return encoding, so the hot path
-- (attached, updating the value) is a read and a write of the entry's
-- 'MutVar#'.
--
-- @
-- -- Increment a counter, inserting 1 if absent:
-- update tsm (\\old -> (Just (maybe 1 (+1) old), ()))
-- @
update :: (MonadIO m) => ThreadStorageMap a -> (Maybe a -> (Maybe a, b)) -> m b
update tsm@(ThreadStorageMap tableRef _) f = liftIO $ do
  Table cap keys# cells# _ <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = cap - 1
    in case probeThreadSlot# keys# cells# mask# s0 of
      (# s1, tid#, slot#, key#, var #)
        | isTrue# (slot# >=# 0#) -> case Exts.readMutVar# var s1 of
            (# s2, old #) -> case f (Just old) of
              (Just !new, !b) -> case Exts.writeMutVar# var new s2 of
                s3 -> (# s3, b #)
              (Nothing, !b) ->
                case detachAt tsm keys# (I# slot#) (I64# key#) (I64# tid#) of
                  { IO d -> case d s2 of { (# s3, _ #) -> (# s3, b #) }}
        | otherwise -> case f Nothing of
            (Nothing, !b) -> (# s1, b #)
            (Just !new, !b) ->
              case setCurrent tsm (I64# tid#) new of
                { IO g -> case g s1 of { (# s2, _ #) -> (# s2, b #) }}
{-# INLINE update #-}


-- | Like 'update', but targets a specific thread.
--
-- This is the most general function in the high-level API.
-- 'attachOnThread' and 'detachFromThread' are implemented in terms of this.
updateOnThread :: (MonadIO m) => ThreadStorageMap a -> ThreadId -> (Maybe a -> (Maybe a, b)) -> m b
updateOnThread tsm tid f = liftIO $ updateKey tsm tid (threadKey tid) f
{-# INLINE updateOnThread #-}


-- | Modify the value for the current thread in place if one is attached.
--
-- Does nothing if the thread has no entry or the entry is detached.
-- The modification is strict ('modifyIORef'').  Uses the fused CMM probe.
adjust :: (MonadIO m) => ThreadStorageMap a -> (a -> a) -> m ()
adjust (ThreadStorageMap tableRef _) f = liftIO $ do
  Table cap keys# cells# _ <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = cap - 1
    in case probeThreadSlot# keys# cells# mask# s0 of
      (# s1, _, slot#, _, var #)
        | isTrue# (slot# >=# 0#) -> case modifyIORef' (toRef var) f of IO g -> g s1
        | otherwise -> (# s1, () #)
{-# INLINE adjust #-}


-- | Like 'adjust', but targets a specific thread.
adjustOnThread :: (MonadIO m) => ThreadStorageMap a -> ThreadId -> (a -> a) -> m ()
adjustOnThread (ThreadStorageMap tableRef _) tid f = liftIO $ do
  Table cap keys# cells# _ <- readIORef tableRef
  let !(I# mask#) = cap - 1
      !(I64# tidKey#) = threadKey tid
  IO $ \s0 ->
    case probeSlotByKey# keys# cells# mask# tidKey# s0 of
      (# s1, slot#, _, var #)
        | isTrue# (slot# >=# 0#) -> case modifyIORef' (toRef var) f of IO g -> g s1
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
-- The 'ThreadId' is still required by 'updateRaw' because a new entry's
-- value lives exactly as long as that thread.


---------------------------------------------------------------------------
-- Raw API
---------------------------------------------------------------------------

-- | Retrieve a value using a pre-computed thread ID (from 'getThreadId').
--
-- Avoids the FFI call to @rts_getThreadId@ that 'lookupOnThread' would
-- make internally. Uses a CMM primop for the key-array probe.
lookupRaw :: (MonadIO m) => ThreadStorageMap a -> Word -> m (Maybe a)
lookupRaw tsm !tidWord = liftIO $ lookupKey tsm (wordKey tidWord)
{-# INLINE lookupRaw #-}


lookupKey :: ThreadStorageMap a -> Key -> IO (Maybe a)
lookupKey (ThreadStorageMap tableRef _) (I64# tidKey#) = do
  Table cap keys# cells# _ <- readIORef tableRef
  let !(I# mask#) = cap - 1
  IO $ \s0 ->
    case probeSlotByKey# keys# cells# mask# tidKey# s0 of
      (# s1, slot#, _, var #)
        | isTrue# (slot# >=# 0#) -> case Exts.readMutVar# var s1 of
            (# s2, val #) -> (# s2, Just val #)
        | otherwise -> (# s1, Nothing #)
{-# INLINE lookupKey #-}


-- | Generalized update using a pre-computed thread ID.
--
-- Behaves like 'updateOnThread' but skips the internal 'getThreadId' call.
-- The 'ThreadId' argument is still needed because a new entry's value
-- lives exactly as long as that thread.  Uses a CMM primop for the
-- key-array probe.
updateRaw :: (MonadIO m) => ThreadStorageMap a -> ThreadId -> Word -> (Maybe a -> (Maybe a, b)) -> m b
updateRaw tsm tid !tidWord f = liftIO $ updateKey tsm tid (wordKey tidWord) f
{-# INLINE updateRaw #-}


updateKey :: ThreadStorageMap a -> ThreadId -> Key -> (Maybe a -> (Maybe a, b)) -> IO b
updateKey tsm@(ThreadStorageMap tableRef _) tid !tidKey@(I64# tidKey#) f = do
  Table cap keys# cells# _ <- readIORef tableRef
  let !(I# mask#) = cap - 1
  IO $ \s0 ->
    case probeSlotByKey# keys# cells# mask# tidKey# s0 of
      (# s1, slot#, key#, var #)
        | isTrue# (slot# >=# 0#) -> case Exts.readMutVar# var s1 of
            (# s2, old #) -> case f (Just old) of
              (Just !new, !b) -> case Exts.writeMutVar# var new s2 of
                s3 -> (# s3, b #)
              (Nothing, !b) ->
                case detachAt tsm keys# (I# slot#) (I64# key#) tidKey of
                  { IO d -> case d s2 of { (# s3, _ #) -> (# s3, b #) }}
        | otherwise -> case f Nothing of
            (Nothing, !b) -> (# s1, b #)
            (Just !new, !b) ->
              case setEntry True tsm tid tidKey new of
                { IO g -> case g s1 of { (# s2, _ #) -> (# s2, b #) }}
{-# INLINE updateKey #-}


-- $ref-based
--
-- The fastest tier. On the hot path (thread already registered), the
-- operations below avoid the hash-table probe entirely by handing you the
-- per-thread 'IORef' directly. Subsequent reads and writes are plain
-- 'IORef' operations.
--
-- An entry keeps the same 'IORef' for as long as its thread lives in the
-- map: 'detach' leaves it in place and a later 'attach' or 'ensureRefFast'
-- writes into it.
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
-- If the thread already has an attached entry, returns its 'IORef'.
-- Otherwise attaches @def@, re-using a detached entry's 'IORef' if there
-- is one, and returns it.
--
-- The @Int@ argument is the numeric thread ID (e.g. from
-- 'getCurrentThreadId' or @fromIntegral . 'getThreadId'@); see
-- 'getCurrentThreadId' for its width on 32-bit targets.
ensureRef :: ThreadStorageMap a -> ThreadId -> Int -> a -> IO (IORef a)
ensureRef tsm@(ThreadStorageMap tableRef _) tid !tidArg def = do
  let !tidKey@(I64# tidKey#) = intKey tidArg
  Table cap keys# cells# _ <- readIORef tableRef
  let !(I# mask#) = cap - 1
  IO $ \s0 ->
    case probeSlotByKey# keys# cells# mask# tidKey# s0 of
      (# s1, slot#, _, var #)
        | isTrue# (slot# >=# 0#) -> (# s1, toRef var #)
        | otherwise -> case setEntry False tsm tid tidKey def of IO g -> g s1
{-# INLINE ensureRef #-}


-- | Fused CMM fast path: get or create the 'IORef' for the /current/ thread.
--
-- Returns @(threadId, ref)@.
--
-- __Steady state__ (entry exists): read the table 'IORef', then a single
-- CMM call reads @CurrentTSO.id@, linearly probes the key array and
-- fetches the entry's 'MutVar#'. No 'ThreadId' allocation, no FFI.
--
-- __First call per thread__ (or after 'detach'): falls back to
-- 'myThreadId' and attaches @def@ as 'ensureRef' does.
ensureRefFast :: ThreadStorageMap a -> a -> IO (Int, IORef a)
ensureRefFast tsm@(ThreadStorageMap tableRef _) def = do
  Table cap keys# cells# _ <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = cap - 1
    in case probeThreadSlot# keys# cells# mask# s0 of
      (# s1, tid#, slot#, _, var #)
        | isTrue# (slot# >=# 0#) -> (# s1, (I# (Exts.int64ToInt# tid#), toRef var) #)
        | otherwise -> case ensureCurrent tsm (I64# tid#) def of IO g -> g s1
{-# INLINE ensureRefFast #-}


-- | Cold path of 'ensureRefFast': re-attach a detached entry in place
-- ('reattachDetached'), or insert through 'setEntry'.
ensureCurrent :: ThreadStorageMap a -> Key -> a -> IO (Int, IORef a)
ensureCurrent tsm tidKey def = IO $ \s0 -> case reattachDetached tsm tidKey def s0 of
  (# s1, (# | var #) #) -> (# s1, (keyInt tidKey, toRef var) #)
  (# s1, (# (# #) | #) #) ->
    let insert = do
          tid <- myThreadId
          ref <- setEntry False tsm tid tidKey def
          pure (keyInt tidKey, ref)
    in case insert of IO k -> k s1
{-# NOINLINE ensureCurrent #-}


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
  Table cap keys# cells# _ <- readIORef tableRef
  IO $ \s0 ->
    let !(I# mask#) = cap - 1
    in case probeThreadSlot# keys# cells# mask# s0 of
      (# s1, tid#, slot#, _, var #)
        | isTrue# (slot# >=# 0#) -> (# s1, (I# (Exts.int64ToInt# tid#), Just (toRef var)) #)
        | otherwise -> (# s1, (I# (Exts.int64ToInt# tid#), Nothing) #)
{-# INLINE lookupRefFast #-}


-- | Look up the 'IORef' for a thread by its numeric ID.
--
-- Use this when you already have the numeric ID but not necessarily the
-- current thread's TSO (e.g. inspecting another thread's slot).
lookupRef :: ThreadStorageMap a -> Int -> IO (Maybe (IORef a))
lookupRef (ThreadStorageMap tableRef _) !tidArg = do
  let !(I64# tidKey#) = intKey tidArg
  Table cap keys# cells# _ <- readIORef tableRef
  let !(I# mask#) = cap - 1
  IO $ \s0 ->
    case probeSlotByKey# keys# cells# mask# tidKey# s0 of
      (# s1, slot#, _, var #)
        | isTrue# (slot# >=# 0#) -> (# s1, Just (toRef var) #)
        | otherwise -> (# s1, Nothing #)
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
-- Internal: writes
---------------------------------------------------------------------------

-- | Re-attach the calling thread's detached entry in place, if it has one.
--
-- Probes again (cheaper than keeping the first probe's answer live through
-- the callers' hot paths). The probe returns a detached entry's 'MutVar#'
-- along with its slot, so this is a claim of that slot and a write into
-- the 'MutVar#', the same step 'placeIn' takes, with no cell read, no
-- 'ThreadId' and no allocation. Returns the entry's 'MutVar#', or nothing
-- if there is no detached entry or the claim lost a race (the slot
-- changed, or its table is being rehashed); callers then go to
-- 'setEntry'. The result is an unboxed sum, so it allocates nothing.
reattachDetached
  :: ThreadStorageMap a -> Key -> a
  -> Exts.State# RealWorld -> (# Exts.State# RealWorld, (# (# #) | MutVar# RealWorld a #) #)
reattachDetached (ThreadStorageMap tableRef _) tidKey@(I64# tidKey#) new s0 =
  case readIORef tableRef of
    IO readTable -> case readTable s0 of
      (# s, Table cap keys# cells# _ #) ->
        let !(I# mask#) = cap - 1
        in case probeSlotByKey# keys# cells# mask# tidKey# s of
          (# s1, slot#, key#, var #)
            | isTrue# (slot# Exts.<=# -2#) ->
                let write = writeVar var new >> pure True
                in case claimAndPublish keys# (negate (I# slot#) - 2) (I64# key#) tidKey write of
                  IO claim -> case claim s1 of
                    (# s2, Wrote #) -> (# s2, (# | var #) #)
                    (# s2, _ #) -> (# s2, (# (# #) | #) #)
            | otherwise -> (# s1, (# (# #) | #) #)
{-# INLINE reattachDetached #-}


-- | Cold path of 'update': attach a value for the current thread, by
-- re-attaching a detached entry in place ('reattachDetached') or through
-- 'setEntry', which needs the 'ThreadId' to key a new cell.
setCurrent :: ThreadStorageMap a -> Key -> a -> IO ()
setCurrent tsm tidKey new = IO $ \s0 -> case reattachDetached tsm tidKey new s0 of
  (# s1, (# | _ #) #) -> (# s1, () #)
  (# s1, (# (# #) | #) #) ->
    let insert = do
          tid <- myThreadId
          void $ setEntry True tsm tid tidKey new
    in case insert of IO k -> k s1
{-# NOINLINE setCurrent #-}


-- | Cold path of 'update' and 'updateKey' detaching an attached entry: try
-- the CAS from the key the probe saw, and fall back to 'detachKey' if the
-- slot changed or its table is being rehashed.
detachAt :: ThreadStorageMap a -> Exts.MutableByteArray# RealWorld -> Int -> Key -> Key -> IO ()
detachAt tsm keys# slot observed tidKey = do
  ok <- casLive keys# slot observed (observed .|. detachedBit)
  when (not ok) $ detachKey tsm tidKey
{-# NOINLINE detachAt #-}


-- | Mark @key@'s entry detached in the current table, if it is attached.
detachKey :: ThreadStorageMap a -> Key -> IO ()
detachKey tsm@(ThreadStorageMap tableRef _) key = do
  Table cap keys# _ _ <- readIORef tableRef
  IO $ \s0 -> case probeFind keys# cap key s0 of
    (# s1, (# (# #) | #) #) -> (# s1, () #)
    (# s1, (# | (# i#, k# #) #) #) ->
      let !k = I64# k#
          next
            | k .&. frozenBit /= 0 = awaitRehash tsm >> detachKey tsm key
            | k .&. detachedBit /= 0 = pure ()
            | otherwise = do
                ok <- casLive keys# (I# i#) k (k .|. detachedBit)
                when (not ok) $ detachKey tsm key
      in case next of IO n -> n s1


-- | Where 'placeIn' left a value.
data Placed a
  = PlacedFresh                -- ^ in the new cell we passed in
  | PlacedExisting (IORef a)   -- ^ in the entry's existing 'IORef'
  | NeedCell                   -- ^ the slot needs a new cell, and we had none
  | TableFull
  | SlotFrozen


-- | Attach @val@ for @key@ in the current table and return the entry's
-- 'IORef', inserting the entry or re-attaching a detached one as needed.
--
-- With @overwrite = False@ an already attached entry is left as it is
-- ('ensureRef'); with @True@ its value is replaced.
--
-- Re-attaching and overwriting write into the entry's existing 'MutVar#',
-- so the first attempt carries no cell. Only when a slot needs one (an
-- insert, or a slot whose thread is gone) is a cell made, outside any
-- claim since nothing may allocate inside one, and the placement retried.
-- If the entry turns out to have a live cell by then, the new one is
-- killed so the RTS does not keep it until the thread dies.
setEntry :: Bool -> ThreadStorageMap a -> ThreadId -> Key -> a -> IO (IORef a)
setEntry overwrite tsm@(ThreadStorageMap tableRef lock) tid key val = withoutCell
  where
    withoutCell = do
      Table cap keys# cells# dead <- readIORef tableRef
      placed <- placeIn overwrite keys# cells# cap key val False dead
      case placed of
        PlacedExisting ref -> pure ref
        NeedCell -> do
          NewCell fresh freshVar <- newCell tid val
          withCell fresh freshVar
        PlacedFresh -> error "setEntry: placed a cell it was not given"
        TableFull -> growFrom keys# >> withoutCell
        SlotFrozen -> awaitRehash tsm >> withoutCell
    withCell fresh freshVar = do
      Table cap keys# cells# _ <- readIORef tableRef
      placed <- placeIn overwrite keys# cells# cap key val True fresh
      case placed of
        PlacedFresh -> pure (toRef freshVar)
        PlacedExisting ref -> killCell fresh >> pure ref
        NeedCell -> error "setEntry: asked for a cell it was given"
        TableFull -> growFrom keys# >> withCell fresh freshVar
        SlotFrozen -> awaitRehash tsm >> withCell fresh freshVar
    growFrom keys# =
      withMVar lock $ \_ -> do
        moved <- tableMoved tableRef keys#
        when (not moved) $ rehash tsm growCapacity


-- | Linear-probe placement into one table. See 'setEntry'. @fresh@ is
-- only used, and @haveFresh@ must only be set, when the caller made a new
-- cell for this write.
--
-- Every slot change goes through 'claimAndPublish'. On a failed claim the
-- same slot is re-read: the key changed under us, so there is always
-- progress. A claim on this key that is already in flight is waited out
-- rather than claimed over, so two writers never publish into the same
-- slot at once.
--
-- Tombstones are skipped, never reclaimed: within one table a slot's
-- thread ID never changes once claimed, which is what lets readers pair a
-- key with its cell without a retry. They still count as used, so inserts
-- stop at 'maxLoad' and the rehash clears them, which keeps enough slots
-- empty for a miss to end its probe quickly.
placeIn
  :: Bool
  -> Exts.MutableByteArray# RealWorld
  -> Exts.MutableArray# RealWorld (Cell a)
  -> Int -> Key -> a -> Bool -> Cell a -> IO (Placed a)
placeIn overwrite keys# cells# cap key val haveFresh fresh = go (slotFor cap key) 0
  where
    !mask = cap - 1
    go !slot !steps
      | steps >= cap = pure TableFull
      | otherwise = do
          k <- readKey keys# slot
          if k .&. frozenBit /= 0
            then pure SlotFrozen
            else if k == emptySlot
              then do
                used <- readUsed keys# cap
                if used >= maxLoad cap
                  then pure TableFull
                  else if not haveFresh
                    then pure NeedCell
                    else do
                      claim <- claimAndPublish keys# slot k key (writeCell cells# slot fresh >> pure True)
                      case claim of
                        Wrote -> bumpUsed keys# cap >> pure PlacedFresh
                        _ -> go slot steps
              else if (k .&. keyMask) == key && not (isTombstone k)
                then
                  if k .&. claimingBit /= 0
                    then yield >> go slot steps
                    else do
                      CellRef cell <- readCellRef cells# slot
                      existing <- cellVar cell
                      case existing of
                        Just ref@(IORef (STRef var))
                          | k .&. detachedBit /= 0 -> do
                              claim <- claimAndPublish keys# slot k key (writeVar var val >> pure True)
                              case claim of
                                Wrote -> pure (PlacedExisting ref)
                                _ -> go slot steps
                          | overwrite -> writeIORef ref val >> pure (PlacedExisting ref)
                          | otherwise -> pure (PlacedExisting ref)
                        Nothing
                          | not haveFresh -> pure NeedCell
                          | otherwise -> do
                              -- The thread is gone but its slot is still
                              -- here (an OnThread write for a finished
                              -- thread). Give it the new cell, if no other
                              -- writer has yet.
                              claim <- claimAndPublish keys# slot k key (casCell cells# slot cell fresh)
                              case claim of
                                Wrote -> pure PlacedFresh
                                _ -> go slot steps
                else go ((slot + 1) .&. mask) (steps + 1)


writeVar :: MutVar# RealWorld a -> a -> IO ()
writeVar var val = IO $ \s -> case Exts.writeMutVar# var val s of s' -> (# s', () #)
{-# INLINE writeVar #-}


isTombstone :: Key -> Bool
isTombstone k = k .&. complement frozenBit == tombstoneBit
{-# INLINE isTombstone #-}


-- | The most slots an insert may use before the table is rehashed: three
-- quarters, counting tombstones.
maxLoad :: Int -> Int
maxLoad cap = cap - cap `quot` 4
{-# INLINE maxLoad #-}


-- | How many slots of a table have ever been claimed from empty. The count
-- lives in one extra key element after the slots (see 'allocateTable');
-- slots never become empty again within a table, so it only grows.
readUsed :: Exts.MutableByteArray# RealWorld -> Int -> IO Int
readUsed keys# cap = fromIntegral <$> readKey keys# cap
{-# INLINE readUsed #-}


bumpUsed :: Exts.MutableByteArray# RealWorld -> Int -> IO ()
bumpUsed keys# cap = do
  n <- readKey keys# cap
  ok <- casKey keys# cap n (n + 1)
  when (not ok) $ bumpUsed keys# cap


-- | Tombstone a slot if its key is still exactly what we observed. Key
-- first, so probes stop matching the slot, then the cell, which is killed
-- so the RTS drops it and its value. Returns 'False' if the key changed
-- under us or its table is being rehashed.
tombstoneSlot
  :: Exts.MutableByteArray# RealWorld
  -> Exts.MutableArray# RealWorld (Cell a)
  -> Cell a -> Int -> Key -> IO Bool
tombstoneSlot keys# cells# dead slot observed = do
  ok <- casLive keys# slot observed tombstoneBit
  when ok $ do
    CellRef cell <- readCellRef cells# slot
    _ <- casCell cells# slot cell dead
    killCell cell
  pure ok
{-# INLINE tombstoneSlot #-}


---------------------------------------------------------------------------
-- Internal: rehash
---------------------------------------------------------------------------

-- | Capacity after an insert found the table full. It doubles if at least
-- half the slots hold running threads. Otherwise the table is full of
-- tombstones and finished threads, which is thread churn: it still
-- doubles up to 'churnCapacity', so that a rehash (and the writers it
-- blocks) comes every few hundred inserts rather than every few dozen,
-- and stays the same size beyond that, which bounds the finished
-- threads' cells a table holds between rehashes.
growCapacity :: Int -> Int -> Int
growCapacity oldCap live
  | live * 2 < oldCap && oldCap >= churnCapacity = oldCap
  | otherwise = oldCap * 2


-- | See 'growCapacity'.
churnCapacity :: Int
churnCapacity = 1024


-- | Copy the current table's live entries into a new table and publish it.
-- MUST be called while holding the resize 'MVar'. @chooseCap@ gets the old
-- capacity and the number of live entries.
--
-- Every slot of the old table is frozen first: a CAS that sets
-- 'frozenBit', after waiting out any claim in flight. Writers never CAS
-- from a frozen word ('casLive'), so once a slot is frozen it is final, and
-- the copy sees every write that will ever land in the old table. Writers
-- that find a frozen slot wait on the lock ('awaitRehash') and retry on
-- the new table. Readers ignore the bit, so they keep finding entries in
-- the old table until they next read 'tableRef'.
--
-- Slots whose thread has finished or is gone are not copied, so a rehash
-- is also the sweep that reclaims them, and the new capacity is chosen
-- from running threads only. Counting every cell the GC has not yet
-- killed would count each thread that finished since the last major GC
-- (a TSO promoted to the old generation is only found dead by a major
-- GC), and under thread churn that grew the table, and with it the dead
-- cells it holds, several times over.
rehash :: ThreadStorageMap a -> (Int -> Int -> Int) -> IO ()
rehash (ThreadStorageMap tableRef _) chooseCap = do
  Table oldCap keys# cells# dead <- readIORef tableRef
  let freeze !i !live
        | i >= oldCap = pure live
        | otherwise = do
            k <- readKey keys# i
            if k .&. claimingBit /= 0
              then yield >> freeze i live
              else do
                ok <- casKey keys# i k (k .|. frozenBit)
                if not ok
                  then freeze i live
                  else do
                    alive <- slotLive k cells# i
                    freeze (i + 1) (if alive then live + 1 else live)
  live <- freeze 0 (0 :: Int)
  newTable@(Table newCap newKeys# newCells# _) <- allocateTable dead (chooseCap oldCap live)
  let !newMask = newCap - 1
      place !k cell !slot = do
        k' <- readKey newKeys# slot
        if k' == emptySlot
          then writeKeyPrivate newKeys# slot k >> writeCell newCells# slot cell
          else place k cell ((slot + 1) .&. newMask)
      -- A thread can finish between the freeze and the copy, so the copy
      -- recounts.
      copy !i !n
        | i >= oldCap = pure n
        | otherwise = do
            (k, CellRef cell) <- readSlot keys# cells# i
            alive <- slotLive k cells# i
            if alive
              then do
                place (k .&. complement frozenBit) cell (slotFor newCap (k .&. keyMask))
                copy (i + 1) (n + 1)
              else copy (i + 1) n
  copied <- copy 0 (0 :: Int)
  writeKeyPrivate newKeys# newCap (fromIntegral copied)
  writeIORef tableRef newTable


-- | Does a (frozen) slot hold an entry whose owning thread is still
-- running? Unlike 'purgeDeadThreads', this keeps an entry written under
-- a raw key that is not its owner's ID, for as long as the owner runs.
slotLive :: Key -> Exts.MutableArray# RealWorld (Cell a) -> Int -> IO Bool
slotLive k cells# i
  | not (hasEntry k) || isTombstone k = pure False
  | otherwise = do
      CellRef cell <- readCellRef cells# i
      IO $ \s -> case cellOwner# cell s of
        (# s', status#, _ #) -> (# s', isTrue# (status# ==# 1#) #)
{-# INLINE slotLive #-}


-- | Finalizer of a map: kill every cell it still holds, so the RTS stops
-- keeping their values alive on behalf of threads that outlive the map.
-- Runs only once the map is unreachable, so nothing races with it.
releaseAll :: Table a -> IO ()
releaseAll (Table cap _ cells# _) = go 0
  where
    go !i
      | i >= cap = pure ()
      | otherwise = do
          CellRef cell <- readCellRef cells# i
          killCell cell
          go (i + 1)


---------------------------------------------------------------------------
-- Monitoring
---------------------------------------------------------------------------

-- | Snapshot all live entries as @(threadId, value)@ pairs.
--
-- Intended for monitoring and debugging, e.g. verifying that entries are
-- cleaned up after threads exit. The result is a point-in-time snapshot;
-- concurrent mutations may or may not be reflected. Entries whose thread
-- is gone are left out even before their slot is reclaimed.
storedItems :: ThreadStorageMap a -> IO [(Int, a)]
storedItems (ThreadStorageMap tableRef _) = do
  Table cap keys# cells# _ <- readIORef tableRef
  let go !i acc
        | i < 0 = pure acc
        | otherwise = do
            (k, CellRef cell) <- readSlot keys# cells# i
            if hasEntry k && not (isTombstone k) && k .&. (detachedBit .|. claimingBit) == 0
              then do
                mref <- cellVar cell
                case mref of
                  Just ref -> do
                    v <- readIORef ref
                    go (i - 1) ((keyInt (k .&. keyMask), v) : acc)
                  Nothing -> go (i - 1) acc
              else go (i - 1) acc
  go (cap - 1) []


---------------------------------------------------------------------------
-- Purge
---------------------------------------------------------------------------

-- | Who owns a cell; see the CMM source.
foreign import prim "stg_cellOwner"
  cellOwner#
    :: Cell a
    -> Exts.State# RealWorld
    -> (# Exts.State# RealWorld, Int#, Exts.Word# #)


-- | Does a cell belong to a running thread whose ID is the slot's key?
-- A cell is keyed on the thread passed to the write that made it, so an
-- entry written under a raw key that is not that thread's own ID belongs
-- to no thread of its own. On 32-bit targets the ID is compared by its
-- low word.
ownedByRunningThread :: Key -> Cell a -> IO Bool
ownedByRunningThread k cell = IO $ \s ->
  case cellOwner# cell s of
    (# s', status#, owner# #) ->
      (# s', isTrue# (status# ==# 1#) && Exts.W# owner# == fromIntegral (k .&. keyMask) #)
{-# INLINE ownedByRunningThread #-}


-- | Tombstone slots belonging to threads that are no longer alive,
-- and shrink the table if the load factor drops below 25%.
--
-- A thread's value is already released by the GC that finds its TSO
-- unreachable, and its slot is reclaimed at the next rehash. This function
-- reclaims slots eagerly: those of threads that have died, of threads that
-- have finished but whose 'ThreadId' is still referenced somewhere (so
-- their TSO stays reachable), and of keys that name no thread of their own
-- (written through 'updateRaw' under a key that is not the given thread's
-- ID).
--
-- Each entry's cell is keyed on its thread's TSO, so the check is exact
-- and per entry: the sweep reads the owning TSO's state through the cell,
-- with no snapshot of the process's threads to go stale. Tombstoning is a
-- CAS from the key the sweep saw, so a slot that has changed since, or
-- whose table is being rehashed, is left alone; slots mid-claim are
-- skipped.
--
-- After tombstoning, if the number of remaining live entries is less
-- than 1\/4 of the table capacity (and the capacity exceeds the 16-slot
-- minimum), the table is rehashed to a smaller power-of-two size under
-- the resize 'MVar' lock.  This prevents unbounded memory use after
-- bursts of short-lived threads.
{-# SPECIALIZE purgeDeadThreads :: ThreadStorageMap a -> IO () #-}
purgeDeadThreads :: (MonadIO m) => ThreadStorageMap a -> m ()
purgeDeadThreads tsm@(ThreadStorageMap tableRef resizeLock) = liftIO $ do
  Table cap keys# cells# dead <- readIORef tableRef
  let sweep !i !live
        | i >= cap = pure live
        | otherwise = do
            (k, CellRef cell) <- readSlot keys# cells# i
            if not (hasEntry k) || isTombstone k
              then sweep (i + 1) live
              else if k .&. (claimingBit .|. frozenBit) /= 0
                then sweep (i + 1) (live + 1)
                else do
                  keep <- ownedByRunningThread k cell
                  removed <- if keep then pure False else tombstoneSlot keys# cells# dead i k
                  sweep (i + 1) (if removed then live else live + 1)
  live <- sweep 0 (0 :: Int)
  when (nextPow2 (max 16 (live * 4)) < cap) $
    withMVar resizeLock $ \_ -> do
      moved <- tableMoved tableRef keys#
      when (not moved) $
        rehash tsm (\oldCap live' -> min oldCap (nextPow2 (max 16 (live' * 4))))
