{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-
Copyright (C) 2006-2018 John MacFarlane <jgm@berkeley.edu>

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
   Module      : Text.Pandoc.Readers.LaTeX.Parsing
   Copyright   : Copyright (C) 2006-2018 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

General parsing types and functions for LaTeX.
-}
module Text.Pandoc.Readers.LaTeX.Parsing
  ( DottedNum(..)
  , renderDottedNum
  , incrementDottedNum
  , LaTeXState(..)
  , defaultLaTeXState
  , LP
  , withVerbatimMode
  , rawLaTeXParser
  , applyMacros
  , tokenize
  , untokenize
  , untoken
  , totoks
  , toksToString
  , satisfyTok
  , doMacros
  , setpos
  , anyControlSeq
  , anySymbol
  , isNewlineTok
  , isWordTok
  , isArgTok
  , spaces
  , spaces1
  , tokTypeIn
  , controlSeq
  , symbol
  , symbolIn
  , sp
  , whitespace
  , newlineTok
  , comment
  , anyTok
  , singleChar
  , specialChars
  , endline
  , blankline
  , primEscape
  , bgroup
  , egroup
  , grouped
  , braced
  , braced'
  , bracedUrl
  , bracedOrToken
  , bracketed
  , bracketedToks
  , parenWrapped
  , dimenarg
  , ignore
  , withRaw
  ) where

import Prelude
import Control.Applicative (many, (<|>))
import Control.Monad
import Control.Monad.Except (throwError)
import Control.Monad.Trans (lift)
import Data.Char (chr, isAlphaNum, isDigit, isLetter, ord)
import Data.Default
import Data.List (intercalate)
import qualified Data.Map as M
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Text.Pandoc.Builder
import Text.Pandoc.Class (PandocMonad, report)
import Text.Pandoc.Error (PandocError (PandocMacroLoop))
import Text.Pandoc.Logging
import Text.Pandoc.Options
import Text.Pandoc.Parsing hiding (blankline, many, mathDisplay, mathInline,
                            optional, space, spaces, withRaw, (<|>))
import Text.Pandoc.Readers.LaTeX.Types (ExpansionPoint (..), Macro (..),
                                        ArgSpec (..), Tok (..), TokType (..))
import Text.Pandoc.Shared
import Text.Parsec.Pos

-- import Debug.Trace (traceShowId)

newtype DottedNum = DottedNum [Int]
  deriving (Show)

renderDottedNum :: DottedNum -> String
renderDottedNum (DottedNum xs) =
  intercalate "." (map show xs)

incrementDottedNum :: Int -> DottedNum -> DottedNum
incrementDottedNum level (DottedNum ns) = DottedNum $
  case reverse (take level (ns ++ repeat 0)) of
       (x:xs) -> reverse (x+1 : xs)
       []     -> []  -- shouldn't happen

data LaTeXState = LaTeXState{ sOptions       :: ReaderOptions
                            , sMeta          :: Meta
                            , sQuoteContext  :: QuoteContext
                            , sMacros        :: M.Map Text Macro
                            , sContainers    :: [String]
                            , sHeaders       :: M.Map Inlines String
                            , sLogMessages   :: [LogMessage]
                            , sIdentifiers   :: Set.Set String
                            , sVerbatimMode  :: Bool
                            , sCaption       :: (Maybe Inlines, Maybe String)
                            , sInListItem    :: Bool
                            , sInTableCell   :: Bool
                            , sLastHeaderNum :: DottedNum
                            , sLastFigureNum :: DottedNum
                            , sLabels        :: M.Map String [Inline]
                            , sHasChapters   :: Bool
                            , sToggles       :: M.Map String Bool
                            }
     deriving Show

defaultLaTeXState :: LaTeXState
defaultLaTeXState = LaTeXState{ sOptions       = def
                              , sMeta          = nullMeta
                              , sQuoteContext  = NoQuote
                              , sMacros        = M.empty
                              , sContainers    = []
                              , sHeaders       = M.empty
                              , sLogMessages   = []
                              , sIdentifiers   = Set.empty
                              , sVerbatimMode  = False
                              , sCaption       = (Nothing, Nothing)
                              , sInListItem    = False
                              , sInTableCell   = False
                              , sLastHeaderNum = DottedNum []
                              , sLastFigureNum = DottedNum []
                              , sLabels        = M.empty
                              , sHasChapters   = False
                              , sToggles       = M.empty
                              }

