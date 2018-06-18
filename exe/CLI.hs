{-|
Module      : Main
Description : The CLI interface to Olifant
-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Prelude   (String)
import Protolude hiding (handle, mod, sin)

import Olifant.Compiler
import Olifant.Core
import Olifant.Gen      (gen)
import Olifant.Parser

import System.Environment (getArgs)
import System.FilePath    (takeBaseName)
import System.IO          (hReady)

usage :: IO ()
usage = putStrLn ("Usage: olifant [-vh] [file] " :: Text)

version :: IO ()
version = putStrLn ("The Glorious Olifant, version 0.0.0.1" :: Text)

-- | Compile source to core
core :: Text -> Either Error [Core]
core src = parse src >>= compile

-- | Generate native code from source
exec :: Text -> IO (Either Error Text)
exec str =
    case core str of
        Right prog -> do
            mod <- gen prog
            case mod of
                Right native -> return $ Right native
                Left e       -> return $ Left e
        Left e -> return $ Left e

sin :: IO (Maybe Text)
sin =
    hReady stdin >>= \case
        False -> return Nothing
        True ->
            getContents >>= \case
                "\n" -> return Nothing
                source -> return $ Just source

parseArgs :: [String] -> IO ()
parseArgs ["-h"] = usage
parseArgs ["-v"] = version
parseArgs ["-p"] =
    sin >>= \case
        Just src ->
            case parse src of
                Right t -> print t
                Left e  -> putStrLn $ render e
        Nothing -> usage
parseArgs ["-c"] =
    sin >>= \case
        Just src ->
            case core src of
                Right t -> print t
                Left e  -> putStrLn $ render e
        Nothing -> usage
parseArgs [file] = do
    source <- readFile file
    ll <- exec source
    case ll of
        Right ir -> writeFile (takeBaseName file ++ ".ll") ir
        Left err -> putStrLn $ render err

parseArgs _ =
    sin >>= \case
        Just src ->
            exec src >>= \case
                Right ir -> putStrLn ir
                Left err -> putStrLn $ render err
        Nothing -> usage

main :: IO ()
main = getArgs >>= parseArgs
