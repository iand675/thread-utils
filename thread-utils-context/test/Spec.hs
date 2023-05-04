{-# LANGUAGE NumericUnderscores #-}
import System.Mem
import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.Thread.Storage
import Control.Monad
import Data.List hiding (lookup)
import Test.Hspec
import Prelude hiding (lookup)

main :: IO ()
main = hspec $ do

  describe "cleanup" $ do
    it "works" $ do
      mv <- newEmptyMVar
      tsm <- newThreadStorageMap
      replicateM_ 100000 $ do
        forkIO $ do
          attach tsm ()
          readMVar mv
      threadDelay 10_000_000
      putMVar mv ()
      threadDelay 10_000_000
      performGC
      threadDelay 10_000_000
      thingsStillInStorage <- storedItems tsm
      sort thingsStillInStorage `shouldBe` []
    it "doesn't happen while a thread is still alive" $ do
      tsm <- newThreadStorageMap
      mv <- newEmptyMVar
      resultVar <- newEmptyMVar
      forkIO $ do
        attach tsm ()
        readMVar mv
        putMVar resultVar =<< lookup tsm
      threadDelay 5_000_000
      performGC
      putMVar mv ()
      result <- readMVar resultVar
      result `shouldBe` Just ()
      performGC
      threadDelay 5_000_000
      items <- storedItems tsm
      items `shouldBe` []
