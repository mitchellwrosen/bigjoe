module Bigjoe
  ( fork,
  )
where

import Control.Concurrent.STM
import Control.Monad (forever)
import Data.ByteString (ByteString)
import GHC.Conc.Sync (getNumCapabilities)
import qualified Ki
import qualified PtrPoker.Write
import Prelude hiding (log)

fork :: Ki.Scope -> (ByteString -> IO ()) -> IO (PtrPoker.Write.Write -> IO ())
fork scope put = do
  chan <- newTChanIO

  caps <- getNumCapabilities

  ifor_ caps \i ->
    Ki.forkWith_
      scope
      Ki.defaultThreadOptions {Ki.affinity = Ki.Capability i}
      (worker put chan)

  pure \message -> atomically (writeTChan chan message)

worker :: (ByteString -> IO ()) -> TChan PtrPoker.Write.Write -> IO void
worker put chan =
  forever do
    message <- atomically (readTChan chan)
    put (PtrPoker.Write.writeToByteString (message <> PtrPoker.Write.word8 10))

ifor_ :: Int -> (Int -> IO ()) -> IO ()
ifor_ m f =
  loop 0
  where
    loop n =
      if n == m
        then pure ()
        else do
          f n
          loop (n + 1)
{-# INLINE ifor_ #-}
