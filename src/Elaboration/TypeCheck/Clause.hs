{-# LANGUAGE OverloadedStrings, LambdaCase, TupleSections #-}
module Elaboration.TypeCheck.Clause where

import Protolude hiding (tails)

import Data.Bitraversable
import Data.Foldable as Foldable
import Data.HashSet(HashSet)
import Data.List.NonEmpty(NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Vector as Vector

import {-# SOURCE #-} Elaboration.TypeCheck.Expr
import Effect
import Effect.Log as Log
import Elaboration.Constraint
import Elaboration.Match as Match
import Elaboration.MetaVar
import Elaboration.MetaVar.Zonk
import Elaboration.Monad
import Elaboration.Subtype
import Elaboration.TypeCheck.Pattern
import Syntax
import qualified Syntax.Core as Core
import qualified Syntax.Pre.Scoped as Pre
import TypedFreeVar
import Util

checkConstantDef
  :: Pre.ConstantDef Pre.Expr FreeV
  -> CoreM
  -> Elaborate (Abstract, CoreM)
checkConstantDef (Pre.ConstantDef a clauses _) typ = do
  e' <- checkClauses clauses typ
  return (a, e')

checkClauses
  :: NonEmpty (Pre.Clause Pre.Expr FreeV)
  -> Polytype
  -> Elaborate CoreM
checkClauses clauses polyType = Log.indent $ do
  forM_ clauses $ \clause -> logPretty "tc.clause" "checkClauses clause" $ pretty <$> clause
  logMeta "tc.clause" "checkClauses typ" $ zonk polyType

  skolemise polyType (minimum $ instUntilClause <$> clauses) $ \rhoType f -> do
    ps <- piPlicitnesses rhoType

    clauses' <- forM clauses $ \(Pre.Clause pats body) -> do
      pats' <- equalisePats ps $ Vector.toList pats
      return $ Pre.Clause (Vector.fromList pats') body

    let equalisedClauses = equaliseClauses clauses'

    forM_ equalisedClauses $ \clause -> logPretty "tc.clause" "checkClauses equalisedClause" $ pretty <$> clause

    res <- checkClausesRho equalisedClauses rhoType

    logMeta "tc.clause" "checkClauses res" $ zonk res

    return $ f res
  where
    instUntilClause :: Pre.Clause Pre.Expr v -> InstUntil
    instUntilClause (Pre.Clause pats s)
      | Vector.length pats > 0 = InstUntil $ fst $ Vector.head pats
      | otherwise = instUntilExpr $ fromScope s

    piPlicitnesses :: CoreM -> Elaborate [Plicitness]
    piPlicitnesses t = do
      t' <- whnf t
      piPlicitnesses' t'

    piPlicitnesses' :: CoreM -> Elaborate [Plicitness]
    piPlicitnesses' (Core.Pi h p t s) =
      extendContext h p t $ \v ->
        (:) p <$> piPlicitnesses (instantiate1 (pure v) s)
    piPlicitnesses' _ = return mempty

checkClausesRho
  :: NonEmpty (Pre.Clause Pre.Expr FreeV)
  -> Rhotype
  -> Elaborate CoreM
checkClausesRho clauses rhoType = do
  forM_ clauses $ \clause -> logPretty "tc.clause" "checkClausesRho clause" $ pretty <$> clause
  logMeta "tc.clause" "checkClausesRho type" $ zonk rhoType

  let (ps, firstPats) = Vector.unzip ppats
        where
          Pre.Clause ppats _ = NonEmpty.head clauses
  (argTele, returnTypeScope, fs) <- funSubtypes rhoType ps
  whenLoggingCategory "tc.clause" $ do
    pargTele <- bitraverseTelescope (\m -> WithVar m <$> prettyMetaVar m) (pure . pretty) argTele
    logPretty "tc.clause" "argTele" pargTele

  clauses' <- forM clauses $ \(Pre.Clause pats bodyScope) -> do
    logShow "tc.clause" "start" ()
    (pats', patVars) <- Log.indent $ tcPats pats mempty argTele
    let body = instantiatePattern pure (boundPatVars patVars) bodyScope
        argExprs = snd3 <$> pats'
        returnType = instantiateTele identity argExprs returnTypeScope
    logPretty "tc.clause" "patVars" patVars
    body' <- Log.indent $ withPatVars patVars $ checkRho body returnType
    return (fst3 <$> pats', body')

  forM_ clauses' $ \(pats, body) -> do
    forM_ pats $ logPretty "tc.clause" "checkClausesRho clause pat" <=< bitraverse prettyMeta (pure . pretty)
    logMeta "tc.clause" "checkClausesRho clause body" $ zonk body

  teleExtendContext (addTeleNames argTele $ Pre.patternHint <$> firstPats) $ \argVars -> do
    logPretty "tc.clause" "argVars" argVars

    let returnType = instantiateTele pure argVars returnTypeScope

    body <- matchClauses
      (Vector.toList $ pure <$> argVars)
      (NonEmpty.toList $ first Vector.toList <$> clauses')
      returnType

    logMeta "tc.clause" "checkClausesRho body res" $ zonk body

    let result = foldr
          (\(f, v) e -> f $ Core.lam v e)
          body
          (Vector.zip fs argVars)

    logMeta "tc.clause" "checkClausesRho res" $ zonk result
    return result

--------------------------------------------------------------------------------
-- "Equalisation" -- making the clauses' number of patterns match eachother
-- by adding implicits and eta-converting
equaliseClauses
  :: NonEmpty (Pre.Clause Pre.Expr v)
  -> NonEmpty (Pre.Clause Pre.Expr v)
equaliseClauses clauses
  = NonEmpty.zipWith
    (uncurry etaClause)
    (go (Vector.toList . Pre.clausePatterns <$> clauses))
    (Pre.clauseScope <$> clauses)
  where
    go
      :: NonEmpty [(Plicitness, Pre.Pat c (Scope b expr v) ())]
      -> NonEmpty ([(Plicitness, Pre.Pat c (Scope b expr v) ())], [Plicitness])
    go clausePats
      | numEx == 0 && numIm == 0 = (, mempty) <$> clausePats
      | numEx == len = NonEmpty.zipWith (first . (:)) heads $ go tails
      | numIm == len = NonEmpty.zipWith (first . (:)) heads $ go tails
      | numIm > 0 = go' $ addImplicit <$> clausePats
      | numEx > 0 = go' $ addExplicit <$> clausePats
      | otherwise = panic "equaliseClauses go"
      where
        numEx = numExplicit clausePats
        numIm = numImplicit clausePats
        heads = fromMaybe (panic "equaliseClauses heads") . head <$> clausePats
        tails = drop 1 <$> clausePats
        len = length clausePats
    go'
      :: NonEmpty ([(Plicitness, Pre.Pat c (Scope b expr v) ())], [Plicitness])
      -> NonEmpty ([(Plicitness, Pre.Pat c (Scope b expr v) ())], [Plicitness])
    go' clausePats
      = NonEmpty.zipWith
        (\ps (pats, ps') -> (pats, ps ++ ps'))
        (snd <$> clausePats)
        (go $ fst <$> clausePats)

    numExplicit, numImplicit :: NonEmpty [(Plicitness, Pre.Pat c (Scope b expr v) ())] -> Int
    numExplicit = length . NonEmpty.filter (\case
      (Explicit, _):_ -> True
      _ -> False)

    numImplicit = length . NonEmpty.filter (\case
      (Implicit, _):_ -> True
      _ -> False)

    addImplicit, addExplicit
      :: [(Plicitness, Pre.Pat c (Scope b expr v) ())]
      -> ([(Plicitness, Pre.Pat c (Scope b expr v) ())], [Plicitness])
    addImplicit pats@((Implicit, _):_) = (pats, mempty)
    addImplicit pats = ((Implicit, Pre.WildcardPat) : pats, mempty)

    addExplicit pats@((Explicit, _):_) = (pats, mempty)
    addExplicit pats = ((Explicit, Pre.VarPat mempty ()) : pats, pure Explicit)

etaClause
  :: [(Plicitness, Pre.Pat (HashSet QConstr) (Scope PatternVar Pre.Expr v) ())]
  -> [Plicitness]
  -> Scope PatternVar Pre.Expr v
  -> Pre.Clause Pre.Expr v
etaClause pats extras (Scope scope)
  = Pre.Clause
    (Vector.fromList pats)
    $ Scope
    $ Pre.apps scope vs
  where
    numBindings = length $ concat $ Foldable.toList . snd <$> pats
    numExtras = length extras
    vs = zip extras $ pure . B . PatternVar <$> [numBindings - numExtras ..]
