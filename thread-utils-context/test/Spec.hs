{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
import System.Mem
import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.Thread.Storage
import Control.Exception (SomeException, evaluate, try)
import Control.Monad
import Data.IORef
import Data.List hiding (lookup)
import GHC.Stats (getRTSStatsEnabled, getRTSStats, gc, gcdetails_live_bytes)
import System.Timeout (timeout)
import Test.Hspec
import Prelude hiding (lookup)

main :: IO ()
main = hspec $ do

  describe "cleanup" $ do
    it "works" $ do
      let n = 100_000
      gate <- newEmptyMVar
      doneRef <- newIORef (0 :: Int)
      tsm <- newThreadStorageMapWith (n * 2)
      replicateM_ n $ do
        forkIO $ do
          attach tsm ()
          readMVar gate
          atomicModifyIORef' doneRef (\x -> (x + 1, ()))

      -- Wait for all threads to have attached
      waitForCount tsm n

      -- Release all threads
      putMVar gate ()

      -- Wait for all threads to finish
      spinUntil $ do
        c <- readIORef doneRef
        pure (c >= n)

      -- Give finalizers a chance to run
      waitUntilGC $ do
        items <- storedItems tsm
        pure (null items)

      thingsStillInStorage <- storedItems tsm
      sort thingsStillInStorage `shouldBe` []

    it "doesn't happen while a thread is still alive" $ do
      tsm <- newThreadStorageMapWith 64
      gate <- newEmptyMVar
      resultVar <- newEmptyMVar
      forkIO $ do
        attach tsm ()
        readMVar gate
        putMVar resultVar =<< lookup tsm

      -- Wait until the child has attached
      waitForCount tsm 1

      performGC
      yield

      -- The entry should still be there since the thread is alive
      putMVar gate ()
      result <- readMVar resultVar
      result `shouldBe` Just ()

      -- Now the thread is dead; give finalizers a chance
      replicateM_ 5 $ performGC >> yield

      waitUntilGC $ do
        items <- storedItems tsm
        pure (null items)

      items <- storedItems tsm
      items `shouldBe` []

  describe "detach" $ do
    it "returns previous value and clears the entry" $ do
      tsm <- newThreadStorageMapWith 16
      resultVar <- newEmptyMVar
      forkIO $ do
        attach tsm (42 :: Int)
        prev <- detach tsm
        after <- lookup tsm
        putMVar resultVar (prev, after)

      (prev, after) <- readMVar resultVar
      prev `shouldBe` Just 42
      after `shouldBe` Nothing

    it "returns Nothing when no value is attached" $ do
      tsm <- newThreadStorageMapWith 16
      resultVar <- newEmptyMVar
      forkIO $ putMVar resultVar =<< detach tsm
      result <- readMVar resultVar
      result `shouldBe` (Nothing :: Maybe Int)

    it "makes the value eligible for GC" $ do
      tsm <- newThreadStorageMapWith 16
      gate <- newEmptyMVar
      forkIO $ do
        attach tsm (42 :: Int)
        _ <- detach tsm
        readMVar gate

      spinUntil $ do
        items <- storedItems tsm
        pure (null items)

      putMVar gate ()

  describe "update" $ do
    it "can insert via Nothing -> Just" $ do
      tsm <- newThreadStorageMapWith 16
      resultVar <- newEmptyMVar
      forkIO $ do
        update tsm (\_ -> (Just (99 :: Int), ()))
        val <- lookup tsm
        putMVar resultVar val

      result <- readMVar resultVar
      result `shouldBe` Just 99

    it "can remove via Just -> Nothing" $ do
      tsm <- newThreadStorageMapWith 16
      resultVar <- newEmptyMVar
      forkIO $ do
        attach tsm (7 :: Int)
        removed <- update tsm (\old -> (Nothing, old))
        after <- lookup tsm
        putMVar resultVar (removed, after)

      (removed, after) <- readMVar resultVar
      removed `shouldBe` Just 7
      after `shouldBe` Nothing

  describe "resize" $ do
    it "grows the table when capacity is exceeded" $ do
      tsm <- newThreadStorageMapWith 16
      let n = 200
      gate <- newEmptyMVar
      doneRef <- newIORef (0 :: Int)
      replicateM_ n $ forkIO $ do
        attach tsm ()
        readMVar gate
        atomicModifyIORef' doneRef (\x -> (x + 1, ()))

      waitForCount tsm n

      items <- storedItems tsm
      length items `shouldBe` n

      putMVar gate ()
      spinUntil $ do
        c <- readIORef doneRef
        pure (c >= n)

      waitUntilGC $ do
        remaining <- storedItems tsm
        pure (null remaining)

    it "preserves values across resize" $ do
      tsm <- newThreadStorageMapWith 16
      let n = 100
      resultRefs <- replicateM n newEmptyMVar
      gate <- newEmptyMVar

      forM_ (zip [1 :: Int ..] resultRefs) $ \(i, mv) ->
        forkIO $ do
          attach tsm i
          readMVar gate
          val <- lookup tsm
          putMVar mv val

      waitForCount tsm n

      putMVar gate ()

      results <- mapM readMVar resultRefs
      let expected = fmap Just [1 .. n]
      sort results `shouldBe` sort expected

  -- GHC's thread IDs are a 64-bit counter. A long-running process passes
  -- 2^32 of them, and the main thread (or any long-lived worker) shares
  -- its low 32 bits with every ID 2^32 further on.
  describe "thread IDs past 2^32" $ do
    it "keep their own entry, apart from the ID that shares their low bits" $ do
      tsm <- newThreadStorageMap
      me <- myThreadId
      let low = getThreadId me
          wide = low + 2 ^ (32 :: Int)
      _ <- attach tsm (1 :: Int)
      updateRaw tsm me wide (\_ -> (Just 2, ()))
      lookup tsm `shouldReturn` Just 1
      lookupRaw tsm low `shouldReturn` Just 1
      lookupRaw tsm wide `shouldReturn` Just 2
      _ <- detach tsm
      lookupRaw tsm wide `shouldReturn` Just 2
      _ <- updateRaw tsm me wide (\_ -> (Nothing, ()))
      attach tsm 3 `shouldReturn` Nothing
      lookupRaw tsm wide `shouldReturn` Nothing
      lookup tsm `shouldReturn` Just 3

  describe "space leak" $ do
    it "repeated attach/detach does not accumulate weak pointers" $ do
      enabled <- getRTSStatsEnabled
      unless enabled $ pendingWith "Requires +RTS -T"

      let cycles = 100_000
      tsm <- newThreadStorageMapWith 16
      phase1Done <- newEmptyMVar
      startPhase2 <- newEmptyMVar
      phase2Done <- newEmptyMVar
      keepAlive <- newEmptyMVar

      _ <- forkIO $ do
        _ <- attach tsm (0 :: Int)
        _ <- detach tsm
        putMVar phase1Done ()
        takeMVar startPhase2
        let go 0 = pure ()
            go !n = do
              _ <- attach tsm n
              _ <- detach tsm
              go (n - 1)
        go cycles
        putMVar phase2Done ()
        takeMVar keepAlive

      takeMVar phase1Done
      replicateM_ 3 performGC
      beforeStats <- getRTSStats
      let !beforeLive = gcdetails_live_bytes (gc beforeStats)

      putMVar startPhase2 ()
      takeMVar phase2Done

      replicateM_ 3 performGC
      afterStats <- getRTSStats
      let !afterLive = gcdetails_live_bytes (gc afterStats)

      putMVar keepAlive ()

      -- Each leaked Weak# + finalizer closure is ~80 bytes.
      -- 100,000 cycles with the bug => ~8 MB of growth.
      -- Fixed code => bounded constant (one Weak# per thread).
      let growth = fromIntegral afterLive - fromIntegral beforeLive :: Int
      growth `shouldSatisfy` (< 1_000_000)

#if MIN_VERSION_base(4,18,0)
  describe "purgeDeadThreads" $ do
    it "reclaims entries for exited threads without waiting for GC" $ do
      let n = 500
      gate <- newEmptyMVar
      doneRef <- newIORef (0 :: Int)
      tsm <- newThreadStorageMap
      replicateM_ n $ forkIO $ do
        attach tsm ()
        readMVar gate
        atomicModifyIORef' doneRef (\x -> (x + 1, ()))

      waitForCount tsm n
      putMVar gate ()
      spinUntil $ (>= n) <$> readIORef doneRef

      -- The whole point of purgeDeadThreads is to reclaim eagerly rather
      -- than waiting on GC finalizers, so spin without performGC here.
      spinUntil $ do
        purgeDeadThreads tsm
        null <$> storedItems tsm

      leftovers <- storedItems tsm
      leftovers `shouldBe` []

    it "keeps entries for threads that are still alive" $ do
      let n = 200
      gate <- newEmptyMVar
      tsm <- newThreadStorageMap
      replicateM_ n $ forkIO $ do
        attach tsm ()
        readMVar gate

      waitForCount tsm n
      purgeDeadThreads tsm
      survivors <- storedItems tsm
      putMVar gate ()
      length survivors `shouldBe` n

    it "purges phantom entries with no matching live thread, and only those" $ do
      let nReal = 200
          nSynthetic = 200
          synthBase = 0x40000000 :: Word
      gate <- newEmptyMVar
      tsm <- newThreadStorageMapWith 16
      mainTid <- myThreadId

      forM_ [0 .. nSynthetic - 1] $ \i ->
        updateRaw tsm mainTid (synthBase + fromIntegral i) (\_ -> (Just (i :: Int), ()))

      replicateM_ nReal $ forkIO $ do
        attach tsm (0 :: Int)
        readMVar gate

      waitForCount tsm (nReal + nSynthetic)

      purgeDeadThreads tsm

      survivors <- storedItems tsm
      putMVar gate ()

      length survivors `shouldBe` nReal
      all (\(k, _) -> fromIntegral k < synthBase) survivors `shouldBe` True

    -- A key and its value are two separately written words. This hammers
    -- the window between them: synthetic keys never appear in listThreads,
    -- so a purge loop tombstones every one of them continuously while a
    -- mutator per key keeps re-inserting and a reader per key keeps
    -- observing. Any read that yields another key's value, or that forces
    -- the dead-slot placeholder, is a bug.
    --
    -- Failure modes this has caught: dereferencing the shared sentinel as
    -- an IORef of the wrong type (garbage Ints), a live IORef left under a
    -- tombstone and later paired with a colliding key (another key's
    -- value), and a resize spinning forever on a half-tombstoned slot
    -- while holding the resize lock (hence the hard timeout).
    it "never exposes another key's value or a dead slot under purge contention" $ do
      let nKeys = 32 :: Int
          iters = 20_000 :: Int
          synthBase = 0x40000000 :: Word
      tsm <- newThreadStorageMapWith 16
      mainTid <- myThreadId
      bad <- newIORef (0 :: Int)
      exc <- newIORef (0 :: Int)
      stop <- newIORef False
      done <- newEmptyMVar
      let check :: Int -> Maybe Int -> IO ()
          check expected mv = case mv of
            Nothing -> pure ()
            Just v -> do
              r <- try (evaluate (v == expected))
              case r of
                Left (_ :: SomeException) -> atomicModifyIORef' exc (\x -> (x + 1, ()))
                Right True -> pure ()
                Right False -> atomicModifyIORef' bad (\x -> (x + 1, ()))
      _ <- forkIO $ do
        let loop = do
              s <- readIORef stop
              unless s $ purgeDeadThreads tsm >> yield >> loop
        loop
        putMVar done ()
      forM_ [0 .. nKeys - 1] $ \i -> do
        let k = synthBase + fromIntegral i
            kInt = fromIntegral k :: Int
        _ <- forkIO $ do
          replicateM_ iters $ do
            _ <- updateRaw tsm mainTid k (\_ -> (Just i, ()))
            lookupRaw tsm k >>= check i
            ref <- ensureRef tsm mainTid kInt i
            readIORef ref >>= check i . Just
          putMVar done ()
        _ <- forkIO $ do
          -- A probe that misses allocates nothing, so a loop of misses has
          -- no safepoint: it can't be preempted and it stalls every GC
          -- until its key reappears, which never happens once the other
          -- capabilities have stopped. Yielding every 64 iterations gives
          -- it a safepoint without a context switch on every pass.
          let loop :: Int -> IO ()
              loop !n = do
                s <- readIORef stop
                unless s $ do
                  lookupRaw tsm k >>= check i
                  mref <- lookupRef tsm kInt
                  forM_ mref $ \r -> readIORef r >>= check i . Just
                  when (n `rem` 64 == 0) yield
                  loop (n + 1)
          loop 1
          putMVar done ()
        pure ()
      finished <- timeout 60_000_000 $ do
        replicateM_ nKeys (takeMVar done) -- mutators
        writeIORef stop True
        replicateM_ (nKeys + 1) (takeMVar done) -- readers + purger
      finished `shouldBe` Just ()
      readIORef bad >>= (`shouldBe` 0)
      readIORef exc >>= (`shouldBe` 0)

    -- Regression test for a laundered TSO pointer in threadKey (formerly
    -- getThreadIdInt).
    --
    -- purgeDeadThreads calls listThreads and converts every ThreadId in the
    -- process to its numeric id. That conversion used to coerce ThreadId# to
    -- Addr# before handing it to rts_getThreadId. ThreadId# is a movable heap
    -- pointer, so once laundered into a non-pointer slot the collector would
    -- neither trace nor relocate it; a GC landing mid-traversal left the C
    -- call dereferencing a stale TSO and the process segfaulted.
    --
    -- This is a race, so it is probabilistic rather than deterministic: many
    -- live threads (a long listThreads result) interleaved with forced GCs
    -- is the shape that reproduces it.
    it "tolerates GC relocating TSOs during the live-thread scan" $ do
      let n = 2_000
      gate <- newEmptyMVar
      tsm <- newThreadStorageMap
      replicateM_ n $ forkIO $ do
        attach tsm (0 :: Int)
        readMVar gate

      waitForCount tsm n
      replicateM_ 100 $ do
        performGC
        purgeDeadThreads tsm

      survivors <- storedItems tsm
      putMVar gate ()
      length survivors `shouldBe` n
#endif


waitForCount :: ThreadStorageMap a -> Int -> IO ()
waitForCount tsm target = spinUntil $ do
  items <- storedItems tsm
  pure (length items >= target)


-- | Spin-wait without GC.  Suitable for waiting on concurrent threads to
-- make progress (insert, signal, etc.).
spinUntil :: IO Bool -> IO ()
spinUntil check = go (500000 :: Int)
  where
    go 0 = error "spinUntil: timed out"
    go !n = do
      done <- check
      unless done $ do
        yield
        go (n - 1)


-- | Spin-wait with periodic 'performGC'.  Use only when waiting for GC
-- finalizers to fire (e.g. dead-thread cleanup).
waitUntilGC :: IO Bool -> IO ()
waitUntilGC check = go (5000 :: Int)
  where
    go 0 = error "waitUntilGC: timed out"
    go !n = do
      done <- check
      unless done $ do
        yield
        performGC
        go (n - 1)
