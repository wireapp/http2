{-# LANGUAGE NamedFieldPuns #-}

module Network.HTTP2.H2.Window where

import Data.IORef
import Network.Control
import UnliftIO.STM

import Control.Concurrent.STM (throwSTM)
import Debug.Trace (traceM, traceShowId)
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

increaseWindowSize :: StreamId -> TVar TxFlow -> WindowSize -> STM ()
increaseWindowSize sid tvar n = do
    tx <- stateTVar tvar $ \flow -> let newFlow = flow{txfLimit = txfLimit flow + n} in (newFlow, newFlow)
    let w = txWindowSize tx

    when (isWindowOverflow w) $ do
        let msg = fromString ("window update for stream " ++ show sid ++ " is overflow")
            err =
                if isControl sid
                    then ConnectionErrorIsSent
                    else StreamErrorIsSent
        throwSTM $ err FlowControlError sid msg

increaseStreamWindowSize :: Stream -> WindowSize -> STM ()
increaseStreamWindowSize Stream{streamNumber, streamTxFlow} n =
    increaseWindowSize streamNumber streamTxFlow n

increaseConnectionWindowSize :: Context -> Int -> STM ()
increaseConnectionWindowSize Context{txFlow} n =
    increaseWindowSize 0 txFlow n

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
    traceM "informWindowUpdate"
    mxc <-
        atomicModifyIORef rxFlow $
            traceShowId . maybeOpenRxWindow len FCTWindowUpdate . traceShowId

    -- below: this modifies the connection stream (stream 0)
    forM_ mxc $ \ws -> do
        let frame = windowUpdateFrame 0 ws
            cframe = CFrames Nothing [frame]
        enqueueControl controlQ cframe
    mxs <- atomicModifyIORef streamRxFlow $ maybeOpenRxWindow len FCTWindowUpdate
    -- below: this modifies the actual stream
    forM_ mxs $ \ws -> do
        let frame = windowUpdateFrame streamNumber ws
            cframe = CFrames Nothing [frame]
        enqueueControl controlQ cframe
