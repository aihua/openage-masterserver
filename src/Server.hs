{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-|
 -Copyright 2016-2016 the openage authors.
 -See copying.md for legal info.
 -}
module Server where

import Data.ByteString as B
import Data.ByteString.Char8 as BC
import Data.ByteString.Lazy as BL
import Data.Aeson
import Data.Text
import Data.List as L
import Data.Map.Strict as Map
import System.IO as S
import Control.Concurrent.STM
import Data.Version
import Network
import Protocol
import DBSchema

-- |Server Datatype
-- Stores Map of running Games and Map of logged in clients
data Server = Server {
  games :: TVar (Map GameName Game),
  clients :: TVar (Map AuthPlayerName Client)
  }

newServer :: IO Server
newServer = do
  games <- newTVarIO Map.empty
  clients <- newTVarIO Map.empty
  return Server{..}

-- |Client datatype
-- It stores players name, handle and a channel to address it.
data Client = Client {
  clientName :: AuthPlayerName,
  clientHandle :: Handle,
  clientChan :: TChan InMessage,
  clientInGame :: Maybe Text
  }

-- |Client constructor
newClient :: AuthPlayerName -> Handle -> IO Client
newClient clientName clientHandle = do
  clientChan <- newTChanIO
  return Client{clientInGame=Nothing,..}

-- |Sends InMessage to the clients channel
sendChannel :: Client -> InMessage -> IO ()
sendChannel Client{..} msg =
  atomically $ writeTChan clientChan msg

-- |Send OutMessage over handle to client
sendEncoded :: ToJSON a => Handle -> a -> IO()
sendEncoded handle = BC.hPutStrLn handle . BL.toStrict . encode

-- |Send encoded GameQueryAnswer
sendGameQueryAnswer :: Handle -> [Game] -> IO ()
sendGameQueryAnswer handle list =
  sendEncoded handle $ GameQueryAnswer list

-- |Send encoded Message
sendMessage :: Handle -> Text -> IO()
sendMessage handle text =
  sendEncoded handle $ Message text

-- |Send encoded Error message
sendError :: Handle -> Text -> IO()
sendError handle text =
  sendEncoded handle $ Protocol.Error text

-- |Get List of Games in servers game map
getGameList :: Server -> IO [Game]
getGameList Server{..} = atomically $ do
  gameList <- readTVar games
  return $ Map.elems gameList

-- |Add game to servers game map
checkAddGame :: Server -> AuthPlayerName -> InMessage -> IO (Maybe Game)
checkAddGame Server{..} pName (GameInit gName gMap gPlay) =
  atomically $ do
    gameMap <- readTVar games
    if Map.member gName gameMap
      then return Nothing
      else do game <- newGame gName pName gMap gPlay
              writeTVar games $ Map.insert gName game gameMap
              return $ Just game
checkAddGame _ _ _ = return Nothing

-- |Remove Game from servers game map
removeGame :: Server -> GameName -> IO ()
removeGame Server{..} name = atomically $
  modifyTVar' games $ Map.delete name

-- |Join Game and return True if join was successful
joinGame :: Server -> Client -> GameName -> IO Bool
joinGame server@Server{..} client@Client{..} gameId = do
  gameLis <- readTVarIO games
  if member gameId gameLis
    then do
      let Game{..} = gameLis!gameId
      if Map.size gamePlayers < numPlayers
        then do
          clientLis <- readTVarIO clients
          atomically $ writeTVar clients
            $ Map.adjust (addClientGame gameId) clientName clientLis
          atomically $ writeTVar games
            $ Map.adjust (joinPlayer clientName False) gameId gameLis
          sendMessage clientHandle "Joined Game."
          return True
        else do
          sendError clientHandle "Game is full."
          return False
    else do
      sendError clientHandle "Game does not exist."
      return False

-- |Add participant to game
joinPlayer :: AuthPlayerName -> Bool -> Game -> Game
joinPlayer name host game@Game{..} =
  game {gamePlayers = Map.insert name
        (newParticipant name host) gamePlayers}

-- |Updates player configuration
updatePlayer :: AuthPlayerName -> Text -> Int -> Bool-> Game -> Game
updatePlayer name civ team rdy game@Game{..} =
  game {gamePlayers = Map.adjust updateP name gamePlayers }
    where
      updateP par = par {parName = name,
                         parCiv = civ,
                         parTeam=team,
                         parReady=rdy}

-- |Add Game to Clients clientInGame field
addClientGame :: GameName -> Client -> Client
addClientGame game client@Client{..} =
  client {clientInGame = Just game}

-- |Leave Game if normal player, close if host
leaveGame :: Server -> Client -> GameName -> IO()
leaveGame server@Server{..} client@Client{..} game = do
      gameLis <- readTVarIO games
      if clientName == gameHost (gameLis!game)
        then do
          clientLis <- readTVarIO clients
          mapM_ (flip sendChannel GameClosedByHost
                 . (!) clientLis. parName)
            $ gamePlayers $ gameLis!game
          removeGame server game
          sendMessage clientHandle "Closed Game."
        else do
          removeClientInGame server client
          clientLis <- readTVarIO clients
          atomically $ writeTVar games
            $ Map.adjust leavePlayer game gameLis
          sendMessage clientHandle "Left Game."
            where
              leavePlayer gameOld@Game{..} =
                gameOld {gamePlayers = Map.delete clientName gamePlayers}

-- |Broadcast message to all Clients in a Game
broadcastGame :: Server -> GameName -> InMessage -> IO ()
broadcastGame Server{..} gameName msg = do
  clientLis <- readTVarIO clients
  gameLis <- readTVarIO games
  mapM_ (flip sendChannel msg . (!) clientLis . parName)
    $ gamePlayers $ gameLis!gameName

-- |Remove ClientInGame from client in servers clientmap
removeClientInGame :: Server -> Client -> IO ()
removeClientInGame server@Server{..} client@Client{..} = do
  clientLis <- readTVarIO clients
  atomically $ writeTVar clients
    $ Map.adjust rmClientGame clientName clientLis
    where
      rmClientGame client = client {clientInGame = Nothing}
