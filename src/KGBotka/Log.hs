{-# LANGUAGE ViewPatterns #-}

module KGBotka.Log
  ( loggingThread
  , LogEntry(..)
  , ProvidesLogging(..)
  , logEntry
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.Text as T
import Data.Time
import KGBotka.Queue
import System.IO

-- NOTE: the Tag is use to indicate the "subsystem" where the event
-- has happened. Examples are "TWITCH", "SQLITE", "ASCIIFY", etc. It
-- is prefered to capitalize them.
data LogEntry = LogEntry
  { logEntryTag :: T.Text
  , logEntryText :: T.Text
  } deriving (Eq, Show)

loggingThread :: FilePath -> ReadQueue LogEntry -> IO ()
loggingThread logFilePath messageQueue = withFile logFilePath AppendMode loop
  where
    loop logHandle = do
      threadDelay 10000 -- to prevent busy looping
      messages <- atomically $ flushQueue messageQueue
      timestamp <-
        formatTime defaultTimeLocale (iso8601DateFormat $ Just "%H:%M:%S") <$>
        getCurrentTime
      mapM_
        (\(LogEntry tag text) ->
           hPutStrLn logHandle $
           "[" <> timestamp <> "] [" <> T.unpack tag <> "] " <> T.unpack text)
        messages
      hFlush logHandle
      loop logHandle

class ProvidesLogging l where
  logQueue :: l -> WriteQueue LogEntry

logEntry :: ProvidesLogging l => l -> LogEntry -> IO ()
logEntry (logQueue -> queue) = atomically . writeQueue queue
