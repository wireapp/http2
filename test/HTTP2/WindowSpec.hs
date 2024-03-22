{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -Wno-orphans -Wno-incomplete-patterns #-}

module HTTP2.WindowSpec where

-- TODO: instead of consumed, received, don't we want received - consumed?  (to avoid overflows on long-living streams)

import Data.List
import Network.Control
import Test.HUnit
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck
import Text.Show.Pretty

-- types

deriving instance Eq RxFlow

data Op = Consume | Receive
  deriving (Eq, Show, Bounded, Enum)

data OpWithResult = ConsumeWithResult (Maybe Int) | ReceiveWithResult Bool
  deriving (Eq, Show)

data Step op = Step {stepOp :: op, stepArg :: Int}
  deriving (Eq, Show)

data Trace = Trace {traceStart :: RxFlow, traceSteps :: [(Step OpWithResult, RxFlow)]}
  deriving (Eq, Show)

-- arbitrary instances

maxWindowSize :: Int
maxWindowSize = 2_000_000

instance Arbitrary RxFlow where
  arbitrary = newRxFlow <$> chooseInt (1, maxWindowSize)

instance Arbitrary Op where
  arbitrary = elements [minBound ..]

instance Arbitrary Trace where
  arbitrary = do
    initialFlow <- arbitrary
    len <- chooseInt (0, 100)
    Trace initialFlow <$> runManySteps len initialFlow
    where
      runManySteps :: Int -> RxFlow -> Gen [(Step OpWithResult, RxFlow)]
      runManySteps 0 _ = pure []
      runManySteps len oldFlow = do
        step@(_, newFlow) <- runStep oldFlow <$> genStep oldFlow
        (step :) <$> runManySteps (len - 1) newFlow

      -- TODO: extend genStep: what happens if we consume or receive 0 or negative numbers?
      -- what if frame size > window size?
      genStep :: RxFlow -> Gen (Step Op)
      genStep oldFlow = oneof [mkConsume, mkReceive]
        where
          mkReceive =
            -- TODO: are frame sizes > window size legal?
            Step Receive <$> chooseInt (1, rxfWindow oldFlow * 2)

          mkConsume =
            let recv = rxfReceived oldFlow
             in if recv > 0
                  then Step Consume <$> chooseInt (1, rxfReceived oldFlow)
                  else mkReceive

      runStep :: RxFlow -> Step Op -> (Step OpWithResult, RxFlow)
      runStep oldFlow = \case
        Step Consume arg ->
          let (newFlow, limitDelta) = maybeOpenRxWindow arg FCTWindowUpdate oldFlow
           in (Step (ConsumeWithResult limitDelta) arg, newFlow)
        Step Receive arg ->
          let (newFlow, isAcceptable) = checkRxLimit arg oldFlow
           in (Step (ReceiveWithResult isAcceptable) arg, newFlow)

  shrink trace@(Trace initialFlow steps) =
    {-
       -- in an earlier version of this test we did this in order to also shrink the frame sizes:
       instance Arbitrary OpScript where
         arbitrary = OpScript <$> arbitrary
         shrink (OpScript ops) = OpScript <$> (mconcat (f (inits ops)) :: [[Op]])
           where
             -- for every element, shrink every element in it
             f :: [[Op]] -> [[[Op]]]
             f = fmap $ \op -> transpose $ shrink <$> op

       data OpScript = OpScript [Op]

       -- instead, we look at the last step and all prefixes of a failing sample.
    -}
    trunc trace : (Trace initialFlow <$> init (inits steps))
    where
      trunc :: Trace -> Trace
      trunc keep@(Trace _ stp) = case reverse stp of
        [] -> keep
        [_] -> keep
        ((lastStep, lastFlow) : (_, initFlow) : _) -> Trace initFlow [(lastStep, lastFlow)]

-- invariants

-- TODO: make it obvious which RxFlow (in which step) is violating an expectation.  something with an index, maybe?
-- TODO: use ppShow and counterexample again.  doesn't matter if it's redundant.

assertTrace :: Trace -> Assertion
assertTrace (Trace initialFlow steps) = assertStep initialFlow `mapM_` steps
  where
    assertStep :: RxFlow -> (Step OpWithResult, RxFlow) -> Assertion
    assertStep oldFlow (step, newFlow) = do
      case step of
        Step (ConsumeWithResult limitDelta) arg -> do
          newFlow
            `shouldBe` RxFlow
              { rxfWindow = rxfWindow newFlow,
                rxfConsumed = rxfConsumed oldFlow + arg,
                rxfReceived = rxfReceived oldFlow,
                rxfLimit =
                  if rxfLimit oldFlow - rxfReceived oldFlow < rxfWindow oldFlow `div` 2 -- TODO: can we make more sense of this?
                    then rxfConsumed oldFlow + arg + rxfWindow oldFlow
                    else rxfLimit oldFlow
              }
          limitDelta
            `shouldBe` if rxfLimit oldFlow - rxfReceived oldFlow < rxfWindow oldFlow `div` 2 -- TODO: can we make more sense of this?
              then Just (rxfLimit newFlow - rxfLimit oldFlow)
              else Nothing
        Step (ReceiveWithResult isAcceptable) arg -> do
          newFlow
            `shouldBe` if isAcceptable
              then
                RxFlow
                  { rxfWindow = rxfWindow newFlow,
                    rxfConsumed = rxfConsumed oldFlow,
                    rxfReceived = rxfReceived oldFlow + arg,
                    rxfLimit = rxfLimit oldFlow
                  }
              else oldFlow

spec :: Spec
spec = do
  fprop "state transition graph checks out" assertTrace

-- cd ~/src/http2 ; cabal test spec --test-options='--seed 1637938524 -f checks'
