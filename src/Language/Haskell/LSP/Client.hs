{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : LSP.Client
-- Description : A client implementation for the Language Server Protocol.
-- Copyright   : (c) Jaro Reinders, 2017
-- License     : GPL-2
-- Maintainer  : jaro.reinders@gmail.com
-- Stability   : experimental
--
-- This module contains an implementation of a client for the
-- <https://github.com/Microsoft/language-server-protocol Language Server Protocol>.
-- It uses the same data types as the
-- <https://hackage.haskell.org/package/haskell-lsp haskell-lsp> library.
--
-- This client is intended to be used by text editors written in haskell
-- to provide the user with IDE-like features.
--
-- This module is intended to be imported qualified:
--
-- > import qualified LSP.Client as Client
--
-- In the examples in this module it is assumed that the following modules are imported:
--
-- > import qualified Language.Haskell.LSP.TH.DataTypesJSON as LSP
--
-- A complete example can be found in the github repository.
--
-- TODO:
--
--   * Implement proper exception handling.
--
module Language.Haskell.LSP.Client
  (
  -- * Initialization
    start
  , Config (..)
  , Client
  -- * Receiving
  , RequestMessageHandler (..)
  , NotificationMessageHandler (..)
  -- * Sending
  , sendClientRequest
  , sendClientNotification
  ) where

import Prelude
import Control.Lens
import System.IO
import qualified Language.Haskell.LSP.TH.DataTypesJSON as LSP
import Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as B
import System.Process
import Control.Exception (handle, IOException, SomeException)
import Control.Monad (forever)
import Control.Concurrent
import qualified Data.IntMap as M
import Data.Proxy (Proxy (Proxy))
import Text.Read (readMaybe)
import Control.Arrow ((&&&))
import System.Exit (exitFailure)
import qualified Data.Text.IO as T


--------------------------------------------------------------------------------
-- The types

data ClientMessage
  = forall params resp. (ToJSON params, ToJSON resp, FromJSON resp)
    => ClientRequest LSP.ClientMethod params (MVar (Maybe (Either LSP.ResponseError resp)))
  | forall params. (ToJSON params)
    => ClientNotification LSP.ClientMethod params

data ResponseVar = forall resp . FromJSON resp =>
  ResponseVar (MVar (Maybe (Either LSP.ResponseError resp)))

data Client = Client
  { reqVar        :: MVar ClientMessage
  , receiveThread :: ThreadId
  , sendThread    :: ThreadId
  }

-- | The configuration of the Language Server Protocol client.
-- 'toServer' and 'fromServer' are the 'Handle's which can be used
-- to send messages to and receive messages from the server.
--
-- Create this configuration and pass it to the 'start' function.
--
-- Example:
--
-- @
-- (Just inp, Just out, _, _) <- createProcess (proc "hie" ["--lsp"])
--   {std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
-- let myConfig = Config inp out testHandleNotificationMessage testHandleRequestMessage
-- @
--
-- This example will run @hie --lsp@ and combine the @inp@ and @out@ 'Handle's
-- with the @testHandleNotificationMessage@ and @testHandleRequestMessage@
-- handlers to form the configuration of the client.
data Config = Config
  { toServer :: !Handle
  , fromServer :: !Handle
  , handleNotification :: !NotificationMessageHandler
  , handleRequest :: !RequestMessageHandler
  }

--------------------------------------------------------------------------------
-- Sending a client request

-- | Send a request message to the Language Server and wait for its response.
--
-- Example:
--
-- @
-- Client.sendClientRequest (Proxy :: Proxy LSP.InitializeRequest)
--                          reqVar
--                          LSP.Initialize
--                          initializeParams
-- @
--
-- Where @reqVar@ is the @MVar@ generated by the 'start' function and @initializeParams@ are the
-- parameters to the initialize request as specified in the Language Server Protocol and
-- the haskell-lsp package. Note that in this case the result is ignored.
sendClientRequest
  :: forall params resp . (ToJSON params, ToJSON resp, FromJSON resp)
  => Client
  -> Proxy (LSP.RequestMessage LSP.ClientMethod params resp)
  -> LSP.ClientMethod
  -> params
  -> IO (Maybe (Either LSP.ResponseError resp))
sendClientRequest client Proxy method params = do
  respVar <- newEmptyMVar :: IO (MVar (Maybe (Either LSP.ResponseError resp)))
  putMVar (reqVar client) (ClientRequest method params respVar)
  takeMVar respVar

--------------------------------------------------------------------------------
-- Sending a client notification

-- | Send a notification message to the Language Server.
--
-- Example:
--
-- @
-- Client.sendClientNotification reqVar LSP.Initialized (Just LSP.InitializedParams)
-- @
--
-- Where @reqVar@ is the @MVar@ generated by the 'start' function.
sendClientNotification
  :: forall params . (ToJSON params)
  => Client
  -> LSP.ClientMethod
  -> params
  -> IO ()
sendClientNotification client method params =
  putMVar (reqVar client) (ClientNotification method params)

--------------------------------------------------------------------------------
-- Starting the language server

-- | Start the language server.
--
-- Example:
--
-- @
-- reqVar <- Client.start myConfig
-- @
--
-- Where @inp@ and @out@ are the 'Handle's of the lsp client and
-- @testHandleNotification@ and @testHandleRequestMessage@ are 'NotificationMessageHandler' and
-- 'RequestMessageHandler' respectively.
-- @reqVar@ can be passed to the 'sendClientRequest' and 'sendClientNotification' functions.
start :: Config -> IO Client
start (Config inp out handleNotification handleRequest) =
  handle (\(e :: IOException) -> hPrint stderr e >> exitFailure >> undefined) $ do
    hSetBuffering inp NoBuffering
    hSetBuffering out NoBuffering

    reqVar <- newEmptyMVar :: IO (MVar ClientMessage)

    requestMap <- newMVar mempty :: IO (MVar (M.IntMap ResponseVar))

    receiveThread <- forkIO (receiving handleNotification handleRequest inp out requestMap)
    sendThread <- forkIO (sending inp reqVar requestMap)

    return (Client reqVar receiveThread sendThread)

stop :: Client -> IO ()
stop (Client _ receiveThread sendThread) = do
  killThread receiveThread
  killThread sendThread

receiving :: NotificationMessageHandler
          -> RequestMessageHandler
          -> Handle
          -> Handle
          -> MVar (M.IntMap ResponseVar)
          -> IO ()
receiving handleNotification handleRequest inp out requestMap =
  forever $ handle (\(e :: SomeException) -> hPrint stderr e) $ do
    headers <- getHeaders out
    case lookup "Content-Length" headers >>= readMaybe of
      Nothing -> fail "Couldn't read Content-Length header"
      Just size -> do
        message <- B.hGet out size

        -- Requestmessages require id and method fields
        --   so it should be the first in this list
        -- Notificationmessages require only the method field
        -- ResponseMessages require only the id field
        --
        -- The decode function is very permissive, so it
        -- will drop fields that it doesn't recognize.
        -- If handleNotificationMessage would be before
        -- handleRequestMessage, then all request messages
        -- would be converted automatically to notification
        -- messages.
        case decode message of
          Just m -> handleRequestMessage inp handleRequest m
          Nothing -> case decode message of
            Just m -> handleNotificationMessage handleNotification m
            Nothing -> case decode message of
              Just m -> handleResponseMessage requestMap m
              Nothing -> fail "malformed message"
  where
    getHeaders :: Handle -> IO [(String,String)]
    getHeaders h = do
      l <- hGetLine h
      let (name,val) = span (/= ':') l
      if null val
        then return []
        else ((name,drop 2 val) :) <$> getHeaders h

sending :: Handle -> MVar ClientMessage -> MVar (M.IntMap ResponseVar) -> IO ()
sending inp req requestMap = do
  -- keeps track of which request ID should be used next
  lspCount <- newMVar 0 :: IO (MVar Int)
  
  forever $ handle (\(e :: SomeException) -> hPrint stderr e) $ do
    clientMessage <- takeMVar req
    case clientMessage of
      (ClientRequest method (req :: req) (respVar :: MVar (Maybe (Either LSP.ResponseError resp)))) -> do
         lspId <- readMVar lspCount
         B.hPutStr inp $ addHeader $ encode
           (LSP.RequestMessage "2.0" (LSP.IdInt lspId) method req
             :: LSP.RequestMessage LSP.ClientMethod req resp)
         modifyMVar_ requestMap $ return . M.insert lspId (ResponseVar respVar)
         modifyMVar_ lspCount $ return . (+ 1)

      (ClientNotification method req) ->
        B.hPutStr inp (addHeader (encode (LSP.NotificationMessage "2.0" method req)))

addHeader :: B.ByteString -> B.ByteString
addHeader content = B.concat
  [ "Content-Length: ", B.pack $ show $ B.length content, "\r\n"
  , "\r\n"
  , content
  ]

--------------------------------------------------------------------------------
-- Handle response messages

handleResponseMessage :: MVar (M.IntMap ResponseVar) -> LSP.ResponseMessage Value -> IO ()
handleResponseMessage requestMap = \case
  LSP.ResponseMessage _ (LSP.IdRspInt lspId) (Just response) Nothing -> do
    mayResVar <- modifyMVar requestMap $ return . (M.delete lspId &&& M.lookup lspId)
    case mayResVar of
      Nothing -> fail "Server sent us an unknown id of type Int"
      Just (ResponseVar resVar) ->
        case fromJSON response of
          Success result -> putMVar resVar $ Just $ Right result
          _ -> putMVar resVar Nothing

  LSP.ResponseMessage _ (LSP.IdRspInt lspId) Nothing (Just rspError) -> do
    mayResVar <- modifyMVar requestMap $ return . (M.delete lspId &&& M.lookup lspId)
    case mayResVar of
      Nothing -> fail "Server sent us an unknown id of type Int"
      Just (ResponseVar resVar) ->
        putMVar resVar $ Just $ Left rspError

  LSP.ResponseMessage _ (LSP.IdRspString _) (Just _) Nothing ->
    fail "Server sent us an unknown id of type String"

  LSP.ResponseMessage _ (LSP.IdRspString _) Nothing (Just _) ->
    fail "Server sent us an unknown id of type String"

  LSP.ResponseMessage _ LSP.IdRspNull _ _ ->
    fail "Server couldn't read our id"

  _ -> fail "Malformed message"

--------------------------------------------------------------------------------
-- Handle request messages

-- | The handlers for request messages from the server.
-- Define these once and pass them via the 'Config' data type to the 'start' function.
--
-- Example:
--
-- @
-- testRequestMessageHandler :: Client.RequestMessageHandler
-- testRequestMessageHandler = Client.RequestMessageHandler
--   (\m -> emptyResponse m <$ print m)
--   (\m -> emptyResponse m <$ print m)
--   (\m -> emptyResponse m <$ print m)
--   (\m -> emptyResponse m <$ print m)
--   where
--     toRspId (LSP.IdInt i) = LSP.IdRspInt i
--     toRspId (LSP.IdString t) = LSP.IdRspString t
--
--     emptyResponse :: LSP.RequestMessage m req resp -> LSP.ResponseMessage a
--     emptyResponse m = LSP.ResponseMessage (m ^. LSP.jsonrpc) (toRspId (m ^. LSP.id)) Nothing Nothing
-- @
--
-- This example will print all request messages to and send back an empty response message.
data RequestMessageHandler = RequestMessageHandler
  { handleWindowShowMessageRequest :: LSP.ShowMessageRequest -> IO LSP.ShowMessageResponse
  , handleClientRegisterCapability :: LSP.RegisterCapabilityRequest -> IO LSP.ErrorResponse
  , handleClientUnregisterCapability :: LSP.UnregisterCapabilityRequest -> IO LSP.ErrorResponse
  , handleWorkspaceApplyEdit :: LSP.ApplyWorkspaceEditRequest   -> IO LSP.ApplyWorkspaceEditResponse
  }

handleRequestMessage
  :: Handle
  -> RequestMessageHandler
  -> LSP.RequestMessage LSP.ServerMethod Value Value
  -> IO ()
handleRequestMessage inp RequestMessageHandler {..} m = do
  resp <- case m ^. LSP.method of
    method@LSP.WindowShowMessageRequest ->
      case fromJSON (m ^. LSP.params) :: Result LSP.ShowMessageRequestParams of
        Success params -> encode <$> handleWindowShowMessageRequest
          (LSP.RequestMessage (m ^. LSP.jsonrpc) (m ^. LSP.id) method params)
        _ -> fail "Invalid parameters of window/showMessage request."

    method@LSP.ClientRegisterCapability ->
      case fromJSON (m ^. LSP.params) :: Result LSP.RegistrationParams of
        Success params -> encode <$> handleClientRegisterCapability
          (LSP.RequestMessage (m ^. LSP.jsonrpc) (m ^. LSP.id) method params)
        _ -> fail "Invalid parameters of client/registerCapability request."

    method@LSP.ClientUnregisterCapability ->
      case fromJSON (m ^. LSP.params) :: Result LSP.UnregistrationParams of
        Success params -> encode <$> handleClientUnregisterCapability
          (LSP.RequestMessage (m ^. LSP.jsonrpc) (m ^. LSP.id) method params)
        _ -> fail "Invalid parameters of client/unregisterCapability request."

    method@LSP.WorkspaceApplyEdit ->
      case fromJSON (m ^. LSP.params) :: Result LSP.ApplyWorkspaceEditParams of
        Success params -> encode <$> handleWorkspaceApplyEdit
          (LSP.RequestMessage (m ^. LSP.jsonrpc) (m ^. LSP.id) method params)
        _ -> fail "Invalid parameters of workspace/applyEdit request."

    _ -> fail "Wrong request method."

  B.hPutStr inp $ addHeader resp

--------------------------------------------------------------------------------
-- Handle notification messages

-- | The handlers for notification messages from the server.
-- Define these once and pass them via the 'Config' data type to the 'start' function.
--
-- Example:
--
-- @
-- testNotificationMessageHandler :: Client.NotificationMessageHandler
-- testNotificationMessageHandler = Client.NotificationMessageHandler
--   (T.putStrLn . view (LSP.params . LSP.message))
--   (T.putStrLn . view (LSP.params . LSP.message))
--   (print . view LSP.params)
--   (mapM_ T.putStrLn . (^.. LSP.params . LSP.diagnostics . traverse . LSP.message))
-- @
--
-- This example will print the message content of each notification.
data NotificationMessageHandler = NotificationMessageHandler
  { handleWindowShowMessage :: LSP.ShowMessageNotification -> IO ()
  , handleWindowLogMessage :: LSP.LogMessageNotification -> IO ()
  , handleTelemetryEvent :: LSP.TelemetryNotification -> IO ()
  , handleTextDocumentPublishDiagnostics :: LSP.PublishDiagnosticsNotification -> IO ()
  }

handleNotificationMessage
  :: NotificationMessageHandler
  -> LSP.NotificationMessage LSP.ServerMethod Value
  -> IO ()
handleNotificationMessage NotificationMessageHandler {..} m =
  case m ^. LSP.method of
    method@LSP.WindowShowMessage ->
      case fromJSON (m ^. LSP.params) :: Result LSP.ShowMessageParams of
        Success params -> handleWindowShowMessage
          (LSP.NotificationMessage (m ^. LSP.jsonrpc) method params)
        _ -> fail "Malformed parameters of window/showMessage notification."

    method@LSP.WindowLogMessage ->
      case fromJSON (m ^. LSP.params) :: Result LSP.LogMessageParams of
        Success params -> handleWindowLogMessage
          (LSP.NotificationMessage (m ^. LSP.jsonrpc) method params)
        _ -> fail "Malformed parameters of window/logMessage notification."

    LSP.TelemetryEvent -> handleTelemetryEvent m

    method@LSP.TextDocumentPublishDiagnostics ->
      case fromJSON (m ^. LSP.params) :: Result LSP.PublishDiagnosticsParams of
        Success params -> handleTextDocumentPublishDiagnostics
          (LSP.NotificationMessage (m ^. LSP.jsonrpc) method params)
        _ -> fail "Malformed parameters of textDocument/publishDiagnostics notification."

    _ -> fail $ "unknown method: " ++ show (m ^. LSP.method)
