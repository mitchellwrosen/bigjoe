module Bigjoe
  ( Bigjoe,
    fork,
    log,
    flush,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (getNumCapabilities, myThreadId, threadCapability)
import Control.Concurrent.STM
import Control.Monad (join, replicateM, when)
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import Data.Functor.Contravariant
import Data.Maybe (mapMaybe)
import Data.Traversable (for)
import qualified GHC.Arr as Array
import qualified Ki
import qualified PtrPoker.Write
import Prelude hiding (log)

data Bigjoe a = Bigjoe
  { _flush :: IO (),
    _log :: a -> IO ()
  }

instance Contravariant Bigjoe where
  contramap f Bigjoe {_flush, _log} =
    Bigjoe
      { _flush,
        _log = _log . f
      }

data Message
  = Log !PtrPoker.Write.Write
  | Flush !(TVar Bool)

fork :: Ki.Scope -> (ByteString -> IO ()) -> IO (Bigjoe PtrPoker.Write.Write)
fork scope put = do
  -- Fork one logging thread per capability
  caps <- getNumCapabilities
  chans <- Array.listArray (0, caps - 1) <$> replicateM (caps - 1) newTChanIO
  for_ (Array.assocs chans) \(i, chan) ->
    Ki.forkWith_
      scope
      Ki.defaultThreadOptions {Ki.affinity = Ki.Capability i}
      (worker put chan)

  -- Flush: write a 'Flush doneVar' to each logging channel, and wait for eacher logger to write back 'True'
  let _flush = do
        dones0 <-
          for chans \chan -> do
            doneVar <- newTVarIO False
            atomically (writeTChan chan (Flush doneVar))
            pure doneVar
        let loop doneVars =
              when (not (null doneVars)) do
                notDoneVars <-
                  atomically do
                    dones <- traverse readTVar doneVars
                    if or dones
                      then do
                        let notDoneVars =
                              mapMaybe
                                (\(done, doneVar) -> if done then Nothing else Just doneVar)
                                (zip dones doneVars)
                        pure notDoneVars
                      else retry
                loop notDoneVars
        loop (Array.elems dones0)

  -- Log: write to the logging channel associated with this capability
  let _log message = do
        threadId <- myThreadId
        (i, _) <- threadCapability threadId
        atomically (writeTChan (chans Array.! i) (Log message))

  pure Bigjoe {_flush, _log}

worker :: forall void. (ByteString -> IO ()) -> TChan Message -> IO void
worker putByteString chan =
  logmode
  where
    logmode :: IO void
    logmode =
      atomically (readTChan chan) >>= \case
        Log message -> do
          putWrite message
          logmode
        Flush done -> flushmode [done]

    flushmode :: [TVar Bool] -> IO void
    flushmode dones = do
      join (atomically (processFull <|> processEmpty))
      where
        processFull :: STM (IO void)
        processFull =
          readTChan chan >>= \case
            Log message ->
              pure do
                putWrite message
                flushmode dones
            Flush done ->
              pure do
                flushmode (done : dones)

        processEmpty :: STM (IO void)
        processEmpty = do
          for_ dones \done -> writeTVar done True
          pure logmode

    putWrite :: PtrPoker.Write.Write -> IO ()
    putWrite message =
      putByteString (PtrPoker.Write.writeToByteString (message <> PtrPoker.Write.word8 10))

log :: Bigjoe a -> a -> IO ()
log =
  _log

flush :: Bigjoe a -> IO ()
flush =
  _flush
