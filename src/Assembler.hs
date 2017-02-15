{-# LANGUAGE OverloadedStrings #-}

module Assembler where

import qualified Data.ByteString.Lazy as BL
import Data.ByteString.Builder (Builder, 
                                word8, 
                                word32LE,  
                                doubleLE,
                                stringUtf8,
                                lazyByteString,
                                toLazyByteString,
                                )
import Data.Word (Word8, Word32)
import Data.Text.Lazy (Text, pack)
import qualified Data.Map as M

data LuaConst = LuaNil | LuaBool Bool | LuaNumber Double | LuaString String
  deriving (Eq, Show)

data LuaFunc = LuaFunc { startline    :: Word32, 
                         endline      :: Word32,
                         upvals       :: Word8,
                         params       :: Word8,
                         vararg       :: Word8,
                         maxstack     :: Word8,
                         instructions :: [LuaInstruction],
                         constants    :: [LuaConst],
                         functions    :: [LuaFunc]
                       } deriving (Eq, Show)

data LuaOp = OpMove |
             OpLoadK |
             OpLoadBool |
             OpLoadNil |
             OpGetUpVal |
             OpGetGlobal |
             OpGetTable |
             OpSetGlobal |
             OpSetUpVal |
             OpSetTable |
             OpNewTable |
             OpSelf |
             OpAdd |
             OpSub |
             OpMul |
             OpDiv |
             OpMod |
             OpPow |
             OpUnM |
             OpNot |
             OpLen |
             OpConcat |
             OpJmp |
             OpEq |
             OpLT |
             OpLE |
             OpTest |
             OpTestSet |
             OpCall |
             OpTailCall |
             OpReturn |
             OpForLoop |
             OpForPrep |
             OpTForLoop |
             OpSetList |
             OpClose |
             OpClosure |
             OpVarArg deriving (Eq, Show, Ord, Enum, Bounded)

formats :: M.Map LuaOp LuaInstFormats
formats = M.fromList[(OpMove, ABC),
                     (OpLoadNil, ABC),
                     (OpLoadK, ABx),
                     (OpLoadBool, ABC),
                     (OpGetGlobal, ABx),
                     (OpSetGlobal, ABx),
                     (OpGetUpVal, ABC),
                     (OpSetUpVal, ABC),
                     (OpGetTable, ABC),
                     (OpSetTable, ABC),
                     (OpAdd, ABC),
                     (OpSub, ABC),
                     (OpMul, ABC),
                     (OpDiv, ABC),
                     (OpMod, ABC),
                     (OpPow, ABC),
                     (OpUnM, ABC),
                     (OpNot, ABC),
                     (OpLen, ABC),
                     (OpConcat, ABC),
                     (OpJmp, AsBx),
                     (OpCall, ABC),
                     (OpReturn, ABC),
                     (OpTailCall, ABC),
                     (OpVarArg, ABC),
                     (OpSelf, ABC),
                     (OpEq, ABC),
                     (OpLT, ABC),
                     (OpLE, ABC),
                     (OpTest, ABC),
                     (OpTestSet, ABC),
                     (OpForPrep, AsBx),
                     (OpForLoop, AsBx),
                     (OpTForLoop, ABC),
                     (OpNewTable, ABC),
                     (OpSetList, ABC),
                     (OpClosure, ABx),
                     (OpClose, ABC)
                     ]

data LuaInstFormats = ABC | ABx | AsBx deriving (Eq, Show, Ord)

data LuaInstruction = IABC { op :: LuaOp, iA :: Int, iB :: Int, iC :: Int } |
                      IABx { op :: LuaOp, iA :: Int, iBx :: Int } |
                      IAsBx { op :: LuaOp, iA :: Int, isBx :: Int }
                        deriving (Eq, Show)

opFormat :: LuaInstruction -> LuaInstFormats
opFormat (IABC _ _ _ _) = ABC
opFormat (IABx _ _ _) = ABx
opFormat (IAsBx _ _ _) = AsBx

validOpFormat :: LuaInstruction -> Maybe Int
validOpFormat ins = if M.lookup opCode formats == Just (opFormat ins) 
                                  then Just (fromEnum opCode)
                                  else Nothing
                    where opCode = op ins

validA :: Int -> Maybe Int
validA n = if 0 <= n && n < (2^8) then Just n else Nothing

validB :: Int -> Maybe Int
validB n = if 0 <= n && n < (2^9) then Just n else Nothing

validC :: Int -> Maybe Int
validC = validB

validBx :: Int -> Maybe Int
validBx n = if 0 <= n && n < (2^18) then Just n else Nothing

validsBx :: Int -> Maybe Int
validsBx n = if (-131071) <= n && n < (2^18 - 131071) then Just n else Nothing
 -- The sBx entry represents negatives with a -131071 bias

inst2int :: LuaInstruction -> Maybe Word32
inst2int ins@(IABC op a b c) = fmap fromIntegral $ sum <$> sequence 
                                [validOpFormat ins, 
                                fmap ((2^6)*) $ validA a,  
                                fmap ((2^14)*) $ validC c, 
                                fmap ((2^23)*) $ validB b]

inst2int ins@(IABx op a b) = fmap fromIntegral $ sum <$> sequence
                              [validOpFormat ins,
                               fmap ((2^6)*) $ validA a,
                               fmap ((2^14)*) $ validBx b]                                   

inst2int ins@(IAsBx op a b) = fmap fromIntegral $ sum <$> sequence
                           [validOpFormat ins,
                            fmap ((2^6*)) $ validA a,
                            fmap (((2^14)*) . (+131071)) $ validsBx b]

check :: Bool -- sanity check
check = inst2int (IABC OpReturn 0 1 0) == Just 8388638


class ToByteString a where
  toBS :: a -> Maybe Builder

instance ToByteString LuaInstruction where
  toBS = (fmap word32LE) . inst2int

instance ToByteString LuaConst where
  toBS LuaNil = Just $ word8 0
  toBS (LuaBool b) = Just $ word8 1 `mappend` word32LE (if b then 1 else 0) 
    -- how is bool is encoded as 0 and 1 in WHAT FORMAT ???
  toBS (LuaNumber n) = Just $ word8 3 `mappend` doubleLE n
  toBS (LuaString str) = Just $ word8 4 `mappend` word32LE sz `mappend` strbytes
    where sz = fromIntegral $ length str + 1
          strbytes = stringUtf8 $ str ++ "\0"

instance (ToByteString a) => ToByteString [a] where
  toBS xs = mappend <$> Just (word32LE (fromIntegral $ length xs)) <*> 
            (fmap mconcat) (traverse toBS $ xs)

instance ToByteString LuaFunc where
  toBS func = (fmap mconcat) . sequence $ 
                       map Just [word32LE (startline func), 
                                  word32LE (endline func),
                                  word8 (upvals func),
                                  word8 (params func),
                                  word8 (vararg func),
                                  word8 (maxstack func)]
                    ++          [ toBS $ instructions func,
                                  toBS $ constants func,
                                  toBS $ functions func]


-- luac header for my architecture
luaHeader :: [Word8]
luaHeader = [0x1b, 0x4c, 0x75, 0x61] ++ -- Header Signature
            [0x51] ++ -- Version Lua 5.1
            [0x00] ++ -- Format version official
            [0x01] ++ -- little endian
            [0x04] ++ -- size of int (bytes)
            [0x04] ++ -- size of size_t (bytes)
            [0x04] ++ -- size of instructions (bytes)
            [0x08] ++ -- size of lua_Number (bytes)
            [0x00]    -- integral flag for floating point

luaFunc :: LuaFunc -- Example function to test
luaFunc = LuaFunc {startline=0, endline=0, upvals=0, params=0, vararg=2,
                   maxstack=3, 
                   instructions=[
                                  IABx OpGetGlobal 0 0
                                , IABx OpLoadK 1 1
                                , IABx OpLoadK 2 2
                                , IABC OpAdd 1 1 2
                                , IABC OpCall 0 2 1
                                , IABC OpReturn 0 1 0
                                ], 
                   constants=[ LuaString "print"
                             , LuaNumber 5.0
                             , LuaNumber 6.0],
                   functions=[]}

finalBuilder :: LuaFunc -> Maybe Builder
finalBuilder f = (fmap mconcat) . sequence $
                 [Just $ foldMap word8 luaHeader, -- header 
                  Just $ word32LE 0, -- source name could go here
                  toBS f, -- main function 
                  Just $ foldMap word32LE [0,0,0]] -- 3 optional lists set to 0

-- Write bytestring to file for testing
writeBuilder :: String -> Builder -> IO ()
writeBuilder file = BL.writeFile file . toLazyByteString

testOutput :: IO ()
testOutput = case finalBuilder luaFunc of 
  Just bs -> writeBuilder "temp" bs
  Nothing -> print "error completing builder"