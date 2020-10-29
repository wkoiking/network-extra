module Main where

import GHC.Generics (Generic)
import Network.Socket.ByteString.Extra
import Control.Concurrent
import Network.Socket
import Data.Fixed (Milli)
import Control.Exception
import System.IO
import Data.List (intercalate)
-- cereal
import Data.Serialize (Get, Serialize(..))
-- time
import Data.Time.Format
import Data.Time.LocalTime
import Data.Time.Clock

showIndianTime :: UTCTime -> String
showIndianTime = formatTime timeLocale "%d/%m/%Y %k:%M:%S" . utcToLocalTime timeZone

timeLocale :: TimeLocale
timeLocale = defaultTimeLocale { knownTimeZones = [indiaTimeZone] }

timeZone :: TimeZone
timeZone = indiaTimeZone

indiaTimeZone :: TimeZone
indiaTimeZone = TimeZone
    { timeZoneMinutes = 60 * 5 + 30
    , timeZoneSummerOnly = False
    , timeZoneName = "IST"
    }

data MyData
    = MyData1
    | MyData2
    deriving (Show, Generic, Serialize)

main :: IO ()
main = do
    vStdout <- newMVar stdout :: IO (MVar Handle)
    let logger :: String -> String -> IO ()
        logger label str = do
            time <- getCurrentTime
            let timeStr :: String
                timeStr = showIndianTime time ++ " "
                tagStr = label ++ ": "
                spaces = replicate (length timeStr) ' '
                headerStr = concat [timeStr, tagStr]
                tailStr = concat [spaces, tagStr]
            withMVar vStdout $ \ h -> hPutStrLn h $ concat [intercalate "\n" $ zipWith (++) (headerStr : repeat tailStr) $ lines str]
    let errorHandler :: SomeException -> IO ()
        errorHandler err = logger "" $ show err

    -- Server
    _ <- forkIO $ runTcpServer (logger "Server1") port (5000 * 1000) $ procRecvVal (get :: Get MyData) $ \ a -> do
        logger "Server1" $ show a
        return ()

--     forkIO $ bracket (openSockTCPServer port) close $ \ mastersock -> forever $ do
--         (connsock, clientaddr) <- accept mastersock
--         log $ "Connected: " ++ show clientaddr
--         forkIO $ handle errorHandler $ (`finally` waitFinAndClose connsock) $ do
--             _ <- recv connsock 4096
--             return ()

    -- Client1
    _ <- forkIO $ handle errorHandler $ withSocket "localhost" port $ \ sock addr -> do
        setSocketOption sock KeepAlive 1
        connect sock addr
        logger "Client1" "connect"
        wait 10
        sendValue put sock $ (-1 :: Int)
        logger "Client1" "sent"
        logger "Client1" "close"

    -- Client2
    _ <- forkIO $ handle errorHandler $ withSocket "localhost" port $ \ sock addr -> do
        setSocketOption sock KeepAlive 1
        connect sock addr
        logger "Client2" "connect"
        wait 2
        sendValue put sock $ (-1 :: Int)
        logger "Client2" "sent"
        logger "Client2" "close"

    wait 20

wait
    :: Milli -- ^ seconds
    -> IO ()
wait s = threadDelay $ truncate $ s * 1000000

port :: String
port = "60232"
