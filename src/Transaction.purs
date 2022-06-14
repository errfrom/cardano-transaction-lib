module Transaction
  ( ModifyTxError(..)
  , finalizeTransaction
  , attachDatum
  , attachRedeemer
  , attachPlutusScript
  , setScriptDataHash
  ) where

import Prelude
import Undefined

import Cardano.Types.Transaction
  ( Transaction(Transaction)
  , Redeemer
  , ScriptDataHash(ScriptDataHash)
  , TransactionWitnessSet(TransactionWitnessSet)
  , TxBody(TxBody)
  , _witnessSet
  )
import Control.Monad.Except.Trans (ExceptT, runExceptT)
import Data.Array as Array
import Data.Either (Either(Right), note)
import Data.Generic.Rep (class Generic)
import Data.Lens ((%~))
import Data.Maybe (Maybe(Just, Nothing))
import Data.Newtype (over, unwrap)
import Data.Show.Generic (genericShow)
import Data.Traversable (traverse, for)
import Deserialization.WitnessSet as Deserialization.WitnessSet
import Effect (Effect)
import Effect.Class (liftEffect)
import Helpers (liftEither)
import ProtocolParametersAlonzo (costModels)
import Serialization (hashScriptData, toBytes)
import Serialization.PlutusData as Serialization.PlutusData
import Serialization.Types as Serialization
import Serialization.WitnessSet as Serialization.WitnessSet
import Types.Datum (Datum(Datum))
import Types.Scripts (PlutusScript)
import Untagged.Union (asOneOf)

data ModifyTxError
  = ConvertWitnessesError
  | ConvertDatumError

derive instance Generic ModifyTxError _
derive instance Eq ModifyTxError

instance Show ModifyTxError where
  show = genericShow

-- | Sets the script integrity hash and attaches redeemers, for use after
-- | reindexing
finalizeTransaction
  :: Array Redeemer
  -> Array Datum
  -> Transaction
  -> Effect (Either ModifyTxError Transaction)
finalizeTransaction rs ds tx = runExceptT $ do
  tx' <- attachRedeemers rs $
    -- Strip the existing redeemers from the transaction, which have since been
    -- re-indexed
    tx # _witnessSet %~ over TransactionWitnessSet _ { redeemers = Nothing }
  liftEffect $ setScriptDataHash rs ds tx'

-- | Set the `Transaction` body's script data hash. NOTE: Must include all of
-- | the datums and redeemers for the given transaction
setScriptDataHash
  :: Array Redeemer -> Array Datum -> Transaction -> Effect Transaction
setScriptDataHash rs ds tx@(Transaction { body }) = do
  scriptDataHash <- ScriptDataHash <<< toBytes <<< asOneOf
    <$> hashScriptData rs costModels (unwrap <$> ds)
  pure $ over Transaction
    _
      { body = over TxBody _ { scriptDataHash = Just scriptDataHash } body
      }
    tx

-- | Attach a `Datum` to a transaction by modifying its existing witness set.
-- | Fails if either the datum or updated witness set cannot be converted during
-- | (de-)serialization
attachDatum :: Datum -> Transaction -> Effect (Either ModifyTxError Transaction)
attachDatum d = runExceptT <<< attachDatums (Array.singleton d)

attachDatums
  :: Array Datum -> Transaction -> ExceptT ModifyTxError Effect Transaction
attachDatums datums tx@(Transaction { witnessSet: ws }) = do
  ds <- traverse
    ( liftEither
        <<< note ConvertDatumError
        <<< Serialization.PlutusData.convertPlutusData
        <<< unwrap
    )
    datums
  updateTxWithWitnesses tx
    =<< convertWitnessesWith ws (Serialization.WitnessSet.setPlutusData ds)

-- | Attach a `Redeemer` to a transaction by modifying its existing witness set.
-- | Note that this is the `Types.Transaction` representation of a redeemer and
-- | not a wrapped `PlutusData`.
--
-- | Fails if either the redeemer or updated witness set cannot be converted
-- | during (de-)serialization
attachRedeemer
  :: Redeemer -> Transaction -> Effect (Either ModifyTxError Transaction)
attachRedeemer r = runExceptT <<< attachRedeemers (Array.singleton r)

attachRedeemers
  :: Array Redeemer -> Transaction -> ExceptT ModifyTxError Effect Transaction
attachRedeemers rs tx@(Transaction { witnessSet: ws }) = do
  rs' <- liftEffect $ traverse Serialization.WitnessSet.convertRedeemer rs
  updateTxWithWitnesses tx
    =<< convertWitnessesWith ws (Serialization.WitnessSet.setRedeemers rs')

-- | Attach a `PlutusScript` to a transaction by modifying its existing witness
-- | set
-- |
-- | Fails if either the script or updated witness set cannot be converted
-- | during (de-)serialization
attachPlutusScript
  :: PlutusScript -> Transaction -> Effect (Either ModifyTxError Transaction)
attachPlutusScript ps = runExceptT <<< attachPlutusScripts (Array.singleton ps)

attachPlutusScripts
  :: Array PlutusScript
  -> Transaction
  -> ExceptT ModifyTxError Effect Transaction
attachPlutusScripts ps tx@(Transaction { witnessSet: ws }) = do
  ps' <- traverse (liftEffect <<< Serialization.WitnessSet.convertPlutusScript)
    ps
  updateTxWithWitnesses tx
    =<< convertWitnessesWith ws (Serialization.WitnessSet.setPlutusScripts ps')

convertWitnessesWith
  :: TransactionWitnessSet
  -> (Serialization.TransactionWitnessSet -> Effect Unit)
  -> ExceptT ModifyTxError Effect TransactionWitnessSet
convertWitnessesWith ws act = do
  ws' <- liftEffect $ Serialization.WitnessSet.convertWitnessSet ws
  liftEffect $ act ws'
  liftEither $ note ConvertWitnessesError
    $ Deserialization.WitnessSet.convertWitnessSet ws'

updateTxWithWitnesses
  :: forall (e :: Type)
   . Transaction
  -> TransactionWitnessSet
  -> ExceptT e Effect Transaction
updateTxWithWitnesses tx@(Transaction t) ws =
  liftEither $ Right $ over Transaction _ { witnessSet = t.witnessSet <> ws } tx
