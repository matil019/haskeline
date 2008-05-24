module System.Console.Haskeline(InputT,
                    runInputT,
                    runInputTWithPrefs,
                    getInputLine,
                    Settings(..),
                    defaultSettings,
                    Prefs(..),
                    BellStyle(..),
                    EditMode(..),
                    defaultPrefs,
                    readPrefs,
                    CompletionType(..),
                    -- * Tab completion functions
                    CompletionFunc,
                    Completion(..),
                    completeWord,
                    simpleCompletion,
                    completeFilename,
                    filenameWordBreakChars)
                     where

import System.Console.Haskeline.LineState
import System.Console.Haskeline.Command
import System.Console.Haskeline.Posix
{--
import System.Console.Haskeline.Command.Undo
import System.Console.Haskeline.Command.Paste
import System.Console.Haskeline.Command.Completion
--}
import System.Console.Haskeline.Command.History
import System.Console.Haskeline.Draw
import System.Console.Haskeline.Vi
import System.Console.Haskeline.Emacs
import System.Console.Haskeline.Settings
import System.Console.Haskeline.Monads
import System.Console.Haskeline.InputT
import System.Console.Haskeline.Command.Completion

import System.Console.Terminfo
import System.IO
import Data.Maybe (fromMaybe)
import Data.Char (isSpace)
import Control.Monad


defaultSettings :: MonadIO m => Settings m
defaultSettings = Settings {complete = completeFilename,
                        historyFile = Nothing,
                        maxHistorySize = Nothing}

-- Note: Without buffering the output, there's a cursor flicker sometimes.
-- We'll keep it buffered, and manually flush the buffer in 
-- repeatTillFinish.
wrapTerminalOps:: MonadIO m => Terminal -> m a -> m a
wrapTerminalOps term f = do
    oldInBuf <- liftIO $ hGetBuffering stdin
    oldEcho <- liftIO $ hGetEcho stdout
    let initialize = do maybeOutput term keypadOn
                        hSetBuffering stdin NoBuffering
                        hSetEcho stdout False
    let reset = do maybeOutput term keypadOff
                   hSetBuffering stdin oldInBuf
                   hSetEcho stdout oldEcho
    finallyIO (liftIO initialize >> f) reset

maybeOutput :: Terminal -> Capability TermOutput -> IO ()
maybeOutput term cap = runTermOutput term $ 
        fromMaybe mempty (getCapability term cap)



data TermSettings = TermSettings {terminal :: Terminal,
                          actions :: Actions}


makeSettings :: IO TermSettings
makeSettings = do
    t <- setupTermFromEnv
    let Just acts = getCapability t getActions
    return TermSettings {terminal = t, actions = acts}


getInputLine :: MonadIO m => String -> InputT m (Maybe String)
getInputLine prefix = do
-- TODO: Cache the terminal, actions
    emode <- asks (\prefs -> case editMode prefs of
                    Vi -> viActions
                    Emacs -> emacsCommands)
    settings <- liftIO makeSettings
    wrapTerminalOps (terminal settings) $ do
        let ls = emptyIM
        layout <- liftIO getLayout

        result <- runInputCmdT layout
                    $ runDraw (actions settings) (terminal settings)
                    $ withGetEvent (terminal settings) $ \getEvent -> 
                        drawLine prefix ls 
                            >> repeatTillFinish getEvent prefix ls emode
        case result of 
            Just line | not (all isSpace line) -> addHistory line
            _ -> return ()
        return result

repeatTillFinish :: forall m s . (MonadIO m, LineState s) 
            => Draw (InputCmdT m) Event -> String -> s -> KeyMap (InputCmdT m) s -> Draw (InputCmdT m) (Maybe String)
repeatTillFinish getEvent prefix = loop
    where 
        -- NOTE: since the functions in this mutually recursive binding group do not have the 
        -- same contexts, we need the -XGADTs flag (or -fglasgow-exts)
        loop :: forall t . LineState t => t -> KeyMap (InputCmdT m) t -> Draw (InputCmdT m) (Maybe String)
        loop s processor = do
                liftIO (hFlush stdout)
                event <- getEvent
                case event of
                    WindowResize newLayout -> 
                        withReposition newLayout (loop s processor)
                    KeyInput k -> case lookupKM processor k of
                        Nothing -> loop s processor
                        Just g -> case g s of
                            Left r -> moveToNextLine s >> return r
                            Right f -> do
                                        KeyAction effect next <- lift f
                                        drawEffect prefix s effect
                                        loop (effectState effect) next