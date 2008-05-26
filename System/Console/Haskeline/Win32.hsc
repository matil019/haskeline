module System.Console.Haskeline.Win32(
                HANDLE,
                Coord(..),
                readKey,
                getConsoleSize,
                getPosition,
                setPosition
                )where


import System.IO
import Foreign.Ptr
import Foreign.Storable
import Foreign.Marshal.Alloc
import Foreign.C.Types
import Foreign.Marshal.Utils
import System.Win32.Types
import Graphics.Win32.Misc(getStdHandle, sTD_INPUT_HANDLE, sTD_OUTPUT_HANDLE)
import Control.Monad(when)
import Data.List(intercalate)


import System.Console.Haskeline.Command
import System.Console.Haskeline.Monads
import System.Console.Haskeline.LineState
import System.Console.Haskeline.InputT

#include "win_console.h"

foreign import stdcall "windows.h GetConsoleMode" c_GetConsoleMode 
    :: HANDLE -> Ptr DWORD -> IO Bool

foreign import stdcall "windows.h SetConsoleMode" c_SetConsoleMode
    :: HANDLE -> DWORD -> IO Bool
    
getConsoleMode :: HANDLE -> IO DWORD
getConsoleMode h = alloca $ \modePtr -> do
    failIfFalse_ "GetConsoleMode" $ c_GetConsoleMode h modePtr 
    peek modePtr
    
setConsoleMode :: HANDLE -> DWORD -> IO ()
setConsoleMode h m = failIfFalse_ "SetConsoleMode" $ c_SetConsoleMode h m

foreign import stdcall "windows.h ReadConsoleInputA" c_ReadConsoleInput
    :: HANDLE -> Ptr () -> DWORD -> Ptr DWORD -> IO Bool
    
readKey :: HANDLE -> IO Key
readKey h = do
    e <- readEvent h
    case e of
        KeyEvent {keyDown = True, unicodeChar = c, virtualKeyCode = vc}
            | c /= '\NUL'                   -> return (KeyChar c)
            | Just k <- keyFromCode vc      -> return k
        _ -> readKey h

