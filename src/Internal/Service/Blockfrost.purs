module Ctl.Internal.Service.Blockfrost
  ( isTxConfirmed
  , getTxMetadata
  , BlockfrostMetadata(BlockfrostMetadata)
  , BlockfrostServiceM
  , BlockfrostServiceParams
  , runBlockfrostServiceM
  , dummyExport
  , submitTx
  , evaluateTx
  ) where

import Prelude

import Aeson
  ( class DecodeAeson
  , Aeson
  , JsonDecodeError(TypeMismatch)
  , decodeAeson
  , parseJsonStringToAeson
  , stringifyAeson
  )
import Affjax (Error, Response, URL, defaultRequest, request) as Affjax
import Affjax.RequestBody (RequestBody, arrayView, string) as Affjax
import Affjax.RequestHeader (RequestHeader(ContentType, RequestHeader)) as Affjax
import Affjax.ResponseFormat (string) as Affjax.ResponseFormat
import Affjax.StatusCode (StatusCode(StatusCode)) as Affjax
import Control.Alt ((<|>))
import Control.Monad.Error.Class (throwError)
import Control.Monad.Logger.Trans (LoggerT, runLoggerT)
import Control.Monad.Reader.Class (ask)
import Control.Monad.Reader.Trans (ReaderT, runReaderT)
import Ctl.Internal.Cardano.Types.Transaction
  ( Transaction
  )
import Ctl.Internal.Contract.QueryBackend (BlockfrostBackend)
import Ctl.Internal.Contract.QueryHandle.Error
  ( GetTxMetadataError
      ( GetTxMetadataTxNotFoundError
      , GetTxMetadataClientError
      , GetTxMetadataMetadataEmptyOrMissingError
      )
  )
import Ctl.Internal.Deserialization.FromBytes (fromBytes)
import Ctl.Internal.Deserialization.Transaction
  ( convertGeneralTransactionMetadata
  )
import Ctl.Internal.QueryM.Ogmios (TxEvaluationR)
import Ctl.Internal.Serialization as Serialization
import Ctl.Internal.ServerConfig (ServerConfig, mkHttpUrl)
import Ctl.Internal.Service.Error
  ( ClientError(ClientHttpError, ClientHttpResponseError, ClientDecodeJsonError)
  , ServiceError(ServiceBlockfrostError)
  )
-- import Ctl.Internal.QueryM (handleAffjaxResponse)
import Ctl.Internal.Types.ByteArray (byteArrayToHex)
import Ctl.Internal.Types.CborBytes (CborBytes, cborBytesToHex)
import Ctl.Internal.Types.Transaction (TransactionHash)
import Ctl.Internal.Types.TransactionMetadata
  ( GeneralTransactionMetadata(GeneralTransactionMetadata)
  )
import Data.Bifunctor (lmap)
import Data.Either (Either(Left, Right), note)
import Data.Generic.Rep (class Generic)
import Data.HTTP.Method (Method(GET, POST))
import Data.Log.Message (Message)
import Data.Map as Map
import Data.Maybe (Maybe(Just), maybe)
import Data.MediaType (MediaType(MediaType))
import Data.Newtype (class Newtype, unwrap, wrap)
import Data.Show.Generic (genericShow)
import Data.Traversable (for)
import Effect.Aff (Aff)
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Effect.Exception (error)
import Undefined (undefined)

--------------------------------------------------------------------------------
-- BlockfrostServiceM
--------------------------------------------------------------------------------

type BlockfrostServiceParams =
  { blockfrostConfig :: ServerConfig
  , blockfrostApiKey :: Maybe String
  }

type BlockfrostServiceM (a :: Type) = LoggerT
  (ReaderT BlockfrostServiceParams Aff)
  a

runBlockfrostServiceM
  :: forall (a :: Type)
   . (Message -> Aff Unit)
  -> BlockfrostBackend
  -> BlockfrostServiceM a
  -> Aff a
