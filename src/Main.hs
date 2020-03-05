{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE QuasiQuotes #-}

module Main
  ( main
  , ConfigTwitch(..)
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Data.Aeson
import Data.Foldable
import qualified Data.Set as S
import qualified Database.SQLite.Simple as Sqlite
import Database.SQLite.Simple.QQ
import Hookup
import Irc.Commands
import Irc.RawIrcMsg
import KGBotka.TwitchThread
import KGBotka.Config
import KGBotka.Log
import KGBotka.Migration
import KGBotka.Queue
import KGBotka.Repl
import KGBotka.Sqlite
import qualified Network.HTTP.Client.TLS as TLS
import Network.Socket (Family(AF_INET))
import System.Environment
import System.Exit
import System.IO

migrations :: [Migration]
migrations =
  [ Migration
      [sql|CREATE TABLE Command (
             id INTEGER PRIMARY KEY,
             code TEXT NOT NULL
           );|]
  , Migration
      [sql|CREATE TABLE CommandName (
             name TEXT NOT NULL,
             commandId INTEGER NOT NULL REFERENCES Command(id) ON DELETE CASCADE,
             UNIQUE(name) ON CONFLICT REPLACE
           );|]
  , Migration
      [sql|CREATE TABLE TwitchRoles (
             id INTEGER PRIMARY KEY,
             name TEXT NOT NULL UNIQUE
           );|]
  , Migration
      [sql|CREATE TABLE TwitchUserRoles (
             userId TEXT NOT NULL,
             roleId INTEGER NOT NULL REFERENCES TwitchRoles(id) ON DELETE CASCADE,
             UNIQUE(userId, roleId) ON CONFLICT IGNORE
           );|]
  , Migration
      [sql|CREATE TABLE FridayVideo (
             id INTEGER PRIMARY KEY,
             submissionText TEXT NOT NULL,
             submissionTime DATETIME NOT NULL,
             authorTwitchId TEXT NOT NULL,
             authorTwitchName TEXT NOT NULL,
             watchedAt DATETIME,
             channel TEXT NOT NULL
           );|]
  , Migration
      [sql|CREATE TABLE TwitchLog (
             id INTEGER PRIMARY KEY,
             channel TEXT NOT NULL,
             senderTwitchId TEXT NOT NULL,
             senderTwitchName TEXT NOT NULL,
             senderTwitchDisplayName TEXT,
             senderTwitchRoles TEXT NOT NULL,
             senderTwitchBadgeRoles TEXT NOT NULL,
             message TEXT NOT NULL,
             messageTime DATETIME DEFAULT (datetime('now')) NOT NULL
           )|]
  , Migration
      [sql|CREATE TABLE Markov (
             event1 TEXT NOT NULL,
             event2 TEXT NOT NULL,
             n INTEGER NOT NULL,
             UNIQUE (event1, event2) ON CONFLICT REPLACE
           );
           CREATE INDEX markov_event1_index ON Markov (event1);|]
  , Migration
      [sql|ALTER TABLE Command
           ADD COLUMN user_cooldown_ms INTEGER NOT NULL DEFAULT 0;|]
  , Migration
      [sql|CREATE TABLE CommandLog (
             userTwitchId TEXT NOT NULL,
             commandId INTEGER NOT NULL,
             commandArgs TEXT NOT NULL,
             timestamp DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
           );|]
  , Migration
      [sql|CREATE TABLE AsciifyUrlCache(
             url TEXT NOT NULL,
             image TEXT NOT NULL,
             UNIQUE (url) ON CONFLICT REPLACE
           );|]
  , Migration
      [sql|CREATE TABLE BttvEmotes (
              name TEXT NOT NULL,
              channel TEXT DEFAULT NULL,
              imageUrl TEXT NOT NULL
           );|]
  , Migration
      [sql|CREATE TABLE FfzEmotes (
              name TEXT NOT NULL,
              channel TEXT DEFAULT NULL,
              imageUrl TEXT NOT NULL
           );|]
  ]

maxIrcMessage :: Int
maxIrcMessage = 500 * 4

twitchConnectionParams :: ConnectionParams
twitchConnectionParams =
  ConnectionParams
    { cpHost = "irc.chat.twitch.tv"
    , cpPort = 443
    , cpTls =
        Just
          TlsParams
            { tpClientCertificate = Nothing
            , tpClientPrivateKey = Nothing
            , tpServerCertificate = Nothing
            , tpCipherSuite = "HIGH"
            , tpInsecure = False
            }
    , cpSocks = Nothing
    , cpFamily = AF_INET
    }

withConnection :: ConnectionParams -> (Connection -> IO a) -> IO a
withConnection params = bracket (connect params) close

sendMsg :: Connection -> RawIrcMsg -> IO ()
sendMsg conn msg = send conn (renderRawIrcMsg msg)

authorize :: ConfigTwitch -> Connection -> IO ()
authorize conf conn = do
  sendMsg conn (ircPass $ configTwitchToken conf)
  sendMsg conn (ircNick $ configTwitchAccount conf)
  sendMsg conn (ircCapReq ["twitch.tv/tags"])

readIrcLine :: Connection -> IO (Maybe RawIrcMsg)
readIrcLine conn = do
  mb <-
    catch
      (recvLine conn maxIrcMessage)
      (\case
         LineTooLong -> do
           hPutStrLn stderr "[WARN] Received LineTooLong. Ignoring it..."
           return Nothing
         e -> throwIO e)
  case (parseRawIrcMsg . asUtf8) =<< mb of
    Just msg -> return (Just msg)
    Nothing -> do
      hPutStrLn stderr "Server sent invalid message!"
      return Nothing

twitchIncomingThread :: Connection -> WriteQueue RawIrcMsg -> IO ()
twitchIncomingThread conn queue = do
  mb <- readIrcLine conn
  for_ mb $ atomically . writeQueue queue
  twitchIncomingThread conn queue

twitchOutgoingThread :: Connection -> ReadQueue RawIrcMsg -> IO ()
twitchOutgoingThread conn queue = do
  rawMsg <- atomically $ readQueue queue
  sendMsg conn rawMsg
  twitchOutgoingThread conn queue

withForkIOs :: [IO ()] -> ([ThreadId] -> IO b) -> IO b
withForkIOs ios = bracket (traverse forkIO ios) (traverse_ killThread)

mainWithArgs :: [String] -> IO ()
mainWithArgs (configPath:databasePath:_) = do
  putStrLn $ "Your configuration file is " <> configPath
  eitherDecodeFileStrict configPath >>= \case
    Right config -> do
      incomingIrcQueue <- atomically newTQueue
      outgoingIrcQueue <- atomically newTQueue
      replQueue <- atomically newTQueue
      logQueue <- atomically newTQueue
      joinedChannels <- atomically $ newTVar S.empty
      manager <- TLS.newTlsManager
      withConnectionAndPragmas databasePath $ \dbConn ->
        Sqlite.withTransaction dbConn $ migrateDatabase dbConn migrations
      withConnection twitchConnectionParams $ \conn -> do
        authorize config conn
        -- TODO(#67): there is no supavisah that restarts essential threads on crashing
        withForkIOs
          [ twitchIncomingThread conn $ WriteQueue incomingIrcQueue
          , twitchOutgoingThread conn $ ReadQueue outgoingIrcQueue
          , twitchThread $
            TwitchThreadParams
              { ttpReplQueue = ReadQueue replQueue
              , ttpChannels = joinedChannels
              , ttpSqliteFileName = databasePath
              , ttpLogQueue = WriteQueue logQueue
              , ttpManager = manager
              , ttpConfig = config
              , ttpIncomingQueue = ReadQueue incomingIrcQueue
              , ttpOutgoingQueue = WriteQueue outgoingIrcQueue
              }
          , loggingThread "kgbotka.log" $ ReadQueue logQueue
          ] $ \_
          -- TODO(#63): backdoor port is hardcoded
         ->
          backdoorThread "6969" $
          ReplState
            { replStateChannels = joinedChannels
            , replStateSqliteFileName = databasePath
            , replStateCurrentChannel = Nothing
            , replStateCommandQueue = WriteQueue replQueue
            , replStateConfigTwitch = config
            , replStateManager = manager
            , replStateHandle = stdout
            , replStateLogQueue = WriteQueue logQueue
            , replStateConnAddr = Nothing
            }
      putStrLn "Done"
    Left errorMessage -> error errorMessage
mainWithArgs _ = do
  hPutStrLn stderr "[ERROR] Not enough arguments provided"
  hPutStrLn stderr "Usage: ./kgbotka <config.json> <database.db>"
  exitFailure

main :: IO ()
main = getArgs >>= mainWithArgs
