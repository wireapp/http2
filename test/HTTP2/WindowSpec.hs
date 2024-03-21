{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module HTTP2.WindowSpec where

import Data.List
import Data.Maybe
import Network.Control
import Test.HUnit
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck

-- TODO: instead of consumed, received, don't we want received - consumed?  (to avoid overflows on long-living streams)
--
data Op = Consume Int | Receive Int
  deriving (Eq, Show)

instance Arbitrary Op where
  arbitrary =
    oneof
      [ Consume <$> chooseInt (0, 2_000_000),
        Receive <$> chooseInt (0, 2_000_000)
      ]
  shrink = \case
    Consume i -> Consume <$> shrink i
    Receive i -> Receive <$> shrink i

newtype OpRun = OpRun [Op]
  deriving (Eq, Show)

instance Arbitrary OpRun where
  arbitrary = OpRun <$> arbitrary
  shrink (OpRun ops) = OpRun <$> (mconcat (f (inits ops)) :: [[Op]])
    where
      -- for every element, shrink every element in it
      f :: [[Op]] -> [[[Op]]]
      f = fmap $ \op -> transpose $ shrink <$> op

instance Arbitrary RxFlow where
  arbitrary = newRxFlow <$> chooseInt (1, 2_000_000)

interpretOpRun :: OpRun -> Assertion
interpretOpRun oprun = do
  flow <- generate arbitrary
  go flow oprun -- TODO: foldM?
  where
    go :: RxFlow -> OpRun -> Assertion
    go _old (OpRun []) = pure ()
    go old (OpRun (op : ops)) = interpretOp old op >>= (`go` OpRun ops)

interpretOp :: RxFlow -> Op -> IO RxFlow
interpretOp rxFlow = \case
  op@(Consume i) -> do
    -- TODO: assert the update limit in the invariants
    let (newFlow, updateLimit) = maybeOpenRxWindow i FCTWindowUpdate rxFlow
    invariants rxFlow op newFlow updateLimit
    -- TODO: invariants for updateLimit and isAcceptable
    pure newFlow
  op@(Receive i) -> do
    let (newFlow, isAcceptable) = checkRxLimit i rxFlow
    if isAcceptable
      then invariants rxFlow op newFlow Nothing
      else newFlow `shouldBe` rxFlow

    pure newFlow

invariants :: RxFlow -> Op -> RxFlow -> Maybe Int -> Assertion
invariants old op new updateLimit = do
  ("window", rxfWindow old) `shouldBe` ("window", rxfWindow new)
  ("consumed", rxfConsumed new)
    `shouldBe` ( "consumed",
                 case op of
                   Consume consumed -> rxfConsumed old + consumed
                   Receive _ -> rxfConsumed old
               )
  ("received " <> show op, rxfReceived new)
    `shouldBe` ( "received " <> show op,
                 case op of
                   Consume _ -> rxfReceived old
                   Receive received -> rxfReceived old + received
               )
  ("limit", rxfLimit new)
    `shouldBe` ( "limit",
                 case op of
                   Consume consumed
                     | rxfLimit old - rxfReceived old < rxfWindow old `div` 2 -> rxfConsumed old + consumed + rxfWindow old
                     | otherwise -> rxfLimit old
                   Receive _ -> rxfLimit old
               )
  ( if rxfLimit old - rxfReceived old < rxfWindow old `div` 2
      then updateLimit `shouldSatisfy` isJust
      else updateLimit `shouldBe` Nothing
    )

spec :: Spec
spec = do
  describe "maybeOpenRxWindow" $ do
    fprop "property!" interpretOpRun

    it "updates window max limit if availability reaches a threshold" $ do
      let consume = 100
      let initRxFlow =
            RxFlow
              { rxfWindow = 100,
                rxfConsumed = 0,
                rxfReceived = 100,
                rxfLimit = 100
              }
          expectedRxFlow =
            RxFlow
              { rxfWindow = 100,
                rxfConsumed = consume,
                rxfReceived = 100,
                rxfLimit = 200
              }
      let (newFlow, limitUpdate) = maybeOpenRxWindow consume FCTWindowUpdate initRxFlow
      limitUpdate `shouldBe` Just 100
      newFlow `shouldBe` expectedRxFlow

    it "does not update max limit if availability does not reach a threshold" $ do
      let consume = 40
          received = 50
      let initRxFlow =
            RxFlow
              { rxfWindow = 100,
                rxfConsumed = 0,
                rxfReceived = received,
                rxfLimit = 100
              }
          expectedRxFlow =
            RxFlow
              { rxfWindow = 100,
                rxfConsumed = consume,
                rxfReceived = received,
                rxfLimit = 100
              }
      let (newFlow, limitUpdate) = maybeOpenRxWindow consume FCTWindowUpdate initRxFlow
      (newFlow, limitUpdate) `shouldBe` (expectedRxFlow, Nothing)

    it "limit goes down?" $ do
      let consume = 100
          received = 500
      let initRxFlow =
            RxFlow
              { rxfWindow = 100,
                rxfConsumed = 350,
                rxfReceived = received,
                rxfLimit = 450
              }
          expectedRxFlow =
            RxFlow
              { rxfWindow = 100,
                rxfConsumed = 350 + consume,
                rxfReceived = received,
                rxfLimit = 100
              }
      let (newFlow, limitUpdate) = maybeOpenRxWindow consume FCTWindowUpdate initRxFlow
      (newFlow, limitUpdate) `shouldBe` (expectedRxFlow, Nothing)

deriving instance Eq RxFlow
