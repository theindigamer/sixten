{-# LANGUAGE OverloadedStrings #-}
module Command where

import Protolude

import Options.Applicative

import qualified Command.Check as Check
import qualified Command.Compile as Compile
import qualified Command.Run as Run
import qualified Command.Test as Test
import qualified Command.LanguageServer as LanguageServer

optionsParser :: ParserInfo (IO ())
optionsParser = info (helper <*> commands)
  $ fullDesc
  <> progDesc "Sixten compiler"
  <> header "sixten"

commands :: Parser (IO ())
commands = subparser
  $ command "compile" Compile.command
  <> command "run" Run.command
  <> command "check" Check.command
  <> command "test" Test.command
  <> command "language-server" LanguageServer.command
