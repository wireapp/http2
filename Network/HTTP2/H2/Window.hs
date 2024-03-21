{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

module Network.HTTP2.H2.Window where

import Data.IORef
import Network.Control
import qualified UnliftIO.Exception as E
import UnliftIO.STM

import Imports
import Network.HTTP2.Frame
import Network.HTTP2.H2.Context
import Network.HTTP2.H2.EncodeFrame
import Network.HTTP2.H2.Queue
import Network.HTTP2.H2.Types

getStreamWindowSize :: Stream -> IO WindowSize
getStreamWindowSize Stream{streamTxFlow} =
    txWindowSize <$> readTVarIO streamTxFlow

getConnectionWindowSize :: Context -> IO WindowSize
getConnectionWindowSize Context{txFlow} =
    txWindowSize <$> readTVarIO txFlow

waitStreamWindowSize :: Stream -> IO ()
waitStreamWindowSize Stream{streamTxFlow} = atomically $ do
    w <- txWindowSize <$> readTVar streamTxFlow
    checkSTM (w > 0)

waitConnectionWindowSize :: Context -> STM ()
waitConnectionWindowSize Context{txFlow} = do
    w <- txWindowSize <$> readTVar txFlow
    checkSTM (w > 0)

----------------------------------------------------------------
-- Receiving window update

increaseWindowSize :: StreamId -> TVar TxFlow -> WindowSize -> IO ()
increaseWindowSize sid tvar n = do
    oldW <- txWindowSize <$> readTVarIO tvar
    atomically $ modifyTVar' tvar $ \flow -> flow{txfLimit = txfLimit flow + n}
    w <- txWindowSize <$> readTVarIO tvar
    when (isWindowOverflow w) $ do
        let msg = fromString ("window update for stream " ++ show sid ++ " is overflow. New window size: " <> show w <> ", from previous size: " <> show oldW)
            err =
                if isControl sid
                    then ConnectionErrorIsSent
                    else StreamErrorIsSent
        E.throwIO $ err FlowControlError sid msg

increaseStreamWindowSize :: Stream -> WindowSize -> IO ()
increaseStreamWindowSize Stream{streamNumber, streamTxFlow} =
    increaseWindowSize streamNumber streamTxFlow

increaseConnectionWindowSize :: Context -> Int -> IO ()
increaseConnectionWindowSize Context{txFlow} =
    increaseWindowSize 0 txFlow

decreaseWindowSize :: Context -> Stream -> WindowSize -> IO ()
decreaseWindowSize Context{txFlow} Stream{streamTxFlow} siz = do
    dec txFlow
    dec streamTxFlow
  where
    dec tvar = atomically $ modifyTVar' tvar $ \flow -> flow{txfSent = txfSent flow + siz}

----------------------------------------------------------------
-- Sending window update

informWindowUpdate :: Context -> Stream -> Int -> IO ()
informWindowUpdate _ _ 0 = return ()
informWindowUpdate Context{controlQ, rxFlow} Stream{streamNumber, streamRxFlow} len = do
    mxc <- atomicModifyIORef' rxFlow $ maybeOpenRxWindow len FCTWindowUpdate
    forM_ mxc $ \ws -> do
        putStrLn $ "\n ------------ new window size for rx: " <> show ws
        let frame = windowUpdateFrame 0 ws
            cframe = CFrames Nothing [frame]
        enqueueControl controlQ cframe
    mxs <- atomicModifyIORef' streamRxFlow $ maybeOpenRxWindow len FCTWindowUpdate
    forM_ mxs $ \ws -> do
        putStrLn $ "\n ------------ new window size for stream rx: " <> show ws
        let frame = windowUpdateFrame streamNumber ws
            cframe = CFrames Nothing [frame]
        enqueueControl controlQ cframe
