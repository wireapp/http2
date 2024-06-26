{-# LANGUAGE OverloadedStrings #-}

module Network.HPACK.Huffman.Decode (
    -- * Huffman decoding
    decodeH,
    decodeHuffman,
    HuffmanDecoder,
    decH,
    GCBuffer,
) where

import Data.Array (Array, listArray)
import Data.Array.Base (unsafeAt)
import qualified Data.ByteString as BS
import Network.ByteOrder
import UnliftIO.Exception (throwIO)

import Imports
import Network.HPACK.Huffman.Bit
import Network.HPACK.Huffman.Params
import Network.HPACK.Huffman.Table
import Network.HPACK.Huffman.Tree
import Network.HPACK.Types (DecodeError (..))

----------------------------------------------------------------

-- | Huffman decoding.
type HuffmanDecoder = ReadBuffer -> Int -> IO ByteString

----------------------------------------------------------------

data Pin
    = EndOfString
    | Forward {-# UNPACK #-} Word8 -- node no.
    | GoBack
        {-# UNPACK #-} Word8 -- node no.
        {-# UNPACK #-} Word8 -- a decoded value
    | GoBack2
        {-# UNPACK #-} Word8 -- node no.
        {-# UNPACK #-} Word8 -- a decoded value
        {-# UNPACK #-} Word8 -- a decoded value
    deriving (Show)

data WayStep = WayStep (Maybe Int) (Array Word8 Pin)
type Way256 = Array Word8 WayStep

next :: WayStep -> Word8 -> Pin
next (WayStep _ a16) w = a16 `unsafeAt` fromIntegral w

----------------------------------------------------------------

-- | Huffman decoding.
decodeH
    :: GCBuffer
    -- ^ A working space
    -> BufferSize
    -> ReadBuffer
    -- ^ A read buffer which contains the target
    -> Int
    -- ^ The target length
    -> IO ByteString
decodeH gcbuf bufsiz rbuf len = withForeignPtr gcbuf $ \buf -> do
    wbuf <- newWriteBuffer buf bufsiz
    decH wbuf rbuf len
    toByteString wbuf

-- | Low devel Huffman decoding in a write buffer.
decH :: WriteBuffer -> ReadBuffer -> Int -> IO ()
decH wbuf rbuf len = go len (way256 `unsafeAt` 0)
  where
    go 0 way0 = case way0 of
        WayStep Nothing _ -> throwIO IllegalEos
        WayStep (Just i) _
            | i <= 8 -> return ()
            | otherwise -> throwIO TooLongEos
    go n way0 = do
        w <- read8 rbuf
        way <- doit way0 w
        go (n - 1) way
    doit way w = case next way w of
        EndOfString -> throwIO EosInTheMiddle
        Forward n -> return $ way256 `unsafeAt` fromIntegral n
        GoBack n v -> do
            write8 wbuf v
            return $ way256 `unsafeAt` fromIntegral n
        GoBack2 n v1 v2 -> do
            write8 wbuf v1
            write8 wbuf v2
            return $ way256 `unsafeAt` fromIntegral n

-- | Huffman decoding with a temporary buffer whose size is 4096.
decodeHuffman :: ByteString -> IO ByteString
decodeHuffman bs = withWriteBuffer 4096 $ \wbuf ->
    withReadBuffer bs $ \rbuf -> decH wbuf rbuf $ BS.length bs

----------------------------------------------------------------

{-# NOINLINE way256 #-}
way256 :: Way256
way256 = construct $ toHTree huffmanTable

construct :: HTree -> Way256
construct decoder = listArray (0, 255) $ map to16ways $ flatten decoder
  where
    to16ways x = WayStep ei a16
      where
        ei = eosInfo x
        a16 = listArray (0, 255) $ map (step decoder x Non) bits8s

data Chara
    = Non
    | One Word8
    | Two Word8 Word8

{- FOURMOLU_DISABLE -}
inc :: Chara -> Word8 -> Chara
inc Non w     = One w
inc (One v) w = Two v w
inc _       _ = error "inc"

step :: HTree -> HTree -> Chara -> [B] -> Pin
step root (Tip _ v)     x  bss
  | v == idxEos                     = EndOfString
  | otherwise                       = let w = fromIntegral v
                                          x' = inc x w
                                      in step root root x' bss
step _    (Bin _ n _ _) Non       [] = Forward (fromIntegral n)
step _    (Bin _ n _ _) (One w)   [] = GoBack (fromIntegral n) w
step _    (Bin _ n _ _) (Two w z) [] = GoBack2 (fromIntegral n) w z
step root (Bin _ _ l _) mx    (F:bs) = step root l mx bs
step root (Bin _ _ _ r) mx    (T:bs) = step root r mx bs

bits8s :: [[B]]
bits8s = [
    [F,F,F,F,F,F,F,F]
  , [F,F,F,F,F,F,F,T]
  , [F,F,F,F,F,F,T,F]
  , [F,F,F,F,F,F,T,T]
  , [F,F,F,F,F,T,F,F]
  , [F,F,F,F,F,T,F,T]
  , [F,F,F,F,F,T,T,F]
  , [F,F,F,F,F,T,T,T]
  , [F,F,F,F,T,F,F,F]
  , [F,F,F,F,T,F,F,T]
  , [F,F,F,F,T,F,T,F]
  , [F,F,F,F,T,F,T,T]
  , [F,F,F,F,T,T,F,F]
  , [F,F,F,F,T,T,F,T]
  , [F,F,F,F,T,T,T,F]
  , [F,F,F,F,T,T,T,T]
  , [F,F,F,T,F,F,F,F]
  , [F,F,F,T,F,F,F,T]
  , [F,F,F,T,F,F,T,F]
  , [F,F,F,T,F,F,T,T]
  , [F,F,F,T,F,T,F,F]
  , [F,F,F,T,F,T,F,T]
  , [F,F,F,T,F,T,T,F]
  , [F,F,F,T,F,T,T,T]
  , [F,F,F,T,T,F,F,F]
  , [F,F,F,T,T,F,F,T]
  , [F,F,F,T,T,F,T,F]
  , [F,F,F,T,T,F,T,T]
  , [F,F,F,T,T,T,F,F]
  , [F,F,F,T,T,T,F,T]
  , [F,F,F,T,T,T,T,F]
  , [F,F,F,T,T,T,T,T]
  , [F,F,T,F,F,F,F,F]
  , [F,F,T,F,F,F,F,T]
  , [F,F,T,F,F,F,T,F]
  , [F,F,T,F,F,F,T,T]
  , [F,F,T,F,F,T,F,F]
  , [F,F,T,F,F,T,F,T]
  , [F,F,T,F,F,T,T,F]
  , [F,F,T,F,F,T,T,T]
  , [F,F,T,F,T,F,F,F]
  , [F,F,T,F,T,F,F,T]
  , [F,F,T,F,T,F,T,F]
  , [F,F,T,F,T,F,T,T]
  , [F,F,T,F,T,T,F,F]
  , [F,F,T,F,T,T,F,T]
  , [F,F,T,F,T,T,T,F]
  , [F,F,T,F,T,T,T,T]
  , [F,F,T,T,F,F,F,F]
  , [F,F,T,T,F,F,F,T]
  , [F,F,T,T,F,F,T,F]
  , [F,F,T,T,F,F,T,T]
  , [F,F,T,T,F,T,F,F]
  , [F,F,T,T,F,T,F,T]
  , [F,F,T,T,F,T,T,F]
  , [F,F,T,T,F,T,T,T]
  , [F,F,T,T,T,F,F,F]
  , [F,F,T,T,T,F,F,T]
  , [F,F,T,T,T,F,T,F]
  , [F,F,T,T,T,F,T,T]
  , [F,F,T,T,T,T,F,F]
  , [F,F,T,T,T,T,F,T]
  , [F,F,T,T,T,T,T,F]
  , [F,F,T,T,T,T,T,T]
  , [F,T,F,F,F,F,F,F]
  , [F,T,F,F,F,F,F,T]
  , [F,T,F,F,F,F,T,F]
  , [F,T,F,F,F,F,T,T]
  , [F,T,F,F,F,T,F,F]
  , [F,T,F,F,F,T,F,T]
  , [F,T,F,F,F,T,T,F]
  , [F,T,F,F,F,T,T,T]
  , [F,T,F,F,T,F,F,F]
  , [F,T,F,F,T,F,F,T]
  , [F,T,F,F,T,F,T,F]
  , [F,T,F,F,T,F,T,T]
  , [F,T,F,F,T,T,F,F]
  , [F,T,F,F,T,T,F,T]
  , [F,T,F,F,T,T,T,F]
  , [F,T,F,F,T,T,T,T]
  , [F,T,F,T,F,F,F,F]
  , [F,T,F,T,F,F,F,T]
  , [F,T,F,T,F,F,T,F]
  , [F,T,F,T,F,F,T,T]
  , [F,T,F,T,F,T,F,F]
  , [F,T,F,T,F,T,F,T]
  , [F,T,F,T,F,T,T,F]
  , [F,T,F,T,F,T,T,T]
  , [F,T,F,T,T,F,F,F]
  , [F,T,F,T,T,F,F,T]
  , [F,T,F,T,T,F,T,F]
  , [F,T,F,T,T,F,T,T]
  , [F,T,F,T,T,T,F,F]
  , [F,T,F,T,T,T,F,T]
  , [F,T,F,T,T,T,T,F]
  , [F,T,F,T,T,T,T,T]
  , [F,T,T,F,F,F,F,F]
  , [F,T,T,F,F,F,F,T]
  , [F,T,T,F,F,F,T,F]
  , [F,T,T,F,F,F,T,T]
  , [F,T,T,F,F,T,F,F]
  , [F,T,T,F,F,T,F,T]
  , [F,T,T,F,F,T,T,F]
  , [F,T,T,F,F,T,T,T]
  , [F,T,T,F,T,F,F,F]
  , [F,T,T,F,T,F,F,T]
  , [F,T,T,F,T,F,T,F]
  , [F,T,T,F,T,F,T,T]
  , [F,T,T,F,T,T,F,F]
  , [F,T,T,F,T,T,F,T]
  , [F,T,T,F,T,T,T,F]
  , [F,T,T,F,T,T,T,T]
  , [F,T,T,T,F,F,F,F]
  , [F,T,T,T,F,F,F,T]
  , [F,T,T,T,F,F,T,F]
  , [F,T,T,T,F,F,T,T]
  , [F,T,T,T,F,T,F,F]
  , [F,T,T,T,F,T,F,T]
  , [F,T,T,T,F,T,T,F]
  , [F,T,T,T,F,T,T,T]
  , [F,T,T,T,T,F,F,F]
  , [F,T,T,T,T,F,F,T]
  , [F,T,T,T,T,F,T,F]
  , [F,T,T,T,T,F,T,T]
  , [F,T,T,T,T,T,F,F]
  , [F,T,T,T,T,T,F,T]
  , [F,T,T,T,T,T,T,F]
  , [F,T,T,T,T,T,T,T]
  , [T,F,F,F,F,F,F,F]
  , [T,F,F,F,F,F,F,T]
  , [T,F,F,F,F,F,T,F]
  , [T,F,F,F,F,F,T,T]
  , [T,F,F,F,F,T,F,F]
  , [T,F,F,F,F,T,F,T]
  , [T,F,F,F,F,T,T,F]
  , [T,F,F,F,F,T,T,T]
  , [T,F,F,F,T,F,F,F]
  , [T,F,F,F,T,F,F,T]
  , [T,F,F,F,T,F,T,F]
  , [T,F,F,F,T,F,T,T]
  , [T,F,F,F,T,T,F,F]
  , [T,F,F,F,T,T,F,T]
  , [T,F,F,F,T,T,T,F]
  , [T,F,F,F,T,T,T,T]
  , [T,F,F,T,F,F,F,F]
  , [T,F,F,T,F,F,F,T]
  , [T,F,F,T,F,F,T,F]
  , [T,F,F,T,F,F,T,T]
  , [T,F,F,T,F,T,F,F]
  , [T,F,F,T,F,T,F,T]
  , [T,F,F,T,F,T,T,F]
  , [T,F,F,T,F,T,T,T]
  , [T,F,F,T,T,F,F,F]
  , [T,F,F,T,T,F,F,T]
  , [T,F,F,T,T,F,T,F]
  , [T,F,F,T,T,F,T,T]
  , [T,F,F,T,T,T,F,F]
  , [T,F,F,T,T,T,F,T]
  , [T,F,F,T,T,T,T,F]
  , [T,F,F,T,T,T,T,T]
  , [T,F,T,F,F,F,F,F]
  , [T,F,T,F,F,F,F,T]
  , [T,F,T,F,F,F,T,F]
  , [T,F,T,F,F,F,T,T]
  , [T,F,T,F,F,T,F,F]
  , [T,F,T,F,F,T,F,T]
  , [T,F,T,F,F,T,T,F]
  , [T,F,T,F,F,T,T,T]
  , [T,F,T,F,T,F,F,F]
  , [T,F,T,F,T,F,F,T]
  , [T,F,T,F,T,F,T,F]
  , [T,F,T,F,T,F,T,T]
  , [T,F,T,F,T,T,F,F]
  , [T,F,T,F,T,T,F,T]
  , [T,F,T,F,T,T,T,F]
  , [T,F,T,F,T,T,T,T]
  , [T,F,T,T,F,F,F,F]
  , [T,F,T,T,F,F,F,T]
  , [T,F,T,T,F,F,T,F]
  , [T,F,T,T,F,F,T,T]
  , [T,F,T,T,F,T,F,F]
  , [T,F,T,T,F,T,F,T]
  , [T,F,T,T,F,T,T,F]
  , [T,F,T,T,F,T,T,T]
  , [T,F,T,T,T,F,F,F]
  , [T,F,T,T,T,F,F,T]
  , [T,F,T,T,T,F,T,F]
  , [T,F,T,T,T,F,T,T]
  , [T,F,T,T,T,T,F,F]
  , [T,F,T,T,T,T,F,T]
  , [T,F,T,T,T,T,T,F]
  , [T,F,T,T,T,T,T,T]
  , [T,T,F,F,F,F,F,F]
  , [T,T,F,F,F,F,F,T]
  , [T,T,F,F,F,F,T,F]
  , [T,T,F,F,F,F,T,T]
  , [T,T,F,F,F,T,F,F]
  , [T,T,F,F,F,T,F,T]
  , [T,T,F,F,F,T,T,F]
  , [T,T,F,F,F,T,T,T]
  , [T,T,F,F,T,F,F,F]
  , [T,T,F,F,T,F,F,T]
  , [T,T,F,F,T,F,T,F]
  , [T,T,F,F,T,F,T,T]
  , [T,T,F,F,T,T,F,F]
  , [T,T,F,F,T,T,F,T]
  , [T,T,F,F,T,T,T,F]
  , [T,T,F,F,T,T,T,T]
  , [T,T,F,T,F,F,F,F]
  , [T,T,F,T,F,F,F,T]
  , [T,T,F,T,F,F,T,F]
  , [T,T,F,T,F,F,T,T]
  , [T,T,F,T,F,T,F,F]
  , [T,T,F,T,F,T,F,T]
  , [T,T,F,T,F,T,T,F]
  , [T,T,F,T,F,T,T,T]
  , [T,T,F,T,T,F,F,F]
  , [T,T,F,T,T,F,F,T]
  , [T,T,F,T,T,F,T,F]
  , [T,T,F,T,T,F,T,T]
  , [T,T,F,T,T,T,F,F]
  , [T,T,F,T,T,T,F,T]
  , [T,T,F,T,T,T,T,F]
  , [T,T,F,T,T,T,T,T]
  , [T,T,T,F,F,F,F,F]
  , [T,T,T,F,F,F,F,T]
  , [T,T,T,F,F,F,T,F]
  , [T,T,T,F,F,F,T,T]
  , [T,T,T,F,F,T,F,F]
  , [T,T,T,F,F,T,F,T]
  , [T,T,T,F,F,T,T,F]
  , [T,T,T,F,F,T,T,T]
  , [T,T,T,F,T,F,F,F]
  , [T,T,T,F,T,F,F,T]
  , [T,T,T,F,T,F,T,F]
  , [T,T,T,F,T,F,T,T]
  , [T,T,T,F,T,T,F,F]
  , [T,T,T,F,T,T,F,T]
  , [T,T,T,F,T,T,T,F]
  , [T,T,T,F,T,T,T,T]
  , [T,T,T,T,F,F,F,F]
  , [T,T,T,T,F,F,F,T]
  , [T,T,T,T,F,F,T,F]
  , [T,T,T,T,F,F,T,T]
  , [T,T,T,T,F,T,F,F]
  , [T,T,T,T,F,T,F,T]
  , [T,T,T,T,F,T,T,F]
  , [T,T,T,T,F,T,T,T]
  , [T,T,T,T,T,F,F,F]
  , [T,T,T,T,T,F,F,T]
  , [T,T,T,T,T,F,T,F]
  , [T,T,T,T,T,F,T,T]
  , [T,T,T,T,T,T,F,F]
  , [T,T,T,T,T,T,F,T]
  , [T,T,T,T,T,T,T,F]
  , [T,T,T,T,T,T,T,T]
  ]
{- FOURMOLU_ENABLE -}
