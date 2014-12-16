module Silk.Opaleye.TH.Column
  ( -- * TH end points
    mkId
  , makeColumnInstances
    -- * TH dependencies defined here
--  , nullableFieldQueryRunnerColumn
  , fromFieldAux
    -- * Re-exported TH dependencies
  , Typeable
  , Default (def)
  , ShowConstant (..)
  , FromField (fromField)
  , QueryRunnerColumnDefault (..)
  , Nullable
  , Column
  , fieldQueryRunnerColumn
  ) where

import Control.Applicative
import Control.Monad
import Data.ByteString (ByteString)
import Data.Data
import Data.Profunctor.Product.Default
import Data.String.Conversions
import Database.PostgreSQL.Simple.FromField (Conversion, Field, FromField (..), ResultError (..), returnError)
import Language.Haskell.TH
import Opaleye.Column
import Opaleye.Internal.RunQuery

import Silk.Opaleye.ShowConstant (ShowConstant (..))
import Silk.Opaleye.TH.Util

-- TODO This assumes the destructor is named unId, can be changed to a pattern match.
-- TODO It's probably too lenient with input as well, only newtypes or constructors with one field are allowed.
mkId :: Name -> Q [Dec]
mkId = return . either error id <=< f <=< reify
  where
    f :: Info -> Q (Either String [Dec])
    f i = case i of
      TyConI (NewtypeD _ctx tyName _tyVars@[] con _names) ->
        case getConNameTy con of
          Left err      -> return $ Left err
          Right (conName, innerTy) -> Right <$> g tyName conName (head innerTy)
      TyConI NewtypeD{} -> return $ Left "Type variables aren't allowed"
      _  -> return $ Left "Must be a newtype"

    g :: Name -> Name -> Type -> Q [Dec]
    g tyName _conName innerTy = do
      let x = [unsafeIdSig, unsafeId, unsafeIdSig', unsafeId']
      y <- makeColumnInstancesInternal tyName innerTy (mkName "unId") (mkName "unsafeId'")
      return $ x ++ y
      where
        unsafeIdSig, unsafeId, unsafeIdSig', unsafeId' :: Dec
        unsafeIdSig = SigD (mkName "unsafeId") $ ArrowT `AppT` innerTy `AppT` ty "Id"
        unsafeId  = plainFun (mkName "unsafeId")  $ ConE (mkName "Id")
        unsafeIdSig' = SigD (mkName "unsafeId'") $ ArrowT `AppT` innerTy `AppT` (ty "Maybe" `AppT` ty "Id")
        unsafeId' = plainFun (mkName "unsafeId'") $ VarE (mkName ".") `AppE` ConE (mkName "Just") `AppE` ConE (mkName "Id")
        plainFun n e = FunD n [Clause [] (NormalB e) []]

makeColumnInstances :: Name -> Name -> Name -> Name -> Q [Dec]
makeColumnInstances tyName innerTyName toDb fromDb = makeColumnInstancesInternal tyName (ConT innerTyName) toDb fromDb

makeColumnInstancesInternal :: Name -> Type -> Name -> Name -> Q [Dec]
makeColumnInstancesInternal tyName innerTy toDb fromDb =
    return [fromFld, showConst, queryRunnerColumn]
  where
    fromFld
      = InstanceD [] (ConT (mkName "FromField") `AppT` ConT tyName)
                  [ FunD (mkName "fromField")
                    [ Clause [] (NormalB $ VarE (mkName "fromFieldAux") `AppE` VarE fromDb) [] ]
                  ]
    showConst
      = InstanceD [] (ConT (mkName "ShowConstant") `AppT` ConT tyName)
                  [ TySynInstD (mkName "PGRep") (TySynEqn [ConT tyName] (ConT (mkName "PGRep") `AppT` innerTy))
                  , FunD (mkName "constant")
                      [ Clause [] (NormalB $ VarE (mkName ".") `AppE` VarE (mkName "constant") `AppE` VarE toDb) [] ]
                  ]
    queryRunnerColumn
      = InstanceD [EqualP (ConT (mkName "PGRep") `AppT` ConT tyName) tyVar] (ConT (mkName "QueryRunnerColumnDefault") `AppT` tyVar `AppT` ConT tyName)
                 queryRunnerBody
      where
        tyVar = VarT $ mkName "a"
    queryRunnerBody = qr "fieldQueryRunnerColumn"
    qr q = [ FunD (mkName "queryRunnerColumnDefault") [ Clause [] (NormalB $ VarE $ mkName q) [] ] ]


-- nullableFieldQueryRunnerColumn :: FromField a => QueryRunnerColumn (Column (Nullable a)) (Maybe a)
-- nullableFieldQueryRunnerColumn = lmap unsafeCoerce fieldQueryRunnerColumn

fromFieldAux :: (FromField a, Typeable b) => (a -> Maybe b) -> Field -> Maybe ByteString -> Conversion b
fromFieldAux fromDb f mdata = case mdata of
  Just dat -> maybe (returnError ConversionFailed f (cs dat)) return . fromDb =<< fromField f mdata
  Nothing  -> returnError UnexpectedNull f ""
