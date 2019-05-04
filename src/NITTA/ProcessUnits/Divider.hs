{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# OPTIONS -Wall -Wcompat -Wredundant-constraints -fno-warn-missing-signatures -fno-warn-type-defaults #-}

{-|
Module      : NITTA.ProcessUnits.Divider
Description :
Copyright   : (c) Aleksandr Penskoi, 2018
License     : BSD3
Maintainer  : aleksandr.penskoi@gmail.com
Stability   : experimental
-}
module NITTA.ProcessUnits.Divider
    ( divider
    , Ports(..)
    ) where

import           Control.Monad                 (void, when)
import           Data.Bits                     (finiteBitSize)
import           Data.Default
import           Data.List                     (partition, sortBy)
import           Data.Maybe                    (fromMaybe)
import           Data.Set                      (Set, member)
import qualified Data.Set                      as S
import           NITTA.Functions               (castF)
import qualified NITTA.Functions               as F
import           NITTA.Types
import           NITTA.Types.Project
import           NITTA.Utils
import           NITTA.Utils.Process
import           NITTA.Utils.Snippets
import           Numeric.Interval              (Interval, inf, intersection,
                                                singleton, sup, width, (...))
import           Text.InterpolatedString.Perl6 (qc)


data InputDesc
    = Numer
    | Denom
    deriving ( Show, Eq )

data OutputDesc
    = Quotient
    | Remain
    deriving ( Show, Eq )



data Divider v x t
    = Divider
        { jobs            :: [Job v x t]
        , remains         :: [F v x]
        , targetIntervals :: [Interval t]
        , sourceIntervals :: [Interval t]
        , process_        :: Process v x t
        , latency         :: t
        , pipeline        :: t
        , mock            :: Bool
        }

divider pipeline mock = Divider
    { jobs=[]
    , remains=[]
    , targetIntervals=[]
    , sourceIntervals=[]
    , process_=def
    , latency=1
    , pipeline
    , mock
    }

instance ( Time t ) => Default (Divider v x t) where
    def = divider 4 True


instance ( Ord t ) => WithFunctions (Divider v x t) (F v x) where
    functions Divider{ process_, remains, jobs }
        = functions process_
        ++ remains
        ++ map function jobs

data Job v x t
    = Input
        { function :: F v x
        , startAt  :: t
        , inputSeq :: [(InputDesc, v)]
        }
    | InProgress
        { function :: F v x
        , startAt  :: t
        , finishAt :: t
        }
    | Output
        { function  :: F v x
        , startAt   :: t
        , rottenAt  :: Maybe t
        , finishAt  :: t
        , outputRnd :: [(OutputDesc, Set v)]
        }
    deriving ( Eq, Show )


nextTargetTick Divider{ targetIntervals=[] }  = 0
nextTargetTick Divider{ targetIntervals=i:_ } = sup i + 1

nextSourceTick Divider{ sourceIntervals=[] }  = 0
nextSourceTick Divider{ sourceIntervals=i:_ } = sup i + 1



findJob f jobs
    = case partition f jobs of
        ([i], other) -> Just (i, other)
        ([], _)      -> Nothing
        _            -> error "findInput internal error"

findInput = findJob (\case Input{} -> True; _ -> False)
findOutput = findJob (\case Output{} -> True; _ -> False)

findNextInProgress jobs
    | let (inProgress, other) = partition (\case InProgress{} -> True; _ -> False) jobs
    , let inProgress' = sortBy
            ( \InProgress{ finishAt=a } InProgress{ finishAt=b } ->
                b `compare` a )
            inProgress
    = case inProgress' of
        []     -> Nothing
        (j:js) -> Just (j, js ++ other)



remain2input nextTick f
    | Just (F.Division (I n) (I d) (O _q) (O _r)) <- castF f
    = Input{ function=f, startAt=nextTick, inputSeq=[(Numer, n), (Denom, d)] }
remain2input _ _ = error "divider inProgress2Output internal error"

inProgress2Output rottenAt InProgress{ function, startAt, finishAt }
    | Just (F.Division _ _ (O q) (O r)) <- castF function
    = Output{ function, rottenAt, startAt, finishAt, outputRnd=filter (not . null . snd) [(Quotient, q), (Remain, r)] }
inProgress2Output _ _ = error "divider inProgress2Output internal error"


resolveColisions [] opt = [ opt ]
resolveColisions intervals opt@EndpointO{ epoAt=tc@TimeConstrain{ tcAvailable } }
    | all ((0 ==) . width . intersection tcAvailable) intervals
    = [ opt ]
    | otherwise  -- FIXME: we must prick out work point from intervals
    , let from = maximum $ map sup intervals
    = [ opt{ epoAt=tc{ tcAvailable=from ... inf tcAvailable } } ]


rottenTime Divider{ pipeline, latency } jobs
    | Just (InProgress{ startAt }, _) <- findNextInProgress jobs
    = Just (startAt + pipeline + latency )
    | Just (Input{ startAt }, _) <- findOutput jobs
    = Just (startAt + pipeline + latency )
    | otherwise = Nothing


pushOutput pu@Divider{ jobs }
    | Just _ <- findOutput jobs = pu
    | Just (ij, other) <- findNextInProgress jobs
    = pu{ jobs=inProgress2Output (rottenTime pu other) ij : other }
    | otherwise = pu



instance ( VarValTime v x t
         ) => ProcessorUnit (Divider v x t) v x t where
    tryBind f pu@Divider{ remains }
        | Just (F.Division (I _n) (I _d) (O _q) (O _r)) <- castF f
        = Right pu
            { remains=f : remains
            }
        | otherwise = Left $ "Unknown functional block: " ++ show f
    process = process_
    setTime t pu@Divider{ process_ } = pu{ process_=process_{ nextTick=t } }


instance ( Var v ) => Locks (Divider v x t) v where
    -- FIXME:
    locks _ = []


instance ( VarValTime v x t
         ) => DecisionProblem (EndpointDT v t)
                   EndpointDT (Divider v x t) where
    options _proxy pu@Divider{ targetIntervals, sourceIntervals, remains, jobs }
        = concatMap (resolveColisions sourceIntervals) targets
        ++ concatMap (resolveColisions targetIntervals) sources
        where
            target v = EndpointO
                (Target v)
                $ TimeConstrain (nextTargetTick pu ... maxBound) (singleton 1)
            targets
                | Just (Input{ inputSeq=(_tag, v):_ }, _) <- findInput jobs
                = [ target v ]
                | otherwise = map (target . snd . head . inputSeq . remain2input nextTick) remains

            source Output{ outputRnd, rottenAt, finishAt }
                = map
                    ( \(_tag, vs) -> EndpointO
                        (Source vs)
                        $ TimeConstrain
                            (max finishAt (nextSourceTick pu) ... fromMaybe maxBound rottenAt)
                            (singleton 1) )
                    outputRnd
            source _ = error "Divider internal error: source."

            sources
                | Just (out, _) <- findOutput jobs = source out
                | Just (ij, other) <- findNextInProgress jobs
                 = source $ inProgress2Output (rottenTime pu other) ij
                | otherwise = []


    -- FIXME: vertical relations
    decision
            proxy
            pu@Divider{ jobs, targetIntervals, remains, pipeline, latency }
            d@EndpointD{ epdRole=Target v, epdAt }
        | ([f], fs) <- partition (\f -> v `member` variables f) remains
        = decision
            proxy
            pu
                { remains=fs
                , jobs=remain2input (sup epdAt) f : jobs
                }
            d

        | Just (i@Input{ inputSeq=((tag, nextV):vs), function, startAt }, other) <- findInput jobs
        , v == nextV
        , let finishAt = sup epdAt + pipeline + latency
        = pushOutput pu
            { targetIntervals=epdAt : targetIntervals
            , jobs=if null vs
                then InProgress{ function, startAt, finishAt } : other
                else i{ inputSeq=vs } : other
            , process_=execSchedule pu $ do
                _endpoints <- scheduleEndpoint d $ scheduleInstruction (inf epdAt) (sup epdAt) $ Load tag
                -- костыль, необходимый для корректной работы автоматически сгенерированных тестов,
                -- которые берут информацию о времени из Process
                updateTick (sup epdAt)
            }

    decision
            _proxy
            pu@Divider{ jobs, sourceIntervals }
            d@EndpointD{ epdRole=Source vs, epdAt }
        | Just (out@Output{ outputRnd, startAt, function }, other) <- findOutput jobs
        , (vss, [(tag, vs')]) <- partition (\(_tag, vs') -> null (vs `S.intersection` vs')) outputRnd
        , let vss' = let tmp = vs' `S.difference` vs
                in if S.null tmp
                    then vss
                    else (tag, tmp) : vss
        = pushOutput pu
            { sourceIntervals=epdAt : sourceIntervals
            , jobs=if null vss'
                then other
                else out{ outputRnd=vss' } : other
            , process_=execSchedule pu $ do
                _endpoints <- scheduleEndpoint d $ scheduleInstruction (inf epdAt) (sup epdAt) $ Out tag
                when (null vss') $ void $ scheduleFunction startAt (sup epdAt) function
                -- костыль, необходимый для корректной работы автоматически сгенерированных тестов,
                -- которые берут информацию о времени из Process
                updateTick (sup epdAt)
            }

    decision _ _ _ = error "divider decision internal error"



instance ( VarValTime v x t, Integral x
        ) => Simulatable (Divider v x t) v x where
    simulateOn cntx _ f
        | Just f'@F.Division{} <- castF f = simulate cntx f'
        | otherwise = error $ "Can't simulate " ++ show f ++ " on Shift."



instance Controllable (Divider v x t) where
    data Instruction (Divider v x t)
        = Load InputDesc
        | Out OutputDesc
        deriving (Show)

    data Microcode (Divider v x t)
        = Microcode
            { wrSignal :: Bool
            , wrSelSignal :: Bool
            , oeSignal :: Bool
            , oeSelSignal :: Bool
            } deriving ( Show, Eq, Ord )

    mapMicrocodeToPorts Microcode{..} Ports{..} =
        [ (wr, Bool wrSignal)
        , (wrSel, Bool wrSelSignal)
        , (oe, Bool oeSignal)
        , (oeSel, Bool oeSelSignal)
        ]


instance Default (Microcode (Divider v x t)) where
    def = Microcode
        { wrSignal=False
        , wrSelSignal=False
        , oeSignal=False
        , oeSelSignal=False
        }
instance UnambiguouslyDecode (Divider v x t) where
    decodeInstruction (Load Numer)   = def{ wrSignal=True, wrSelSignal=False }
    decodeInstruction (Load Denom)   = def{ wrSignal=True, wrSelSignal=True }
    decodeInstruction (Out Quotient) = def{ oeSignal=True, oeSelSignal=False }
    decodeInstruction (Out Remain)   = def{ oeSignal=True, oeSelSignal=True }


instance Connected (Divider v x t) where
    data Ports (Divider v x t)
        = Ports{ wr, wrSel, oe, oeSel :: SignalTag }
        deriving ( Show )


instance ( Val x, Show t
         ) => TargetSystemComponent (Divider v x t) where
    moduleName _ _ = "pu_div"
    software _ _ = Empty
    hardware title pu@Divider{ mock } = Aggregate Nothing
        [ if mock
            then FromLibrary "div/div_mock.v"
            else FromLibrary "div/div.v"
        , FromLibrary $ "div/" ++ moduleName title pu ++ ".v"
        ]
    hardwareInstance title _pu@Divider{ mock, pipeline }
            TargetEnvironment
                { unitEnv=ProcessUnitEnv
                    { signal
                    , dataIn, dataOut
                    , parameterAttrWidth, attrIn, attrOut
                    }
                , signalClk
                , signalRst
                }
            Ports{ oe, oeSel, wr, wrSel }
        = fixIndent [qc|
|           pu_div #
|                   ( .DATA_WIDTH( { finiteBitSize (def :: x) } )
|                   , .ATTR_WIDTH( { parameterAttrWidth } )
|                   , .INVALID( 0 ) // FIXME: Сделать и протестировать работу с атрибутами
|                   , .PIPELINE( { pipeline } )
|                   , .SCALING_FACTOR_POWER( { fractionalBitSize (def :: x) } )
|                   , .MOCK_DIV( { bool2verilog mock } )
|                   ) { title }
|               ( .clk( { signalClk } )
|               , .rst( { signalRst } )
|               , .signal_wr( { signal wr } )
|               , .signal_wr_sel( { signal wrSel } )
|               , .data_in( { dataIn } )
|               , .attr_in( { attrIn } )
|               , .signal_oe( { signal oe } )
|               , .signal_oe_sel( { signal oeSel } )
|               , .data_out( { dataOut } )
|               , .attr_out( { attrOut } )
|               );
|           |]
    hardwareInstance _title _pu TargetEnvironment{ unitEnv=NetworkEnv{} } _bnPorts
        = error "Should be defined in network."


instance IOTest (Divider v x t) v x


instance ( VarValTime v x t, Integral x
         ) => Testable (Divider v x t) v x where
    testBenchImplementation prj@Project{ pName, pUnit }
        = Immediate (moduleName pName pUnit ++ "_tb.v")
            $ snippetTestBench prj SnippetTestBenchConf
                { tbcSignals=["oe", "oeSel", "wr", "wrSel"]
                , tbcPorts=Ports
                    { oe=SignalTag 0
                    , oeSel=SignalTag 1
                    , wr=SignalTag 2
                    , wrSel=SignalTag 3
                    }
                , tbcSignalConnect= \case
                    (SignalTag 0) -> "oe"
                    (SignalTag 1) -> "oeSel"
                    (SignalTag 2) -> "wr"
                    (SignalTag 3) -> "wrSel"
                    _ -> error "testBenchImplementation wrong signal"
                , tbcCtrl= \Microcode{ oeSignal, oeSelSignal, wrSignal, wrSelSignal } ->
                    [qc|oe <= {bool2verilog oeSignal}; oeSel <= {bool2verilog oeSelSignal}; wr <= {bool2verilog wrSignal}; wrSel <= {bool2verilog wrSelSignal};|]
                , tbDataBusWidth=finiteBitSize (def :: x)
                }
