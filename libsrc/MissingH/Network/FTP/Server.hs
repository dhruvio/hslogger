{- arch-tag: FTP server support
Copyright (C) 2004 John Goerzen <jgoerzen@complete.org>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module     : MissingH.Network.FTP.Server
   Copyright  : Copyright (C) 2004 John Goerzen
   License    : GNU GPL, version 2 or above

   Maintainer : John Goerzen, 
   Maintainer : jgoerzen@complete.org
   Stability  : experimental
   Portability: systems with networking

This module provides a server-side interface to the File Transfer Protocol
as defined by RFC959 and RFC1123.

Written by John Goerzen, jgoerzen\@complete.org

-}

module MissingH.Network.FTP.Server(
                                   anonFtpHandler
                                  )
where
import MissingH.Network.FTP.ParserServer
import Network.BSD
import Network.Socket
import qualified Network
import System.IO
import MissingH.Logging.Logger
import MissingH.Network
import MissingH.Str
import MissingH.Printf
import MissingH.IO.HVIO
import MissingH.IO.HVFS
import Data.Char
import MissingH.Printf
import Data.IORef
import Data.List

data DataType = ASCII | Binary
              deriving (Eq, Show)
data AuthState = NoAuth 
              | User String
              | Authenticated String
                deriving (Eq, Show)
data FTPState = FTPState
              { auth :: IORef AuthState,
                datatype :: IORef DataType,
                rename :: IORef (Maybe String)}

data FTPServer = forall a. HVFS a => FTPServer Handle a FTPState

s_crlf = "\r\n"
logname = "MissingH.Network.FTP.Server"
ftpPutStrLn :: FTPServer -> String -> IO ()
ftpPutStrLn (FTPServer h _ _) text =
    do hPutStr h (text ++ s_crlf)
       hFlush h

{- | Send a reply code, handling multi-line text as necessary. -}
sendReply :: FTPServer -> Int -> String -> IO ()
sendReply h codei text =
    let codes = vsprintf "%03d" codei
        writethis [] = ftpPutStrLn h (codes ++ "  ")
        writethis [item] = ftpPutStrLn h (codes ++ " " ++ item)
        writethis (item:xs) = do ftpPutStrLn h (codes ++ "-" ++ item)
                                 writethis xs
        in 
        writethis (map (rstrip) (lines text))

{- | Main FTP handler; pass the result of applying this to one argument to 
'MissingH.Network.SocketServer.handleHandler' -}

anonFtpHandler :: forall a. HVFS a => a -> Handle -> SockAddr -> IO ()
anonFtpHandler f h sa =
    let serv r = FTPServer h f r
        in
        traplogging logname NOTICE "" $
          do authr <- newIORef (NoAuth)
             typer <- newIORef ASCII
             renamer <- newIORef (Nothing::Maybe String)
             let s = serv (FTPState {auth = authr, datatype = typer,
                                    rename = renamer})
             sendReply s 220 "Welcome to MissingH.Network.FTP.Server."
             commandLoop s sa

type CommandHandler = FTPServer -> SockAddr -> String -> IO Bool
type Command = (String, (CommandHandler, (String, String)))

instance Eq Command where
    x == y = (fst x) == (fst y)
instance Ord Command where
    compare x y = compare (fst x) (fst y)

trapIOError :: FTPServer -> IO a -> (a -> IO Bool) -> IO Bool
trapIOError h testAction remainingAction =
    do result <- try testAction
       case result of
         Left err -> do sendReply h 550 (show err)
                        return True
         Right result -> remainingAction result

forceLogin :: CommandHandler -> CommandHandler
forceLogin func h@(FTPServer _ _ state) sa args =
    do state <- readIORef (auth state)
       case state of 
          Authenticated _ -> func h sa args
          x -> do sendReply h 530 "Command not possible in non-authenticated state."
                  return True

commands :: [Command]
commands =
    [("HELP", (cmd_help,             help_help))
    ,("QUIT", (cmd_quit,             help_quit))
    ,("USER", (cmd_user,             help_user))
    ,("PASS", (cmd_pass,             help_pass))
    ,("CWD",  (forceLogin cmd_cwd,   help_cwd))
    ,("CDUP", (forceLogin cmd_cdup,  help_cdup))
    ,("TYPE", (forceLogin cmd_type,  help_type))
    ,("NOOP", (forceLogin cmd_noop,  help_noop))
    ,("RNFR", (forceLogin cmd_rnfr,  help_rnfr))
    ,("RNTO", (forceLogin cmd_rnto,  help_rnto))
    ]

commandLoop :: FTPServer -> SockAddr -> IO ()
commandLoop h@(FTPServer fh _ _) sa =
    let errorhandler e = do noticeM logname
                                    ("Closing due to error: " ++ (show e))
                            hClose fh
                            return False
        in do continue <- (flip catch) errorhandler 
               (do x <- parseCommand fh
                   case x of
                     Left err -> do sendReply h 500 $
                                      " Couldn't parse command: " ++ (show err)
                                    return True
                     Right (cmd, args) -> 
                         case lookup cmd commands of
                            Nothing -> do sendReply h 502 $
                                           "Unrecognized command " ++ cmd
                                          return True
                            Just hdlr -> (fst hdlr) h sa args
               )
              if continue
                 then commandLoop h sa
                 else return ()

