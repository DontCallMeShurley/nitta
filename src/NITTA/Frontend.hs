{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# OPTIONS -Wall -fno-warn-missing-signatures -fno-warn-type-defaults #-}
{-# OPTIONS_GHC -fno-cse #-}


--  {-# LANGUAGE NoMonomorphismRestriction           #-}

{-|
Module      : NITTA.Frontend
Description : Lua frontend prototype
Copyright   : (c) Aleksandr Penskoi, 2018
License     : BSD3
Maintainer  : aleksandr.penskoi@gmail.com
Stability   : experimental
-}

module NITTA.Frontend
    ( lua2functions
    , ValueType(..)
    , NumberReprType(..)
    ) where

import           Control.Monad                 (when)
import           Control.Monad.Identity
import           Control.Monad.State
import           Data.Default
import           Data.List                     (find, group, sort)
import qualified Data.Map                      as M
import           Data.Maybe                    (fromMaybe)
import qualified Data.String.Utils             as S
import           Data.Text                     (Text, unpack)
import qualified Data.Text                     as T
import           Language.Lua
import qualified NITTA.Functions               as F
import           NITTA.Types                   (IntX, toX)
import           Text.InterpolatedString.Perl6 (qq)

-- import Debug.Trace

-- FIXME: Variable b don't consume anywhere, except recursive call and it causes the exception.
-- function f(a, b)
--     a, b = a / 2
--     f(a, b)
-- end
-- f(1025, 0)

lua2functions src
    = let
        ast = either (\e -> error $ "can't parse lua src: " ++ show e) id $ parseText chunk src
        AlgBuilder{ algItems } = buildAlg ast
        fs = filter (\case Function{} -> True; _ -> False) algItems
        varDict = M.fromList
            $ map varRow
            $ group $ sort $ concatMap fIn fs
    in snd $ execState (mapM_ (store <=< function2nitta) fs) (varDict, [])
    where
        varRow lst@(x:_)
            = let vs = zipWith (\v i -> [qq|{unpack v}_{i}|]) lst [0..]
            in (x, (vs, vs))
        varRow _ = undefined


buildAlg ast
    = let
        Right (mainName, mainCall, mainFunDef) = findMain ast
        alg0 = AlgBuilder
            { algItems=[]
            , algBuffer=[]
            , algVarGen=map (\i -> [qq|#{i}|]) [0..]
            , algVars=[]
            }
        builder = do
            addMainInputs mainFunDef mainCall
            mapM_ (processStatement mainName) $ funAssignStatments mainFunDef
            patchAlgForType
            addConstants
    in execState builder alg0 :: AlgBuilder Int

-- |Описание способа представления вещественных чисел в алгоритме
data NumberReprType
    -- |В алгоритме не поддерживаются вещественные числа.
    = IntRepr
    -- |Представление вещественных чисел как целочисленных, умножением на 10 в заданной степени.
    | DecimalFixedPoint Int
    -- |Представление вещественных чисел как целочисленных, умножением на 2 в заданной степени.
    | BinaryFixedPoint Int
    deriving Show

-- |Описывает формат представления чисел в алгоритме.
data ValueType
    = ValueType
        { reprType      :: NumberReprType -- ^Представление вещественных чисел в алгоритме
        , valueWidth    :: Int            -- ^Количество бит требующихся на представление числа (по модулю)
        , isValueSigned :: Bool           -- ^Возможность использования отрицательных чисел
        }
    deriving Show

instance Default ValueType where
    def = ValueType{ reprType=IntRepr, valueWidth=32, isValueSigned=True }

data AlgBuilder x
    = AlgBuilder
        { algItems  :: [AlgBuilderItem x]
        , algBuffer :: [AlgBuilderItem x]
        , algVarGen :: [Text]
        , algVars   :: [Text]
        }

instance ( Show x ) => Show (AlgBuilder x) where
    show AlgBuilder{ algItems, algBuffer, algVars }
        = "AlgBuilder\n{ algItems=\n"
        ++ S.join "\n" (map show $ reverse algItems)
        ++ "\nalgBuffer: " ++ show algBuffer
        ++ "\nalgVars: " ++ show algVars
        ++ "\n}"

data AlgBuilderItem x
    = InputVar
        { iIx  :: Int -- ^Index
        , iVar :: Text  -- ^Symbol
        , iX   :: x -- ^Initial value
        }
    | Constant{ cVar :: Text, cX :: x }
    | Alias{ aFrom :: Text, aTo :: Text }
    | Renamed{ rFrom :: Text, rTo :: Text }
    | Function
        { fIn     :: [Text]
        , fOut    :: [Text]
        , fName   :: String
        , fValues :: [x]
        }
    -- FIXME: check all local variable declaration
    deriving ( Show )



-- *Translate AlgBuiler functions to nitta functions
function2nitta Function{ fName="loop",     fIn=[i],    fOut=[o],    fValues=[x] } = F.loop x <$> input i <*> output o
function2nitta Function{ fName="reg",      fIn=[i],    fOut=[o],    fValues=[]  } = F.reg <$> input i <*> output o
function2nitta Function{ fName="constant", fIn=[],     fOut=[o],    fValues=[x] } = F.constant x <$> output o
function2nitta Function{ fName="send",     fIn=[i],    fOut=[],     fValues=[]  } = F.send <$> input i
function2nitta Function{ fName="add",      fIn=[a, b], fOut=[c],    fValues=[]  } = F.add <$> input a <*> input b <*> output c
function2nitta Function{ fName="sub",      fIn=[a, b], fOut=[c],    fValues=[]  } = F.sub <$> input a <*> input b <*> output c
function2nitta Function{ fName="multiply", fIn=[a, b], fOut=[c],    fValues=[]  } = F.multiply <$> input a <*> input b <*> output c
function2nitta Function{ fName="divide",   fIn=[d, n], fOut=[q, r], fValues=[]  } = F.division <$> input d <*> input n <*> output q <*> output r
function2nitta Function{ fName="receive",  fIn=[],     fOut=[o],    fValues=[]  } = F.receive <$> output o
function2nitta Function{ fName="shiftL",   fIn=[a],    fOut=[c],    fValues=[]  } = F.shiftL <$> input a <*> output c
function2nitta Function{ fName="shiftR",   fIn=[a],    fOut=[c],    fValues=[]  } = F.shiftR <$> input a <*> output c
function2nitta f = error $ "frontend don't known function: " ++ show f



input v = do
    (dict, fs) <- get
    let (x:xs, lst) = dict M.! v
    put (M.insert v (xs, lst) dict, fs)
    return x

output v
    | T.head v == '_' = return []
    | otherwise = gets $ \(dict, _fs) ->
        snd (fromMaybe (error [qq|unknown variable: $v|]) (dict M.!? v))

store f = modify' $ \(dict, fs) -> (dict, f:fs)



-- *AST inspection and algorithm builder

findMain (Block statements Nothing)
    | [call] <- filter (\case FunCall{} -> True; _ -> False) statements
    , [funAssign] <- filter (\case FunAssign{} -> True; _ -> False) statements
    , (FunCall (NormalFunCall (PEVar (VarName (Name fnCall))) _)) <- call
    , (FunAssign (FunName (Name fnAssign) _ _) _) <- funAssign
    , fnCall == fnAssign
    = Right (fnCall, call, funAssign)
findMain _ = error "can't find main function in lua source code"


addMainInputs
        (FunAssign (FunName (Name _funName) _ _) (FunBody declArgs _ _))
        (FunCall (NormalFunCall _ (Args callArgs))) = do
    let vars = map (\case (Name v) -> v) declArgs

    let values = map (\case (Number _ s) -> unpack s; _ -> error "lua: wrong main argument") callArgs
    let values' = map toX values
    when (length vars /= length values')
        $ error "a different number of arguments in main a function declaration and call"

    forM_ (zip3 [0..] vars values')
        $ \(iIx, iVar, iX) -> addItem InputVar{ iIx, iVar, iX } [iVar]

addMainInputs _ _ = error "bad main function description"


addConstants = do
    AlgBuilder{ algItems } <- get
    let constants = filter (\case Constant{} -> True; _ -> False) algItems
    forM_ constants $ \Constant{ cVar, cX } ->
        addFunction Function{ fName="constant", fIn=[], fOut=[cVar], fValues=[cX] }



class PatchAlgForType x where
    patchAlgForType :: State (AlgBuilder x) ()

instance PatchAlgForType Int where
    patchAlgForType = return ()

instance PatchAlgForType Integer where
    patchAlgForType = return ()

instance PatchAlgForType (IntX w) where
    patchAlgForType = do
        alg@AlgBuilder{ algItems } <- get
        put alg{ algItems=[] }
        mapM_ preprocessFunctions' algItems
        where
            rt = BinaryFixedPoint 1
            preprocessFunctions' Function{ fName="multiply", fIn=[a, b], fOut=[c], fValues=[] } = do
                v <- genVar "tmp"
                q <- genVar "_mod"
                cnst <- expConstant "arithmetic_constant" $ Number IntNum "1"
                modify' $ \alg@AlgBuilder{ algItems } -> alg{ algItems = case rt of
                    -- FIXME: add shift for more than 1
                    BinaryFixedPoint  1 -> Function{ fName="multiply", fIn=[a, b], fOut=[v], fValues=[] } :
                                        Function{ fName="shiftR", fIn=[v], fOut=[c], fValues=[] } :
                                        algItems
                    _                   -> Function{ fName="multiply", fIn=[a, b], fOut=[v], fValues=[] } :
                                        Function{ fName="divide", fIn=[v, cnst], fOut=[c, q], fValues=[] } :
                                        algItems
                }

            preprocessFunctions' Function{ fName="divide", fIn=[d, n], fOut=[q, r], fValues=[] } = do
                v <- genVar "tmp"
                cnst <- expConstant "arithmetic_constant" $ Number IntNum "1"
                modify' $ \alg@AlgBuilder{ algItems } -> alg{ algItems = case rt of
                    BinaryFixedPoint  1 -> Function{ fName="shiftL", fIn=[d], fOut=[v], fValues=[] } :
                                        Function{ fName="divide", fIn=[v, n], fOut=[q, r], fValues=[] } :
                                        algItems

                    _                   -> Function{ fName="multiply", fIn=[d, cnst], fOut=[v], fValues=[] } :
                                        Function{ fName="divide", fIn=[v, n], fOut=[q, r], fValues=[] } :
                                        algItems
                }

            preprocessFunctions' item = modify' $ \alg@AlgBuilder{ algItems } -> alg{ algItems=item : algItems }



processStatement fn (LocalAssign names (Just [rexp])) = do
    processStatement fn $ LocalAssign names Nothing
    processStatement fn $ Assign (map VarName names) [rexp]

processStatement _fn (LocalAssign names Nothing) = do
    AlgBuilder{ algVars } <- get
    forM_ names $ \(Name n) ->
        when (n `elem` algVars) $ error "local variable already defined"

processStatement _fn st@(Assign lexps rexps)
    = if
        | length lexps == length rexps -> do
            let outs = map (\case (VarName (Name v)) -> [v]; l -> error $ "bad left expression: " ++ show l) lexps
            diff <- concat <$> mapM renameVarsIfNeeded outs
            zipWithM_ (rightExp diff) outs rexps
            flushBuffer
        | length lexps > 1 && length rexps == 1 -> do
            let outs = map (\case (VarName (Name v)) -> v; l -> error $ "bad left expression: " ++ show l) lexps
            diff <- renameVarsIfNeeded outs
            rightExp diff outs $ head rexps
            flushBuffer
        | otherwise -> error $ "processStatement: " ++ show st

processStatement fn (FunCall (NormalFunCall (PEVar (VarName (Name fName))) (Args args)))
    | fn == fName
    = do
        AlgBuilder{ algItems } <- get
        let algIn = reverse $ filter (\case InputVar{} -> True; _ -> False) algItems
        mapM_ (uncurry f) $ zip algIn args
        where
            f InputVar{ iX, iVar } rexp = do
                i <- expArg [] rexp
                let fun = Function{ fName="loop", fIn=[i], fOut=[iVar], fValues=[iX] }
                modify' $ \alg@AlgBuilder{ algItems } -> alg{ algItems=fun : algItems }
            f _ _ = undefined

processStatement _fn (FunCall (NormalFunCall (PEVar (VarName (Name fName))) (Args args))) = do
    fIn <- mapM (expArg []) args
    addFunction Function{ fName=unpack fName, fIn, fOut=[], fValues=[] }

processStatement _fn st = error $ "statement: " ++ show st



rightExp diff fOut (Binop op a b) = do
    a' <- expArg diff a
    b' <- expArg diff b
    let f = Function{ fName=binop op, fIn=[a', b'], fOut, fValues=[] }
    patchAndAddFunction f diff
    where
        binop Add = "add"
        binop Sub = "sub"
        binop Mul = "multiply"
        binop Div = "divide"
        binop o   = error $ "unknown binop: " ++ show o

rightExp
        diff
        fOut
        (PrefixExp (PEFunCall (NormalFunCall
            (PEVar (VarName (Name fn)))
            (Args args)
        ))) = do
    fIn <- mapM (expArg diff) args
    let f = Function{ fName=unpack fn, fIn, fOut, fValues=[] }
    patchAndAddFunction f diff

rightExp diff [a] (PrefixExp (PEVar (VarName (Name b)))) -- a = b
    = addItemToBuffer Alias{ aFrom=a, aTo=applyPatch diff b }

rightExp diff [a] n@(Number _ _) = do -- a = 42
    b <- expConstant (T.concat [a, "_constant"]) n
    addItemToBuffer Alias{ aFrom=a, aTo=applyPatch diff b }

-- FIXME: add negative function
rightExp diff [a] (Unop Neg (Number numType n)) = rightExp diff [a] $ Number numType $ T.cons '-' n

rightExp diff [a] (Unop Neg expr@(PrefixExp _)) =
    let binop = Binop Sub (Number IntNum "0") expr
    in rightExp diff [a] binop

rightExp _diff _out rexp = error $ "rightExp: " ++ show rexp



expArg _diff n@(Number _ _) = expConstant "constant" n

expArg _diff (PrefixExp (PEVar (VarName (Name var)))) = findAlias var

expArg diff call@(PrefixExp (PEFunCall _)) = do
    c <- genVar "tmp"
    rightExp diff [c] call
    return c

expArg diff (PrefixExp (Paren arg)) = expArg diff arg

expArg diff binop@Binop{} = do
    c <- genVar "tmp"
    rightExp diff [c] binop
    return c

expArg _diff (Unop Neg (Number numType n)) = expConstant "constant" $ Number numType $ T.cons '-' n

expArg diff (Unop Neg expr@(PrefixExp _)) = do
    c <- genVar "tmp"
    let binop = Binop Sub (Number IntNum "0") expr
    rightExp diff [c] binop
    return c

expArg _diff a = error $ "expArg: " ++ show a



-- *Internal

expConstant prefix (Number _ textX) = do
    AlgBuilder{ algItems } <- get
    let x = toX $ unpack textX
    case find (\case Constant{ cX } | cX == x -> True; _ -> False) algItems of
        Just Constant{ cVar } -> return cVar
        Nothing -> do
            g <- genVar prefix
            addItem Constant{ cX=x, cVar=g } []
            return g
        Just _ -> error "internal error"
expConstant _ _ = undefined



addFunction f@Function{ fOut } = do
    diff <- renameVarsIfNeeded fOut
    patchAndAddFunction f diff
addFunction e = error $ "addFunction try to add: " ++ show e



patchAndAddFunction f@Function{ fIn } diff = do
    let fIn' = map (applyPatch diff) fIn
    alg@AlgBuilder{ algItems } <- get
    put alg
        { algItems=f{ fIn=fIn' } : algItems
        }
patchAndAddFunction _ _ = undefined



renameVarsIfNeeded fOut = do
    AlgBuilder{ algVars } <- get
    mapM autoRename $ filter (`elem` algVars) fOut

autoRename var = do
    var' <- genVar var
    renameFromTo var var'
    return (var, var')

renameFromTo rFrom rTo = do
    alg@AlgBuilder{ algItems, algVars } <- get
    put alg
        { algItems=Renamed{ rFrom, rTo } : patch algItems
        , algVars=rTo : algVars
        }
    where
        patch [] = []
        patch (i@InputVar{ iVar } : xs) = i{ iVar=rn iVar } : patch xs
        patch (Constant{ cX, cVar } : xs) = Constant{ cX, cVar=rn cVar } : patch xs
        patch (Alias{ aFrom, aTo } : xs) = Alias (rn aFrom) (rn aTo) : patch xs
        patch (f@Function{ fIn, fOut } : xs) = f{ fIn=map rn fIn, fOut=map rn fOut } : patch xs
        patch (x:xs) = x : patch xs

        rn v
            | v == rFrom = rTo
            | otherwise = v



funAssignStatments (FunAssign _ (FunBody _ _ (Block statments _))) = statments
funAssignStatments _                                               = error "funAssignStatments : not function assignment"


flushBuffer = modify'
    $ \alg@AlgBuilder{ algBuffer, algItems } -> alg
        { algItems=algBuffer ++ algItems
        , algBuffer=[]
        }


addItemToBuffer item = modify'
    $ \alg@AlgBuilder{ algBuffer } -> alg
        { algBuffer=item : algBuffer
        }


addItem item vars = modify'
    $ \alg@AlgBuilder{ algItems, algVars } -> alg
        { algItems=item : algItems
        , algVars=vars ++ algVars
        }



genVar prefix = do
    alg@AlgBuilder{ algVarGen=g:gs } <- get
    put alg{ algVarGen=gs }
    return $ T.concat [prefix, g]



findAlias var0 = do
    AlgBuilder{ algItems } <- get
    return $ inner var0 algItems
    where
        inner var [] = var
        inner var (Alias{ aFrom, aTo }:xs)
            | aFrom == var = inner aTo xs
        inner var (_:xs) = inner var xs



applyPatch diff v
    = case find ((== v) . fst) diff of
        Just (_, v') -> v'
        _            -> v
