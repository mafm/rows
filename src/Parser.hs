{-# language FlexibleContexts #-}
{-# language OverloadedLists #-}
{-# language OverloadedStrings #-}
{-# language TypeFamilies #-}
module Parser where

import Control.Applicative ((<**>), (<|>), many, optional)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Text (Text)

import qualified Data.List.NonEmpty as NonEmpty

import qualified Data.Text as Text

import Text.Megaparsec (MonadParsec, between, failure, try)
import Text.Megaparsec.Char
  (lowerChar, upperChar, space1, space, string, alphaNumChar)
import Text.Megaparsec.Char.Lexer (lexeme, symbol)

import qualified Text.Megaparsec as Parse

import Label
import Tm
import Ty

{-# inline chainl1Try #-}
chainl1Try :: MonadParsec e s m => m a -> m (a -> a -> a) -> m a
chainl1Try p op = scan
  where
    scan = p <**> rst
    rst = try ((\f y g x -> g (f x y)) <$> op <*> p) <*> rst <|> pure id

ident :: MonadParsec e Text m => m Text
ident = fmap Text.pack $ (:) <$> lowerChar <*> many alphaNumChar

label :: MonadParsec e Text m => m Label
label = Label <$> ident

parseTm :: MonadParsec e Text m => m (Tm Text Text)
parseTm = expr
  where
    expr =
      lexeme space $
      lambda <|>
      ann

    ann =
      (\e -> maybe e (TmAnn e)) <$>
      lexeme space restrict <*>
      optional (symbol space ":" *> parseTy)

    lambda =
      lam <$ symbol space "\\" <*>
      lexeme space ident <* symbol space "->" <*>
      expr

    restrict =
      foldl (\a b -> TmApp (TmRestrict b) a) <$>
      app <*>
      many (try (space *> symbol space "-") *> label)

    app = chainl1Try select (TmApp <$ space1)

    select =
      foldl (\a b -> TmApp (TmSelect b) a) <$>
      atom <*>
      many (try (space *> symbol space ".") *> label)

    atom =
      var <|>
      record <|>
      bracketed <|>
      variant

    keywords :: [Text]
    keywords = ["is"]

    var = do
      i <- ident
      if i `elem` keywords
        then
          failure
            (Just $ Parse.Tokens $ NonEmpty.fromList $ Text.unpack i)
            [Parse.Label ('v' :| "ariable")]
        else pure $ TmVar i

    extendSeq =
      tmExtend <$ symbol space "," <*>
      lexeme space label <* symbol space "=" <*>
      expr <*>
      (extendSeq <|> TmEmpty <$ string "}")

    record =
      symbol space "*{" *>
      (tmExtend <$>
       lexeme space label <* symbol space "=" <*>
       expr <*>
       (extendSeq <|>
        symbol space "|" *> expr <* string "}")

       <|>

       TmEmpty <$ string "}")

    bracketed = between (symbol space "(") (string ")") expr

    matchSeq =
      tmMatch <$ symbol space "," <*>
      try (expr <* symbol space "is") <*>
      lexeme space label <* symbol space "?" <*>
      expr <*>
      (matchSeq <|>
       symbol space "|" *> expr <|>
       pure (lam "x" $ pure "x"))

    embedSeq =
      tmEmbed <$ symbol space "," <*>
      lexeme space label <*>
      embedSeq

      <|>

      symbol space "|" *> expr

    variant =
      between (symbol space "+{") (string "}") $

      tmMatch <$>
      try (expr <* symbol space "is") <*>
      lexeme space label <* symbol space "?" <*>
      expr <*>
      (matchSeq <|> symbol space "|" *> expr)

      <|>

      (\lbl -> either (tmInject lbl) (tmEmbed lbl)) <$>
      lexeme space label <*>
      (fmap Left (symbol space "=" *> expr) <|>
       fmap Right embedSeq)

parseTy :: MonadParsec e Text m => m (Ty Text)
parseTy = ty
  where
    ty = lexeme space arrs

    arrs =
      (\a -> maybe a (tyArr a)) <$>
      app <*>
      optional (try (space *> symbol space "->") *> arrs)

    app = chainl1Try atom (TyApp <$ space1)

    var = TyVar <$> ident

    ctor =
      fmap
        (\x ->
           if x == "Record"
           then TyRecord
           else if x == "Variant"
           then TyVariant
           else TyCtor x) $
      (:) <$> upperChar <*> many alphaNumChar

    extendSeq =
      symbol space "|" *> ty <* string ")"

      <|>

      tyRowExtend <$ symbol space "," <*>
      lexeme space label <* symbol space ":" <*>
      ty <*>
      (extendSeq <|> TyRowEmpty <$ string ")")

    bracketed =
      symbol space "(" *>
      (tyRowExtend <$>
       lexeme space label <* symbol space ":" <*>
       ty <*>
       extendSeq

       <|>

       TyArr <$ symbol space "->" <* string ")"

       <|>

       ty <* string ")"

       <|>

       TyRowEmpty <$ string ")")

    atom =
      var <|>
      ctor <|>
      bracketed
