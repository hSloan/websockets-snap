{-# LANGUAGE OverloadedStrings #-}

--------------------------------------------------------------------------------
-- | Snap integration for the WebSockets library
{-# LANGUAGE DeriveDataTypeable #-}
module Network.WebSockets.Snap
    ( runWebSocketsSnap
    , runWebSocketsSnapWith
    ) where


--------------------------------------------------------------------------------
import Control.Concurrent (forkIO, myThreadId, threadDelay)
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad (forever)
import Data.ByteString (ByteString)
import qualified Blaze.ByteString.Builder as Builder
import qualified Data.ByteString.Builder as BSBuilder
import qualified Data.ByteString.Builder.Extra as BSBuilder
import qualified Data.ByteString.Char8 as BC
import Data.Typeable (Typeable, cast)
import qualified Network.WebSockets as WS
import qualified Network.WebSockets.Connection as WS
import qualified Snap.Core as Snap
import qualified Snap.Types.Headers as Headers
import qualified System.IO.Streams as Streams
import qualified System.IO.Streams.Attoparsec as Streams

--------------------------------------------------------------------------------
data Chunk
    = Chunk ByteString
    | Eof
    | Error SomeException
    deriving (Show)


--------------------------------------------------------------------------------
data ServerAppDone = ServerAppDone
    deriving (Eq, Ord, Show, Typeable)


--------------------------------------------------------------------------------
instance Exception ServerAppDone where
    toException ServerAppDone       = SomeException ServerAppDone
    fromException (SomeException e) = cast e


--------------------------------------------------------------------------------
-- | The following function escapes from the current 'Snap.Snap' handler, and
-- continues processing the 'WS.WebSockets' action. The action to be executed
-- takes the 'WS.Request' as a parameter, because snap has already read this
-- from the socket.
runWebSocketsSnap
    :: Snap.MonadSnap m
    => WS.ServerApp
    -> m ()
runWebSocketsSnap = runWebSocketsSnapWith WS.defaultConnectionOptions


--------------------------------------------------------------------------------
-- | Variant of 'runWebSocketsSnap' which allows custom options
runWebSocketsSnapWith
  :: Snap.MonadSnap m
  => WS.ConnectionOptions
  -> WS.ServerApp
  -> m ()
runWebSocketsSnapWith options app = do
  rq <- Snap.getRequest
  Snap.escapeHttp $ \tickle readEnd writeEnd -> do
    thisThread <- myThreadId
    
    curWrite <- newMVar $ \b -> do
      Streams.write b writeEnd

    let streamParse p = do
          tickle (max 20)
          r <- try (Streams.parseFromStream p readEnd)
          case r of
            Left (Streams.ParseException e) -> do
              return Nothing
            Right x -> return $ Just x

        streamWrite v = do
          withMVar curWrite $ \write -> do
            write (Just (BSBuilder.lazyByteString
                                    (Builder.toLazyByteString v)))
            write (Just (BSBuilder.flush))

        streamClose = do
          write <- modifyMVar curWrite $ \write -> return (\_ -> throwIO WS.ConnectionClosed, write)
          write Nothing
          throwIO WS.ConnectionClosed

        options' = options
                   { WS.connectionOnPong = do
                        tickle (max 30)
                        WS.connectionOnPong options
                   }

        pc = WS.PendingConnection
               { WS.pendingOptions  = options'
               , WS.pendingRequest  = fromSnapRequest rq
               , WS.pendingOnAccept = forkPingThread tickle
               , WS.pendingStreamParse = streamParse
               , WS.pendingStreamWrite = streamWrite
               , WS.pendingStreamClose = streamClose
               }
    app pc >> throwTo thisThread ServerAppDone

--------------------------------------------------------------------------------
-- | Start a ping thread in the background
forkPingThread :: ((Int -> Int) -> IO ()) -> WS.Connection -> IO ()
forkPingThread tickle conn = do
    _ <- forkIO pingThread
    return ()
  where
    pingThread = handle ignore $ forever $ do
        WS.sendPing conn (BC.pack "ping")
        tickle (min 15)
        threadDelay $ 30 * 1000 * 1000

    ignore :: SomeException -> IO ()
    ignore _   = return ()


--------------------------------------------------------------------------------
-- | Convert a snap request to a websockets request
fromSnapRequest :: Snap.Request -> WS.RequestHead
fromSnapRequest rq = WS.RequestHead
    { WS.requestPath    = Snap.rqURI rq
    , WS.requestHeaders = Headers.toList (Snap.rqHeaders rq)
    , WS.requestSecure  = Snap.rqIsSecure rq
    }
