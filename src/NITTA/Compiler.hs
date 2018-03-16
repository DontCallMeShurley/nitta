{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# OPTIONS -Wall -fno-warn-missing-signatures #-}

module NITTA.Compiler
  ( bindAll
  , bindAllAndNaiveSchedule
  , compiler
  , CompilerDT
  , CompilerStep(..)
  , isSchedulingComplete
  , naive
  , naive'
  , NaiveOpt(..)
  , option2decision
  , optionsWithMetrics
  , passiveOption2action
  , GlobalMetrics(..)
  , SpecialMetrics(..)
  ) where

import           Control.Arrow    (second)
import           Data.Default
import           Data.List        (find, intersect, sort, sortOn)
import qualified Data.Map         as M
import           Data.Maybe
import           Data.Proxy
import           GHC.Generics
import           NITTA.BusNetwork
import           NITTA.FlowGraph
import           NITTA.Types
import           NITTA.Utils
import           NITTA.Utils.Lens
import           Numeric.Interval (Interval, (...))


-- | Выполнить привязку списка функциональных блоков к указанному вычислительному блоку.
bindAll fbs pu = either (\l -> error $ "Can't bind FB to PU: " ++ show l) id $ foldl nextBind (Right pu) fbs
  where
    nextBind (Right pu') fb = bind fb pu'
    nextBind (Left r) _     = error r


-- | Выполнить привязку списка функциональных блоков к указанному вычислительному блоку и наивным
-- образом спланировать вычислительный процесса пасивного блока обработки данных (PUClass Passive).
bindAllAndNaiveSchedule alg pu0 = naiveSchedule $ bindAll alg pu0
  where
    naiveSchedule pu
      | opt : _ <- options endpointDT pu = naiveSchedule $ decision endpointDT pu $ passiveOption2action opt
      | otherwise = pu


-- | Проверка является процесс планирования вычислительного процесса полностью завершимым (все
-- функционаные блоки могут быть выполнены). Данная функция используется для проверки возможности
-- привязки функционального блока.
isSchedulingComplete pu
  = let os = options endpointDT pu
        d = passiveOption2action $ head os
        algVars = sort $ concatMap variables $ functionalBlocks pu
        processVars = sort $ concatMap variables $ getEndpoints $ process pu
    in if null os
        then algVars == processVars
        else isSchedulingComplete $ decision endpointDT pu d
        -- then trace ("end on: " ++ show processVars ++ " " ++ show algVars) $ algVars == processVars
        -- else trace ("continue: " ++ show d ++ " " ++ show os) $ isSchedulingComplete $ decision endpointDT pu d


-- | Настройки процесса компиляции.
newtype NaiveOpt = NaiveOpt
  { -- | Порог колличества вариантов, после которого пересылка данных станет приоритетнее, чем
    -- привязка функциональных блоков.
    threshhold :: Int
  } deriving ( Generic )

instance Default NaiveOpt where
  def = NaiveOpt{ threshhold=2
                }



---------------------------------------------------------------------
-- * Представление решения компилятора.


data CompilerDT title tag v t
compiler = Proxy :: Proxy CompilerDT


instance DecisionType (CompilerDT title tag v t) where
  data Option (CompilerDT title tag v t)
    = ControlFlowOption (ControlFlowGraph tag v)
    | BindingOption (FB (Parcel v) v) title
    | DataFlowOption (Source title (TimeConstrain t)) (Target title v (TimeConstrain t))
    deriving ( Generic )

  data Decision (CompilerDT title tag v t)
    = ControlFlowDecision (ControlFlowGraph tag v)
    | BindingDecision (FB (Parcel v) v) title
    | DataFlowDecision (Source title (Interval t)) (Target title v (Interval t))
    deriving ( Generic )

filterBindingOption opts = [ x | x@BindingOption{} <- opts ]
filterControlFlowOption opts = [ x | x@ControlFlowOption{} <- opts ]
filterDataFlowOption opts = [ x | x@DataFlowOption{} <- opts ]

specializeDataFlowOption (DataFlowOption s t) = DataFlowO s t
specializeDataFlowOption _ = error "Can't specialize non DataFlow option!"

generalizeDataFlowOption (DataFlowO s t) = DataFlowOption s t
generalizeControlFlowOption (ControlFlowO x) = ControlFlowOption x
generalizeBindingOption (BindingO s t) = BindingOption s t



instance ( Tag tag, Time t, Var v
         ) => DecisionProblem (CompilerDT String tag v (TaggedTime tag t))
                   CompilerDT (BranchedProcess String tag v (TaggedTime tag t))
         where
  options _ Bush{..} = options compiler currentBranch
  options _ branch@Branch{..} = concat
    [ map generalizeDataFlowOption dataFlowOptions
    , map generalizeControlFlowOption $ options controlFlowDecision branch
    , map generalizeBindingOption $ options binding branch
    ]
    where
      dataFlowOptions = sensibleOptions $ filterByControlModel controlFlow $ options dataFlowDT topPU
      filterByControlModel controlModel opts
        = let cfOpts = allowByControlFlow controlModel
          in map (\t@DataFlowO{..} -> t
                  { dfoTargets=M.fromList $ map (\(v, desc) -> (v, if v `elem` cfOpts
                                                                      then desc
                                                                      else Nothing)
                                                ) $ M.assocs dfoTargets
                  }) opts
      sensibleOptions = filter $ \DataFlowO{..} -> any isJust $ M.elems dfoTargets

  decision _ bush@Bush{..} act
    = let bush' = bush{ currentBranch=decision compiler currentBranch act }
      in if isCurrentBranchOver bush'
        then finalizeBranch bush'
        else bush'
  decision _ branch (BindingDecision fb title)
    = decision binding branch $ BindingD fb title
  decision _ branch (ControlFlowDecision d)
    = decision controlFlowDecision branch $ ControlFlowD d
  decision _ branch@Branch{ topPU=pu, .. } (DataFlowDecision src trg)
    = branch{ topPU=decision dataFlowDT pu $ DataFlowD src trg }


option2decision (ControlFlowOption cf)   = ControlFlowDecision cf
option2decision (BindingOption fb title) = BindingDecision fb title
option2decision (DataFlowOption src trg)
  = let pushTimeConstrains = map snd $ catMaybes $ M.elems trg
        predictPullStartFromPush o = o^.avail.infimum - 1 -- сдвиг на 1 за счёт особенностей используемой сети.
        pullStart    = maximum $ (snd src^.avail.infimum) : map predictPullStartFromPush pushTimeConstrains
        pullDuration = maximum $ map (\o -> o^.dur.infimum) $ snd src : pushTimeConstrains
        pullEnd = pullStart + pullDuration - 1
        pushStart = pullStart + 1
        mkEvent (from_, tc@TimeConstrain{..})
          = Just (from_, pushStart ... (pushStart + tc^.dur.infimum - 1))
        pushs = map (second $ maybe Nothing mkEvent) $ M.assocs trg
    in DataFlowDecision ( fst src, pullStart ... pullEnd ) $ M.fromList pushs



---------------------------------------------------------------------
-- * Наивный, но полноценный компилятор.

data CompilerStep title tag v t
  = CompilerStep
    { state        :: BranchedProcess title tag v t
    , config       :: NaiveOpt
    , lastDecision :: Maybe (Decision (CompilerDT title tag v t))
    }
  deriving ( Generic )

instance Default (CompilerStep title tag v t) where
  def = CompilerStep{ state=undefined
                    , config=def
                    , lastDecision=Nothing
                    }


instance ( Tag tag, Time t, Var v
         ) => DecisionProblem (CompilerDT String tag v (TaggedTime tag t))
                   CompilerDT (CompilerStep String tag v (TaggedTime tag t))
         where
  options proxy CompilerStep{..} = options proxy state
  decision proxy st@CompilerStep{..} act = st{ state=decision proxy state act }


optionsWithMetrics CompilerStep{..}
  = sortOn (\(x, _, _, _, _) -> x) $ map measure' opts
  where
    opts = options compiler state
    gm = measureG opts state
    measure' o
      = let m = measure opts state o
        in ( integral gm m, gm, m, o, option2decision o )

naive' st@CompilerStep{..}
  = if null opts
    then Nothing
    else Just st{ state=decision compiler state d
                , lastDecision=Just d
                }
  where
    opts = optionsWithMetrics st
    (_, _, _, _, d) = last opts


naive opt branch
  = let st = CompilerStep branch opt Nothing
        CompilerStep{ state=st' } = fromMaybe st $ naive' st
    in st'



data GlobalMetrics
  = GlobalMetrics
    { bindingOptions, dataFlowOptions, controlFlowOptions :: Int
    } deriving ( Show, Generic )

measureG opts _
  = GlobalMetrics{ bindingOptions=length $ filterBindingOption opts
                 , dataFlowOptions=length $ filterDataFlowOption opts
                 , controlFlowOptions=length $ filterControlFlowOption opts
                 }

-- | Метрики для принятия решения компилятором.
data SpecialMetrics
  = BindingMetrics -- ^ Решения о привязке функциональных блоков к ВУ.
    -- | Устанавливается для таких функциональных блоков, привязка которых может быть заблокирована
    -- другими. Пример - занятие Loop-ом адреса, используемого FramInput.
    { critical :: Bool
    -- | Колличество альтернативных привязок для функционального блока.
    , alternative
    -- | Привязка данного функционального блока может быть активировано только спустя указанное
    -- колличество тактов.
    , restless
    -- | Данная операция может быть привязана прямо сейчас и это приведёт к разрешению указанного
    -- количества пересылок.
    , allowDataFlow :: Int
    }
  | DataFlowMetrics { waitTime :: Int }
  | ControlFlowMetrics
  deriving ( Show, Generic )


measure _ Bush{} _ = error "Can't measure Bush!"
measure opts Branch{ topPU=net@BusNetwork{..} } (BindingOption fb title) = BindingMetrics
  { critical=isCritical fb
  , alternative=length (howManyOptionAllow (filterBindingOption opts) M.! fb)
  , allowDataFlow=sum $ map (length . variables) $ filter isTarget $ optionsAfterBind fb (bnPus M.! title)
  , restless=fromMaybe 0 $ do
      (_var, tcFrom) <- find (\(v, _) -> v `elem` variables fb) $ waitingTimeOfVariables net
      return $ fromEnum tcFrom
  }
measure _ _ ControlFlowOption{} = ControlFlowMetrics
measure _ _ opt@DataFlowOption{} = DataFlowMetrics
  { waitTime=fromEnum ((specializeDataFlowOption opt)^.at.avail.infimum)
  }


integral GlobalMetrics{..} DataFlowMetrics{..}
  | dataFlowOptions >= 2                                   = 10000 + 200 - waitTime
integral GlobalMetrics{..} BindingMetrics{ critical=True } = 2000
integral GlobalMetrics{..} BindingMetrics{ alternative=1 } = 500
integral GlobalMetrics{..} BindingMetrics{..}              = 200 + allowDataFlow * 10 - restless * 2
integral GlobalMetrics{..} DataFlowMetrics{..}             = 200 - waitTime
integral GlobalMetrics{..} _                               = 0



-- * Работа с потоком управления.


-- | Функция применяется к кусту и позволяет определить, осталась ли работа в текущей ветке или нет.
isCurrentBranchOver Bush{ currentBranch=branch@Branch{..} }
  | opts <- options compiler branch
  = null $ filterBindingOption opts ++ filterDataFlowOption opts
isCurrentBranchOver _ = False


-- | Функция позволяет выполнить работы по завершению текущей ветки. Есть два варианта:
--
-- 1) Сменить ветку на следующую.
-- 2) Вернуться в выполнение корневой ветки, для чего слить вычислительный процесс всех вариантов
--    ветвления алгоритма.
finalizeBranch bush@Bush{ remainingBranches=b:bs, ..}
  = bush
    { currentBranch=b
    , remainingBranches=bs
    , completedBranches=currentBranch : completedBranches
    }
finalizeBranch Bush{..}
  = let branchs = currentBranch : completedBranches
        mergeTime = (maximum $ map (nextTick . process . topPU) branchs){ tag=branchTag rootBranch }
        Branch{ topPU=pu@BusNetwork{..} } = currentBranch
    in rootBranch
      { topPU=setTime mergeTime pu
          { bnProcess=snd $ modifyProcess bnProcess $
              mapM_ (\Step{..} -> add sTime sDesc) $ concatMap inBranchSteps branchs
          }
      }
finalizeBranch Branch{} = error "finalizeBranch: wrong args."



-- | Подсчитать, сколько вариантов для привязки функционального блока определено.
-- Если вариант всего один, может быть стоит его использовать сразу?
howManyOptionAllow bOptions
  = foldl ( \st (BindingOption fb title) -> M.alter (countOption title) fb st ) (M.fromList []) bOptions
  where
    countOption title (Just titles) = Just $ title : titles
    countOption title Nothing       = Just [ title ]


-- | Время ожидания переменных.
waitingTimeOfVariables net@BusNetwork{..}
  = [ (variable, tc^.avail.infimum)
    | DataFlowO{ dfoSource=(_, tc@TimeConstrain{..}), ..} <- options dataFlowDT net
    , (variable, Nothing) <- M.assocs dfoTargets
    ]


-- | Оценить, сколько новых вариантов развития вычислительного процесса даёт привязка
-- функциоанльного блока.
optionsAfterBind fb pu = case bind fb pu of
  Right pu' -> filter (\(EndpointO act _) -> act `optionOf` fb) $ options endpointDT pu'
  _         -> []
  where
    act `optionOf` fb' = not $ null (variables act `intersect` variables fb')


-- * Утилиты

passiveOption2action d@EndpointO{..}
  = let a = d^.at.avail.infimum
        -- "-1" - необходимо, что бы не затягивать процесс на лишний такт, так как интервал включает
        -- граничные значения.
        b = d^.at.avail.infimum + d^.at.dur.infimum - 1
    in EndpointD epoType (a ... b)

inBranchSteps Branch{..} = whatsHappenWith branchTag topPU
inBranchSteps Bush{}     = error "inBranchSteps: wrong args"


whatsHappenWith tag pu =
  [ st | st@Step{..} <- steps $ process pu
       , tag == placeInTimeTag sTime
       ]
