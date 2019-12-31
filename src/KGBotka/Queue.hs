module KGBotka.Queue
  ( WriteQueue(..)
  , writeQueue
  , ReadQueue(..)
  , readQueue
  , tryReadQueue
  , toWriteQueue
  , toReadQueue
  ) where

import Control.Concurrent.STM

newtype WriteQueue a = WriteQueue
  { getWriteQueue :: TQueue a
  }

writeQueue :: WriteQueue a -> a -> STM ()
writeQueue = writeTQueue . getWriteQueue
{-# INLINE writeQueue #-}

newtype ReadQueue a = ReadQueue
  { getReadQueue :: TQueue a
  }

readQueue :: ReadQueue a -> STM a
readQueue = readTQueue . getReadQueue
{-# INLINE readQueue #-}

tryReadQueue :: ReadQueue a -> STM (Maybe a)
tryReadQueue = tryReadTQueue . getReadQueue
{-# INLINE tryReadQueue #-}

toWriteQueue :: ReadQueue a -> WriteQueue a
toWriteQueue = WriteQueue . getReadQueue
{-# INLINE toWriteQueue #-}

toReadQueue :: WriteQueue a -> ReadQueue a
toReadQueue = ReadQueue . getWriteQueue
{-# INLINE toReadQueue #-}
