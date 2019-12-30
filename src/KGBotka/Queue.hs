module KGBotka.Queue where

import Control.Concurrent.STM

newtype WriteQueue a = WriteQueue
  { getWriteQueue :: TQueue a
  }

writeQueue :: WriteQueue a -> a -> STM ()
writeQueue = writeTQueue . getWriteQueue

newtype ReadQueue a = ReadQueue
  { getReadQueue :: TQueue a
  }

readQueue :: ReadQueue a -> STM a
readQueue = readTQueue . getReadQueue

tryReadQueue :: ReadQueue a -> STM (Maybe a)
tryReadQueue = tryReadTQueue . getReadQueue
