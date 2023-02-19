{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- |
Module      : NITTA.Model.Problems.Refactor.BreakLoop
Description : Refactoring for support computational loops
Copyright   : (c) Aleksandr Penskoi, 2021
License     : BSD3
Maintainer  : aleksandr.penskoi@gmail.com
Stability   : experimental

BreakLoop example:

> BreakLoop x o i

before:

> l@( Loop (X x) (O o) (I i) )

after:

> LoopEnd l (I i)
> LoopBegin l (O o)

For more details: 'NITTA.Intermediate.Functions.Loop'
-}
module NITTA.Model.Problems.Refactor.BreakLoop (
    BreakLoop (..),
    BreakLoopProblem (..),
    recLoop,
    recLoopIn,
    recLoopOut,
) where

import Data.Set qualified as S
import GHC.Generics
import NITTA.Intermediate.Functions
import NITTA.Intermediate.Types

data BreakLoop v x = BreakLoop
    { loopX :: x
    -- ^ initial looped value
    , loopO :: S.Set v
    -- ^ output variables
    , loopI :: v
    -- ^ input variable
    }
    deriving (Generic, Eq)

instance (Var v, Val x) => Show (BreakLoop v x) where
    show = ("BreakLoop: " <>) . show . recLoop

class BreakLoopProblem u v x | u -> v x where
    breakLoopOptions :: u -> [BreakLoop v x]
    breakLoopOptions _ = []

    breakLoopDecision :: u -> BreakLoop v x -> u
    breakLoopDecision _ _ = error "not supported"

recLoop BreakLoop{loopX, loopO, loopI} =
    packF $ Loop (X loopX) (O loopO) (I loopI)

recLoopIn BreakLoop{loopX, loopO, loopI} =
    packF $ LoopEnd (Loop (X loopX) (O loopO) (I loopI)) (I loopI)

recLoopOut BreakLoop{loopX, loopO, loopI} =
    packF $ LoopBegin (Loop (X loopX) (O loopO) (I loopI)) (O loopO)
