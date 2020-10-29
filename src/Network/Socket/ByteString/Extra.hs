module Network.Socket.ByteString.Extra
    ( runTcpServer
    , procRecvVal
    , sendValueCompressed
    , recvValueCompressed
    , sendValue
    , recvValue
    , recvAll
    , openSockUDPSender
    , openSockUDPReceiver
    , openSockTCPServer
    , openSockTCPClient
    , waitFin
    , withSocket
    )
where

import GHC.Generics (Generic)
-- network-socket-options
import Network.Socket.Options
-- network
import Network.Socket hiding (send, sendTo, recv, recvFrom)
import Network.Socket.ByteString (recv, sendMany)
-- bytestring
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB hiding (unpack)
import qualified Data.ByteString.Lazy.Char8 as LB (unpack)
import Data.ByteString.Builder (byteStringHex, toLazyByteString)

-- safe-exceptions
import Control.Exception.Safe
-- base
import Control.Monad (when, forever)
import Control.Concurrent (forkIO)
import Data.List (splitAt, intercalate)
import System.Timeout (timeout)
-- cereal
import Data.Serialize (runGetPartial, runPutLazy, decodeLazy, encodeLazy, Get, Putter, Result(..), Serialize(..))
-- deepseq
import Control.DeepSeq
-- zlib
import Codec.Compression.GZip (compress, decompress)

newtype Compressed = Compressed LB.ByteString
    deriving stock (Eq, Show, Generic)
    deriving newtype (NFData, Serialize)

sendValueCompressed
    :: Serialize a
    => Socket
    -> a
    -> IO ()
sendValueCompressed sock val = sendValue put sock $ Compressed $ compress $ encodeLazy val

recvValueCompressed
    :: Serialize a
    => Socket
    -> Int -- ^ maximum number of byte for each chunk to receive
    -> IO (Either String a)
recvValueCompressed sock n = do
    (eVal, _) <- recvValue get sock n
    return $ do
        Compressed bstr <- eVal
        decodeLazy $ decompress bstr


-- | receive stream until the message is successfully parsed or failed for TCP/IP

sendValue
    :: Putter a
    -> Socket
    -> a
    -> IO ()
sendValue putter sock val = sendMany sock $ LB.toChunks $ runPutLazy $ putter val

recvValue
    :: Get a
    -> Socket
    -> Int -- ^ maximum number of byte for each chunk to receive
    -> IO (Either String a, ByteString)
recvValue getter sock n = receiveWithCont $ runGetPartial getter
 where receiveWithCont :: (ByteString -> Result a) -> IO (Either String a, ByteString)
       receiveWithCont cont = do
           first <- recv sock n
           case cont first of
               Done a _ -> return $ (Right a, first)
               Fail err _ -> return $ (Left err, first)
               Partial cont' -> do
                   (result, rest) <- receiveWithCont cont'
                   return (result, first <> rest)

-- | receive all stream until FIN received for TCP/IP
recvAll
    :: Socket
    -> Int -- ^ maximum number of byte for each chunk to receive
    -> IO ByteString
recvAll sock n = do
    first <- recv sock n
    if B.length first == 0
        then return mempty
        else do
            rest <- recvAll sock n
            return $ first <> rest

openSockUDPSender
     :: Bool -- ^ isBroadCast
     -> String -- ^ IP Address
     -> String -- ^ Port Number
     -> IO (Socket, SockAddr)
openSockUDPSender isBroadCast addr port = do
     addrinfos <- getAddrInfo Nothing (Just addr) (Just port)
     let receiverAddr = head addrinfos
     sock <- socket AF_INET Datagram 0
     when isBroadCast $ setSocketOption sock Broadcast 1
     setSocketOption sock SendBuffer 1472
     return (sock, addrAddress receiverAddr)

openSockUDPReceiver
    :: String -- ^ Port number or name
    -> IO Socket
openSockUDPReceiver port = do
    addrinfos <- getAddrInfo (Just (defaultHints {addrFlags = [AI_PASSIVE]})) Nothing (Just port)
    let serveraddr = head addrinfos
    sock <- socket (addrFamily serveraddr) Datagram defaultProtocol
    bind sock (addrAddress serveraddr)
    return sock

