{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_HADDOCK hide #-}

-- | JWT-style base64 encoding and decoding

module Jose.Internal.Base64 where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Base64.URL as B64

import Jose.Types

-- | Base64 URL encode without padding.
encode :: ByteString -> ByteString
encode = strip . B64.encode
  where
    strip "" = ""
    strip bs = case BC.last bs of
      '=' -> strip $ B.init bs
      _   -> bs

-- | Base64 decode.
decode :: ByteString -> Either JwtError ByteString
decode bs = either (Left . Base64Error) Right $ B64.decode bsPadded
  where
    bsPadded = case B.length bs `mod` 4 of
      3 -> bs `BC.snoc` '='
      2 -> bs `B.append` "=="
      _ -> bs

