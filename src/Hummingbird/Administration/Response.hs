{-# LANGUAGE DeriveGeneric #-}
module Hummingbird.Administration.Response where

import           Control.Monad
import           Control.Monad.IO.Class
import qualified Data.Binary                        as B
import           Data.Int
import           Data.Maybe
import           Data.UUID                          (UUID)
import           GHC.Generics                       (Generic)
import           Network.MQTT.Broker.Authentication (Principal (..), Quota (..))
import           Network.MQTT.Broker.Session        (ConnectionState (..),
                                                     SessionIdentifier (..),
                                                     SessionStatistic (..),
                                                     connectedAt,
                                                     connectedCleanSession,
                                                     connectedRemoteAddress,
                                                     connectedSecure,
                                                     connectedWebSocket)
import           Network.MQTT.Message               (ClientIdentifier (..),
                                                     Username (..))
import qualified Network.MQTT.Trie                  as Trie
import           System.Clock

import           Hummingbird.Administration.Escape

data Response
   = Success String
   | Failure String
   | Help
   | AuthInfo
   { authLastException         :: Maybe String
   }
   | BrokerInfo
   { brokerUptime              :: Int64
   , brokerSessionCount        :: Int
   , brokerSubscriptionCount   :: Int
   , brokerTransportException  :: Maybe String
   , brokerTerminatorException :: Maybe String
   , brokerSysInfoException    :: Maybe String
   }
   | Session SessionInfo
   | SessionList [SessionInfo]
   | SessionSubscriptions String
   deriving (Eq, Show, Generic)

data SessionInfo
   = SessionInfo
   { sessionIdentifier          :: SessionIdentifier
   , sessionCreatedAt           :: Int64
   , sessionClientIdentifier    :: ClientIdentifier
   , sessionPrincipalIdentifier :: UUID
   , sessionPrincipal           :: Principal
   , sessionConnectionState     :: ConnectionState
   , sessionStatistic           :: SessionStatistic
   }
   deriving (Eq, Show, Generic)

instance B.Binary Response
instance B.Binary SessionInfo

render :: MonadIO m => (String -> m ()) -> Response -> m ()
render p (Success msg) =
  p (cyan msg)

render p (Failure msg) =
  p (lightRed msg)

render p Help = do
    p "help                      : show this help"
    p "broker                    : show broker information"
    p "config"
    p "  reload                  : reload configuration file (does not apply it!)"
    p "auth"
    p "  restart                 : restart the authentication module (after config file reload)"
    p "sessions                  : list all sessions"
    p "  [0-9]+                  : show session summary"
    p "    disconnect            : disconnect associated client (if any)"
    p "    subscriptions         : show session subscriptions"
    p "    terminate             : terminate session (and disconnect client)"
    p "  expiring                : show sessions in order of expiration"
    p "transports                : show status of transports"
    p "  start                   : start transports"
    p "  stop                    : stop transports"

render p info@BrokerInfo {} = do
--  format "Version            " $ brokerVersion info
  format "Uptime               " $ ago (brokerUptime info)
  format "Sessions             " $ show (brokerSessionCount info)
  format "Subscriptions        " $ show (brokerSubscriptionCount info)
  p $ cyan "Threads"
  format "  Transports         " $ case brokerTransportException info of
    Nothing -> green "Running."
    Just e  -> lightRed e
  format "  Terminator         " $ case brokerTerminatorException info of
    Nothing -> green "Running."
    Just e  -> lightRed e
  format "  SysInfo            " $ case brokerSysInfoException info of
    Nothing -> green "Running."
    Just e  -> lightRed e
  where
    format key value =
      p $ cyan key ++ ": " ++ lightCyan value ++ "\ESC[0m"

render p info@AuthInfo {} =
  format "Last exception      " $ show (authLastException info)
  where
    format key value =
      p $ cyan key ++ ": " ++ lightCyan value ++ "\ESC[0m"

render p (Session s) = do
  now <- liftIO $ sec <$> getTime Realtime
  format "Alive since                    " $ ago $ now - sessionCreatedAt s
  case sessionConnectionState s of
    Connected {} ->
      pure ()
    Disconnected { disconnectedSessionExpiresAt = expiresAt } ->
      format "Expires in                     " $ lightRed $ ago $ expiresAt - now
  format "Client                         " $ escapeText clientIdentifier
  format "Principal                      " $ show (sessionPrincipalIdentifier s)
  case principalUsername (sessionPrincipal s) of
    Nothing -> pure ()
    Just (Username username) -> format "  Username                     " $ escapeText username
  p $ cyan "  Quota"
  format "    Max idle session TTL       " $ show (quotaMaxIdleSessionTTL $ principalQuota $ sessionPrincipal s)
  format "    Max packet size            " $ show (quotaMaxPacketSize $ principalQuota $ sessionPrincipal s)
  format "    Max packet identifiers     " $ show (quotaMaxPacketIdentifiers $ principalQuota $ sessionPrincipal s)
  format "    Max queue size QoS 0       " $ show (quotaMaxQueueSizeQoS0 $ principalQuota $ sessionPrincipal s)
  format "    Max queue size QoS 1       " $ show (quotaMaxQueueSizeQoS1 $ principalQuota $ sessionPrincipal s)
  format "    Max queue size QoS 2       " $ show (quotaMaxQueueSizeQoS2 $ principalQuota $ sessionPrincipal s)
  p $ cyan "  Permissions"
  p $ cyan "    Publish"
  forM_ (fmap fst $ Trie.toList $ principalPublishPermissions   $ sessionPrincipal s) $ \f-> p ("      " ++ lightCyan (show f))
  p $ cyan "    Subscribe"
  forM_ (fmap fst $ Trie.toList $ principalSubscribePermissions $ sessionPrincipal s) $ \f-> p ("      " ++ lightCyan (show f))
  p $ cyan "    Retain"
  forM_ (fmap fst $ Trie.toList $ principalRetainPermissions    $ sessionPrincipal s) $ \f-> p ("      " ++ lightCyan (show f))
  case sessionConnectionState s of
    cs@Connected {} -> do
      format "Connection                     " $ lightGreen "connected"
      format "  Connected since              " $ ago  $ now - connectedAt cs
      format "  Clean Session                " $ show $ connectedCleanSession cs
      format "  Secure                       " $ show $ connectedSecure cs
      format "  WebSocket                    " $ show $ connectedWebSocket cs
      case connectedRemoteAddress cs of
        Nothing   -> pure ()
        Just addr -> format "  Remote Address               " $ escapeByteString addr
    cs@Disconnected {} -> do
      format "Connection                     " $ lightRed "disconnected"
      format "  Disconnected since           " $ ago $ now - disconnectedAt cs
      format "  Disconnected with            " $ case disconnectedWith cs of
        Nothing  -> "graceful disconnect"
        Just msg -> lightRed msg
  p $ cyan "Statistic"
  p $ cyan "  Publications"
  format "    accepted                   " $ show (ssPublicationsAccepted  $ sessionStatistic s)
  format "    dropped                    " $ show (ssPublicationsDropped   $ sessionStatistic s)
  p $ cyan "  Retentions"
  format "    accepted                   " $ show (ssRetentionsAccepted    $ sessionStatistic s)
  format "    dropped                    " $ show (ssRetentionsDropped     $ sessionStatistic s)
  p $ cyan "  Subscriptions"
  format "    accepted                   " $ show (ssSubscriptionsAccepted $ sessionStatistic s)
  format "    rejected                   " $ show (ssSubscriptionsRejected $ sessionStatistic s)
  p $ cyan "  Queue QoS0"
  format "    length                     " $ show (ssQueueQoS0Length       $ sessionStatistic s)
  format "    dropped                    " $ show (ssQueueQoS0Dropped      $ sessionStatistic s)
  p $ cyan "  Queue QoS1"
  format "    length                     " $ show (ssQueueQoS1Length       $ sessionStatistic s)
  format "    dropped                    " $ show (ssQueueQoS1Dropped      $ sessionStatistic s)
  p $ cyan "  Queue QoS2"
  format "    length                     " $ show (ssQueueQoS2Length       $ sessionStatistic s)
  format "    dropped                    " $ show (ssQueueQoS2Dropped      $ sessionStatistic s)
  where
    ClientIdentifier clientIdentifier = sessionClientIdentifier s
    format key value =
      p $ cyan key ++ ": " ++ lightCyan value ++ "\ESC[0m"

render p (SessionList ss) = do
  now <- liftIO $ sec <$> getTime Realtime
  forM_ ss $ \session-> do
    let x1 = leftPad 8 ' '  $ showSessionIdentifier (sessionIdentifier session)
    let x2 = status now (sessionConnectionState session)
    let x3 = leftPad 18 ' ' $ ago $ now - sessionCreatedAt session
    let x4 = q0l session ++  " " ++ q1l session ++ " " ++ q2l session
    let x5 = lightCyan $ leftPad 35 ' ' $ show $ sessionPrincipalIdentifier session
    let x6 = leftPad 24 ' ' $ showClientIdentifier (sessionClientIdentifier session)
    let x7 = leftPad 12 ' ' $ remoteAddr (sessionConnectionState session)
    p $ unwords [x1,x2,x3,x4,x5,x6,x7]
  where
    status now Disconnected { disconnectedSessionExpiresAt = expAt }
      | expAt > now = lightRed     "DISCONNECTED"
      | otherwise   = lightMagenta "EXPIRED     "
    status _ Connected { connectedCleanSession = clean }
      | clean       = lightYellow  "CONNECTED*  "
      | otherwise   = lightGreen   "CONNECTED   "
    remoteAddr Disconnected {} = ""
    remoteAddr c@Connected  {} = fromMaybe "" $ escapeByteString <$> connectedRemoteAddress c
    showSessionIdentifier (SessionIdentifier s) = show s
    showClientIdentifier  (ClientIdentifier  s) = take 24 $ escapeText s
    q0l s = green $ leftPad 7 ' ' $ show (ssQueueQoS0Length $ sessionStatistic s)
    q1l s = green $ leftPad 7 ' ' $ show (ssQueueQoS1Length $ sessionStatistic s)
    q2l s = green $ leftPad 7 ' ' $ show (ssQueueQoS2Length $ sessionStatistic s)

render p (SessionSubscriptions s) =
  p s
