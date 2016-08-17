-- | Convenience functions to launch mintette.

module RSCoin.Mintette.Launcher
       ( ContextArgument (..)
       , mintetteWrapperReal
       , launchMintetteReal
       ) where

import           Control.Monad.Catch       (bracket)
import           Control.Monad.Trans       (MonadIO (liftIO))

import           RSCoin.Core               (SecretKey, mintetteLoggerName)
import           RSCoin.Timed              (ContextArgument (..), MsgPackRpc,
                                            fork_, runRealModeUntrusted)

import           RSCoin.Mintette.Acidic    (closeState, openMemState, openState)
import           RSCoin.Mintette.AcidState (State)
import           RSCoin.Mintette.Server    (serve)
import           RSCoin.Mintette.Worker    (runWorker)

mintetteWrapperReal :: Maybe FilePath
                    -> ContextArgument
                    -> (State -> MsgPackRpc a)
                    -> IO a
mintetteWrapperReal dbPath ca action = do
    let openAction = maybe openMemState openState dbPath
    runRealModeUntrusted mintetteLoggerName ca .
        bracket (liftIO openAction) (liftIO . closeState) $
        action

launchMintetteReal :: Int -> SecretKey -> Maybe FilePath -> ContextArgument -> IO ()
launchMintetteReal port sk dbPath ctxArg =
    mintetteWrapperReal dbPath ctxArg $
    \st -> do
        fork_ $ runWorker sk st dbPath
        serve port st sk