runBlockfrostServiceM logger backend =
  flip runReaderT serviceParams <<< flip runLoggerT (liftAff <<< logger)
  where
  serviceParams :: BlockfrostServiceParams
  serviceParams =
    { blockfrostConfig: backend.blockfrostConfig
    , blockfrostApiKey: backend.blockfrostApiKey
    }

--------------------------------------------------------------------------------
-- Making requests to Blockfrost endpoints
--------------------------------------------------------------------------------

data BlockfrostEndpoint
  = SubmitTransaction
  | EvaluateTransaction
  | Transaction TransactionHash
  | TransactionMetadata TransactionHash

realizeEndpoint :: BlockfrostEndpoint -> Affjax.URL
realizeEndpoint endpoint =
  case endpoint of
    SubmitTransaction -> "/tx/submit"
    EvaluateTransaction -> "/utils/txs/evaluate"
    Transaction txHash -> "/txs/" <> byteArrayToHex (unwrap txHash)
    TransactionMetadata txHash -> "/txs/" <> byteArrayToHex (unwrap txHash)
      <> "/metadata/cbor"

dummyExport :: Unit -> Unit
dummyExport _ = undefined blockfrostPostRequest

blockfrostGetRequest
  :: BlockfrostEndpoint
  -> BlockfrostServiceM (Either Affjax.Error (Affjax.Response String))
blockfrostGetRequest endpoint = ask >>= \params -> liftAff do
  Affjax.request $ Affjax.defaultRequest
    { method = Left GET
    , url = mkHttpUrl params.blockfrostConfig <> realizeEndpoint endpoint
    , responseFormat = Affjax.ResponseFormat.string
    , headers =
        maybe mempty (\apiKey -> [ Affjax.RequestHeader "project_id" apiKey ])
          params.blockfrostApiKey
    }

blockfrostPostRequest
  :: BlockfrostEndpoint
  -> MediaType
  -> Maybe Affjax.RequestBody
  -> BlockfrostServiceM (Either Affjax.Error (Affjax.Response String))
blockfrostPostRequest endpoint mediaType mbContent =
  ask >>= \params -> liftAff do
    Affjax.request $ Affjax.defaultRequest
      { method = Left POST
      , url = mkHttpUrl params.blockfrostConfig <> realizeEndpoint endpoint
      , content = mbContent
      , responseFormat = Affjax.ResponseFormat.string
      , headers =
          [ Affjax.ContentType mediaType ] <>
            maybe mempty
              (\apiKey -> [ Affjax.RequestHeader "project_id" apiKey ])
              params.blockfrostApiKey
      }

--------------------------------------------------------------------------------
-- Blockfrost response handling
--------------------------------------------------------------------------------

handleBlockfrostResponse
  :: forall (result :: Type)
   . DecodeAeson result
  => Either Affjax.Error (Affjax.Response String)
  -> Either ClientError result
handleBlockfrostResponse (Left affjaxError) =
  Left (ClientHttpError affjaxError)
handleBlockfrostResponse (Right { status: Affjax.StatusCode statusCode, body })
  | statusCode < 200 || statusCode > 299 = do
      blockfrostError <-
        body # lmap (ClientDecodeJsonError body)
          <<< (decodeAeson <=< parseJsonStringToAeson)
      Left $ ClientHttpResponseError (wrap statusCode) $
        ServiceBlockfrostError blockfrostError
  | otherwise =
      body # lmap (ClientDecodeJsonError body)
        <<< (decodeAeson <=< parseJsonStringToAeson)

submitTx
  :: Transaction
  -> BlockfrostServiceM (Either ClientError TransactionHash)
submitTx tx = do
  cslTx <- liftEffect $ Serialization.convertTransaction tx
  handleBlockfrostResponse <$> request (Serialization.toBytes cslTx)
  where
  request
    :: CborBytes
    -> BlockfrostServiceM (Either Affjax.Error (Affjax.Response String))
  request cbor =
    blockfrostPostRequest SubmitTransaction (MediaType "application/cbor")
      $ Just
      $ Affjax.arrayView
      $ unwrap
      $ unwrap cbor

