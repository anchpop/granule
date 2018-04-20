{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ImplicitParams #-}

module Checker.Types where

import Control.Monad.State.Strict
import Control.Monad.Trans.Maybe
import Data.List

import Checker.Coeffects
import Checker.Kinds
import Checker.Monad
import Checker.Predicates
import Checker.Substitutions
import Syntax.Expr
import Syntax.Pretty
import Utils

lEqualTypes :: (?globals :: Globals )
  => Span -> Type -> Type -> MaybeT Checker (Bool, Type, Substitution)
lEqualTypes s = equalTypesRelatedCoeffectsAndUnify s ApproximatedBy False SndIsSpec

equalTypes :: (?globals :: Globals )
  => Span -> Type -> Type -> MaybeT Checker (Bool, Type, Substitution)
equalTypes s = equalTypesRelatedCoeffectsAndUnify s Eq False SndIsSpec

equalTypesWithUniversalSpecialisation :: (?globals :: Globals )
  => Span -> Type -> Type -> MaybeT Checker (Bool, Type, Substitution)
equalTypesWithUniversalSpecialisation s = equalTypesRelatedCoeffectsAndUnify s Eq True SndIsSpec

{- | Check whether two types are equal, and at the same time
     generate coeffect equality constraints and unify the
     two types

     The first argument is taken to be possibly approximated by the second
     e.g., the first argument is inferred, the second is a specification
     being checked against
-}
equalTypesRelatedCoeffectsAndUnify :: (?globals :: Globals )
  => Span
  -- Explain how coeffects should be related by a solver constraint
  -> (Span -> Coeffect -> Coeffect -> CKind -> Constraint)
  -- Whether to allow universal specialisation
  -> Bool
  -- Starting spec indication
  -> SpecIndicator
  -- Left type (usually the inferred)
  -> Type
  -- Right type (usually the specified)
  -> Type
  -- Result is a effectful, producing:
  --    * a boolean of the equality
  --    * the most specialised type (after the unifier is applied)
  --    * the unifier
  -> MaybeT Checker (Bool, Type, Substitution)
equalTypesRelatedCoeffectsAndUnify s rel allowUniversalSpecialisation spec t1 t2 = do

   (eq, unif) <- equalTypesRelatedCoeffects s rel allowUniversalSpecialisation t1 t2 spec
   if eq
     then do
        t2 <- substitute unif t2
        return (eq, t2, unif)
     else return (eq, t1, [])

data SpecIndicator = FstIsSpec | SndIsSpec | PatternCtxt
  deriving (Eq, Show)

flipIndicator FstIsSpec = SndIsSpec
flipIndicator SndIsSpec = FstIsSpec
flipIndicator PatternCtxt = PatternCtxt

{- | Check whether two types are equal, and at the same time
     generate coeffect equality constraints and a unifier
      Polarity indicates which -}
equalTypesRelatedCoeffects :: (?globals :: Globals )
  => Span
  -- Explain how coeffects should be related by a solver constraint
  -> (Span -> Coeffect -> Coeffect -> CKind -> Constraint)
  -> Bool -- whether to allow universal specialisation
  -> Type
  -> Type
  -- Indicates whether the first type or second type is a specification
  -> SpecIndicator
  -> MaybeT Checker (Bool, Substitution)
equalTypesRelatedCoeffects s rel uS (FunTy t1 t2) (FunTy t1' t2') sp = do
  -- contravariant position (always approximate)
  (eq1, u1) <- equalTypesRelatedCoeffects s ApproximatedBy uS t1' t1 (flipIndicator sp)
   -- covariant position (depends: is not always over approximated)
  t2 <- substitute u1 t2
  t2' <- substitute u1 t2'
  (eq2, u2) <- equalTypesRelatedCoeffects s rel uS t2 t2' sp
  unifiers <- combineSubstitutions s u1 u2
  return (eq1 && eq2, unifiers)

equalTypesRelatedCoeffects _ _ _ (TyCon con) (TyCon con') _ =
  return (con == con', [])

-- THE FOLLOWING TWO CASES ARE TEMPORARY UNTIL WE MAKE 'Effect' RICHER

-- Over approximation by 'FileIO' "monad"
equalTypesRelatedCoeffects s rel uS (Diamond ef t) (TyApp (TyCon con) t') sp
   | internalName con == "FileIO" = do
    (eq, unif) <- equalTypesRelatedCoeffects s rel uS t t' sp
    return (eq, unif)

-- Under approximation by 'FileIO' "monad"
equalTypesRelatedCoeffects s rel uS (TyApp (TyCon con) t') (Diamond ef t) sp
   | internalName con == "FileIO" = do
    (eq, unif) <- equalTypesRelatedCoeffects s rel uS t t' sp
    return (eq, unif)

-- Over approximation by 'Session' "monad"
equalTypesRelatedCoeffects s rel uS (Diamond ef t) (TyApp (TyCon con) t') sp
       | internalName con == "Session" && ("Com" `elem` ef || null ef) = do
        (eq, unif) <- equalTypesRelatedCoeffects s rel uS t t' sp
        return (eq, unif)

-- Under approximation by 'Session' "monad"
equalTypesRelatedCoeffects s rel uS (TyApp (TyCon con) t') (Diamond ef t) sp
       | internalName con == "Session" && ("Com" `elem` ef || null ef) = do
        (eq, unif) <- equalTypesRelatedCoeffects s rel uS t t' sp
        return (eq, unif)


equalTypesRelatedCoeffects s rel uS (Diamond ef t) (Diamond ef' t') sp = do
  (eq, unif) <- equalTypesRelatedCoeffects s rel uS t t' sp
  if ef == ef'
    then return (eq, unif)
    else
      -- Effect approximation
      if (ef `isPrefixOf` ef')
      then return (eq, unif)
      else halt $ GradingError (Just s) $
        "Effect mismatch: " ++ pretty ef ++ " not equal to " ++ pretty ef'

equalTypesRelatedCoeffects s rel uS (Box c t) (Box c' t') sp = do
  -- Debugging messages
  debugM "equalTypesRelatedCoeffects (pretty)" $ pretty c ++ " == " ++ pretty c'
  debugM "equalTypesRelatedCoeffects (show)" $ "[ " ++ show c ++ " , " ++ show c' ++ "]"
  -- Unify the coeffect kinds of the two coeffects
  kind <- mguCoeffectTypes s c c'
  -- subst <- unify c c'
  addConstraint (rel s c c' kind)
  equalTypesRelatedCoeffects s rel uS t t' sp
  --(eq, subst') <- equalTypesRelatedCoeffects s rel uS t t' sp
  --case subst of
  --  Just subst -> do
--      substFinal <- combineSubstitutions s subst subst'
--      return (eq, substFinal)
  --  Nothing -> return (False, [])

equalTypesRelatedCoeffects s rel uS (TyApp t1 t2) (TyApp t1' t2') sp = do
  (one, u1) <- equalTypesRelatedCoeffects s rel uS t1 t1' sp
  t2  <- substitute u1 t2
  t2' <- substitute u1 t2'
  (two, u2) <- equalTypesRelatedCoeffects s rel uS t2 t2' sp
  unifiers <- combineSubstitutions s u1 u2
  return (one && two, unifiers)

equalTypesRelatedCoeffects s _ _ (TyVar n) (TyVar m) _ | n == m = do
  checkerState <- get
  case lookup n (tyVarContext checkerState) of
    Just _ -> return (True, [])
    Nothing -> halt $ UnboundVariableError (Just s) ("Type variable " ++ pretty n)

equalTypesRelatedCoeffects s _ _ (TyVar n) (TyVar m) sp = do
  checkerState <- get

  case (lookup n (tyVarContext checkerState), lookup m (tyVarContext checkerState)) of

    -- Two universally quantified variables are unequal
    (Just (_, ForallQ), Just (_, ForallQ)) ->
        return (False, [])

    -- We can unify a universal a dependently bound universal
    (Just (k1, ForallQ), Just (k2, BoundQ)) | sp == FstIsSpec || sp == PatternCtxt ->
      tyVarConstraint k2 k1 m n

    (Just (k1, BoundQ), Just (k2, ForallQ)) | sp == SndIsSpec || sp == PatternCtxt ->
      tyVarConstraint k1 k2 n m

    -- We can unify two instance type variables
    (Just (k1, InstanceQ), Just (k2, BoundQ)) ->
        tyVarConstraint k1 k2 n m

    -- We can unify two instance type variables
    (Just (k1, BoundQ), Just (k2, InstanceQ)) ->
        tyVarConstraint k1 k2 n m

    -- We can unify two instance type variables
    (Just (k1, InstanceQ), Just (k2, InstanceQ)) ->
      tyVarConstraint k1 k2 n m

    -- We can unify two instance type variables
    (Just (k1, BoundQ), Just (k2, BoundQ)) ->
        tyVarConstraint k1 k2 n m


    -- But we can unify a forall and an instance
    (Just (k1, InstanceQ), Just (k2, ForallQ)) ->
      tyVarConstraint k1 k2 n m

    -- But we can unify a forall and an instance
    (Just (k1, ForallQ), Just (k2, InstanceQ)) ->
      tyVarConstraint k1 k2 n m

    -- Trying to unify other (existential) variables
    (Just (KType, _), Just (k, _)) | k /= KType -> do
      k <- inferKindOfType s (TyVar m)
      illKindedUnifyVar s (TyVar n) KType (TyVar m) k

    (Just (k, _), Just (KType, _)) | k /= KType -> do
      k <- inferKindOfType s (TyVar n)
      illKindedUnifyVar s (TyVar n) k (TyVar m) KType

    -- Otherwise
    --(Just (k1, _), Just (k2, _)) ->
    --  tyVarConstraint k1 k2 n m

    (t1, t2) -> error $ pretty s ++ "-" ++ show sp ++ "\n" ++ pretty n ++ " : " ++ show t1 ++ "\n" ++ pretty m ++ " : " ++ show t2
  where
    tyVarConstraint k1 k2 n m = do
      case k1 `joinKind` k2 of
        Just (KConstr kc) -> do
          addConstraint (Eq s (CVar n) (CVar m) (CConstr kc))
          return (True, [(n, SubstT $ TyVar m)])
        Just _ ->
          return (True, [(n, SubstT $ TyVar m)])
        Nothing ->
          return (False, [])

equalTypesRelatedCoeffects s rel allowUniversalSpecialisation (TyVar n) t sp = do
  checkerState <- get
  debugM "Types.equalTypesRelatedCoeffects on TyVar"
          $ "span: " ++ show s
          ++ "\nallowUniversalSpecialisation: " ++ show allowUniversalSpecialisation
          ++ "\nTyVar: " ++ show n ++ "\ntype: " ++ show t ++ "\nspec indicator: " ++ show sp
  case lookup n (tyVarContext checkerState) of
    -- We can unify an instance with a concrete type
    (Just (k1, q)) | q == InstanceQ || q == BoundQ -> do
      k2 <- inferKindOfType s t
      case k1 `joinKind` k2 of
        Nothing -> illKindedUnifyVar s (TyVar n) k1 t k2

        -- If the kind is Nat=, then create a solver constraint
        Just (KConstr k) | internalName k == "Nat=" -> do
          nat <- compileNatKindedTypeToCoeffect s t
          addConstraint (Eq s (CVar n) nat (CConstr $ mkId "Nat="))
          return (True, [(n, SubstT t)])

        Just _ -> return (True, [(n, SubstT t)])

    -- Unifying a forall with a concrete type may only be possible if the concrete
    -- type is exactly equal to the forall-quantified variable
    -- This can only happen for nat indexed types at the moment via the
    -- additional equations so performa an additional check if they
    -- are both of Nat kind
    (Just (k1, ForallQ)) -> do
      k1 <- inferKindOfType s (TyVar n)
      k2 <- inferKindOfType s t
      case k1 `joinKind` k2 of
        Just (KConstr k) | internalName k == "Nat=" -> do
          c1 <- compileNatKindedTypeToCoeffect s (TyVar n)
          c2 <- compileNatKindedTypeToCoeffect s t
          addConstraint $ Eq s c1 c2 (CConstr $ mkId "Nat=")
          return (True, [(n, SubstT t)])
        x ->
          if allowUniversalSpecialisation
            then
              return (True, [(n, SubstT t)])
            else
            halt $ GenericError (Just s)
            $ case sp of
             FstIsSpec -> "Trying to match a polymorphic type '" ++ pretty n
                       ++ "' with monomorphic " ++ pretty t
             SndIsSpec -> pretty t ++ " is not equal to " ++ pretty (TyVar n)

    (Just (_, InstanceQ)) -> error "Please open an issue at https://github.com/dorchard/granule/issues"
    (Just (_, BoundQ)) -> error "Please open an issue at https://github.com/dorchard/granule/issues"
    Nothing -> halt $ UnboundVariableError (Just s) (pretty n <?> ("Types.equalTypesRelatedCoeffects: " ++ show (tyVarContext checkerState)))

equalTypesRelatedCoeffects s rel uS t (TyVar n) sp =
  equalTypesRelatedCoeffects s rel uS (TyVar n) t (flipIndicator sp)

equalTypesRelatedCoeffects s rel uS t1 t2 t = do
  debugM "equalTypesRelatedCoeffects" $ "called on: " ++ show t1 ++ "\nand:\n" ++ show t2
  equalOtherKindedTypesGeneric s t1 t2

{- | Check whether two Nat-kinded types are equal -}
equalOtherKindedTypesGeneric :: (?globals :: Globals )
    => Span
    -> Type
    -> Type
    -> MaybeT Checker (Bool, Substitution)
equalOtherKindedTypesGeneric s t1 t2 = do
  k1 <- inferKindOfType s t1
  k2 <- inferKindOfType s t2
  case (k1, k2) of
    (KConstr n, KConstr n')
      | "Nat" `isPrefixOf` (internalName n) && "Nat" `isPrefixOf` (internalName  n') -> do
        c1 <- compileNatKindedTypeToCoeffect s t1
        c2 <- compileNatKindedTypeToCoeffect s t2
        if internalName n == "Nat" && internalName n' == "Nat"
           then addConstraint $ Eq s c1 c2 (CConstr $ mkId "Nat=")
           else addConstraint $ Eq s c1 c2 (CConstr $ mkId "Nat=")
        return (True, [])
    (KType, KType) ->
       halt $ GenericError (Just s) $ pretty t1 ++ " is not equal to " ++ pretty t2

    (KConstr n, KConstr n') | internalName n == "Session" && internalName n' == "Session" ->
       sessionEquality s t1 t2
    _ ->
       halt $ KindError (Just s) $ "Equality is not defined between kinds "
                 ++ pretty k1 ++ " and " ++ pretty k2
                 ++ "\t\n from equality "
                 ++ "'" ++ pretty t2 ++ "' and '" ++ pretty t1 ++ "' equal."

sessionEquality :: (?globals :: Globals)
    => Span -> Type -> Type -> MaybeT Checker (Bool, Substitution)
sessionEquality s (TyApp (TyCon c) t) (TyApp (TyCon c') t')
  | internalName c == "Send" && internalName c' == "Send" = do
  (g, _, u) <- equalTypes s t t'
  return (g, u)

sessionEquality s (TyApp (TyCon c) t) (TyApp (TyCon c') t')
  | internalName c == "Recv" && internalName c' == "Recv" = do
  (g, _, u) <- equalTypes s t t'
  return (g, u)

sessionEquality s (TyCon c) (TyCon c')
  | internalName c == "End" && internalName c' == "End" =
  return (True, [])

sessionEquality s t1 t2 =
  halt $ GenericError (Just s)
       $ "Session type '" ++ pretty t1 ++ "' is not equal to '" ++ pretty t2 ++ "'"

-- Essentially equality on types but join on any coeffects
joinTypes :: (?globals :: Globals) => Span -> Type -> Type -> MaybeT Checker Type
joinTypes s (FunTy t1 t2) (FunTy t1' t2') = do
  t1j <- joinTypes s t1' t1 -- contravariance
  t2j <- joinTypes s t2 t2'
  return (FunTy t1j t2j)

joinTypes _ (TyCon t) (TyCon t') | t == t' = return (TyCon t)

joinTypes s (Diamond ef t) (Diamond ef' t') = do
  tj <- joinTypes s t t'
  if ef `isPrefixOf` ef'
    then return (Diamond ef' tj)
    else
      if ef' `isPrefixOf` ef
      then return (Diamond ef tj)
      else halt $ GradingError (Just s) $
        "Effect mismatch: " ++ pretty ef ++ " not equal to " ++ pretty ef'

joinTypes s (Box c t) (Box c' t') = do
  kind <- mguCoeffectTypes s c c'
  -- Create a fresh coeffect variable
  topVar <- freshCoeffectVar (mkId "") kind
  -- Unify the two coeffects into one
  addConstraint (ApproximatedBy s c  (CVar topVar) kind)
  addConstraint (ApproximatedBy s c' (CVar topVar) kind)
  tu <- joinTypes s t t'
  return $ Box (CVar topVar) tu

joinTypes _ (TyInt n) (TyInt m) | n == m = return $ TyInt n

joinTypes s (TyInt n) (TyVar m) = do
  -- Create a fresh coeffect variable
  let kind = CConstr $ mkId "Nat="
  var <- freshCoeffectVar m kind
  -- Unify the two coeffects into one
  addConstraint (Eq s (CNat Discrete n) (CVar var) kind)
  return $ TyInt n

joinTypes s (TyVar n) (TyInt m) = joinTypes s (TyInt m) (TyVar n)

joinTypes s (TyVar n) (TyVar m) = do
  -- Create fresh variables for the two tyint variables
  let kind = CConstr $ mkId "Nat="
  nvar <- freshCoeffectVar n kind
  mvar <- freshCoeffectVar m kind
  -- Unify the two variables into one
  addConstraint (ApproximatedBy s (CVar nvar) (CVar mvar) kind)
  return $ TyVar n

joinTypes s (TyApp t1 t2) (TyApp t1' t2') = do
  t1'' <- joinTypes s t1 t1'
  t2'' <- joinTypes s t2 t2'
  return (TyApp t1'' t2'')

joinTypes s t1 t2 = do
  halt $ GenericError (Just s)
    $ "Type '" ++ pretty t1 ++ "' and '"
               ++ pretty t2 ++ "' have no upper bound"
