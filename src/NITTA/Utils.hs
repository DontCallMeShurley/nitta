{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE UndecidableInstances      #-}

module NITTA.Utils where

import           Control.Monad.State
import           Data.Default
import           Data.List            (find, intersect, isSubsequenceOf,
                                       partition)
import qualified Data.List            as L
import qualified Data.Map             as M
import           Data.Maybe           (catMaybes, fromMaybe, isJust)
import           Data.Typeable        (Typeable, cast, typeOf)
import           NITTA.FunctionBlocks
import qualified NITTA.FunctionBlocks as FB
import           NITTA.Types
import           System.Exit
import           System.Process




isPull (PUVar (Pull _) _) = True
isPull _                  = False
isPush (PUVar (Push _) _) = True
isPush _                  = False




modifyProcess p state = runState state p

add time info = do
  p@Process{..} <- get
  put p { nextUid=succ nextUid
        , steps=Step nextUid time info : steps
        }
  return nextUid

relation r = do
  p@Process{..} <- get
  put p{ relations=r : relations }

setTime t = do
  p <- get
  put p{ tick=t }

whatsHappen t = filter (\Step{ time=Event{..} } -> eStart <= t && t < eStart + eDuration)
infoAt t = catMaybes . map (\Step{..} -> cast info) . whatsHappen t
filterSteps :: Typeable a => [Step v t] -> [(Step v t, a)]
filterSteps = catMaybes . map (\step@Step{..} -> fmap (step, ) $ cast info)



fromLeft :: a -> Either a b -> a
fromLeft _ (Left a) = a
fromLeft a _        = a
fromRight :: b -> Either a b -> b
fromRight _ (Right b) = b
fromRight b _         = b