openSockTCPServer
    :: String -- ^ Port number or name
    -> IO Socket
openSockTCPServer port = do
    addrinfos <- getAddrInfo (Just (defaultHints {addrFlags = [AI_PASSIVE]})) Nothing (Just port)
    let serveraddr = head addrinfos
    sock <- socket (addrFamily serveraddr) Stream defaultProtocol
    bind sock (addrAddress serveraddr)
    listen sock 2048
    return sock

openSockTCPClient
    :: HostName -- ^ IP Address of the target server to communicate
    -> ServiceName -- ^ Port number of the target server to communicate
    -> IO Socket
openSockTCPClient hostname port = do
    addrinfos <- getAddrInfo Nothing (Just hostname) (Just port)
    let serveraddr = head addrinfos
    sock <- socket (addrFamily serveraddr) Stream defaultProtocol
--     setSocketOption sock KeepAlive 1
    connect sock (addrAddress serveraddr)
    return sock

waitFin :: Socket -> IO ()
waitFin sock = do
--     shutdown sock ShutdownSend
    _ <- recvAll sock 1024
    return ()

withSocket
    :: HostName -- ^ IP Address of the target server to communicate
    -> ServiceName -- ^ Port number of the target server to communicate
    -> (Socket -> SockAddr -> IO a)
    -> IO a
withSocket hostname port io = bracket initializer (close . fst) (uncurry io)
 where initializer = do
           addrinfos <- getAddrInfo Nothing (Just hostname) (Just port)
           let serveraddr = head addrinfos
           sock <- socket (addrFamily serveraddr) Stream defaultProtocol
           return (sock, addrAddress serveraddr)

runTcpServer
    :: (String -> IO ())
    -> ServiceName
    -> Microseconds -- ^ timeout of receiving each chunk in microseconds
    -> (Socket -> SockAddr -> IO ()) -> IO ()
runTcpServer logger port timeoutMicroSec proc = bracket (openSockTCPServer port) close $ \ mastersock -> forever $ do
    (connsock, clientaddr) <- accept mastersock
    setRecvTimeout connsock timeoutMicroSec

    let log' :: String -> IO ()
        log' str = logger $ intercalate "\n" $ map unwords
            [ ["Exeption for", port, "<==", show clientaddr]
            , [str]
            ]

    let errorHandler :: SomeException -> IO ()
        errorHandler err = case fromException err :: Maybe StringException of
            Just (StringException str _) -> log' str
            Nothing                      -> log' $ unwords ["error message:", show err]
    forkIO $ handle errorHandler $ (`finally` close connsock) $ do
        m <- timeout (fromIntegral timeoutMicroSec) $ do
            proc connsock clientaddr
            waitFin connsock
        case m of
            Just () -> return ()
            Nothing -> throwString "Process timeout"
        

procRecvVal :: Get a -> (a -> IO ()) -> Socket -> SockAddr -> IO ()
procRecvVal getter proc sock _  = do
    (eVal, msg) <- recvValue getter sock 4096 -- 2 ^ 13
    case eVal of
        Right val -> proc val
        Left err -> throwString $ unlines $ map unwords
            [ ["packet length:", show $ B.length msg]
            , ["decode error message:", err]
            , ["contents:"]
            , [showByteStringHex msg]
            ]

showByteStringHex :: ByteString -> String
showByteStringHex = formatHex . LB.unpack . toLazyByteString . byteStringHex

formatHex :: String -> String
formatHex xs = unlines
    [ replicate 10 ' ' ++ unwords (map (padTo'' 2 . show) ([0 .. 9] :: [Int]))
    , unlines $ map (\ (i, str) -> concat [take 10 $ show i ++ repeat ' ', str]) $ zip ([0..] :: [Int]) $ map unwords x00_00s
    ]
 where x00s = toTable 2 xs
       x00_00s = toTable 10 x00s

padTo'' :: Int -> String -> String
padTo'' i str = reverse $ take i $ reverse str ++ repeat ' '

toTable
    :: Int
    -> [a]
    -> [[a]]
toTable _ [] = []
toTable n xs = case splitAt n xs of
    (ls, []) -> [ls]
    (ls, rs) -> ls : toTable n rs
