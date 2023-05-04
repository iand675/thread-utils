{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
module Control.Concurrent.Thread.Finalizers
  ( mkWeakThreadIdWithFinalizer
  , addThreadFinalizer
  , finalizeThread
  ) where
import Control.Concurrent
import Control.Exception
import Control.Monad ( void )
import GHC.IO (IO(..))
import GHC.Prim ( mkWeak# )
import GHC.Weak ( Weak(..), finalize )
import GHC.Conc.Sync ( ThreadId(..) )

-- | A variant of 'Control.Concurrent.mkWeakThreadId' that supports
-- finalization.
--
-- Make a weak pointer to a 'ThreadId'.  It can be important to do
-- this if you want to hold a reference to a 'ThreadId' while still
-- allowing the thread to receive the @BlockedIndefinitely@ family of
-- exceptions (e.g. 'BlockedIndefinitelyOnMVar').  Holding a normal
-- 'ThreadId' reference will prevent the delivery of
-- @BlockedIndefinitely@ exceptions because the reference could be
-- used as the target of 'throwTo' at any time, which would unblock
-- the thread.
--
-- Holding a @Weak ThreadId@, on the other hand, will not prevent the
-- thread from receiving @BlockedIndefinitely@ exceptions.  It is
-- still possible to throw an exception to a @Weak ThreadId@, but the
-- caller must use @deRefWeak@ first to determine whether the thread
-- still exists.
--
mkWeakThreadIdWithFinalizer :: ThreadId -> IO () -> IO (Weak ThreadId)
mkWeakThreadIdWithFinalizer t@(ThreadId t#) (IO finalizer) = IO $ \s ->
  case mkWeak# t# t finalizer s of
    (# s1, w #) -> (# s1, Weak w #)

{-|
  A specialised version of 'mkWeakThreadIdWithFinalizer', where the 'Weak' object
  returned is simply thrown away (however the finalizer will be
  remembered by the garbage collector, and will still be run
  when the key becomes unreachable).
-}
addThreadFinalizer :: ThreadId -> IO () -> IO ()
addThreadFinalizer tid m = void $ mkWeakThreadIdWithFinalizer tid m

{-|
  Run a thread's finalizers. This is just a convenience alias for 'System.Mem.Weak.finalize'.

  The thread can still be used afterwards, it will simply not run the associated finalizers again.
-}
finalizeThread :: Weak ThreadId -> IO ()
finalizeThread = finalize