instance PandocMonad m => HasQuoteContext LaTeXState m where
  getQuoteContext = sQuoteContext <$> getState
  withQuoteContext context parser = do
    oldState <- getState
    let oldQuoteContext = sQuoteContext oldState
    setState oldState { sQuoteContext = context }
    result <- parser
    newState <- getState
    setState newState { sQuoteContext = oldQuoteContext }
    return result

instance HasLogMessages LaTeXState where
  addLogMessage msg st = st{ sLogMessages = msg : sLogMessages st }
  getLogMessages st = reverse $ sLogMessages st

instance HasIdentifierList LaTeXState where
  extractIdentifierList     = sIdentifiers
  updateIdentifierList f st = st{ sIdentifiers = f $ sIdentifiers st }

instance HasIncludeFiles LaTeXState where
  getIncludeFiles = sContainers
  addIncludeFile f s = s{ sContainers = f : sContainers s }
  dropLatestIncludeFile s = s { sContainers = drop 1 $ sContainers s }

instance HasHeaderMap LaTeXState where
  extractHeaderMap     = sHeaders
  updateHeaderMap f st = st{ sHeaders = f $ sHeaders st }

instance HasMacros LaTeXState where
  extractMacros  st  = sMacros st
  updateMacros f st  = st{ sMacros = f (sMacros st) }

instance HasReaderOptions LaTeXState where
  extractReaderOptions = sOptions

instance HasMeta LaTeXState where
  setMeta field val st =
    st{ sMeta = setMeta field val $ sMeta st }
  deleteMeta field st =
    st{ sMeta = deleteMeta field $ sMeta st }

instance Default LaTeXState where
  def = defaultLaTeXState

type LP m = ParserT [Tok] LaTeXState m

withVerbatimMode :: PandocMonad m => LP m a -> LP m a
withVerbatimMode parser = do
  updateState $ \st -> st{ sVerbatimMode = True }
  result <- parser
  updateState $ \st -> st{ sVerbatimMode = False }
  return result

rawLaTeXParser :: (PandocMonad m, HasMacros s, HasReaderOptions s)
               => Bool -> LP m a -> LP m a -> ParserT String s m (a, String)
