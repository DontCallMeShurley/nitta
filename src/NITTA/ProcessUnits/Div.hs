{-# LANGUAGE AllowAmbiguousTypes    #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE NamedFieldPuns         #-}
{-# LANGUAGE PartialTypeSignatures  #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# OPTIONS -Wall -fno-warn-missing-signatures #-}

module NITTA.ProcessUnits.Div
  ( Div(..)
  , Link(..)
  ) where

import           Control.Monad.State
import           Data.Default
import           Data.Either
import           Data.List            (find)
import qualified Data.Set             as S
import           Data.Typeable
import           NITTA.FunctionBlocks (castFB)
import qualified NITTA.FunctionBlocks as FB
import           NITTA.Types
import           NITTA.Utils
import           NITTA.Utils.Lens
import           Numeric.Interval     ((...))



data ArgumentSel
  = Denom
  | Numer
  deriving ( Show, Eq )

data ResultSel
  = Quotient
  |	Remain
  deriving ( Show, Eq )

data Div v x t
  = Div
  { puTarget  :: [(ArgumentSel, v)]
  , puSource  :: [(ResultSel, v)]
  , puRemain  :: [FB (Parcel v x)]
  , puProcess :: Process (Parcel v x) t
  } deriving ( Show )

instance ( Time t, Var v ) => Default (Div v x t) where
  def = Div [] [] [] def



instance ( Var v, Time t
         , Typeable x
         ) => DecisionProblem (EndpointDT v t)
                   EndpointDT (Div v x t)
         where
  options _proxy Div{} = []
  decision _proxy pu@Div{} act = undefined


instance ( Var v, Time t
         ) => ProcessUnit (Div v x t) (Parcel v x) t where
  bind fb pu@Div{ puRemain }
    | Just FB.Div{} <- castFB fb = Right pu{ puRemain=fb : puRemain }
    | otherwise = Left $ "Unknown functional block: " ++ show fb
  process = puProcess
  setTime t pu@Div{ puProcess } = pu{ puProcess=puProcess{ nextTick=t } }



instance Controllable (Div v x t) where
  data Microcode (Div v x t)
    = Microcode{ wrSignal :: Bool
               , selSignal :: Bool
               , oeSignal :: Bool
               , resSelSignal :: Bool
               } deriving ( Show, Eq, Ord )

  data Instruction (Div v x t)
    = Nop
    | Load ArgumentSel
    | Out ResultSel
    deriving (Show)



instance Default (Instruction (Div v x t)) where
  def = Nop



instance Default (Microcode (Div v x t)) where
  def = Microcode{ wrSignal=False
                 , selSignal=False
                 , oeSignal=False
                 , resSelSignal=False
                 }


instance UnambiguouslyDecode (Div v x t) where
  decodeInstruction Nop            = def
  decodeInstruction (Load Denom)   = def{ wrSignal=True, selSignal=True }
  decodeInstruction (Load Numer)   = def{ wrSignal=True, selSignal=False }
  decodeInstruction (Out Quotient) = def{ oeSignal=True, resSelSignal=True }
  decodeInstruction (Out Remain)   = def{ oeSignal=True, resSelSignal=False }



instance Connected (Div v x t) i where
  data Link (Div v x t) i
    = Link { wr, wrSel, oe, oeSel :: i } deriving ( Show )
  transmitToLink Microcode{..} Link{..}
    = [ (wr, B wrSignal)
      , (wrSel, B selSignal)
      , (oe, B resSelSignal)
      , (oeSel, B oeSignal)
      ]


instance ( Var v
         , Integral x
         ) => Simulatable (Div v x t) v x where
  simulateOn cntx _ fb
    | Just fb'@FB.Div{} <- castFB fb = simulate cntx fb'
    | otherwise = error $ "Can't simulate " ++ show fb ++ " on Shift."



instance ( Var v, Show t ) => DefinitionSynthesis (Div v x t) where
  moduleName _ = "pu_div"
  hardware pu = Project "" [ FromLibrary "div/div_placeholder.v"
                          --  , FromLibrary "div/div.v"
                           , FromLibrary $ "div/" ++ moduleName pu ++ ".v"
                           ]
  software pu = Empty

instance ( Time t, Var v
         ) => Synthesis (Div v x t) LinkId where
  hardwareInstance _ name NetworkLink{..} Link{..} = renderST
    [ "pu_div"
    , "  #( .DATA_WIDTH( " ++ link dataWidth ++ " )"
    , "   , .ATTR_WIDTH( " ++ link attrWidth ++ " )"
    -- , "   , .INVALID( INVALID )" -- FIXME:
    , "   ) $name$"
    , "  ( .clk( " ++ link clk ++ " )"
    , "  , .rst( " ++ link rst ++ " )"
    , "  , .signal_wr( " ++ link wr ++ " )"
    , "  , .signal_sel( " ++ control wrSel ++ " )"
    , "  , .data_in( " ++ link dataIn ++ " )"
    , "  , .attr_in( " ++ link attrIn ++ " )"
    , "  , .signal_oe( " ++ control oe ++ " )"
    , "  , .signal_res( " ++ control oeSel ++ " )"
    , "  , .data_out( " ++ link dataOut ++ " )"
    , "  , .attr_out( " ++ link attrOut ++ " )"
    , "  );"
    ] [("name", name)]
    where
      control = link . controlBus