{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnliftedFFITypes #-}
{-# LANGUAGE UnboxedTuples #-}
-- | A perilous implementation of thread-local storage for Haskell.
-- This module uses a fair amount of GHC internals to enable performing
-- lookups of context for any threads that are alive. Caution should be
-- taken for consumers of this module to not retain ThreadId references
-- indefinitely, as that could delay cleanup of thread-local state.
--
-- Thread-local contexts have the following semantics:
--
-- - A value 'attach'ed to a 'ThreadId' will remain alive at least as long
--   as the 'ThreadId'. 
-- - A value may be detached from a 'ThreadId' via 'detach' by the
--   library consumer without detriment.
-- - No guarantees are made about when a value will be garbage-collected
--   once all references to 'ThreadId' have been dropped. However, this simply
--   means in practice that any unused contexts will cleaned up upon the next
--   garbage collection and may not be actively freed when the program exits.
--
-- Note that this implementation of context sharing is
-- mildly expensive for the garbage collector, hard to reason about without deep
-- knowledge of the code you are instrumenting, and has limited guarantees of behavior 
-- across GHC versions due to internals usage.
module Control.Concurrent.Thread.Storage 
  ( 
    -- * Create a 'ThreadStorageMap'
    ThreadStorageMap
  , newThreadStorageMap
    -- * Retrieve values from a 'ThreadStorageMap'
  , lookup
  , lookupOnThread
    -- * Associate values with a thread in a 'ThreadStorageMap'
  , attach
  , attachOnThread
    -- * Remove values from a thread in a 'ThreadStorageMap'
  , detach
  , detachFromThread
    -- * Update values for a thread in a 'ThreadStorageMap'
  , adjust
  , adjustOnThread
    -- * Monitoring utilities
  , storedItems
  ) where

import Control.Concurrent
import Control.Concurrent.Thread.Finalizers
import Control.Monad ( void )
import Control.Monad.IO.Class
import GHC.IO (IO(..))
import GHC.Int
import GHC.Conc.Sync ( ThreadId(..) )
import GHC.Prim
import qualified Data.IntMap.Lazy as I
import Foreign.C.Types
import Prelude hiding (lookup)

foreign import ccall unsafe "rts_getThreadId" c_getThreadId :: ThreadId# -> CInt

numStripes :: Int
numStripes = 32

getThreadId :: ThreadId -> Int
getThreadId (ThreadId tid#) = fromIntegral (c_getThreadId tid#)

threadHash :: Int -> Int
threadHash = (`mod` numStripes)

readStripe :: ThreadStorageMap a -> ThreadId -> IO (I.IntMap a)
readStripe (ThreadStorageMap arr#) t = IO $ \s -> readArray# arr# tid# s
  where
    (I# tid#) = threadHash $ getThreadId t

atomicModifyStripe :: ThreadStorageMap a -> Int -> (I.IntMap a -> (I.IntMap a, b)) -> IO b
atomicModifyStripe (ThreadStorageMap arr#) tid f = IO $ \s -> go s
  where
    (I# stripe#) = threadHash tid
    go s = case readArray# arr# stripe# s of
      (# s1, intMap #) -> 
        let (updatedIntMap, result) = f intMap 
        in case casArray# arr# stripe# intMap updatedIntMap s1 of
             (# s2, outcome, old #) -> case outcome of
               0# -> (# s2, result #)
               1# -> go s2
               _ -> error "Got impossible result in atomicModifyStripe"
          
-- | A storage mechanism for values of a type. This structure retains items
-- on per-(green)thread basis, which can be useful in rare cases.
data ThreadStorageMap a = ThreadStorageMap (MutableArray# RealWorld (I.IntMap a))

-- | Create a new thread storage map. The map is striped by thread
-- into 32 sections in order to reduce contention.
newThreadStorageMap 
  :: MonadIO m => m (ThreadStorageMap a)
newThreadStorageMap = liftIO $ IO $ \s -> case newArray# numStripes# mempty s of
  (# s1, ma #) -> (# s1, ThreadStorageMap ma #)
  where
    (I# numStripes#) = numStripes

-- | Retrieve a value if it exists for the current thread
lookup :: MonadIO m => ThreadStorageMap a -> m (Maybe a)
lookup tsm = liftIO $ do
  tid <- myThreadId
  lookupOnThread tsm tid

-- | Retrieve a value if it exists for the specified thread
lookupOnThread :: MonadIO m => ThreadStorageMap a -> ThreadId -> m (Maybe a)
lookupOnThread tsm tid = liftIO $ do
  let threadAsInt = getThreadId tid
  m <- readStripe tsm tid
  pure $ I.lookup threadAsInt m

-- | Associate the provided value with the current thread
attach :: MonadIO m => ThreadStorageMap a -> a -> m ()
attach tsm x = liftIO $ do
  tid <- myThreadId
  attachOnThread tsm tid x

-- | Associate the provided value with the specified thread
attachOnThread :: MonadIO m => ThreadStorageMap a -> ThreadId -> a -> m ()
attachOnThread tsm tid ctxt = liftIO $ do
  let threadAsInt = getThreadId tid
  addThreadFinalizer tid $ cleanUp tsm threadAsInt
  atomicModifyStripe tsm threadAsInt $ \m -> (I.insert threadAsInt ctxt m, ())

-- | Disassociate the associated value from the current thread, returning it if it exists.
detach :: MonadIO m => ThreadStorageMap a -> m (Maybe a)
detach tsm = liftIO $ do
  tid <- myThreadId
  detachFromThread tsm tid

-- | Disassociate the associated value from the specified thread, returning it if it exists.
detachFromThread :: MonadIO m => ThreadStorageMap a -> ThreadId -> m (Maybe a)
detachFromThread tsm tid = liftIO $ do
  let threadAsInt = getThreadId tid
  atomicModifyStripe tsm threadAsInt $ \m -> (I.delete threadAsInt m, I.lookup threadAsInt m)

-- | Update the associated value for the current thread if it is attached.
adjust :: MonadIO m => ThreadStorageMap a -> (a -> a) -> m ()
adjust tsm f = liftIO $ do
  tid <- myThreadId
  adjustOnThread tsm tid f

-- | Update the associated value for the specified thread if it is attached.
adjustOnThread :: MonadIO m => ThreadStorageMap a -> ThreadId -> (a -> a) -> m ()
adjustOnThread tsm tid f = liftIO $ do
  let threadAsInt = getThreadId tid 
  atomicModifyStripe tsm threadAsInt $ \m -> (I.adjust f threadAsInt m, ())

-- Remove this context for thread from the map on finalization
cleanUp :: ThreadStorageMap a -> Int -> IO ()
cleanUp tsm tid = atomicModifyStripe tsm tid $ \m -> 
  (I.delete tid m, ())

-- | List thread ids with live entries in the 'ThreadStorageMap'.
-- 
-- This is useful for monitoring purposes to verify that there
-- are no memory leaks retaining threads and thus preventing
-- items from being freed from a 'ThreadStorageMap' 
storedItems :: ThreadStorageMap a -> IO [Int]
storedItems tsm = do
  stripes <- mapM (stripeByIndex tsm) [0..(numStripes - 1)]
  pure $ concatMap I.keys stripes

stripeByIndex :: ThreadStorageMap a -> Int -> IO (I.IntMap a)
stripeByIndex (ThreadStorageMap arr#) (I# i#) = IO $ \s -> readArray# arr# i# s