rawLaTeXParser retokenize parser valParser = do
  inp <- getInput
  let toks = tokenize "source" $ T.pack inp
  pstate <- getState
  let lstate = def{ sOptions = extractReaderOptions pstate }
  let lstate' = lstate { sMacros = extractMacros pstate }
  let rawparser = (,) <$> withRaw valParser <*> getState
  res' <- lift $ runParserT (snd <$> withRaw parser) lstate "chunk" toks
  case res' of
       Left _    -> mzero
       Right toks' -> do
         res <- lift $ runParserT (do when retokenize $ do
                                        -- retokenize, applying macros
                                        doMacros
                                        ts <- many (satisfyTok (const True))
                                        setInput ts
                                      rawparser)
                        lstate' "chunk" toks'
         case res of
              Left _    -> mzero
              Right ((val, raw), st) -> do
                updateState (updateMacros (sMacros st <>))
                _ <- takeP (T.length (untokenize toks'))
                return (val, T.unpack (untokenize raw))

applyMacros :: (PandocMonad m, HasMacros s, HasReaderOptions s)
            => String -> ParserT String s m String
applyMacros s = (guardDisabled Ext_latex_macros >> return s) <|>
   do let retokenize = doMacros *>
             (toksToString <$> many (satisfyTok (const True)))
      pstate <- getState
      let lstate = def{ sOptions = extractReaderOptions pstate
                      , sMacros  = extractMacros pstate }
      res <- runParserT retokenize lstate "math" (tokenize "math" (T.pack s))
      case res of
           Left e   -> fail (show e)
           Right s' -> return s'
tokenize :: SourceName -> Text -> [Tok]
tokenize sourcename = totoks (initialPos sourcename)

totoks :: SourcePos -> Text -> [Tok]
totoks pos t =
  case T.uncons t of
       Nothing        -> []
       Just (c, rest)
         | c == '\n' ->
           Tok pos Newline "\n"
           : totoks (setSourceColumn (incSourceLine pos 1) 1) rest
         | isSpaceOrTab c ->
           let (sps, rest') = T.span isSpaceOrTab t
           in  Tok pos Spaces sps
               : totoks (incSourceColumn pos (T.length sps))
                 rest'
         | isAlphaNum c ->
           let (ws, rest') = T.span isAlphaNum t
           in  Tok pos Word ws
               : totoks (incSourceColumn pos (T.length ws)) rest'
         | c == '%' ->
           let (cs, rest') = T.break (== '\n') rest
           in  Tok pos Comment ("%" <> cs)
               : totoks (incSourceColumn pos (1 + T.length cs)) rest'
         | c == '\\' ->
           case T.uncons rest of
                Nothing -> [Tok pos (CtrlSeq " ") "\\"]
                Just (d, rest')
                  | isLetterOrAt d ->
                      -- \makeatletter is common in macro defs;
                      -- ideally we should make tokenization sensitive
                      -- to \makeatletter and \makeatother, but this is
                      -- probably best for now
                      let (ws, rest'') = T.span isLetterOrAt rest
                          (ss, rest''') = T.span isSpaceOrTab rest''
                      in  Tok pos (CtrlSeq ws) ("\\" <> ws <> ss)
                          : totoks (incSourceColumn pos
                               (1 + T.length ws + T.length ss)) rest'''
                  | isSpaceOrTab d || d == '\n' ->
                      let (w1, r1) = T.span isSpaceOrTab rest
                          (w2, (w3, r3)) = case T.uncons r1 of
                                          Just ('\n', r2)
                                                  -> (T.pack "\n",
                                                        T.span isSpaceOrTab r2)
                                          _ -> (mempty, (mempty, r1))
                          ws = "\\" <> w1 <> w2 <> w3
                      in  case T.uncons r3 of
                               Just ('\n', _) ->
                                 Tok pos (CtrlSeq " ") ("\\" <> w1)
                                 : totoks (incSourceColumn pos (T.length ws))
                                   r1
                               _ ->
                                 Tok pos (CtrlSeq " ") ws
                                 : totoks (incSourceColumn pos (T.length ws))
                                   r3
                  | otherwise  ->
                      Tok pos (CtrlSeq (T.singleton d)) (T.pack [c,d])
                      : totoks (incSourceColumn pos 2) rest'
         | c == '#' ->
           let (t1, t2) = T.span (\d -> d >= '0' && d <= '9') rest
           in  case safeRead (T.unpack t1) of
                    Just i ->
                       Tok pos (Arg i) ("#" <> t1)
                       : totoks (incSourceColumn pos (1 + T.length t1)) t2
                    Nothing ->
                       Tok pos Symbol "#"
                       : totoks (incSourceColumn pos 1) t2
         | c == '^' ->
           case T.uncons rest of
                Just ('^', rest') ->
                  case T.uncons rest' of
                       Just (d, rest'')
                         | isLowerHex d ->
                           case T.uncons rest'' of
                                Just (e, rest''') | isLowerHex e ->
                                  Tok pos Esc2 (T.pack ['^','^',d,e])
                                  : totoks (incSourceColumn pos 4) rest'''
                                _ ->
                                  Tok pos Esc1 (T.pack ['^','^',d])
                                  : totoks (incSourceColumn pos 3) rest''
                         | d < '\128' ->
                                  Tok pos Esc1 (T.pack ['^','^',d])
                                  : totoks (incSourceColumn pos 3) rest''
                       _ -> Tok pos Symbol "^" :
                            Tok (incSourceColumn pos 1) Symbol "^" :
                            totoks (incSourceColumn pos 2) rest'
                _ -> Tok pos Symbol "^"
                     : totoks (incSourceColumn pos 1) rest
         | otherwise ->
           Tok pos Symbol (T.singleton c) : totoks (incSourceColumn pos 1) rest

isSpaceOrTab :: Char -> Bool
isSpaceOrTab ' '  = True
isSpaceOrTab '\t' = True
isSpaceOrTab _    = False

isLetterOrAt :: Char -> Bool
isLetterOrAt '@' = True
isLetterOrAt c   = isLetter c

isLowerHex :: Char -> Bool
isLowerHex x = x >= '0' && x <= '9' || x >= 'a' && x <= 'f'

untokenize :: [Tok] -> Text
untokenize = mconcat . map untoken

untoken :: Tok -> Text
untoken (Tok _ _ t) = t

toksToString :: [Tok] -> String
toksToString = T.unpack . untokenize

satisfyTok :: PandocMonad m => (Tok -> Bool) -> LP m Tok
satisfyTok f =
  try $ do
    res <- tokenPrim (T.unpack . untoken) updatePos matcher
    doMacros -- apply macros on remaining input stream
    return res
  where matcher t | f t       = Just t
                  | otherwise = Nothing
        updatePos :: SourcePos -> Tok -> [Tok] -> SourcePos
        updatePos _spos _ (Tok pos _ _ : _) = pos
        updatePos spos _ []                 = incSourceColumn spos 1

doMacros :: PandocMonad m => LP m ()
doMacros = do
  verbatimMode <- sVerbatimMode <$> getState
  unless verbatimMode $ do
    mbNewInp <- getInput >>= doMacros' 1
    case mbNewInp of
         Nothing  -> return ()
         Just inp -> setInput inp

doMacros' :: PandocMonad m => Int -> [Tok] -> LP m (Maybe [Tok])
doMacros' n inp = do
  case inp of
     Tok spos (CtrlSeq "begin") _ : Tok _ Symbol "{" :
      Tok _ Word name : Tok _ Symbol "}" : ts
        -> handleMacros n spos name ts
     Tok spos (CtrlSeq "end") _ : Tok _ Symbol "{" :
      Tok _ Word name : Tok _ Symbol "}" : ts
        -> handleMacros n spos ("end" <> name) ts
     Tok _ (CtrlSeq "expandafter") _ : t : ts
        -> (fmap (combineTok t)) <$> doMacros' n ts
     Tok spos (CtrlSeq name) _ : ts
        -> handleMacros n spos name ts
     _ -> return Nothing

  where
    combineTok (Tok spos (CtrlSeq name) x) (Tok _ Word w : ts)
      | T.all isLetterOrAt w =
        Tok spos (CtrlSeq (name <> w)) (x1 <> w <> x2) : ts
          where (x1, x2) = T.break isSpaceOrTab x
    combineTok t ts = t:ts

    matchTok (Tok _ toktype txt) =
      satisfyTok (\(Tok _ toktype' txt') ->
                    toktype == toktype' &&
                    txt == txt')

    matchPattern toks = try $ mapM_ matchTok toks

    getargs argmap [] = return argmap
    getargs argmap (Pattern toks : rest) = try $ do
       matchPattern toks
       getargs argmap rest
    getargs argmap (ArgNum i : Pattern toks : rest) =
      try $ do
        x <- mconcat <$> manyTill bracedOrToken (matchPattern toks)
        getargs (M.insert i x argmap) rest
    getargs argmap (ArgNum i : rest) = do
      x <- try $ spaces >> bracedOrToken
      getargs (M.insert i x argmap) rest

    addTok False args spos (Tok _ (Arg i) _) acc =
       case M.lookup i args of
            Nothing -> mzero
            Just xs -> foldr (addTok True args spos) acc xs
    -- see #4007
    addTok _ _ spos (Tok _ (CtrlSeq x) txt)
           acc@(Tok _ Word _ : _)
      | not (T.null txt)
      , isLetter (T.last txt) =
        Tok spos (CtrlSeq x) (txt <> " ") : acc
    addTok _ _ spos t acc = setpos spos t : acc

    handleMacros n' spos name ts = do
      when (n' > 20)  -- detect macro expansion loops
        $ throwError $ PandocMacroLoop (T.unpack name)
      macros <- sMacros <$> getState
      case M.lookup name macros of
           Nothing -> return Nothing
           Just (Macro expansionPoint argspecs optarg newtoks) -> do
             setInput ts
             args <- case optarg of
                          Nothing -> getargs M.empty argspecs
                          Just o  -> do
                             x <- option o bracketedToks
                             getargs (M.singleton 1 x) argspecs
             -- first boolean param is true if we're tokenizing
             -- an argument (in which case we don't want to
             -- expand #1 etc.)
             ts' <- getInput
             let result = foldr (addTok False args spos) ts' newtoks
             case expansionPoint of
               ExpandWhenUsed    ->
                  doMacros' (n' + 1) result >>=
                    maybe (return (Just result)) (return . Just)
               ExpandWhenDefined -> return $ Just result

setpos :: SourcePos -> Tok -> Tok
setpos spos (Tok _ tt txt) = Tok spos tt txt

anyControlSeq :: PandocMonad m => LP m Tok
anyControlSeq = satisfyTok isCtrlSeq

isCtrlSeq :: Tok -> Bool
isCtrlSeq (Tok _ (CtrlSeq _) _) = True
isCtrlSeq _                     = False

anySymbol :: PandocMonad m => LP m Tok
anySymbol = satisfyTok isSymbolTok

isSymbolTok :: Tok -> Bool
isSymbolTok (Tok _ Symbol _) = True
isSymbolTok _                = False

isWordTok :: Tok -> Bool
isWordTok (Tok _ Word _) = True
isWordTok _              = False

isArgTok :: Tok -> Bool
isArgTok (Tok _ (Arg _) _) = True
isArgTok _                 = False

spaces :: PandocMonad m => LP m ()
spaces = skipMany (satisfyTok (tokTypeIn [Comment, Spaces, Newline]))

spaces1 :: PandocMonad m => LP m ()
spaces1 = skipMany1 (satisfyTok (tokTypeIn [Comment, Spaces, Newline]))

tokTypeIn :: [TokType] -> Tok -> Bool
tokTypeIn toktypes (Tok _ tt _) = tt `elem` toktypes

controlSeq :: PandocMonad m => Text -> LP m Tok
controlSeq name = satisfyTok isNamed
  where isNamed (Tok _ (CtrlSeq n) _) = n == name
        isNamed _                     = False

symbol :: PandocMonad m => Char -> LP m Tok
symbol c = satisfyTok isc
  where isc (Tok _ Symbol d) = case T.uncons d of
                                    Just (c',_) -> c == c'
                                    _           -> False
        isc _ = False

symbolIn :: PandocMonad m => [Char] -> LP m Tok
symbolIn cs = satisfyTok isInCs
  where isInCs (Tok _ Symbol d) = case T.uncons d of
                                       Just (c,_) -> c `elem` cs
                                       _          -> False
        isInCs _ = False

sp :: PandocMonad m => LP m ()
sp = whitespace <|> endline

whitespace :: PandocMonad m => LP m ()
whitespace = () <$ satisfyTok isSpaceTok

isSpaceTok :: Tok -> Bool
isSpaceTok (Tok _ Spaces _) = True
isSpaceTok _                = False

newlineTok :: PandocMonad m => LP m ()
newlineTok = () <$ satisfyTok isNewlineTok

isNewlineTok :: Tok -> Bool
isNewlineTok (Tok _ Newline _) = True
isNewlineTok _                 = False

comment :: PandocMonad m => LP m ()
comment = () <$ satisfyTok isCommentTok

isCommentTok :: Tok -> Bool
isCommentTok (Tok _ Comment _) = True
isCommentTok _                 = False

anyTok :: PandocMonad m => LP m Tok
anyTok = satisfyTok (const True)

singleChar :: PandocMonad m => LP m Tok
singleChar = try $ do
  Tok pos toktype t <- satisfyTok (tokTypeIn [Word, Symbol])
  guard $ not $ toktype == Symbol &&
                T.any (`Set.member` specialChars) t
  if T.length t > 1
     then do
       let (t1, t2) = (T.take 1 t, T.drop 1 t)
       inp <- getInput
       setInput $ Tok (incSourceColumn pos 1) toktype t2 : inp
       return $ Tok pos toktype t1
     else return $ Tok pos toktype t

specialChars :: Set.Set Char
specialChars = Set.fromList "#$%&~_^\\{}"

endline :: PandocMonad m => LP m ()
endline = try $ do
  newlineTok
  lookAhead anyTok
  notFollowedBy blankline

blankline :: PandocMonad m => LP m ()
blankline = try $ skipMany whitespace *> newlineTok

primEscape :: PandocMonad m => LP m Char
primEscape = do
  Tok _ toktype t <- satisfyTok (tokTypeIn [Esc1, Esc2])
  case toktype of
       Esc1 -> case T.uncons (T.drop 2 t) of
                    Just (c, _)
                      | c >= '\64' && c <= '\127' -> return (chr (ord c - 64))
                      | otherwise                 -> return (chr (ord c + 64))
                    Nothing -> fail "Empty content of Esc1"
       Esc2 -> case safeRead ('0':'x':T.unpack (T.drop 2 t)) of
                    Just x  -> return (chr x)
                    Nothing -> fail $ "Could not read: " ++ T.unpack t
       _    -> fail "Expected an Esc1 or Esc2 token" -- should not happen

bgroup :: PandocMonad m => LP m Tok
bgroup = try $ do
  skipMany sp
  symbol '{' <|> controlSeq "bgroup" <|> controlSeq "begingroup"

egroup :: PandocMonad m => LP m Tok
egroup = symbol '}' <|> controlSeq "egroup" <|> controlSeq "endgroup"

grouped :: (PandocMonad m,  Monoid a) => LP m a -> LP m a
grouped parser = try $ do
  bgroup
  -- first we check for an inner 'grouped', because
  -- {{a,b}} should be parsed the same as {a,b}
  try (grouped parser <* egroup) <|> (mconcat <$> manyTill parser egroup)

braced' :: PandocMonad m => LP m Tok -> Int -> LP m [Tok]
braced' getTok n =
  handleEgroup <|> handleBgroup <|> handleOther
  where handleEgroup = do
          t <- egroup
          if n == 1
             then return []
             else (t:) <$> braced' getTok (n - 1)
        handleBgroup = do
          t <- bgroup
          (t:) <$> braced' getTok (n + 1)
        handleOther = do
          t <- getTok
          (t:) <$> braced' getTok n

braced :: PandocMonad m => LP m [Tok]
braced = bgroup *> braced' anyTok 1

-- URLs require special handling, because they can contain %
-- characters.  So we retonenize comments as we go...
bracedUrl :: PandocMonad m => LP m [Tok]
bracedUrl = bgroup *> braced' (retokenizeComment >> anyTok) 1

-- For handling URLs, which allow literal % characters...
retokenizeComment :: PandocMonad m => LP m ()
retokenizeComment = (do
  Tok pos Comment txt <- satisfyTok isCommentTok
  let updPos (Tok pos' toktype' txt') =
        Tok (incSourceColumn (incSourceLine pos' (sourceLine pos - 1))
             (sourceColumn pos)) toktype' txt'
  let newtoks = map updPos $ tokenize (sourceName pos) $ T.tail txt
  getInput >>= setInput . ((Tok pos Symbol "%" : newtoks) ++))
    <|> return ()

bracedOrToken :: PandocMonad m => LP m [Tok]
bracedOrToken = braced <|> ((:[]) <$> (anyControlSeq <|> singleChar))

bracketed :: PandocMonad m => Monoid a => LP m a -> LP m a
bracketed parser = try $ do
  symbol '['
  mconcat <$> manyTill parser (symbol ']')

bracketedToks :: PandocMonad m => LP m [Tok]
bracketedToks = do
  symbol '['
  mconcat <$> manyTill (braced <|> (:[]) <$> anyTok) (symbol ']')

parenWrapped :: PandocMonad m => Monoid a => LP m a -> LP m a
parenWrapped parser = try $ do
  symbol '('
  mconcat <$> manyTill parser (symbol ')')

dimenarg :: PandocMonad m => LP m Text
dimenarg = try $ do
  ch  <- option False $ True <$ symbol '='
  Tok _ _ s <- satisfyTok isWordTok
  guard $ T.take 2 (T.reverse s) `elem`
           ["pt","pc","in","bp","cm","mm","dd","cc","sp"]
  let num = T.take (T.length s - 2) s
  guard $ T.length num > 0
  guard $ T.all isDigit num
  return $ T.pack ['=' | ch] <> s

ignore :: (Monoid a, PandocMonad m) => String -> ParserT s u m a
ignore raw = do
  pos <- getPosition
  report $ SkippedContent raw pos
  return mempty

withRaw :: PandocMonad m => LP m a -> LP m (a, [Tok])
withRaw parser = do
  inp <- getInput
  result <- parser
  nxt <- option (Tok (initialPos "source") Word "") (lookAhead anyTok)
  let raw = takeWhile (/= nxt) inp
  return (result, raw)
