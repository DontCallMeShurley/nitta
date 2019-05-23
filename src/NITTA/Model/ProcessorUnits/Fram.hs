{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# OPTIONS -Wall -Wcompat -Wredundant-constraints -fno-warn-missing-signatures #-}

{-|
Module      : NITTA.Model.ProcessorUnits.Fram
Description : Register file
Copyright   : (c) Aleksandr Penskoi, 2019
License     : BSD3
Maintainer  : aleksandr.penskoi@gmail.com
Stability   : experimental

Вычислительный блок fram является одним из наиболее простых блоков с точки хрения аппаратной
реализации. Его внутренее устройство представляет из себя:

- набор входных регистров для защёлкивания входных сначений (как сигналов, так и данных);
- массив регистров, в который могут быть сохранены входные данные.

Но не смотря простоту с аппаратной точки зрения, он имеет весьма высокую сложность с точки зрения
использования прикладного алгоритма. Эта сложность складывается из:

- многофункциональности (fram может в момент написания этого текста выполняет следующие функции:
  FramInput, FramOutput, Reg, Loop, Constant);
- параллелизма (fram может в один момент времени выполнять множество различных функций);
- историчности:

    - fram является statefull вычислительным блоком относительно выполняемых функций, как следствие,
      требует инициализации и работы с состоянием при моделировании / тестировании;
    - fram имеет внутрении ресурсы, ячейки памяти, занятие которых накладывает ограничения на
      функциональные возможности вычислительного блока. Каждая ячейка памяти определяет следующие
      ресурсы:

        - передача данных с предыдущега вычислительного цикла;
        - текущее хранимое значение в рамках вычислительного цикла;
        - передача данных на следующий вычислительный цикл.

Именно по этому реализация модели вычислительного блока настолько велика и сложна. В её рамках были
установлены следующие инварианты, необходимые для корректной работы (по видимому, они должны быть
распространены на все вычислительные блоки):

- Функция bind работает безопастно относительно функций options и decision. Другими словами, если
  функции привязаны к вычислительному блоку, то они могут быть вычислены.
- Функция bind работает небезопастно относительно самой себя. Другими словами, привязка одной
  функции может заблокировать привязку другой функции.
- Функция options работает безопастно. Другими словами, она предоставляет только такие варианты
  решений, при которых гарантируется, что все загруженные функции могут быть выполнены. И это
  гарантируется вне зависимости от очерёдности принятия решений (само собой вопрос эффективности
  умалчивается).
- Функция decision работает небезопастно по отношению к функции bind. Другими словами, принятые
  решения может ограничить функциональность вычислительного блока и запретить привязку функций.

TODO: Каким образом необходимо работать со внутренними ресурсами в условиях разветвлённого времени?
Не получится ли так, что один ресурс будет задействован дважды в разных временных линиях?
-}
module NITTA.Model.ProcessorUnits.Fram
  ( Fram(..)
  , Ports(..)
  ) where

import           Data.Array
import           Data.Bits                        (finiteBitSize, testBit)
import           Data.Default
import           Data.Either
import           Data.Foldable
import           Data.Generics.Aliases            (orElse)
import           Data.List                        (find)
import           Data.Maybe
import qualified Data.Set                         as S
import qualified Data.String.Utils                as S
import           NITTA.Intermediate.Functions
import           NITTA.Intermediate.Types
import           NITTA.Model.Problems.Endpoint
import           NITTA.Model.Problems.Types
import           NITTA.Model.ProcessorUnits.Types
import           NITTA.Model.Types
import           NITTA.Project.Implementation
import           NITTA.Project.Parts.TestBench
import           NITTA.Project.Snippets
import           NITTA.Project.Types
import           NITTA.Synthesis.Utils
import           NITTA.Utils
import           NITTA.Utils.Lens
import           Numeric.Interval                 ((...))
import           Text.InterpolatedString.Perl6    (qc)



data Fram v x t = Fram
  { frMemory   :: Array Int (Cell v x t)
  -- | Информация о функциональных блоках, которые необходимо обработать fram-у. Требуют хранения
  -- дополнительной информации, такой как время привязки функционального блока. Нельзя сразу делать
  -- привязку к ячейке памяти, так как это будет неэффективно.
  , frRemains  :: [ (F v x, ProcessUid) ]
  , frBindedFB :: [ F v x ]
  , frProcess  :: Process v x t
  , frSize     :: Int
  } deriving ( Show )

instance ( Default t
         , Default x
         ) => Default (Fram v x t) where
  def = Fram { frMemory=listArray (0, defaultSize - 1) cells
             , frBindedFB=[]
             , frRemains=[]
             , frProcess=def
             , frSize=defaultSize
             }
    where
      defaultSize = 16
      cells = repeat def{ initialValue=def }


instance WithFunctions (Fram v x t) (F v x) where
    functions Fram{ frBindedFB } = frBindedFB



isReg f | Just Reg{} <- castF f = True
isReg _ = False

isConstOrLoop f | Just Constant{} <- castF f = True
isConstOrLoop f | Just Loop{} <- castF f     = True
isConstOrLoop _ = False


---------------------------------------------------------------------


-- | Описание отдельной ячейки памяти.
data Cell v x t = Cell
  { input        :: IOState v x t -- ^ Ячейка позволяет получить значения с предыдущего вычислительного цикла.
  , current      :: Maybe (Job v x t) -- ^ Ячейка в настоящий момент времени используется для работы.
  , output       :: IOState v x t -- ^ Ячейка позволяет передать значение на следующий вычислительный цикл.
  , lastWrite    :: Maybe t -- ^ Момент последней записи в ячейку (необходим для корректной работы с задержками).
  , initialValue :: x -- ^ Значение ячейки после запуска системы (initial секции).
  } deriving ( Show )

instance ( Default x ) => Default (Cell v x t) where
  def = Cell NotDef Nothing NotDef Nothing def



-- | Описание состояния ячейки относительно начала (Input) и конца (Output) вычислительного цикла.
data IOState v x t
  = NotDef -- ^ Ячейка никак не задействована.
  | Def (Job v x t) -- ^ Ячейка будет использоваться для взаимодействия на границе вычислительного цикла.
  | UsedOrBlocked -- ^ Ячейка либо зарезервирована для использования, либо не может быть использована.
  deriving ( Show, Eq )



-- | Данные, необходимые для описания работы вычислительного блока.
data Job v x t
  = Job { -- | Хранение информации для последующего фиксирования межуровневых взаимосвязей между
          -- шанами вычислительного процесса.
          cads, endpoints, instructions :: [ ProcessUid ]
          -- | Время начала выполнения работы.
        , startAt                       :: Maybe t
          -- | Функция, выполняемая в рамках описываемой работы.
        , function                      :: F v x
          -- | Список действие, которые необходимо выполнить для завершения работы.
        , actions                       :: [ EndpointRole v ]
        }
  deriving ( Eq )

deriving instance {-# INCOHERENT #-} ( Show v, Show x, Show t ) => Show (Job v x t)

instance Default (Job v x t) where
  def = Job def def def def undefined def




-- | Предикат, определяющий время привязки функции к вычислительному блоку. Если возвращается
-- Nothing - то привязка выполняеся в ленивом режиме, если возвращается Just адрес - то привязка
-- должна быть выполнена немедленно к указанной ячейки.
immidiateBindTo f
  | Just (FramInput addr _) <- castF f = Just addr
  | Just (FramOutput addr _) <- castF f = Just addr
immidiateBindTo _ = Nothing


-- | Привязать функцию к указанной ячейке памяти, сформировав описание работы для её выполнения.
bindToCell cs f c@Cell{ input=NotDef }
  | Just (FramInput _ (O a)) <- castF f
  = Right c{ input=Def def{ function=f
                          , cads=cs
                          , actions=[ Source a ]
                          }
           }
bindToCell cs f c@Cell{ output=NotDef }
  | Just (FramOutput _ (I b)) <- castF f
  = Right c{ output=Def def{ function=f
                           , cads=cs
                           , actions=[ Target b ]
                           }
           }
bindToCell cs f c@Cell{ current=Nothing, output }
  | Just (Reg (I a) (O b)) <- castF f
  , output /= UsedOrBlocked
  = Right c{ current=Just $ def{ function=f
                               , cads=cs
                               , actions=[ Target a, Source b ]
                               }
           }
bindToCell cs f c@Cell{ input=NotDef, output=NotDef }
  | Just (Loop (X x) (O b) (I a)) <- castF f
  = Right c{ input=Def def{ function=f
                          , cads=cs
                          , actions=[ Source b, Target a ]
                          }
           , initialValue=x
           }
-- Всё должно быть хорошо, так как если ячейка ранее использовалась, то input будет заблокирован.
bindToCell cs f c@Cell{ input=NotDef, current=Nothing, output=NotDef }
  | Just (Constant (X x) (O b)) <- castF f
  = Right c{ current=Just $ def{ function=f
                               , cads=cs
                               , actions=[ Source b ]
                               }
           , input=UsedOrBlocked
           , output=UsedOrBlocked
           , initialValue=x
           }
bindToCell _ f cell = Left $ "Can't bind " ++ show f ++ " to " ++ show cell



instance ( VarValTime v x t
         ) => ProcessorUnit (Fram v x t) v x t where
    tryBind f Fram{ frBindedFB }
        | not $ null (variables f `S.intersection` S.unions (map variables frBindedFB))
        = Left "Can't bind, because needed self transaction."

    tryBind f pu@Fram{ frMemory, frBindedFB, frRemains, frProcess } = do
        pu' <- bind' f
        if isPUSynthesisFinite pu'
            then Right pu'
            else Left "Schedule can't complete stop."
        where
            bind' fb
                | Just addr <- immidiateBindTo fb
                , let cell = frMemory ! addr
                , let (cad, frProcess') = modifyProcess frProcess $ bindFB f $ nextTick frProcess
                , Right cell' <- bindToCell [cad] fb cell
                = Right pu
                    { frProcess=frProcess'
                    , frMemory=frMemory // [(addr, cell')]
                    , frBindedFB=f : frBindedFB
                    }

                | Right (_ :: Cell v x t) <- bindToCell def fb def
                , let (cad, frProcess') = modifyProcess frProcess $ bindFB f $ nextTick frProcess
                = Right pu
                    { frProcess=frProcess'
                    , frRemains=(f, cad) : frRemains
                    , frBindedFB=f : frBindedFB
                    }

                | otherwise = Left ""

    process = frProcess
    setTime t fr@Fram{..} = fr{ frProcess=frProcess{ nextTick=t } }


instance ( Var v ) => Locks (Fram v x t) v where
    -- FIXME:
    locks _ = []

instance ( VarValTime v x t
         ) => DecisionProblem (EndpointDT v t)
                   EndpointDT (Fram v x t)
         where

    options _proxy pu@Fram{ frProcess=Process{ nextTick }, frRemains, frMemory } = fromCells ++ fromRemain
        where
            fromRemain =
                [ EndpointO ep $ constrain c ep
                | (f, cad) <- frRemains
                , not (isReg f) || isSourceBlockAllow
                , (c, ep) <- toList $ do
                    (_addr, cell) <- findCell pu f
                    cell' <- bindToCell [cad] f cell
                    ep <- cellEndpoints False cell'
                    return (cell', ep)
                ]

            fromCells =
                [ EndpointO ep $ constrain cell ep
                | (_addr, cell) <- assocs frMemory
                , ep <- toList $ cellEndpoints isTargetBlockAllow cell
                ]

            -- | Загрузка в память значения на следующий вычислительный цикл не позволяет использовать её
            -- в качестве регистра на текущем цикле.
            isTargetBlockAllow
                = let
                    need = length $ filter (isReg . fst) frRemains
                    allow = length $ filter (\Cell{ output } -> output /= UsedOrBlocked) $ elems frMemory
                    reserved = length $ filter (isConstOrLoop . fst) frRemains
                in need == 0 || allow - reserved > 1
            isSourceBlockAllow
                = let
                    reserved = length (filter (isConstOrLoop . fst) frRemains)
                    allow = length $ filter (\Cell{ input, output } -> input == NotDef && output == NotDef) $ elems frMemory
                in reserved == 0 || reserved < allow

            constrain Cell{ lastWrite } (Source _)
                | lastWrite == Just nextTick = TimeConstrain (nextTick + 1 + 1 ... maxBound) (1 ... maxBound)
                | otherwise                  = TimeConstrain (nextTick + 1 ... maxBound) (1 ... maxBound)
            constrain _cell (Target _) = TimeConstrain (nextTick ... maxBound) (1 ... maxBound)


    decision proxy pu@Fram{ frProcess=p@Process{ nextTick=tick0 }, frMemory, frRemains } d@EndpointD{ epdRole }
        | isTimeWrap p d = timeWrapError p d

        | Just (fb, cad1) <- find ( anyInAction . variables . fst ) frRemains
        = either error id $ do
            (addr, cell) <- findCell pu fb

            let (cad2, p') = modifyProcess p $ bind2CellStep addr fb tick0
            cell' <- bindToCell [cad1, cad2] fb cell
            let pu' = pu
                    { frRemains=filter ((/= fb) . fst) frRemains
                    , frMemory=frMemory // [(addr, cell')]
                    , frProcess=p'
                    }
            return $ decision proxy pu' d

        | Just (addr, cell) <- find ( any (<< epdRole) . cellEndpoints True . snd ) $ assocs frMemory
        = case cell of
            Cell{ input=Def job@Job{ actions=a : _ } } | a << epdRole
                -> let
                    (p', job') = scheduleFRAM addr job
                    cell' = updateLastWrite (nextTick p') cell
                    cell'' = case job' of
                        Just job''@Job{ actions=Target _ : _, function=f }
                            | Just Loop{} <- castF f
                            -- Данная ветка работает в случае Loop. "Ручной" перенос работы необходим для
                            -- сохранения целостности описания вычислительного процесса.
                            -> cell'{ input=UsedOrBlocked, output=Def job'' }
                        Just job''@Job{ actions=Source _ : _ } -> cell{ input=Def job'' }
                        Just _ -> error "Fram internal error after input process."
                        Nothing -> cell'{ input=UsedOrBlocked }
                in pu
                    { frMemory=frMemory // [(addr, cell'')]
                    , frProcess=p'
                    }
            Cell{ current=Just job@Job{ actions=a : _ } } | a << epdRole
                -> let
                    (p', job') = scheduleFRAM addr job
                    cell' = updateLastWrite (nextTick p') cell
                    cell'' = cell'
                        { input=UsedOrBlocked
                        , current=job'
                        }
                in pu
                    { frMemory=frMemory // [(addr, cell'')]
                    , frProcess=p'
                    }
            Cell{ output=Def j@Job{ actions=act1 : _ } } | act1 << epdRole
                -> let
                    (p', Nothing) = scheduleFRAM addr j
                    -- TODO: Eсть потенциальная проблема, которая может встречаться и в других вычислительных блоках. Если
                    -- вычислительный блок загружает данные в последний такт вычислительного цикла, а выгружает их в
                    -- первый так, то возможно ситуация, когда внутрение процессы не успели завершиться. Решение этой
                    -- проблемы должно лежать в плоскости метода process, в рамках которого должен производиться анализ
                    -- уже построенного вычислительного процесса и в случае необходимости, добавляться лишний так простоя.
                    cell' = cell
                        { input=UsedOrBlocked
                        , output=UsedOrBlocked
                        }
                in pu
                    { frMemory=frMemory // [(addr, cell')]
                    , frProcess=p'
                    }
            _ -> error "Fram internal decision error."

        | otherwise
            = error $ "Can't found selected decision: " ++ show d
                  ++ " tick: " ++ show (nextTick p) ++ "\n"
                  ++ "available options: \n" ++ concatMap ((++ "\n") . show) (options endpointDT pu)
                  ++ "cells:\n" ++ concatMap ((++ "\n") . show) (assocs frMemory)
                  ++ "remains:\n" ++ concatMap ((++ "\n") . show) frRemains
        where
            anyInAction = any (`elem` variables d)
            bind2CellStep addr fb t
                = addStep (Event t) $ CADStep $ "Bind " ++ show fb ++ " to cell " ++ show addr
            updateLastWrite t cell
                | Target _ <- epdRole = cell{ lastWrite=Just t }
                | otherwise = cell{ lastWrite=Nothing }

            scheduleFRAM addr job
                = case scheduleWork addr job of
                    (p', job'@Job{ actions=[] }) -> (finishSchedule p' job', Nothing)
                    (p', job') -> (p', Just job')

            scheduleWork _addr Job{ actions=[] } = error "Fram:scheudle internal error."
            scheduleWork addr job@Job{ actions=x:xs, startAt=startAt, instructions, endpoints }
                = let
                    ( instrTi, instr ) = case d^.endRole of
                        Source _ -> ( shift (-1) d^.at, Load addr)
                        Target _ -> ( d^.at, Save addr)
                    ((ep, instrs), p') = modifyProcess p $ do
                        e <- addStep (Activity $ d^.at) $ EndpointRoleStep $ d^.endRole
                        i <- addInstr pu instrTi instr
                        -- when (tick0 < instrTi^.infimum) $ void $ addInstr pu (tick0 ... instrTi^.infimum - 1) Nop
                        -- mapM_ (relation . Vertical e) instrs
                        setProcessTime $ d^.at.supremum + 1
                        return (e, [i])
                in (p', job
                    { endpoints=ep : endpoints
                    , instructions=instrs ++ instructions
                    , startAt=startAt `orElse` Just (d^.at.infimum)
                    , actions=if x == d^.endRole then xs else (x \\\ (d^.endRole)) : xs
                    })
            finishSchedule p' Job{ startAt, function } = snd $ modifyProcess p' $ do
                let start = fromMaybe (error "startAt field is empty!") startAt
                _ <- addStep (Activity $ start ... d^.at.supremum) $ FStep function
                return ()
                -- mapM_ (relation . Vertical h) cads
                -- mapM_ (relation . Vertical h) endpoints
                -- mapM_ (relation . Vertical h) instructions



cellEndpoints _blockAllow Cell{ input=Def Job{ actions=x:_ } }    = Right x
cellEndpoints _blockAllow Cell{ current=Just Job{ actions=x:_ } } = Right x
cellEndpoints True        Cell{ output=Def Job{actions=x:_ } }    = Right x
cellEndpoints _ _                                                 = Left undefined



findCell pu@Fram{ frMemory } f
  | Just Reg{} <- castF f
  , let cs = filter ( isRight . bindToCell [] f . snd ) $ assocs frMemory
  , not $ null cs
  = Right $ minimumOn cellLoad cs
  | Just Loop{} <- castF f = findFreeCell pu
  | Just Constant{} <- castF f = findFreeCell pu
  | otherwise = Left "Not found."

findFreeCell Fram{ frMemory }
  | let cs = filter (\(_, c) -> case c of
                                  Cell{ input=NotDef, current=Nothing, output=NotDef } -> True;
                                  _ -> False
                    ) $ assocs frMemory
  , not $ null cs
  = Right $ minimumOn cellLoad cs
findFreeCell _ = Left "Not found."

cellLoad (_addr, Cell{ input, output })
    = sum
        [ if input == UsedOrBlocked then -2 else 0
        , if output == NotDef then -1 else 0
        ] :: Int



---------------------------------------------------------------------


instance Controllable (Fram v x t) where
  data Instruction (Fram v x t)
    = Load Int
    | Save Int
    deriving (Show)

  data Microcode (Fram v x t)
    = Microcode{ oeSignal :: Bool
               , wrSignal :: Bool
               , addrSignal :: Maybe Int
               }
    deriving (Show, Eq, Ord)

  mapMicrocodeToPorts Microcode{ oeSignal, wrSignal, addrSignal } FramPorts{ oe, wr, addr }
    = [ (oe, Bool oeSignal)
      , (wr, Bool wrSignal)
      ] ++ addrs
    where
      addrs = map (\(linkId, i) -> ( linkId
                                   , maybe Undef Bool $ fmap (`testBit` i) addrSignal
                                   )
                  ) $ zip (reverse addr) [0..]


instance Connected (Fram v x t) where
  data Ports (Fram v x t)
    = FramPorts{ oe, wr :: SignalTag, addr :: [SignalTag] } deriving ( Show )


getAddr (Load addr) = addr
getAddr (Save addr) = addr


instance Default (Microcode (Fram v x t)) where
  def = Microcode False False Nothing

instance UnambiguouslyDecode (Fram v x t) where
  decodeInstruction (Load addr) = Microcode True False $ Just addr
  decodeInstruction (Save addr) = Microcode False True $ Just addr



instance ( VarValTime v x t
         ) => Simulatable (Fram v x t) v x where
  simulateOn cntx Fram{..} fb
    | Just f'@Constant{} <- castF fb = simulate cntx f'
    | Just f'@Loop{} <- castF fb = simulate cntx f'
    | Just f'@Reg{} <- castF fb = simulate cntx f'
    --  | Just (FramInput _addr (O k)) <- castF fb = do
    --   let v = fromMaybe def $ cntx `get` oneOf k
    --   set cntx k v
    --  | Just (FramOutput addr (I k)) <- castF fb = do
    --   v <- get cntx k
    --   let cntxFram' = M.alter (Just . maybe [v] (v:)) (addr, k) cntxFram
    --   return cntx{ cntxFram=cntxFram' }
    | otherwise = error $ "Can't simulate " ++ show fb ++ " on Fram."



---------------------------------------------------

instance ( VarValTime v x t
         ) => Testable (Fram v x t) v x where
  testBenchImplementation Project{ pName, pUnit=pu@Fram{ frProcess=Process{ steps }, .. }, pTestCntx=Cntx{ cntxProcess } }
    = Immediate (moduleName pName pu ++ "_tb.v") testBenchImp
    where
      cntx = head cntxProcess

      hardwareInstance' = hardwareInstance pName pu
        TargetEnvironment{ signalClk="clk"
                , signalRst="rst"
                , signalCycle="cycle"
                , inputPort=undefined
                , outputPort=undefined
                , unitEnv=ProcessUnitEnv
                  { parameterAttrWidth=IntParam 4
                  , dataIn="data_in"
                  , attrIn="attr_in"
                  , dataOut="data_out"
                  , attrOut="attr_out"
                  , signal= \(SignalTag i) -> case i of
                    0 -> "oe"
                    1 -> "wr"
                    j -> "addr[" ++ show (3 - (j - 2)) ++ "]"
                  }
                }
        FramPorts
            { oe=SignalTag 0
            , wr=SignalTag 1
            , addr=map SignalTag [ 2, 3, 4, 5 ]
            }
      testBenchImp = fixIndent [qc|
|       {"module"} { moduleName pName pu }_tb();
|       parameter DATA_WIDTH = { finiteBitSize (def :: x) };
|       parameter ATTR_WIDTH = 4;
|
|       /*
|       Context:
|       { show cntx }
|
|       Algorithm:
|       { unlines $ map show $ functions pu }
|
|       Process:
|       { unlines $ map show steps }
|       */
|
|       reg clk, rst, wr, oe;
|       reg [3:0] addr;
|       reg [DATA_WIDTH-1:0]  data_in;
|       reg [ATTR_WIDTH-1:0]  attr_in;
|       wire [DATA_WIDTH-1:0] data_out;
|       wire [ATTR_WIDTH-1:0] attr_out;
|
|       { hardwareInstance' }
|
|       { snippetDumpFile $ moduleName pName pu }
|       { snippetClkGen }
|
|       initial
|         begin
|           $dumpfile("{ moduleName pName pu }_tb.vcd");
|           $dumpvars(0, { moduleName pName pu }_tb);
|           @(negedge rst);
|           forever @(posedge clk);
|         end
|
|       { snippetInitialFinish $ controlSignals pu }
|       { snippetInitialFinish $ testDataInput pu cntx }
|       { snippetInitialFinish $ testDataOutput pName pu cntx }
|
|       endmodule
|       |]

controlSignals pu@Fram{ frProcess=Process{ nextTick } }
  = concatMap ( ("      " ++) . (++ " @(posedge clk)\n") . showMicrocode . microcodeAt pu) [ 0 .. nextTick + 1 ]
  where
    showMicrocode Microcode{..} = concat
      [ "oe <= ", bool2verilog oeSignal, "; "
      , "wr <= ", bool2verilog wrSignal, "; "
      , "addr <= ", maybe "0" show addrSignal, "; "
      ]

testDataInput Fram{ frProcess=p@Process{..}, ..} cntx
  = concatMap ( ("      " ++) . (++ " @(posedge clk);\n") . busState ) [ 0 .. nextTick + 1 ]
  where
    busState t
      | Just (Target v) <- endpointAt t p
       = "data_in <= " ++ (either (error . ("testDataInput: " ++)) show $ getX cntx v) ++ ";"
      | otherwise = "/* NO INPUT */"

testDataOutput tag pu@Fram{ frProcess=p@Process{..}, ..} cntx
  = concatMap ( ("      @(posedge clk); " ++) . (++ "\n") . busState ) [ 0 .. nextTick + 1 ] ++ bankCheck
  where
    busState t
      | Just (Source vs) <- endpointAt t p, let v = oneOf vs
      = checkBus v $ either (error . ("testDataOutput: " ++) ) show (getX cntx v)
      | otherwise
      = "$display( \"data_out: %d\", data_out ); "

    checkBus v value = concat
      [ "$write( \"data_out: %d == %d\t(%s)\", data_out, " ++ show value ++ ", " ++ show v ++ " ); "
      ,  "if ( !( data_out === " ++ value ++ " ) ) "
      ,   "$display(\" FAIL\");"
      ,  "else $display();"
      ]

    bankCheck
      = "\n      @(posedge clk);\n"
      ++ unlines [ "  " ++ checkBank addr v (either (error . ("bankCheck: " ++)) show $ getX cntx v)
                 | Step{ sDesc=FStep f, .. } <- filter isFB $ map descent steps
                 , let addr_v = outputStep pu f
                 , isJust addr_v
                 , let Just (addr, v) = addr_v
                 ]
    outputStep pu' fb
      | Just (Loop _ _bs (I v)) <- castF fb = Just (findAddress v pu', v)
      | Just (FramOutput addr (I v)) <- castF fb = Just (addr, v)
      | otherwise = Nothing

    checkBank addr v value = concatMap ("    " ++)
      [ "if ( !( " ++ tag ++ ".bank[" ++ show addr ++ "] === " ++ show value ++ " ) ) "
      ,   "$display("
      ,     "\""
      ,       "FAIL wrong value of " ++ show' v ++ " in fram bank[" ++ show' addr ++ "]! "
      ,       "(got: %h expect: %h)"
      ,     "\","
      ,     "data_out, " ++ show value
      ,   ");"
      ]
    show' s = filter (/= '\"') $ show s



findAddress var pu@Fram{ frProcess=Process{ steps } }
    | [ time ] <- variableSendAt var
    , [ instr ] <- map getAddr $ extractInstructionAt pu (time^.infimum)
    = instr
    | otherwise = error $ "Can't find instruction for effect of variable: " ++ show var
    where
        variableSendAt v = [ t | Step{ sTime=Activity t, sDesc=info } <- steps
                           , v `elem` f info
                           ]
        f (EndpointRoleStep rule) = variables rule
        f _                       = S.empty


softwareFile tag pu = moduleName tag pu ++ "." ++ tag ++ ".dump"

instance ( VarValTime v x t ) => TargetSystemComponent (Fram v x t) where
    moduleName _ _ = "pu_fram"
    hardware tag pu = FromLibrary $ moduleName tag pu ++ ".v"
    software tag pu@Fram{ frMemory }
        = Immediate
            (softwareFile tag pu)
            $ unlines $ map
                (\Cell{ initialValue=initialValue } -> hdlValDump initialValue)
                $ elems frMemory
    hardwareInstance tag pu@Fram{..} TargetEnvironment{ unitEnv=ProcessUnitEnv{..}, signalClk } FramPorts{..} =
        [qc|pu_fram
        #( .DATA_WIDTH( { finiteBitSize (def :: x) } )
        , .ATTR_WIDTH( { show parameterAttrWidth } )
        , .RAM_SIZE( { show frSize } )
        , .FRAM_DUMP( "$path${ softwareFile tag pu }" )
        ) { tag }
        ( .clk( { signalClk } )
        , .signal_addr( \{ { S.join ", " (map signal addr) } } )

        , .signal_wr( { signal wr } )
        , .data_in( { dataIn } )
        , .attr_in( { attrIn } )

        , .signal_oe( { signal oe } )
        , .data_out( { dataOut } )
        , .attr_out( { attrOut } )
        );
        |]
    hardwareInstance _title _pu TargetEnvironment{ unitEnv=NetworkEnv{} } _bnPorts
        = error "Should be defined in network."

instance IOTestBench (Fram v x t) v x