evaluateTx :: Transaction -> BlockfrostServiceM TxEvaluationR
evaluateTx tx = do
  cslTx <- liftEffect $ Serialization.convertTransaction tx
  resp <- handleBlockfrostResponse <$> request (Serialization.toBytes cslTx)
  case unwrapBlockfrostEvaluateTx <$> resp of
    Left err -> throwError $ error $ show err
    Right (Left err) ->
      -- Replicate the error of QueryM's fault handler
      throwError $ error $ "Server responded with `fault`: " <> stringifyAeson
        err
    Right (Right eval) -> pure eval
  where
  -- Hex encoded, not binary like submission
  request
    :: CborBytes
    -> BlockfrostServiceM (Either Affjax.Error (Affjax.Response String))
  request cbor =
    blockfrostPostRequest EvaluateTransaction (MediaType "application/cbor")
      $ Just
      $ Affjax.string
      $ cborBytesToHex cbor

data BlockfrostEvaluateTx = BlockfrostEvaluateTx (Either Aeson TxEvaluationR)

derive instance Generic BlockfrostEvaluateTx _

instance Show BlockfrostEvaluateTx where
  show = genericShow

instance DecodeAeson BlockfrostEvaluateTx where
  decodeAeson aeson = success <|> failure <#> BlockfrostEvaluateTx
    where
    success = do
      { result } :: { result :: TxEvaluationR } <- decodeAeson aeson
      pure $ Right result

    failure = pure $ Left aeson

unwrapBlockfrostEvaluateTx :: BlockfrostEvaluateTx -> Either Aeson TxEvaluationR
unwrapBlockfrostEvaluateTx (BlockfrostEvaluateTx ei) = ei

isTxConfirmed
  :: TransactionHash
  -> BlockfrostServiceM (Either ClientError Boolean)
isTxConfirmed txHash = do
  response <- blockfrostGetRequest $ Transaction txHash
  pure case handleBlockfrostResponse response of
    Right (_ :: Aeson) -> Right true
    Left (ClientHttpResponseError (Affjax.StatusCode 404) _) -> Right false
    Left e -> Left e

getTxMetadata
  :: TransactionHash
  -> BlockfrostServiceM (Either GetTxMetadataError GeneralTransactionMetadata)
getTxMetadata txHash = do
  response <- blockfrostGetRequest (TransactionMetadata txHash)
  pure case unwrapBlockfrostMetadata <$> handleBlockfrostResponse response of
    Left (ClientHttpResponseError (Affjax.StatusCode 404) _) ->
      Left GetTxMetadataTxNotFoundError
    Left e ->
      Left (GetTxMetadataClientError e)
    Right metadata
      | Map.isEmpty (unwrap metadata) ->
          Left GetTxMetadataMetadataEmptyOrMissingError
      | otherwise -> Right metadata

--------------------------------------------------------------------------------
-- `getTxMetadata` reponse parsing
--------------------------------------------------------------------------------

newtype BlockfrostMetadata = BlockfrostMetadata
  GeneralTransactionMetadata

derive instance Generic BlockfrostMetadata _
derive instance Eq BlockfrostMetadata
derive instance Newtype BlockfrostMetadata _

instance Show BlockfrostMetadata where
  show = genericShow

instance DecodeAeson BlockfrostMetadata where
  decodeAeson = decodeAeson >=>
    \(metadatas :: Array { metadata :: CborBytes }) -> do
      metadatas' <- for metadatas \{ metadata } -> do
        map (unwrap <<< convertGeneralTransactionMetadata) <$> flip note
          (fromBytes metadata) $
          TypeMismatch "Hexadecimal encoded Metadata"

      pure $ BlockfrostMetadata $ GeneralTransactionMetadata $ Map.unions
        metadatas'

unwrapBlockfrostMetadata :: BlockfrostMetadata -> GeneralTransactionMetadata
unwrapBlockfrostMetadata (BlockfrostMetadata metadata) = metadata
