{-# LANGUAGE NumericUnderscores #-}
import System.Mem
import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.Thread.Storage
import Control.Monad

main :: IO ()
main = do
  mv <- newEmptyMVar
  tsm <- newThreadStorageMap
  replicateM_ 20 $ do
    forkIO $ do
      myThreadId >>= print
      attach tsm ()
      readMVar mv
  threadDelay 2_000_000
  print =<< storedItems tsm
  putMVar mv ()
  threadDelay 2_000_000
  performGC
  print =<< storedItems tsm

  