keyFromCode (#const VK_BACK) = Just Backspace
keyFromCode (#const VK_LEFT) = Just KeyLeft
keyFromCode (#const VK_RIGHT) = Just KeyRight
keyFromCode (#const VK_UP) = Just KeyUp
keyFromCode (#const VK_DOWN) = Just KeyDown
keyFromCode (#const VK_DELETE) = Just DeleteForward
-- TODO: KeyMeta (option-x), KillLine
keyFromCode _ = Nothing
    
data InputEvent = KeyEvent {keyDown :: BOOL,
                          repeatCount :: WORD,
                          virtualKeyCode :: WORD,
                          virtualScanCode :: WORD,
                          unicodeChar :: Char,
                          controlKeyState :: DWORD}
            -- TODO: WINDOW_BUFFER_SIZE_RECORD
            -- I can't figure out how the user generates them.
           | OtherEvent
                        deriving Show

readEvent :: HANDLE -> IO InputEvent
readEvent h = allocaBytes (#size INPUT_RECORD) $ \pRecord -> 
                        alloca $ \numEventsPtr -> do
    failIfFalse_ "ReadConsoleInput" 
        $ c_ReadConsoleInput h pRecord 1 numEventsPtr
    -- useful? numEvents <- peek numEventsPtr
    eventType :: WORD <- (#peek INPUT_RECORD, EventType) pRecord
    let eventPtr = (#ptr INPUT_RECORD, Event) pRecord
    case eventType of
        (#const KEY_EVENT) -> getKeyEvent eventPtr
        _ -> return OtherEvent
        
getKeyEvent :: Ptr () -> IO InputEvent
getKeyEvent p = do
    kDown' <- (#peek KEY_EVENT_RECORD, bKeyDown) p
    repeat' <- (#peek KEY_EVENT_RECORD, wRepeatCount) p
    keyCode <- (#peek KEY_EVENT_RECORD, wVirtualKeyCode) p
    scanCode <- (#peek KEY_EVENT_RECORD, wVirtualScanCode) p
    char :: CChar <- (#peek KEY_EVENT_RECORD, uChar) p -- TODO: unicode?
    state <- (#peek KEY_EVENT_RECORD, dwControlKeyState) p
    return KeyEvent {keyDown = kDown',
                            repeatCount = repeat',
                            virtualKeyCode = keyCode,
                            virtualScanCode = scanCode,
                            unicodeChar = toEnum $ fromEnum char,
                            controlKeyState = state}

-- NOTE: may be good to make COORD Storable, since used in multiple places.
data Coord = Coord {coordX, coordY :: Int}
                deriving Show
                
instance Storable Coord where
    sizeOf _ = (#size COORD)
    alignment = undefined -- ???
    peek p = do
        x :: CShort <- (#peek COORD, X) p
        y :: CShort <- (#peek COORD, Y) p
        return Coord {coordX = fromEnum x, coordY = fromEnum y}
    poke p c = do
        (#poke COORD, X) p (toEnum (coordX c) :: CShort)
        (#poke COORD, Y) p (toEnum (coordY c) :: CShort)
                
                            
foreign import ccall "SetPosition"
    c_SetPosition :: HANDLE -> Ptr Coord -> IO Bool
    
setPosition :: HANDLE -> Coord -> IO ()
setPosition h c = with c $ failIfFalse_ "SetConsoleCursorPosition" 
                    . c_SetPosition h
                    
foreign import stdcall "windows.h GetConsoleScreenBufferInfo"
    c_GetScreenBufferInfo :: HANDLE -> Ptr () -> IO Bool
    
getPosition :: HANDLE -> IO Coord
getPosition = withScreenBufferInfo $ 
    (#peek CONSOLE_SCREEN_BUFFER_INFO, dwCursorPosition)

getConsoleSize :: HANDLE -> IO Coord
getConsoleSize = withScreenBufferInfo $
    (#peek CONSOLE_SCREEN_BUFFER_INFO, dwSize)
    
withScreenBufferInfo :: (Ptr () -> IO a) -> HANDLE -> IO a
withScreenBufferInfo f h = allocaBytes (#size CONSOLE_SCREEN_BUFFER_INFO)
                                $ \infoPtr -> do
        failIfFalse_ "GetConsoleScreenBufferInfo"
            $ c_GetScreenBufferInfo h infoPtr
        f infoPtr

----------------------------
-- Drawing

data Win32State = Win32State {inHandle, outHandle :: HANDLE}

newtype Draw m a = Draw (ReaderT Win32State m a)
    deriving (Monad,MonadIO, MonadTrans, MonadReader Win32State)
    
runDraw :: MonadIO m => Draw m a -> m a
runDraw (Draw f) = liftIO win32State >>= runReaderT f

win32State :: IO Win32State
win32State = do
    hIn <- getStdHandle sTD_INPUT_HANDLE
    hOut <- getStdHandle sTD_OUTPUT_HANDLE
    return Win32State {inHandle = hIn, outHandle = hOut}
    
getPos :: MonadIO m => Draw m Coord
getPos = asks outHandle >>= liftIO . getPosition
    
setPos :: MonadIO m => Coord -> Draw m ()
setPos c = asks outHandle >>= \h -> liftIO (setPosition h c)

moveToNextLine :: (MonadIO m, LineState s) => s -> Draw (InputCmdT m) ()
moveToNextLine s = do
    Coord {coordX = x, coordY = y} <- getPos
    w <- asks width
    let n = lengthToEnd s
    let linesToEnd = if n+x < w then 1 else 1 + div (x+n) w
    setPos Coord {coordX = 0, coordY = y+linesToEnd}
    
-- TODO: is it bad to be using putStr here?
-- Do I really need to keep the handles around as a reader?
printText :: MonadIO m => String -> Draw m ()
printText = liftIO . putStr
    
printAfter :: MonadIO m => String -> Draw (InputCmdT m) ()
printAfter str = do
    p <- getPos
    printText str
    setPos p
    
drawLine :: (MonadIO m, LineState s) => String -> s -> Draw (InputCmdT m) ()
drawLine prefix s = do
    printText (beforeCursor prefix s)
    printAfter (afterCursor s)
    
diffLinesBreaking :: (LineState s, LineState t, MonadIO m)
                        => String -> s -> t -> Draw (InputCmdT m) ()
diffLinesBreaking prefix s1 s2 = let
    xs1 = beforeCursor prefix s1
    ys1 = afterCursor s1
    xs2 = beforeCursor prefix s2
    ys2 = afterCursor s2
    in case matchInit xs1 xs2 of
        ([],[])     | ys1 == ys2            -> return ()
        (xs1',[])   | xs1' ++ ys1 == ys2    -> movePos $ negate $ length xs1'
        ([],xs2')   | ys1 == xs2' ++ ys2    -> movePos $ length xs2'
        (xs1',xs2')                         -> do
            movePos (length xs1')
            let m = length xs1' + length ys1 - (length xs2' + length ys2)
            let deadText = replicate m ' '
            printText xs2'
            printAfter (ys2 ++ deadText)

-- todo: Dupe of Draw.hs
matchInit :: Eq a => [a] -> [a] -> ([a],[a])
matchInit (x:xs) (y:ys)  | x == y = matchInit xs ys
matchInit xs ys = (xs,ys)

movePos :: MonadIO m => Int -> Draw (InputCmdT m) ()
movePos n = do
    Coord {coordX = x, coordY = y} <- getPos
    w <- asks width
    let (h,x') = divMod (x+n) w
    setPos Coord {coordX = x', coordY = y+h}

crlf = "\r\n"

drawEffect :: (LineState s, LineState t, MonadIO m) 
    => String -> s -> Effect t -> Draw (InputCmdT m) ()
drawEffect prefix s (Change t) = do
    diffLinesBreaking prefix s t
drawEffect prefix s (PrintLines ls t shouldDraw) = do
    moveToNextLine s
    printText $ intercalate crlf ls
    when shouldDraw $ do
        when (not (null ls)) $ printText crlf
        drawLine prefix t
-- TODO: rest