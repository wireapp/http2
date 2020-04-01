module Network.HTTP2.Arch.File where

import System.IO

import Imports
import Network.HPACK

-- | Offset for file.
type FileOffset = Int64
-- | How many bytes to read
type ByteCount = Int64

-- | Position read for files.
type PositionRead = FileOffset -> ByteCount -> Buffer -> IO ByteCount

-- | Manipulating a file resource.
data Sentinel =
    -- | Closing a file resource. Its refresher is automatiaclly generated by
    --   the internal timer.
    Closer (IO ())
    -- | Refreshing a file resource while reading.
    --   Closing the file must be done by its own timer or something.
  | Refresher (IO ())

-- | Making a position read and its closer.
type PositionReadMaker = FilePath -> IO (PositionRead, Sentinel)
-- | Position read based on 'Handle'.
defaultPositionReadMaker :: PositionReadMaker
defaultPositionReadMaker file = do
    hdl <- openBinaryFile file ReadMode
    return (pread hdl, Closer $ hClose hdl)
  where
    pread :: Handle -> PositionRead
    pread hdl off bytes buf = do
        hSeek hdl AbsoluteSeek $ fromIntegral off
        fromIntegral <$> hGetBufSome hdl buf (fromIntegral bytes)