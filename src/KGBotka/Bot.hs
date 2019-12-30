{-# LANGUAGE OverloadedStrings #-}

module KGBotka.Bot
  ( botThread
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import Data.Either
import Data.Foldable
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Database.SQLite.Simple as Sqlite
import Irc.Commands
import Irc.Identifier (Identifier, idText)
import Irc.Message
import Irc.RawIrcMsg
import Irc.UserInfo (userNick)
import KGBotka.Command
import KGBotka.Expr
import KGBotka.Flip
import KGBotka.Parser
import KGBotka.Queue
import KGBotka.Repl
import KGBotka.Roles
import Network.URI
import System.IO
import Text.Regex.TDFA (defaultCompOpt, defaultExecOpt)
import Text.Regex.TDFA.String

evalExpr :: M.Map T.Text T.Text -> Expr -> T.Text
evalExpr _ (TextExpr t) = t
evalExpr vars (FunCallExpr "or" args) =
  fromMaybe "" $ listToMaybe $ dropWhile T.null $ map (evalExpr vars) args
evalExpr vars (FunCallExpr "urlencode" args) =
  T.concat $ map (T.pack . encodeURI . T.unpack . evalExpr vars) args
  where
    encodeURI = escapeURIString (const False)
evalExpr vars (FunCallExpr "flip" args) =
  T.concat $ map (flipText . evalExpr vars) args
evalExpr vars (FunCallExpr funame _) = fromMaybe "" $ M.lookup funame vars

evalExprs :: M.Map T.Text T.Text -> [Expr] -> T.Text
evalExprs vars = T.concat . map (evalExpr vars)

textContainsLink :: T.Text -> Bool
textContainsLink t =
  isRight $ do
    regex <-
      compile
        defaultCompOpt
        defaultExecOpt
        "[-a-zA-Z0-9@:%._\\+~#=]{2,256}\\.[a-z]{2,6}\\b([-a-zA-Z0-9@:%_\\+.~#?&\\/\\/=]*)"
    match <- execute regex $ T.unpack t
    case match of
      Just x -> Right x
      Nothing -> Left "No match found"

data TwitchBadgeRole
  = TwitchSub
  | TwitchVip
  | TwitchBroadcaster
  | TwitchMod
  deriving (Show)

roleOfBadge :: T.Text -> Maybe TwitchBadgeRole
roleOfBadge badge
  | "subscriber" `T.isPrefixOf` badge = Just TwitchSub
  | "vip" `T.isPrefixOf` badge = Just TwitchVip
  | "broadcaster" `T.isPrefixOf` badge = Just TwitchBroadcaster
  | "moderator" `T.isPrefixOf` badge = Just TwitchMod
  | otherwise = Nothing

badgeRolesFromRawIrcMsg :: RawIrcMsg -> [TwitchBadgeRole]
badgeRolesFromRawIrcMsg RawIrcMsg {_msgTags = tags} =
  fromMaybe [] $ do
    badges <- lookupEntryValue "badges" tags
    return $ mapMaybe roleOfBadge $ T.splitOn "," badges

tagEntryPair :: TagEntry -> (T.Text, T.Text)
tagEntryPair (TagEntry name value) = (name, value)

tagEntryName :: TagEntry -> T.Text
tagEntryName = fst . tagEntryPair

tagEntryValue :: TagEntry -> T.Text
tagEntryValue = snd . tagEntryPair

lookupEntryValue :: T.Text -> [TagEntry] -> Maybe T.Text
lookupEntryValue name = fmap tagEntryValue . find ((== name) . tagEntryName)

userIdFromRawIrcMsg :: RawIrcMsg -> Maybe TwitchUserId
userIdFromRawIrcMsg RawIrcMsg {_msgTags = tags} =
  TwitchUserId <$> lookupEntryValue "user-id" tags

botThread ::
     ReadQueue RawIrcMsg
  -> WriteQueue RawIrcMsg
  -> ReadQueue ReplCommand
  -> TVar (S.Set Identifier)
  -> Sqlite.Connection
  -> FilePath
  -> IO ()
botThread incomingQueue outgoingQueue replQueue state dbConn logFilePath =
  withFile logFilePath AppendMode $ \logHandle -> botLoop logHandle
  where
    botLoop logHandle = do
      threadDelay 10000 -- to prevent busy looping
      maybeRawMsg <- atomically $ tryReadQueue incomingQueue
      for_ maybeRawMsg $ \rawMsg -> do
        let cookedMsg = cookIrcMsg rawMsg
        hPutStrLn logHandle $ "[TWITCH] " <> show rawMsg
        hFlush logHandle
        case cookedMsg of
          Ping xs -> atomically $ writeQueue outgoingQueue (ircPong xs)
          Join _ channelId _ ->
            atomically $ modifyTVar state $ S.insert channelId
          Part _ channelId _ ->
            atomically $ modifyTVar state $ S.delete channelId
          Privmsg userInfo channelId message -> do
            roles <-
              maybe
                (return [])
                (getTwitchUserRoles dbConn)
                (userIdFromRawIrcMsg rawMsg)
            let badgeRoles = badgeRolesFromRawIrcMsg rawMsg
            case (roles, badgeRoles) of
              ([], [])
                | textContainsLink message ->
                  atomically $
                  writeQueue outgoingQueue $
                  ircPrivmsg
                    (idText channelId)
                    ("/timeout " <> idText (userNick userInfo) <> " 1")
              _ ->
                case parseCommandCall "!" message of
                  Just (CommandCall name args) -> do
                    command <- commandByName dbConn name
                    case command of
                      Just (Command _ code) ->
                        let codeAst = snd <$> runParser exprs code
                         in case codeAst of
                              Right codeAst' -> do
                                hPutStrLn logHandle $ "[AST] " <> show codeAst'
                                hFlush logHandle
                                atomically $
                                  writeQueue outgoingQueue $
                                  ircPrivmsg (idText channelId) $
                                  twitchCmdEscape $
                                  evalExprs (M.fromList [("1", args)]) codeAst'
                              Left err ->
                                hPutStrLn logHandle $ "[ERROR] " <> show err
                      Nothing -> return ()
                  _ -> return ()
          _ -> return ()
      atomically $ do
        replCommand <- tryReadQueue replQueue
        case replCommand of
          Just (Say channel msg) ->
            writeQueue outgoingQueue $ ircPrivmsg channel msg
          Just (JoinChannel channel) ->
            writeQueue outgoingQueue $ ircJoin channel Nothing
          Just (PartChannel channelId) ->
            writeQueue outgoingQueue $ ircPart channelId ""
          Nothing -> return ()
      botLoop logHandle
    twitchCmdEscape :: T.Text -> T.Text
    twitchCmdEscape = T.dropWhile (`elem` ['/', '.']) . T.strip