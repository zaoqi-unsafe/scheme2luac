{-# LANGUAGE TypeSynonymInstances
           , FlexibleInstances #-}

module CodeGenerator where

import Assembler
import Parser2
import Macro
import Data.Monoid
import Data.List (foldl', elemIndex)
import Text.Trifecta (parseFromFile, Result(Success, Failure), parseString)
import Data.List (nub)
import Data.Maybe (maybeToList, isJust)
import Control.Monad.State
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Word (Word8)

-- | An unfinished Lua Function to be built upon.
--
data PartialLuaFunc = PartialLuaFunc  { inst :: [LuaInstruction]
                                      , cnst :: [LuaConst]
                                      , funcs :: [LuaFunc]
                                      , next :: Int
                                      -- ^ next open register
                                      } deriving (Eq, Show)

emptyPartialFunc = PartialLuaFunc [] [] [] 0

instance Monoid (State PartialLuaFunc ()) where
  mempty = return ()
  mappend = (>>)

-- | Find the index of a value in a list and append the value if not present.
--
addSingle :: (Eq a) => a -> [a] -> (Int, [a])
addSingle a xs = 
  let n = length xs
      place = elemIndex a xs
  in  case place of 
    Nothing -> (n, xs ++ [a])
    Just m -> (m, xs)

-- | Get index for multiple elements, appending them if not present.
--
addAndGetNewInx :: (Eq a) => [a] -> [a] -> ([Int], [a])
addAndGetNewInx (x:xs) ys = 
  let (n, zs) = addSingle x ys
      (ns, ws) = addAndGetNewInx xs zs
  in  (n:ns, ws)
addAndGetNewInx [] ys = ([], ys)

addConstants :: [LuaConst] -> State PartialLuaFunc [Int]
addConstants cs = state $ \f ->
  let (inxs, newcnst) = addAndGetNewInx cs (cnst f)
      newfunc = PartialLuaFunc 
        { inst = inst f
        , cnst = newcnst
        , funcs = funcs f
        , next = next f
        }
  in  (inxs, newfunc)

addFunctions :: [LuaFunc] -> State PartialLuaFunc [Int]
addFunctions fs = state $ \f ->
  let (inxs, newfs) = addAndGetNewInx fs (funcs f)
      newfunc = PartialLuaFunc
        { inst = inst f
        , cnst = cnst f
        , funcs = newfs
        , next = next f
        }
  in  (inxs, newfunc)

addInstructions :: [LuaInstruction] -> State PartialLuaFunc ()
addInstructions is = state $ \f -> ((), PartialLuaFunc 
  { inst = inst f ++ is
  , cnst = cnst f
  , funcs = funcs f
  , next = next f
  })

-- | Increment the next open register.
--
incNext :: State PartialLuaFunc ()
incNext = state $ \f -> 
  let newf = PartialLuaFunc {inst=inst f, cnst=cnst f, funcs=funcs f,
                             next=next f + 1}
  in ((), newf)

-- | Get the next open register
--
getNext :: State PartialLuaFunc Int
getNext = state $ \f -> (next f, f)

-- | Set the next open register
--
setNext :: Int -> State PartialLuaFunc ()
setNext n = state $ \f -> ((), PartialLuaFunc
  { inst = inst f
  , cnst = cnst f
  , funcs = funcs f
  , next = n
  })

-- | If the last instruction is a Call, change it to a TailCall.
--
changeToTail :: State PartialLuaFunc ()
changeToTail = state $ \f -> 
  let
    newf = case last $ inst f of
      IABC OpCall n v _ -> PartialLuaFunc
        { inst = init (inst f) ++ [IABC OpTailCall n v 0]
        , cnst = cnst f
        , funcs = funcs f
        , next = 0
        }
      _ -> f
  in
    ((), newf)

-- | Append instructions, constants, and functions to the partial func to place
-- the evaluated expr in the register indicated by the int
--
addExpr :: AnnExpr -> State PartialLuaFunc ()
addExpr (Var s label) = do
  inxs <- addConstants [ LuaString s ]
  let i = head inxs
  n <- getNext
  addInstructions [ IABC  OpGetUpVal n 0 0 -- env table
                  , IABC  OpGetTable n n (256 + i) -- get s from env
                  ]
  incNext

addExpr (Literal (LitBool b)) =
  do
    n <- getNext 
    addInstructions [ IABC OpLoadBool n val 0 ]
    incNext
  where
    val = if b then 1 else 0

addExpr (Literal (LitQuote (SimpleDatum (Literal x)))) = addExpr (Literal x)

addExpr (Literal (LitQuote (SimpleDatum (Var s ())))) = do
  n <- getNext
  inx <- addConstants [ LuaNumber 0
                      , LuaString s
                      , LuaString "quote"
                      , LuaString "list"
                      ]
  addInstructions [ IABC OpNewTable n 1 2 -- table for quote
                  , IABC OpSetTable n (256 + inx !! 0) (256 + inx !! 1)
                    -- ^ set var in 0 in table
                  , IABC OpLoadBool (n+1) 1 0 -- load true reg n+1
                  , IABC OpSetTable n (256 + inx !! 2) (n+1) -- set quote to T
                  , IABC OpLoadBool (n+1) 0 0 -- load false
                  , IABC OpSetTable n (256 + inx !! 3) (n+1) -- set list to F
                  ]
  incNext

addExpr (Literal (LitQuote (CompoundDatum []))) = do
  n <- getNext
  inx <- addConstants [ LuaString "quote"
                      , LuaString "list"
                      ]
  addInstructions [ IABC OpNewTable n 0 2
                  , IABC OpLoadBool (n+1) 1 0 -- load true reg n+1
                  , IABC OpSetTable n (256 + head inx) (n+1) -- 'quote' = T
                  , IABC OpSetTable n (256 + inx !! 1) (n+1) -- 'list' = T
                  ]
  incNext

addExpr (Literal (LitQuote (CompoundDatum (y:ys)))) = do
  let x = Literal . LitQuote $ y
  let rest = Literal . LitQuote . CompoundDatum $ ys
  n <- getNext
  inx <- addConstants [ LuaNumber 0
                      , LuaNumber 1
                      , LuaString "quote"
                      , LuaString "list" 
                      ]
  addInstructions [ IABC OpNewTable n 2 2 ]
  incNext
  addExpr x
  addExpr rest
  addInstructions [ IABC OpSetTable n (256 + inx !! 0) (n+1) -- 0 to car
                  , IABC OpSetTable n (256 + inx !! 1) (n+2) -- 1 to cdr
                  , IABC OpLoadBool (n+1) 1 0 -- load T
                  , IABC OpSetTable n (256 + inx !! 2) (n+1) -- 'quote'=T
                  , IABC OpSetTable n (256 + inx !! 3) (n+1) -- 'list'=T
                  ]
  setNext $ n+1

addExpr (Literal cs) =
  do
    n <- getNext
    inx <- addConstants [val]
    addInstructions [ IABx OpLoadK n (head inx) ]
    incNext
  where
    val = case cs of
      LitChar c -> LuaString [c]
      LitStr s -> LuaString s
      LitNum m -> LuaNumber m

addExpr (Call (Var "eval" Global) xs) =
  do
    n <- getNext
    addExpr (Var "eval" Global)
    addInstructions [ IAsBx OpJmp 0 0
                    , IABC  OpGetUpVal (n+1) 0 0 -- env in reg n+1
                    ]
    incNext
    addExpr (head xs) -- param in reg n+2
    addInstructions [ IABC OpCall n 3 3 -- call on env and param
                    , IABC OpSetUpVal n 0 0 -- set upval to returned env
                    , IABC OpMove n (n+1) 0 -- move result to n
                    ]
    setNext (n+1)

addExpr (Call f xs) =
  do
    n <- getNext
    let nvars = length xs
    addExpr f
    foldMap addExpr xs
    addInstructions [ IABC OpCall n (nvars + 1) 2 ]
    setNext (n + 1)

addExpr (Lambda vs b) =
  do
    n <- getNext
    inx <- addFunctions [toFuncLambda vs b]
    addInstructions [ IABx OpClosure n (head inx)
                    , IABC OpGetUpVal 0 0 0
                    ]
    incNext

addExpr (Cond a b c) = 
  do
    n <- getNext
    inx <- addFunctions [toFunc a, toFunc b, toFunc c]
    addInstructions  [ IABx  OpClosure n (inx !! 0) -- cond closure
                     , IABC  OpGetUpVal 0 0 0 -- pass env
                     , IABC  OpCall 0 1 2 -- call cond
                     , IABC  OpLoadBool (n+1) 0 0 -- load false in reg n+1
                     , IABC  OpEq 1 (n+1) n -- skip if reg n is not false
                     , IAsBx OpJmp 0 3 -- jump to false case
                     , IABx  OpClosure n (inx !! 1) -- exp1 closure
                     , IABC  OpGetUpVal 0 0 0 -- pass in env
                     , IAsBx OpJmp 0 2 -- jump to return
                     , IABx  OpClosure n (inx !! 2) -- exp2 closure
                     , IABC  OpGetUpVal 0 0 0 -- pass in env
                     , IABC  OpCall n 1 0 -- get expr
                     ]
    incNext


completeFunc :: String -> PartialLuaFunc -> LuaFunc
completeFunc s f = LuaFunc { startline=0, endline=0, upvals=1, params=0,
                             vararg=0, source=s, instructions=inst f,
                             constants=cnst f, functions=funcs f,
                             maxstack = fromIntegral . (+1) . maximum $ 
                              map maxReg (inst f)
                           }

completeFuncParamUpval :: Word8 -> Word8 -> String -> PartialLuaFunc -> LuaFunc
completeFuncParamUpval p u s f =
                 LuaFunc { startline=0, endline=0, upvals=u, params=p,
                           vararg=0, source=s, instructions=inst f,
                           constants=cnst f, functions=funcs f,
                           maxstack= fromIntegral . (+1) . maximum $ 
                             map maxReg (inst f)
                         }

completeTopLevel :: PartialLuaFunc -> LuaFunc
completeTopLevel f = LuaFunc { startline=0, endline=0, upvals=0, params=0,
                             vararg=0, source="@main\0", instructions = inst f,
                             constants = cnst f, functions = funcs f,
                             maxstack = fromIntegral . (+1) . maximum $
                              map maxReg (inst f)
                           }

-- | Converts an annotated scheme expression into a Lua chunk. The chunk takes 
-- no parameters and a single upval which is the evaluation environment. When 
-- called the chunk will return the value that the expression evaluates to.
--
toFunc :: AnnExpr -> LuaFunc
toFunc x = completeFunc name $ 
  execState (do
    n <- getNext
    addExpr x
    changeToTail
    addInstructions [IABC OpReturn n 0 0])
    emptyPartialFunc
  where
    name = case x of
      (Var s _) -> "@var_" ++ show s ++ "\0"
      (Literal (LitBool b)) -> "@litBool_" ++ show b ++ "\0"
      (Literal (LitChar c)) -> "@litChar_" ++ show c ++ "\0"
      (Literal (LitNum n)) -> "@litNum_" ++ show n ++ "\0"
      (Literal (LitStr s)) -> "@litStr_" ++ show s ++ "\0"
      (Call _ _) -> "@call\0"
      (Lambda _ _) -> "@lambda\0"
      (Cond _ _ _) -> "@cond\0"
      (Assign _ _) -> "@assign\0"

-- |Turn a def into a lua chunk by evaluating the expression and then binding it
-- to the proper variable name in the current environment.
-- 
toFuncDef :: AnnDef -> LuaFunc
toFuncDef x = completeFunc name $ 
  execState (do
    addDef x
    addInstructions [IABC OpReturn 0 1 0])
    emptyPartialFunc
  where
    name = case x of 
      (Def1 x _) -> "@def1_" ++ show x ++ "\0"
      (Def2 x _ _) -> "@def2_" ++ show x ++ "\0"
      (Def3 _) -> "@def3\0" 

addLambda :: [Expr] -> AnnBody -> State PartialLuaFunc ()
addLambda vars f = do
  n <- getNext
  let nVars = length vars
  let varStart = n - nVars
  freeVarInxs <- addConstants 
    (map LuaString . S.toList $ freeNonGlobalVars (Lambda vars f))
  varInxs <- addConstants $ map (\(Var s _) -> LuaString s) vars
  funcInxs <- addFunctions [toFuncBody f]
  addInstructions $ [ IABC OpNewTable n 0 0 -- new env
                    , IABC OpGetUpVal (n+1) 0 0 -- old env
                    ] ++
    (concatMap (\x -> [ IABC OpGetTable (n+2) (n+1) (256+x) --copy var to n+2
                      , IABC OpSetTable n (256+x) (n+2) -- copy n+2 to new table
                      ]) freeVarInxs) ++
    (concatMap (\i -> [ IABC OpSetTable n (256+(varInxs !! i)) (varStart + i) ])
                       -- ^ insert ith variable in env at ith variable expr
                        [0..nVars - 1]) ++
                      [ IABx OpClosure (n+1) 0 -- closure for f
                      , IABC OpMove 0 n 0 -- pass in new env
                      , IABC OpCall (n+1) 1 0 -- call f
                      ]

toFuncLambda :: [Expr] -> AnnBody -> LuaFunc
toFuncLambda vars f =
  completeFuncParamUpval (fromIntegral $ length vars) 1 "@lambdabody\0" $
    execState (do
      let n = length vars
      setNext n
      addLambda vars f
      changeToTail
      addInstructions [ IABC OpReturn n 0 0 ]
      ) emptyPartialFunc

-- |The lua chunk that evaluates a body simply evaluates each def or expr in
-- turn and then returns the last one.
--
addBody :: AnnBody -> State PartialLuaFunc ()
addBody (Body ds es) = do
  n <- getNext
  dinx <- addFunctions (map toFuncDef ds)
  einx <- addFunctions (map toFunc es)
  mapM_ (\i -> addInstructions [ IABx OpClosure n i
                               , IABC OpGetUpVal 0 0 0
                               , IABC OpCall n 1 2
                               ]) (dinx ++ einx)

toFuncBody :: AnnBody -> LuaFunc
toFuncBody b = completeFunc "@inBody\0" $
  execState (do
    n <- getNext
    addBody b
    changeToTail
    addInstructions [IABC OpReturn n 0 0]
    ) emptyPartialFunc

-- | Add a definition to a PartialFunc.
-- 
addDef :: AnnDef -> State PartialLuaFunc ()
addDef (Def1 (Var x _) e) = do
  inx <- addConstants [LuaString x]
  n <- getNext
  addInstructions [ IABC OpGetUpVal n 0 0 ]
  incNext
  addExpr e
  addInstructions [ IABC OpSetTable n (256 + head inx) (n+1) ]
  setNext n

addDef (Def2 x vs b) = addDef $ Def1 x (Lambda vs b)  
addDef (Def3 ds) = foldMap addDef ds

addProgram :: [CommOrDef] -> State PartialLuaFunc ()
addProgram xs = do
  finxs <- addFunctions $ map tofunc axs
  ginxs <- addFunctions $ map snd prims
  cinxs <- addConstants $ map (LuaString . fst) prims
  n <- getNext
  traverse (\(ci, fi) -> addInstructions [ IABx OpClosure n fi
                                         , IABC OpSetTable 0 (256 + ci) n ])
    (zip cinxs ginxs)                      -- ^ assume env in table in 0
  serfinxs <- addFunctions $ map snd serialized
  sercinxs <- addConstants $ map (LuaString . fst) serialized
  n <- getNext
  traverse (\(ci, fi) -> addInstructions [ IABx OpClosure n fi
                                         , IABx OpSetGlobal n ci ])
    (zip sercinxs serfinxs)                 -- ^ serialization funcs in globals
  traverse (\fi -> addInstructions [ IABx OpClosure n fi
                                   , IABC OpMove 0 0 0 -- assume env table in 0
                                   , IABC OpCall n 1 2]) finxs
  return ()
  where
    axs = annotateProgram xs -- annotate the parse tree
    freeVars = allVars xs -- search for free variables
    prims = filter ((`S.member` freeVars) . fst) primitives -- add primitives
    serialized = if "eval" `S.member` freeVars then serialize_funcs else []
    tofunc (Comm x) = toFunc x
    tofunc (Def x) = toFuncDef x

toFuncProgram :: [CommOrDef] -> LuaFunc
toFuncProgram xs = completeFunc "@main\0" $ execState (do
  pinx <- addConstants [LuaString "print"]
  addInstructions [ IABC OpNewTable 0 0 0
                  , IABx OpGetGlobal 1 (head pinx) ]
  setNext 2
  addProgram (preProcess xs)
  addInstructions [ IABC OpCall 1 2 1
                  , IABC OpReturn 0 1 0 ])
  emptyPartialFunc

preProcess :: [CommOrDef] -> [CommOrDef]
preProcess = applyMacrosProgram defaultMacros 

toFuncWithoutEnv :: [CommOrDef] -> LuaFunc
toFuncWithoutEnv xs = completeFuncParamUpval 1 0 "@in_eval\0" $ execState (do
  setNext 1
  addProgram $ preProcess xs
  addInstructions [ IABC OpReturn 0 3 0 ] -- return env and result
  ) emptyPartialFunc

evalWrapper :: [CommOrDef] -> LuaFunc
evalWrapper xs = completeTopLevel $ execState (do
  inxs <- addFunctions [toFuncWithoutEnv xs]
  cinxs <- addConstants [LuaString "func_from_haskell"]
  addInstructions [ IABx OpClosure 0 (head inxs)
                  , IABx OpSetGlobal 0 (head cinxs)
                  , IABC OpReturn 0 1 0
                  ]
  ) emptyPartialFunc

------------------- Functions to load at beginning ------------------------

primitives :: [(String, LuaFunc)]
primitives = [ ("*", LuaFunc {startline=0, endline=0, upvals=0, params=0, 
                              vararg=2, maxstack=7, source="@prim*\0",
                   instructions=[ 
                                  IABC  OpNewTable 0 0 0 -- to hold values
                                , IABC  OpVarArg 1 0 0 -- args in reg 1 and up
                                , IABC  OpSetList 0 0 1 -- save args to table
                                , IABx  OpLoadK 1 0 -- load 1 (loop init)
                                , IABC  OpLen 2 0 0 -- load length (loop max)
                                , IABx  OpLoadK 3 0 -- load 1 (loop step)
                                , IABx  OpLoadK 5 0 -- load unit
                                , IAsBx OpForPrep 1 2 
                                , IABC  OpGetTable 6 0 1 -- next arg
                                , IABC  OpMul 5 5 6 -- product -> r5
                                , IAsBx OpForLoop 1 (-3)
                                , IABC  OpReturn 5 2 0 -- return 
                                ], 
                   constants=   [ LuaNumber 1
                                ],
                   functions=   []}) 
             , ("+", LuaFunc {startline=0, endline=0, upvals=0, params=0, 
                              vararg=2, maxstack=7, source="@prim+\0",
                   instructions=[ 
                                  IABC  OpNewTable 0 0 0
                                , IABC  OpVarArg 1 0 0
                                , IABC  OpSetList 0 0 1
                                , IABx  OpLoadK 1 1
                                , IABC  OpLen 2 0 0
                                , IABx  OpLoadK 3 1
                                , IABx  OpLoadK 5 0
                                , IAsBx OpForPrep 1 2
                                , IABC  OpGetTable 6 0 1
                                , IABC  OpAdd 5 5 6
                                , IAsBx OpForLoop 1 (-3)
                                , IABC  OpReturn 5 2 0
                                ], 
                   
                   constants=   [ LuaNumber 0
                                , LuaNumber 1
                                ],
                   
                   functions=   []})
             , ("-", LuaFunc {startline=0, endline=0, upvals=0, params=0, 
                              vararg=2, maxstack=9, source="@prim-\0",
                   instructions=[ 
                                  IABC  OpNewTable 0 0 0 -- table for args
                                , IABC  OpVarArg 1 0 0 -- load arguments
                                , IABC  OpSetList 0 0 1  -- save args in table
                                , IABx  OpLoadK 1 2 -- 2 -> reg 1 (loop init)
                                , IABC  OpLen 2 0 0 -- #args -> reg 2 (loop max) 
                                , IABx  OpLoadK 3 1 -- 1 -> reg 3 (loop step)
                                , IABC  OpGetTable 5 0 257 -- first arg -> reg 5
                                , IABC  OpEq 0 3 2 -- if #args = 1 pc+
                                , IAsBx OpJmp 0 2 -- jump to for loop
                                , IABC  OpUnM 5 5 0 -- negate first arg
                                , IAsBx OpJmp 0 4 -- jump to return
                                , IAsBx OpForPrep 1 2 
                                , IABC  OpGetTable 6 0 1 -- load table value
                                , IABC  OpSub 5 5 6 -- r5 = r5 - r6
                                , IAsBx OpForLoop 1 (-3)  
                                , IABC  OpReturn 5 2 0
                                ], 
                   
                   constants=   [ LuaNumber 0
                                , LuaNumber 1
                                , LuaNumber 2
                                ],
                   
                   functions=   []})
             , ("quotient", LuaFunc { startline=0, endline=0, upvals=0, 
                                      params=2, vararg=0, maxstack = 2,
                                      source="@prim-quotient\0",
                    instructions = [ IABC  OpDiv 0 0 1 
                                   , IABC  OpReturn 0 2 0
                                   ],
                    constants    = [],
                    functions    = []})
             , ("modulo", LuaFunc { startline=0, endline=0, upvals=0, 
                                      params=2, vararg=0, maxstack = 2,
                                      source="@prim-modulo\0",
                    instructions = [ IABC  OpMod 0 0 1 
                                   , IABC  OpReturn 0 2 0
                                   ],
                    constants    = [],
                    functions    = []})
             , ("expt", LuaFunc { startline=0, endline=0, upvals=0, 
                                      params=2, vararg=0, maxstack = 2,
                                      source="@prim-expt\0",
                    instructions = [ IABC  OpPow 0 0 1 
                                   , IABC  OpReturn 0 2 0
                                   ],
                    constants    = [],
                    functions    = []})
             , ("not", LuaFunc { startline=0, endline=0, upvals=0, 
                                      params=1, vararg=0, maxstack = 1,
                                      source="@prim-not\0",
                    instructions = [ IABC  OpNot 0 0 0 
                                   , IABC  OpReturn 0 2 0
                                   ],
                    constants    = [],
                    functions    = []})
             , ("=", LuaFunc { startline=0, endline=0, upvals=0, 
                                      params=2, vararg=0, maxstack = 2,
                                      source="@prim=\0",
                    instructions = [ IABC  OpEq 0 0 1 -- if eq then PC++
                                   , IAsBx OpJmp 0 1 -- jmp requred after eq
                                   , IABC  OpLoadBool 0 1 1 -- load true, PC++
                                   , IABC  OpLoadBool 0 0 0 -- load false  
                                   , IABC  OpReturn 0 2 0 
                                   ],
                    constants    = [],
                    functions    = []})
             , ("<", LuaFunc { startline=0, endline=0, upvals=0, 
                                      params=2, vararg=0, maxstack = 2,
                                      source="@prim<\0",
                    instructions = [ IABC  OpLT 0 0 1 -- if lt then PC++
                                   , IAsBx OpJmp 0 1 -- jmp requred after lt
                                   , IABC  OpLoadBool 0 1 1 -- load true, PC++
                                   , IABC  OpLoadBool 0 0 0 -- load false  
                                   , IABC  OpReturn 0 2 0 
                                   ],
                    constants    = [],
                    functions    = []})
             , (">", LuaFunc { startline=0, endline=0, upvals=0, 
                                      params=2, vararg=0, maxstack = 2,
                                      source="@prim>\0",
                    instructions = [ IABC  OpLT 0 1 0 -- if gt then PC++
                                   , IAsBx OpJmp 0 1 -- jmp requred after gt
                                   , IABC  OpLoadBool 0 1 1 -- load true, PC++
                                   , IABC  OpLoadBool 0 0 0 -- load false  
                                   , IABC  OpReturn 0 2 0 
                                   ],
                    constants    = [],
                    functions    = []})
             , ("force", LuaFunc { startline=0, endline=0, upvals=0,
                                   params=1, vararg=0, maxstack=1,
                                   source="@prim_force\0",
                    instructions = [ IABC OpTailCall 0 1 0
                                   , IABC OpReturn 0 0 0
                                   ],
                    constants    = [],
                    functions    = []})
             , ("eval", LuaFunc { startline=0, endline=0, upvals=0,
                                  params=2, vararg=0, maxstack=6,
                                  source="@prim_eval\0",
                  instructions  = [ IABx OpGetGlobal 2 0 -- 'require'
                                  , IABx OpLoadK 3 1 -- 'lualibhelper'
                                  , IABC OpCall 2 2 1 -- req lualib
                                  , IABx OpGetGlobal 2 2 -- 'hs_init'
                                  , IABC OpCall 2 1 1 -- call hs_init
                                  , IABx OpGetGlobal 2 3 -- 'dofile'
                                  , IABx OpGetGlobal 3 4 -- 'compile_in_haskell'
                                  , IABx OpGetGlobal 4 5 -- 'serialize'
                                  , IABC OpMove 5 1 0 -- param1 -> reg 5
                                  , IABC OpCall 4 2 2 -- call serialize
                                  , IABC OpCall 3 2 2 -- call compile_in_haskell
                                  , IABC OpCall 2 2 1 -- call dofile
                                  , IABx OpGetGlobal 1 6 -- 'hs_exit'
                                  , IABC OpCall 1 1 1 -- call hs_exit
                                  , IABx OpGetGlobal 1 7 -- 'func_from_haskell'
                                  , IAsBx OpJmp 0 0
                                  , IABC OpMove 2 0 0 -- env -> reg 2
                                  , IABC OpTailCall 1 2 0 -- call with env
                                  , IABC OpReturn 1 0 0
                                  ],
                  constants     = [ LuaString "require"
                                  , LuaString "lualibhelper"
                                  , LuaString "hs_init"
                                  , LuaString "dofile"
                                  , LuaString "compile_in_haskell"
                                  , LuaString "serialize"
                                  , LuaString "hs_exit"
                                  , LuaString "func_from_haskell"
                                  ],
                  functions     = []})
             , ("cons", LuaFunc{ startline=0, endline=0, upvals=0,
                                 params=2, vararg=0, maxstack=3,
                                 source="@prim_cons\0",
                  instructions = [ IABC OpNewTable 2 2 0
                                 , IABC OpSetTable 2 256 0
                                 , IABC OpSetTable 2 257 1
                                 , IABC OpReturn 2 2 0
                                 ],
                  constants    = [ LuaNumber 0
                                 , LuaNumber 1
                                 ],
                  functions    = []})
             , ("car", LuaFunc { startline=0, endline=0, upvals=0,
                                 params=1, vararg=0, maxstack=1,
                                 source="@prim_car\0",
                  instructions = [ IABC OpGetTable 0 0 256
                                 , IABC OpReturn 0 2 0 
                                 ],
                  constants    = [ LuaNumber 0 ],
                  functions    = []})
             , ("cdr", LuaFunc { startline=0, endline=0, upvals=0,
                                 params=1, vararg=0, maxstack=1,
                                 source="@prim_cdr\0",
                  instructions = [ IABC OpGetTable 0 0 256
                                 , IABC OpReturn 0 2 0
                                 ],
                  constants    = [ LuaNumber 1 ],
                  functions    = []})
             ]

serialize_funcs = 
             [ ("serialize", LuaFunc { startline=0, endline=0, upvals=0,
                                       params=1, vararg=0, maxstack=3,
                                       source="@serialize\0",
                  instructions = [ IABx  OpGetGlobal 1 0 -- 'type'
                                 , IAsBx OpJmp 0 0
                                 , IABC  OpMove 2 0 0 -- param to reg 2
                                 , IABC  OpCall 1 2 2 -- call type on param
                                 , IABx  OpLoadK 2 9 -- 'nil'
                                 , IABC  OpEq  0 1 2 -- if type is nil pc++
                                 , IAsBx OpJmp 0 2 -- to next loadk
                                 , IABx  OpLoadK 1 10 -- load empty string
                                 , IAsBx OpJmp 0 22 -- to return
                                 , IABx  OpLoadK 2 1 -- 'string'
                                 , IABC  OpEq 0 1 2 -- if type is string pc++
                                 , IAsBx OpJmp 0 2 -- to next loadk
                                 , IABx  OpGetGlobal 1 5 -- get ser_str
                                 , IAsBx OpJmp 0 15 -- jump to last move
                                 , IABx  OpLoadK 2 2 -- 'boolean'
                                 , IABC  OpEq 0 1 2 -- if type is bool pc++
                                 , IAsBx OpJmp 0 2 -- jump to next load
                                 , IABx  OpGetGlobal 1 6 -- get ser_bool
                                 , IAsBx OpJmp 0 10 -- to last move
                                 , IABx  OpLoadK 2 3 -- 'number'
                                 , IABC  OpEq 0 1 2 -- if type is num pc++
                                 , IAsBx OpJmp 0 2 -- to next load
                                 , IABx  OpGetGlobal 1 7 -- get ser_num
                                 , IAsBx OpJmp 0 5 -- to last move
                                 , IABx  OpLoadK 2 4 -- 'table'
                                 , IABC  OpEq 0 1 2 -- if type is table pc++
                                 , IAsBx OpJmp 0 2 -- to move
                                 , IABx  OpGetGlobal 1 8 --get ser_quote
                                 , IAsBx OpJmp 0 0
                                 , IABC  OpMove 2 0 0 -- param to 2
                                 , IABC  OpTailCall 1 0 0 -- call ser_ on param
                                 , IABC  OpReturn 1 0 0 
                                 ],
                  constants    = [ LuaString "type"
                                 , LuaString "string"
                                 , LuaString "boolean"
                                 , LuaString "number"
                                 , LuaString "table"
                                 , LuaString "ser_str"
                                 , LuaString "ser_bool"
                                 , LuaString "ser_num"
                                 , LuaString "ser_quote"
                                 , LuaString "nil"
                                 , LuaString ""
                                 ],
                  functions    = []})
             , ("ser_bool", LuaFunc { startline=0, endline=0, upvals=0,
                                      params=1, vararg=0, maxstack=2,
                                      source="@ser_bool\0",
                  instructions = [ IABC  OpLoadBool 1 1 0 -- load T
                                 , IABC  OpEq 0 0 1 -- if param is T pc++
                                 , IAsBx OpJmp 0 2 -- to next loadbool
                                 , IABx  OpLoadK 0 0 -- '#t'
                                 , IAsBx OpJmp 0 4 -- to return
                                 , IABC  OpLoadBool 1 0 0 -- load F
                                 , IABC  OpEq 0 0 1 -- if param is F pc++
                                 , IAsBx OpJmp 0 1 -- to return
                                 , IABx  OpLoadK 0 1 -- '#f'
                                 , IABC  OpReturn 0 2 0 -- return reg 0
                                 ],
                  constants =    [ LuaString "#t"
                                 , LuaString "#f"
                                 ],
                  functions =    []})
             -- | TODO: change this from just the %f format so that we can
             -- actually properly pass numbers
             --
             , ("ser_num", LuaFunc { startline=0, endline=0, upvals=0,
                                     params=1, vararg=0, maxstack=4,
                                     source="@ser_num\0",
                  instructions = [ IABx OpGetGlobal 1 0
                                 , IABC OpGetTable 1 1 257
                                 , IABx OpLoadK 2 2
                                 , IABC OpMove 3 0 0
                                 , IABC OpCall 1 3 2
                                 , IABC OpReturn 1 2 0
                                 ],
                  constants    = [ LuaString "string"
                                 , LuaString "format"
                                 , LuaString "%f"
                                 ],
                  functions    = []})
             , ("ser_quote", LuaFunc { startline=0, endline=0, upvals=0,
                                       params=1, vararg=0, maxstack=11,
                                       source="@ser_quote\0",
                  instructions = [ IABC  OpGetTable 1 0 256 -- get 'list'
                                 , IABC  OpLoadBool 2 1 0 -- load true
                                 , IABC  OpEq 0 1 2 -- if list=T then pc++
                                 , IAsBx OpJmp 0 15 -- not list -> last get tab
                                 , IABx  OpLoadK 1 4 -- '(' to acc (reg 1)
                                 , IABx  OpClosure 4 0 -- loop closure
                                 , IAsBx OpJmp 0 0 -- noop
                                 , IABC  OpMove 6 0 0
                                  -- ^ move param to cdr spot (reg 5)
                                 , IAsBx OpJmp 0 3 -- to tforloop
                                 , IABC  OpMove 3 8 0 -- move str to 3
                                 , IABx  OpLoadK 2 6 -- space -> reg 2
                                 , IABC  OpConcat 1 1 3 -- concat acc with str
                                 , IABC  OpTForLoop 4 0 2 -- call closure
                                 , IAsBx OpJmp 0 (-5) -- if not nil go back
                                 , IABx  OpLoadK 2 6 -- space -> reg 2
                                 , IABC  OpMove 3 8 0 -- move last str
                                 , IABx  OpLoadK 4 5 -- load ')'
                                 , IABC  OpConcat 1 1 4 -- concat acc, str, ')'
                                 , IAsBx OpJmp 0 1 -- to return
                                 , IABC  OpGetTable 1 0 257 -- get index 0
                                 , IABC  OpReturn 1 2 0
                                 ],
                  constants    = [ LuaString "list"
                                 , LuaNumber 0
                                 , LuaNumber 1
                                 , LuaString "ser_quote"
                                 , LuaString "("
                                 , LuaString ")"
                                 , LuaString " "
                                 ],
                  functions    = [ LuaFunc { startline=0, endline=0, upvals=0,
                                             params=2, vararg=0, maxstack=4,
                                             source="@ser_quote_loop\0",
                    instructions = [ IABx OpGetGlobal 2 0 -- 'serialize'
                                   , IABC OpGetTable 3 1 257 -- car
                                   , IABC OpCall 2 2 2 -- serialize car
                                   , IABC OpGetTable 1 1 258 -- cdr
                                   , IABC OpReturn 1 3 0 -- return cdr, str
                                   ],
                    constants    = [ LuaString "serialize"
                                   , LuaNumber 0
                                   , LuaNumber 1
                                   ],
                    functions    = []}]})
             -- , ("serialize_literal",
             --      LuaFunc { startline=0, endline=0, upvals=0,
             --                params=1, vararg=0, maxstack=1,
             --                source="@prim_serialize_lit\0",
             --      instructions = [ IABC OpGetTable 1 0 256 
             --                     , ]
             --      constants    = [ LuaString "type"
             --                     , LuaString "bool"
             --                     , LuaString "num"
             --                     , LuaString ""]} 
             -- , ("serialize_quote", LuaFunc { startline=0, endline=0, upvals=0,
             --                                  params=1, vararg=0, maxstack=???,
             --                                  source="@prim_serialize\0",
             --      instructions = [ IABC OpGetTable 1 0 257
             --                     , IABC OpLoadBool 2 1 0
             --                     , IABC OpEq ? 1 2
             --                     , ]
             --      constants = [ LuaNumber 0
             --                  , LuaString "list"
             --                  ]}
            ]


------------------------- Main Functions -----------------------------
compileFromFile :: String -> IO (Maybe LuaFunc)
compileFromFile   = (fmap . fmap) toFuncProgram . parseFromFile parProgram

parseAndWrite :: String -> String -> IO ()
parseAndWrite inp out = compileFromFile inp >>= writeLuaFunc out

maybeToEither :: Maybe a -> Either String a
maybeToEither (Just a) = Right a
maybeToEither Nothing = Left "failed to parse file"

writeLuaFunc :: String -> Maybe LuaFunc -> IO ()
writeLuaFunc f ml = case maybeToEither ml >>= finalBuilder of
                       Right bs -> writeBuilder f bs
                       Left s -> print s