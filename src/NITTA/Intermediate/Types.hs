{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE NamedFieldPuns         #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# OPTIONS -Wall -Wcompat -Wredundant-constraints -fno-warn-missing-signatures #-}

{-|
Module      : NITTA.Intermediate.Types
Description : Types and instances, related to function description
Copyright   : (c) Aleksandr Penskoi, 2019
License     : BSD3
Maintainer  : aleksandr.penskoi@gmail.com
Stability   : experimental
-}
module NITTA.Intermediate.Types
    ( -- *Variables
      Var, Variables(..)
      -- *Function interface description
    , I(..), O(..), X(..)
    , Lock(..), Locks(..)
      -- *Function description
    , F(..), Function(..), WithFunctions(..)
      -- *Application level simulation
    , FunctionSimulation(..)
    , CycleCntx(..), Cntx(..)
    , getX, setZipX, cntxReceivedBySlice
      -- *Other
    , Patch(..), Diff(..), reverseDiff
    , Label(..)
    , castF
    , module NITTA.Intermediate.Values
    ) where

import           Data.Default
import           Data.List
import qualified Data.Map                    as M
import           Data.Maybe
import qualified Data.Set                    as S
import qualified Data.String.Utils           as S
import           Data.Tuple
import           Data.Typeable
import           NITTA.Intermediate.Values
import           NITTA.UIBackend.VisJS.Types


class WithFunctions a f | a -> f where
    -- |Получить список связанных функциональных блоков.
    functions :: a -> [f]


-----------------------------------------------------------

-- |Variable identifier. Used for simplify type description.
type Var v = ( Typeable v, Ord v, Show v, Label v )

-- |Type class of something, which is related to varibles.
class Variables a v | a -> v where
    -- |Get all related variables.
    variables :: a -> S.Set v



-----------------------------------------------------------

-- |Input variable.
newtype I v = I v
    deriving ( Show, Eq, Ord )

instance ( Eq v ) => Patch (I v) (v, v) where
    patch (v, v') i@(I v0)
        | v0 == v = I v'
        | otherwise = i

instance Variables (I v) v where
    variables (I v) = S.singleton v



-- |Output variables.
newtype O v = O (S.Set v)
    deriving ( Eq, Ord )

instance ( Ord v ) => Patch (O v) (v, v) where
    patch (v, v') o@(O vs)
        | v `S.member` vs = O $ S.fromList (v':(S.elems vs \\ [v]))
        | otherwise = o

instance ( Show v ) => Show (O v) where
    show (O vs) = "O " ++ show (S.elems vs)

instance Variables (O v) v where
    variables (O v) = v



-- |Value of variable (constant or initial value).
newtype X x = X x
    deriving ( Show, Eq )



-- |The type class for a thing, which can defines order of variable transfers.
class ( Var v ) => Locks x v | x -> v where
    locks :: x -> [Lock v]

-- |Variable casuality.
data Lock v
    = Lock
        { locked :: v
        , lockBy :: v
        }
    deriving ( Show )



-----------------------------------------------------------

-- |Type class for application algorithm functions.
class Function f v | f -> v where
    -- |Get all input variables.
    inputs :: f -> S.Set v
    inputs _ = S.empty
    -- |Get all output variables.
    outputs :: f -> S.Set v
    outputs _ = S.empty
    -- |Is function break evaluation loop (throw data to a next loop).
    isBreakLoop :: f -> Bool
    isBreakLoop _ = False
    -- |Sometimes, one function can cause internal process unit lock for another function.
    isInternalLockPossible :: f -> Bool
    isInternalLockPossible _ = False



-- |Box forall functions.
data F v x where
    F ::
        ( Function f v
        , Patch f (v, v)
        , Locks f v
        , Show f
        , Label f
        , ToVizJS f
        , FunctionSimulation f v x
        , Typeable f
        ) => f -> F v x

instance Eq (F v x) where
    F a == F b = show a == show b

instance Function (F v x) v where
    isBreakLoop (F f) = isBreakLoop f
    isInternalLockPossible (F f) = isInternalLockPossible f
    inputs (F f) = inputs f
    outputs (F f) = outputs f

instance FunctionSimulation (F v x) v x where
    simulate cntx (F f) = simulate cntx f

instance Label (F v x) where
    label (F f) = label f

instance ( Var v ) => Locks (F v x) v where
    locks (F f) = locks f

instance Ord (F v x) where
    (F a) `compare` (F b) = show a `compare` show b

instance Patch (F v x) (v, v) where
    patch diff (F f) = F $ patch diff f

instance ( Ord v ) => Patch (F v x) (Diff v) where
    patch Diff{ diffI, diffO } f0 = let
            diffI' = map (\v -> case diffI M.!? v of
                    Just v' -> Just (v, v')
                    Nothing -> Nothing
                ) $ S.elems $ inputs f0
            diffO' = map (\v -> case diffO M.!? v of
                    Just v' -> Just (v, v')
                    Nothing -> Nothing
                ) $ S.elems $ outputs f0
        in foldl (\f diff -> patch diff f) f0 $ catMaybes $ diffI' ++ diffO'


