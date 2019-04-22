{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# OPTIONS -Wall -Wcompat -Wredundant-constraints -fno-warn-missing-signatures #-}

{-|
Module      : NITTA.Test.BusNetwork
Description :
Copyright   : (c) Aleksandr Penskoi, 2018
License     : BSD3
Maintainer  : aleksandr.penskoi@gmail.com
Stability   : experimental
-}
module NITTA.Test.BusNetwork
    ( busNetworkTests
    ) where

import           Data.Default
import           Data.Map                      (fromList)
import qualified Data.Set                      as S
import           NITTA.DataFlow                (endpointOption2action)
import qualified NITTA.Functions               as F
import qualified NITTA.ProcessUnits.Accum      as A
import           NITTA.Test.Microarchitectures
import           NITTA.Types
import           NITTA.Types.Function          (Diff (..), F, Patch (..))
import           Test.Tasty                    (TestTree, testGroup)
import           Test.Tasty.HUnit
import           Test.Tasty.TH


test_someAlgorithm =
    [ algTestCase "accum_fram" march
        [ F.framInput 3 [ "d", "p" ]
        , F.framInput 4 [ "e", "k" ]
        , F.framOutput 5 "p"
        , F.framOutput 6 "k"
        , F.loop 22 "sum" ["s"]
        , F.framOutput 7 "s"
        , F.add "d" "e" ["sum"]
        ]
    ]


test_fibonacci =
    [ algTestCase "simple" march
        [ F.loop 0  "b2" ["a1"      ]
        , F.loop 1  "c"  ["b1", "b2"]
        , F.add "a1" "b1" ["c"]
        ]
    , algTestCase "io_drop_data" (marchSPIDropData proxyInt) alg
    , algTestCase "io_no_drop_data" (marchSPI proxyInt) alg
    ]
    where
        alg =
            [ F.loop 0 "b2" ["a1"      ]
            , F.loop 1 "c"  ["b1", "b2"]
            , F.add "a1" "b1" ["c", "c_copy"]
            , F.send "c_copy"
            ]


test_io =
    [ algTestCaseWithInput "double_receive" [("a", [10..15]),("b", [20..25])] (marchSPI proxyInt)
        [ F.receive ["a"]
        , F.receive ["b"]
        , F.add "a" "b" ["c"]
        , F.send "c"
        ]
    ]



f1 = F.add "a" "b" ["c", "d"] :: F String Int

test_patchFunction =
    [ testCase "non-patched function" $
        show f1 @?= "c = d = a + b"

    , testCase "direct patched function input" $
        show (patch ("a", "a'") f1) @?= "c = d = a' + b"
    , testCase "direct patched function output" $
        show (patch ("c", "c'") f1) @?= "c' = d = a + b"

    , testCase "diff patched function input by input" $
        show (patch def{ diffI=fromList [("a", "a'")] } f1) @?= "c = d = a' + b"
    , testCase "diff non patched function input by output" $
        show (patch def{ diffO=fromList [("a", "a'")] } f1) @?= "c = d = a + b"

    , testCase "diff patched function output by output" $
        show (patch def{ diffO=fromList [("c", "c'")] } f1) @?= "c' = d = a + b"
    , testCase "diff non patched function output by input" $
        show (patch def{ diffI=fromList [("c", "c'")] } f1) @?= "c = d = a + b"

    , testCase "diff non patched function output by input" $
        show (patch def
                { diffI=fromList [("b", "b'"), ("d", "d!")]
                , diffO=fromList [("d", "d'"), ("b", "b!")]
                } f1) @?= "c = d' = a + b'"
    ]


pu = let
    Right pu' = tryBind f1 $ PU def (def :: A.Accum String Int Int) undefined undefined
    in pu'

test_patchEndpointOptions =
    [ testCase "non-patched function options" $
        show' opts @?= "[Target a,Target b]"

    , testCase "patched function options input by input" $
        show' (patch def{ diffI=fromList [("a","a'")]} opts) @?= "[Target a',Target b]"
    , testCase "non-patched function options input by output" $
        show' (patch def{ diffO=fromList [("a","a'")]} opts) @?= "[Target a,Target b]"

    , testCase "patched function options output by output" $
        show' (patch def{ diffO=fromList [("d","d'")]} opts') @?= "[Source c,d']"
    , testCase "non-patched function options output by input" $
        show' (patch def{ diffI=fromList [("d","d'")]} opts') @?= "[Source c,d]"
    ]
    where
        opts = options endpointDT pu
        opts' = let
                o1 = head opts
                pu' = decision endpointDT pu $ endpointOption2action o1
                o2 = head $ options endpointDT pu'
                pu'' = decision endpointDT pu' $ endpointOption2action o2
            in options endpointDT pu''
        show' = show . map epoRole


test_patchPU =
    [ testCase "patched PU input options" $
        show' o1 @?= "[Target a',Target b]"
    , testCase "non-patched PU input options" $
        show' o3 @?= "[Target b]"
    , testCase "patched PU output options" $
        show' o4 @?= "[Source c,d']"
    , testCase "non-patched PU all done" $
        show' o5 @?= "[]"
    ]
    where
        pu1 = patch (I "a", I "a'") pu
        o1 = options endpointDT pu1
        pu2 = patch (O $ S.fromList ["d"], O $ S.fromList ["d'"]) pu1
        o2 = options endpointDT pu2
        pu3 = decision endpointDT pu2 $ endpointOption2action $ head o2
        o3 = options endpointDT pu3
        pu4 = decision endpointDT pu3 $ endpointOption2action $ head o3
        o4 = options endpointDT pu4
        pu5 = decision endpointDT pu4 $ endpointOption2action $ head o4
        o5 = options endpointDT pu5

        show' = show . map epoRole


busNetworkTests :: TestTree
busNetworkTests = $(testGroupGenerator)
