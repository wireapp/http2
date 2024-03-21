{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -Wno-orphans -Wno-incomplete-patterns #-}

module HTTP2.WindowSpec where

-- TODO: instead of consumed, received, don't we want received - consumed?  (to avoid overflows on long-living streams)

-- TODO: do we need to grant further assumptions on the operations args?  like, don't conume more than you've received so far?

import Data.List
import Network.Control
import Test.HUnit
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck
import Text.Show.Pretty

-- types

deriving instance Eq RxFlow

data Op
  = Consume {consumeArg :: Int, consumeResult :: Maybe Int}
  | Receive {receiveArg :: Int, receiveResult :: Maybe Bool}
  deriving (Eq, Show)

newtype OpScript = OpScript [Op]
  deriving (Eq, Show)

data OpTrace = OpTrace {traceStart :: RxFlow, traceSteps :: [(Op, RxFlow)]}
  deriving (Eq, Show)

-- arbitrary instances

instance Arbitrary RxFlow where
  arbitrary = newRxFlow <$> chooseInt (1, 2_000_000)

instance Arbitrary Op where
  arbitrary =
    oneof
      [ (`Consume` Nothing) <$> chooseInt (0, 2_000_000),
        (`Receive` Nothing) <$> chooseInt (0, 2_000_000)
      ]
  shrink = \case
    Consume i r -> (`Consume` r) <$> shrink i
    Receive i r -> (`Receive` r) <$> shrink i

instance Arbitrary OpScript where
  arbitrary = OpScript <$> arbitrary
  shrink (OpScript ops) = OpScript <$> (mconcat (f (inits ops)) :: [[Op]])
    where
      -- for every element, shrink every element in it
      f :: [[Op]] -> [[[Op]]]
      f = fmap $ \op -> transpose $ shrink <$> op

-- run a script

runOpScript :: RxFlow -> OpScript -> OpTrace
runOpScript initialFlow (OpScript steps) = OpTrace initialFlow (runManySteps initialFlow steps)
  where
    runManySteps :: RxFlow -> [Op] -> [(Op, RxFlow)]
    runManySteps _ [] = []
    runManySteps oldFlow (op : ops) =
      let step@(_, newFlow) = runStep oldFlow op
       in step : runManySteps newFlow ops

    runStep :: RxFlow -> Op -> (Op, RxFlow)
    runStep oldFlow = \case
      op@(Consume i Nothing) ->
        let (newFlow, limitDelta) = maybeOpenRxWindow i FCTWindowUpdate oldFlow
         in (op {consumeResult = limitDelta}, newFlow)
      op@(Receive i Nothing) ->
        let (newFlow, isAcceptable) = checkRxLimit i oldFlow
         in (op {receiveResult = Just isAcceptable}, newFlow)

-- invariants

assertOpTrace :: OpTrace -> Assertion
assertOpTrace (OpTrace initialFlow steps) = assertOpStep initialFlow `mapM_` steps
  where
    assertOpStep :: RxFlow -> (Op, RxFlow) -> Assertion
    assertOpStep oldFlow (op, newFlow) = do
      case op of
        Consume i limitDelta -> do
          (op, newFlow)
            `shouldBe` ( op,
                         RxFlow
                           { rxfWindow = rxfWindow newFlow,
                             rxfConsumed = rxfConsumed oldFlow + i,
                             rxfReceived = rxfReceived oldFlow,
                             rxfLimit =
                               if rxfLimit oldFlow - rxfReceived oldFlow < rxfWindow oldFlow `div` 2 -- TODO: can we make more sense of this?
                                 then rxfConsumed oldFlow + i + rxfWindow oldFlow
                                 else rxfLimit oldFlow
                           }
                       )
          limitDelta
            `shouldBe` if rxfLimit oldFlow - rxfReceived oldFlow < rxfWindow oldFlow `div` 2
              then Just (rxfLimit newFlow - rxfLimit oldFlow)
              else Nothing
        Receive i (Just isAcceptable) -> do
          if isAcceptable
            then
              newFlow
                `shouldBe` RxFlow
                  { rxfWindow = rxfWindow newFlow,
                    rxfConsumed = rxfConsumed oldFlow,
                    rxfReceived = rxfReceived oldFlow + i,
                    rxfLimit = rxfLimit oldFlow
                  }
            else
              newFlow
                `shouldBe` oldFlow

spec :: Spec
spec = do
  fprop "state transition graph checks out" $
    \(initialFlow, script) -> do
      let trace = runOpScript initialFlow script
      counterexample ("trace: " <> ppShow trace) (assertOpTrace trace)

-- Randomized with seed 1637938524
-- cd ~/src/http2 ; cabal test --test-options='--seed 1637938524'