help_quit =
    ("Terminate the session",
     "")

cmd_quit :: CommandHandler
cmd_quit h sa args =
    do sendReply h 211 "OK, Goodbye."
       return False

help_user =
    ("Provide a username",
     unlines $ 
     ["USER username will provide the username for authentication."
     ,"It should be followed by a PASS command to finish the authentication."
     ])

cmd_user :: CommandHandler
cmd_user h@(FTPServer _ _ state) _ passedargs =
    let args = strip passedargs
        in
        case args of
           "anonymous" -> do sendReply h 331 "User name accepted; send password."
                             writeIORef (auth state) (User args)
                             return True
           _ -> do sendReply h 530 "Unrecognized user name; please try \"anonymous\""
                   writeIORef (auth state) NoAuth
                   return True

help_pass =
    ("Provide a password",
     "PASS password will provide the password for authentication.")
cmd_pass :: CommandHandler
cmd_pass h@(FTPServer _ _ state) _ passedargs =
    do curstate <- readIORef (auth state)
       case curstate of
         User "anonymous" -> 
             do sendReply h 230 "Anonymous login successful."
                writeIORef (auth state) (Authenticated "anonymous")
                infoM logname "Anonymous authentication successful"
                return True
         _ -> do sendReply h 530 "Out of sequence PASS command"
                 return True

help_cwd =
    ("Change working directory",
     unlines $
     ["Syntax: CWD cwd"
     ,""
     ,"Changes the working directory to the specified item"])

cmd_cwd :: CommandHandler
cmd_cwd h@(FTPServer _ fs _) _ args =
    do trapIOError h (vSetCurrentDirectory fs args)
         $ \_ -> do
                 newdir <- vGetCurrentDirectory fs
                 sendReply h 250 $ "New directory now " ++ newdir
                 return True

help_cdup = 
    ("Change to parent directory", "Same as CWD ..")
cmd_cdup h sa _ = cmd_cwd h sa ".."

help_type =
    ("Change the type of data transfer", "Valid args are A, AN, and I")
cmd_type :: CommandHandler
cmd_type h@(FTPServer _ _ state) _ args =
    let changetype newt =
            do oldtype <- readIORef (datatype state)
               writeIORef (datatype state) newt
               sendReply h 200 $ "Type changed from " ++ show oldtype ++
                             " to " ++ show newt
               return True
        in case args of
         "I" -> changetype Binary
         "A" -> changetype ASCII
         "AN" -> changetype ASCII
         _ -> do sendReply h 504 $ "Type \"" ++ args ++ "\" not supported."
                 return True
       
help_noop = ("Do nothing", "")
cmd_noop :: CommandHandler
cmd_noop h _ _ =
    do sendReply h 200 "OK"
       return True

help_rnfr = ("Specify FROM name for a file rename", "")
cmd_rnfr :: CommandHandler
cmd_rnfr h@(FTPServer _ _ state) _ args = 
    if length args < 1
       then do sendReply h 501 "Filename required"
               return True
       else do writeIORef (rename state) (Just args)
               sendReply h 350 "Noted rename from name; please send RNTO."
               return True

help_rnto = ("Specify TO name for a file name", "")
cmd_rnto :: CommandHandler
cmd_rnto h@(FTPServer _ fs state) _ args =
    if length args < 1
       then do sendReply h 501 "Filename required"
               return True
       else do fr <- readIORef (rename state)
               case fr of
                   Nothing -> do sendReply h 503 "RNFR required before RNTO"
                                 return True
                   Just fromname -> 
                       do writeIORef (rename state) Nothing
                          trapIOError h (vRenameFile fs fromname args)
                              $ \_ -> do sendReply h 250 
                                           ("File " ++ fromname ++ 
                                            " renamed to " ++ args)
                                         return True

help_help =
    ("Display help on available commands",
     "When called without arguments, shows a summary of available system\n"
     ++ "commands.  When called with an argument, shows detailed information\n"
     ++ "on that specific command.")

cmd_help :: CommandHandler
cmd_help h sa args =
    let genericreply addr = unlines $
          [" --- General Help Response ---"
          ,""
          ,"Welcome to the FTP server, " ++ addr ++ "."
          ,"This server is implemented as the MissingH.Network.FTP.Server"
          ,"component of the MissingH library.  The MissingH library"
          ,"is available from http://quux.org/devel/missingh."
          ,""
          ,""
          ,"I know of the following commands:"
          ,concatMap (\ (name, (_, (summary, _))) -> vsprintf "%-10s %s\n" name summary)
              (sort commands)
          ,""
          ,"You may type \"HELP command\" for more help on a specific command."
          ]
        in
        if args == ""
           then do sastr <- showSockAddr sa
                   sendReply h 214 (genericreply sastr)
                   return True
           else let newargs = map toUpper args
                    in case lookup newargs commands of
                         Nothing -> do 
                                    sendReply h 214 $ "No help for \"" ++ newargs
                                      ++ "\" is available.\nPlese send HELP"
                                      ++ " without arguments for a list of\n"
                                      ++ "valid commands."
                                    return True
                         Just (_, (summary, detail)) ->
                             do sendReply h 214 $ newargs ++ ": " ++ summary ++ 
                                               "\n\n" ++ detail
                                return True