instance ( Patch b v ) => Patch [b] v where
    patch diff fs = map (patch diff) fs

instance Show (F v x) where
    show (F f) = S.replace "\"" "" $ show f

instance ( Var v ) => Variables (F v x) v where
    variables (F f) = inputs f `S.union` outputs f

instance {-# OVERLAPS #-} ToVizJS (F v x) where
    toVizJS (F f) = toVizJS f

castF :: ( Typeable f, Typeable v, Typeable x ) => F v x -> Maybe (f v x)
castF (F f) = cast f



-----------------------------------------------------------

-- |The type class for function simulation.
class FunctionSimulation f v x | f -> v x where
    -- FIXME: CycleCntx - problem, because its prevent Receive simulation with
    -- data drop (how implement that?).
    simulate :: CycleCntx v x -> f -> Either String (CycleCntx v x)


data CycleCntx v x = CycleCntx{ cycleCntx :: M.Map v x }
    deriving ( Show )

instance Default (CycleCntx v x) where
    def = CycleCntx def

data Cntx v x
    = Cntx
        { cntxProcess     :: [ CycleCntx v x ]
        , cntxReceived    :: M.Map v [x]
        , cntxThrown      :: [ (v, [v]) ]
        , cntxCycleNumber :: Int
        }
instance {-# OVERLAPS #-} ( Show v, Show x ) => Show (Cntx v x) where
    show Cntx{ cntxProcess, cntxCycleNumber } = let
            header = S.join "\t" $ sort $ map show $ M.keys $ cycleCntx $ head cntxProcess
            body = map (row . cycleCntx) $ take cntxCycleNumber cntxProcess
        in S.join "\n" (header : body)
        where
            row cntx = S.join "\t" $  map (show . snd) $ sortOn (show . fst) $ M.assocs cntx

instance Default (Cntx v x) where
    def = Cntx
        { cntxProcess=def
        , cntxReceived=def
        , cntxThrown=def
        , cntxCycleNumber=5
        }

cntxReceivedBySlice Cntx{ cntxReceived } = cntxReceivedBySlice' $ M.assocs cntxReceived
cntxReceivedBySlice' received
    | all (not . null . snd) received
    = let
        slice = M.fromList [ (v, x) | ( v, x:_ ) <- received ]
        received' = [ (v, xs) | ( v, _:xs ) <- received ]
    in slice : cntxReceivedBySlice' received'
    | otherwise = []

getX (CycleCntx cntx) v = case cntx M.!? v of
        Just x  -> Right x
        Nothing -> Left $ "variable value not defined: " ++ show v

setX cycleCntx vxs = setX' cycleCntx vxs
setZipX cycleCntx vs x = setX cycleCntx $ zip (S.elems vs) $ repeat x

setX' cycleCntx [] = Right cycleCntx
setX' (CycleCntx cntx) ((v, x):vxs)
    | M.member v cntx = Left $ "variable value already defined: " ++ show v
    | otherwise = setX' (CycleCntx $ M.insert v x cntx) vxs


-----------------------------------------------------------

-- |Patch class allows replacing one variable by another. Especially for algorithm refactor.
class Patch f diff where
    patch :: diff -> f -> f

data Diff v = Diff
    { diffI :: M.Map v v
    , diffO :: M.Map v v
    }

reverseDiff Diff{ diffI, diffO } = Diff
    { diffI=M.fromList $ map swap $ M.assocs diffI
    , diffO=M.fromList $ map swap $ M.assocs diffO
    }

instance Default (Diff v) where
    def = Diff def def



-- |Type class for making fine label for Functions (firtly for VisJS).
class Label a where
    label :: a -> String

instance ( Show (f v x) ) => Label (f v x) where
    label f = S.replace "\"" "" $ show f

instance Label String where
    label s = s