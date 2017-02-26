{-# LANGUAGE FlexibleInstances #-}

module Parser where

import Text.Trifecta
import Data.Char (isSpace)
import Data.List (intercalate)
import Control.Applicative ((<|>))
import Data.List (nub)
import System.IO

data Value = Number Integer
           | Boolean Bool
           | Atom String
           | List [Value]
           deriving (Eq, Show)

validChar :: Parser Char
validChar = satisfy $ \x -> not (isSpace x) && x /= ')' && x /= '(' 

atom :: Parser Value
atom = fmap Atom $ some validChar

number :: Parser Value
number = fmap Number $ natural

bool :: Parser Value
bool = fmap Boolean $ 
          (string "#t" *> return True) 
      <|> (string "#f" *> return False)

list :: Parser Value
list = fmap List $ parens $ 
        whiteSpace *> many (token bool 
                        <|> token number 
                        <|> token atom 
                        <|> token list)

file :: Parser [Value]
file = some list

getAtoms :: Value -> [String]
getAtoms (Atom x) = pure x
getAtoms (List xs) = nub $ foldMap getAtoms xs
getAtoms _ = mempty

parseFile :: IO (Maybe [Value])
parseFile = parseFromFile file "samplecode"
