{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LiberalTypeSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ExistentialQuantification #-}
#if defined(__GLASGOW_HASKELL__) && __GLASGOW_HASKELL__ >= 704
{-# LANGUAGE Trustworthy #-}
#endif
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Data.Lens
-- Copyright   :  (C) 2012 Edward Kmett, (C) 2006-2012 Neil Mitchell
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  experimental
-- Portability :  Rank2Types
--
-- Smart and naïve generic traversals given 'Data' instances.
--
-- 'template', 'uniplate', and 'biplate' each build up information about what
-- types can be contained within another type to speed up 'Traversal'.
--
----------------------------------------------------------------------------
module Data.Data.Lens
  (
  -- * Generic Traversal
    template
  , tinplate
  , uniplate
  , biplate
  -- * Field Accessor Traversal
  , upon
  , upon'
  , uponTheDeep
  , uponTheDeep'
  -- * Data Traversal
  , gtraverse
  ) where

import           Control.Applicative
import           Control.Arrow ((&&&))
import           Control.Exception as E
import           Control.Lens.Getter
import           Control.Lens.Indexed
import           Control.Lens.IndexedLens
import           Control.Lens.IndexedSetter
import           Control.Lens.IndexedTraversal
import           Control.Lens.Internal
import           Control.Lens.Setter
import           Control.Lens.Traversal
import           Control.Lens.Type
import           Data.Data
import           Data.Foldable
import qualified Data.HashMap.Strict as M
import           Data.HashMap.Strict (HashMap, (!))
import qualified Data.HashSet as S
import           Data.HashSet (HashSet)
import           Data.IORef
import           Data.Monoid
import           GHC.IO
import           GHC.Exts (realWorld#)
import           Unsafe.Coerce as Unsafe

-- $setup
-- >>> import Control.Lens

-------------------------------------------------------------------------------
-- Generic Traversal
-------------------------------------------------------------------------------

-- | A generic applicative transformation that maps over the immediate subterms.
--
-- 'gtraverse' is to 'traverse' what 'gmapM' is to 'mapM'
--
-- This really belongs in @Data.Data@.
gtraverse :: (Applicative f, Data a) => (forall d. Data d => d -> f d) -> a -> f a
gtraverse f = gfoldl (\x y -> x <*> f y) pure

-------------------------------------------------------------------------------
-- Naïve Traversal
-------------------------------------------------------------------------------

-- | Naïve 'Traversal' using 'Data'. This does not attempt to optimize the traversal.
--
-- This is primarily useful when the children are immediately obvious, and for benchmarking.
tinplate :: (Data s, Typeable a) => Simple Traversal s a
tinplate f = gfoldl (step f) pure
{-# INLINE tinplate #-}

step :: (Applicative f, Typeable a, Data s) => (a -> f a) -> f (s -> r) -> s -> f r
step f w s = w <*> case cast s of
  Just a  -> unsafeCoerce <$> f a
  Nothing -> tinplate f s
{-# INLINE step #-}

-------------------------------------------------------------------------------
-- Smart Traversal
-------------------------------------------------------------------------------

-- | Find every occurence of a given type @a@ recursively that doesn't require
-- passing through something of type @a@ using 'Data', while avoiding traversal
-- of areas that cannot contain a value of type @a@.
--
-- This is 'uniplate' with a more liberal signature.
template :: forall s a. (Data s, Typeable a) => Simple Traversal s a
template = uniplateData (fromOracle answer) where
  answer = hitTest (undefined :: s) (undefined :: a)
{-# INLINE template #-}

-- | Find descendants of type @a@ non-transitively, while avoiding computation of areas that cannot contain values of
-- type @a@ using 'Data'.
--
-- 'uniplate' is a useful default definition for 'Control.Plated.plate'
uniplate :: Data a => Simple Traversal a a
uniplate = template
{-# INLINE uniplate #-}

-- | 'biplate' performs like 'template', except when @s ~ a@, it returns itself and nothing else.
biplate :: forall s a. (Data s, Typeable a) => Simple Traversal s a
biplate = biplateData (fromOracle answer) where
  answer = hitTest (undefined :: s) (undefined :: a)
{-# INLINE biplate #-}

------------------------------------------------------------------------------
-- Automatic Traversal construction from field accessors
------------------------------------------------------------------------------

data FieldException a = FieldException !Int a deriving Typeable

instance Show (FieldException a) where
  showsPrec d (FieldException i _) = showParen (d > 10) $
    showString "<field " . showsPrec 11 i . showChar '>'

instance Typeable a => Exception (FieldException a)

lookupon :: Typeable a => SimpleLensLike (Indexing Mutator) s a -> (s -> a) -> s -> Maybe (Int, Context a a s)
lookupon l field s = case unsafePerformIO $ E.try $ evaluate $ field $ s & indexed l %@~ \i (a::a) -> E.throw (FieldException i a) of
  Right _ -> Nothing
  Left e -> case fromException e of
    Nothing -> Nothing
    Just (FieldException i a) -> Just (i, Context (\a' -> set (elementOf l i) a' s) a)
{-# INLINE lookupon #-}

-- | This automatically constructs a 'Simple' 'Traversal' from a field accessor.
--
-- >>> (2,4) & upon fst *~ 5
-- (10,4)
--
-- There are however, a few caveats on how this function can be used:
--
-- First, the user supplied function must access one of the \"immediate descendants\" of the structure as attempts
-- to access deeper structures or use non-field accessor functions will generate an empty 'Traversal'.
--
-- A more rigorous way to say \"immediate descendants\" is that the function must only inspect one value that would
-- be visited by 'template'.
--
-- Note: this even permits some functions to be used directly.
--
-- >>> [1,2,3,4] & upon head .~ 0
-- [0,2,3,4]
--
-- >>> [1,2,3,4] & upon last .~ 5
-- [1,2,3,5]
--
-- >>> [1,2,3,4] ^? upon tail
-- Just [2,3,4]
--
-- >>> "" ^? upon tail
-- Nothing
--
-- Second, the structure must not contain strict or unboxed fields of the same type that will be visited by 'Data'
--
-- If the supplied function is not a descendant that would be visible to 'template', the resulting 'Traversal'
-- will traverse no elements.
--
-- If the field you name isn't visible to 'template', but is a "descendant" of a field visible to 'template', then
-- upon will return the *ancestor* it can visit, not the field you asked for! Be careful.
--
-- >>> upon (tail.tail) .~ [10,20] $ [1,2,3,4] -- BAD
-- [1,10,20]
--
-- To resolve this when you need deep self-similar recursion, use 'uponTheDeep'. However, 'upon' terminates for
-- more inputs, while 'uponTheDeep' can get lost in structures that are infinitely depth-recursive through @a@.
--
-- >>> uponTheDeep (tail.tail) .~ [10,20] $ [1,2,3,4] -- GOOD
-- [1,2,10,20]
--
-- The index of the 'Traversal' can be used as an offset into @'elementOf' ('indexed' 'template')@ or into the list
-- returned by @'holesOf' 'template'@.
upon :: forall s a. (Data s, Typeable a) => (s -> a) -> SimpleIndexedTraversal Int s a
upon field = indexing $ \f s -> case lookupon template field s of
  Nothing -> pure s
  Just (i, Context k a) -> k <$> f i a
{-# INLINE upon #-}

-- | This more trusting version of 'upon' uses your function directly as the getter for a 'Lens'.
--
-- This means that reading from 'upon'' is considerably faster than 'upon'.
--
-- However, you pay for faster access in two ways:
--
-- 1. When passed an illegal field accessor, 'upon'' will give you a 'Lens' that quietly violates
--    the laws unlike 'upon' will will give you a legal 'Traversal', that avoids modifying the target.
--
-- 2. Modifying with the lens is slightly slower, since it has to go back and calculate the index after the fact.
--
-- When given a legal field accessor, the index of the 'Lens' can be used as an offset into
-- @'elementOf' ('indexed' 'template')@ or into the list returned by @'holesOf' 'template'@.
upon' :: forall s a. (Data s, Typeable a) => (s -> a) -> SimpleIndexedLens Int s a
upon' field = indexing $ \f s -> let
    ~(i, Context k _) = case lookupon template field s of
      Nothing -> error "upon': no index, not a member"
      Just ip -> ip
  in k <$> f i (field s)
{-# INLINE upon' #-}

-- | The design of 'upon' doesn't allow it to search inside of values of type 'a' for other values of type 'a'.
-- uponTheDeep provides this additional recursion.
--
-- >>> uponTheDeep (tail.tail) .~ [10,20] $ [1,2,3,4]
-- [1,2,10,20]
--
-- @'uponTheDeep' :: ('Data' s, 'Data' a) => (s -> a) -> 'SimpleIndexedTraversal' [Int] s a@
uponTheDeep :: forall k f s a. (Indexed [Int] k, Applicative f, Data s, Data a) => (s -> a) -> k (a -> f a) (s -> f s)
uponTheDeep field = indexing $ \ f s -> case lookupon template field s of
  Nothing -> pure s
  Just (i, Context k0 a0) ->
    let
      go :: [Int] -> SimpleTraversal s a -> (a -> s) -> a -> f s
      go is l k a = case lookupon (l.uniplate) field s of
        Nothing                 -> k <$> f (reverse is) a
        Just (j, Context k' a') -> go (j:is) (l.elementOf uniplate j) k' a'
    in go [i] (elementOf template i) k0 a0
{-# INLINE uponTheDeep #-}

-- | The design of 'upon'' doesn't allow it to search inside of values of type 'a' for other values of type 'a'.
-- 'uponTheDeep'' provides this additional recursion.
--
-- Like 'upon'', 'uponTheDeep'' trusts the user supplied function more than 'uponTheDeep' using it directly
-- as the accessor. This enables reading from the resulting 'Lens' to be considerably faster at the risk of
-- generating an illegal lens.
--
-- >>> uponTheDeep' (tail.tail) .~ [10,20] $ [1,2,3,4]
-- [1,2,10,20]
uponTheDeep' :: forall s a. (Data s, Data a) => (s -> a) -> SimpleIndexedLens [Int] s a
uponTheDeep' field = indexing $ \ f s -> let
    ~(isn, kn) = case lookupon template field s of
      Nothing -> (error "uponTheDeep': no index, not a member", const s)
      Just (i, Context k0 _) -> go [i] (elementOf template i) k0
    go :: [Int] -> SimpleTraversal s a -> (a -> s) -> ([Int], a -> s)
    go is l k = case lookupon (l.uniplate) field s of
      Nothing                -> (reverse is, k)
      Just (j, Context k' _) -> go (j:is) (l.elementOf uniplate j) k'
  in kn <$> f isn (field s)
{-# INLINE uponTheDeep' #-}

-------------------------------------------------------------------------------
-- Data Box
-------------------------------------------------------------------------------

data DataBox = forall a. Data a => DataBox
  { dataBoxKey :: TypeRep
  , _dataBoxVal :: a
  }

dataBox :: Data a => a -> DataBox
dataBox a = DataBox (typeOf a) a
{-# INLINE dataBox #-}

-- partial, caught elsewhere
sybChildren :: Data a => a -> [DataBox]
sybChildren x
  | isAlgType dt = do
    c <- dataTypeConstrs dt
    gmapQ dataBox (fromConstr c `asTypeOf` x)
  | otherwise = []
  where dt = dataTypeOf x

-------------------------------------------------------------------------------
-- HitMap
-------------------------------------------------------------------------------

type HitMap = HashMap TypeRep (HashSet TypeRep)

emptyHitMap :: HitMap
emptyHitMap = M.fromList
  [ (tRational, S.singleton tInteger)
  , (tInteger,  S.empty)
  ] where
  tRational = typeOf (undefined :: Rational)
  tInteger  = typeOf (undefined :: Integer )

insertHitMap :: DataBox -> HitMap -> HitMap
insertHitMap box hit = fixEq trans (populate box) `mappend` hit where
  populate :: DataBox -> HitMap
  populate a = f a M.empty where
    f (DataBox k v) m
      | M.member k hit || M.member k m = m
      | cs <- sybChildren v = fs cs $ M.insert k (S.fromList $ map dataBoxKey cs) m
    fs []     m = m
    fs (x:xs) m = fs xs (f x m)

  trans :: HitMap -> HitMap
  trans m = M.map f m where
    f x = x `mappend` foldMap g x
    g x = M.lookupDefault (hit ! x) x m

fixEq :: Eq a => (a -> a) -> a -> a
fixEq f = go where
  go x | x == x'   = x'
       | otherwise = go x'
       where x' = f x
{-# INLINE fixEq #-}

-- | inlineable 'unsafePerformIO'
inlinePerformIO :: IO a -> a
inlinePerformIO (IO m) = case m realWorld# of
  (# _, r #) -> r
{-# INLINE inlinePerformIO #-}

-------------------------------------------------------------------------------
-- Cache
-------------------------------------------------------------------------------

data Cache = Cache HitMap (HashMap TypeRep (HashMap TypeRep (Maybe Follower)))

cache :: IORef Cache
cache = unsafePerformIO $ newIORef $ Cache emptyHitMap M.empty
{-# NOINLINE cache #-}

readCacheFollower :: DataBox -> TypeRep -> Maybe Follower
readCacheFollower b@(DataBox kb _) ka = inlinePerformIO $
  readIORef cache >>= \ (Cache hm m) -> case M.lookup kb m >>= M.lookup ka of
    Just a -> return a
    Nothing -> E.try (return $! insertHitMap b hm) >>= \r -> case r of
      Left SomeException{}                         -> atomicModifyIORef cache $ \(Cache hm' n) -> (Cache hm' (insert2 kb ka Nothing n), Nothing)
      Right hm' | fol <- Just (follower kb ka hm') -> atomicModifyIORef cache $ \(Cache _ n) -> (Cache hm' (insert2 kb ka fol n),    fol)

insert2 :: TypeRep -> TypeRep -> a -> HashMap TypeRep (HashMap TypeRep a) -> HashMap TypeRep (HashMap TypeRep a)
insert2 x y v = M.insertWith (const $ M.insert y v) x (M.singleton y v)
{-# INLINE insert2 #-}

{-
readCacheHitMap :: DataBox -> Maybe HitMap
readCacheHitMap b@(DataBox kb _) = inlinePerformIO $
  readIORef cache >>= \ (Cache hm _) -> case M.lookup kb hm of
    Just _  -> return $ Just hm
    Nothing -> E.try (return $! insertHitMap b hm) >>= \r -> case r of
      Left SomeException{} -> return Nothing
      Right hm' -> atomicModifyIORef cache $ \(Cache _ follow) -> (Cache hm' follow, Just hm')
-}

-------------------------------------------------------------------------------
-- Answers
-------------------------------------------------------------------------------

data Answer a
  = Hit a
  | Follow
  | Miss
  deriving (Eq,Ord,Show,Read)

instance Functor Answer where
  fmap f (Hit a) = Hit (f a)
  fmap _ Follow  = Follow
  fmap _ Miss    = Miss

-------------------------------------------------------------------------------
-- Oracles
-------------------------------------------------------------------------------

newtype Oracle a = Oracle { fromOracle :: forall t. Typeable t => t -> Answer a }

instance Functor Oracle where
  fmap f (Oracle g) = Oracle (fmap f . g)

hitTest :: (Data a, Typeable b) => a -> b -> Oracle b
hitTest a b
  | kb <- typeOf b = case readCacheFollower (dataBox a) kb of
    Nothing -> Oracle $ \c ->
      if typeOf c == kb
      then Hit (unsafeCoerce c)
      else Follow
    Just p -> Oracle $ \c -> let kc = typeOf c in
      if kc == kb then Hit (unsafeCoerce c)
      else if p kc then Follow
      else Miss

-------------------------------------------------------------------------------
-- Traversals
-------------------------------------------------------------------------------


biplateData :: forall f s a. (Applicative f, Data s, Typeable a) => (forall c. Typeable c => c -> Answer a) -> (a -> f a) -> s -> f s
biplateData o f a0 = go2 a0 where
  go :: Data d => d -> f d
  go s = gfoldl (\x y -> x <*> go2 y) pure s
  go2 :: Data d => d -> f d
  go2 s = case o s of
    Hit a  -> Unsafe.unsafeCoerce <$> f a
    Follow -> go s
    Miss   -> pure s
{-# INLINE biplateData #-}

uniplateData :: forall f s a. (Applicative f, Data s, Typeable a) => (forall c. Typeable c => c -> Answer a) -> (a -> f a) -> s -> f s
uniplateData o f a0 = go a0 where
  go :: Data d => d -> f d
  go s = gfoldl (\x y -> x <*> go2 y) pure s
  go2 :: Data d => d -> f d
  go2 s = case o s of
    Hit a  -> Unsafe.unsafeCoerce <$> f a
    Follow -> go s
    Miss   -> pure s
{-# INLINE uniplateData #-}

-------------------------------------------------------------------------------
-- Follower
-------------------------------------------------------------------------------

part :: (a -> Bool) -> HashSet a -> (HashSet a, HashSet a)
part p = S.filter p &&& S.filter (not . p)
{-# INLINE part #-}

type Follower = TypeRep -> Bool

follower :: TypeRep -> TypeRep -> HitMap -> Follower
follower a b m
  | S.null hit               = const False
  | S.null miss              = const True
  | S.size hit < S.size miss = \k -> S.member k hit
  | otherwise = \k -> not (S.member k miss)
  where (hit, miss) = part (\x -> S.member b (m ! x)) (S.insert a (m ! a))

