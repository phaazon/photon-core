-----------------------------------------------------------------------------
-- |
-- Copyright   : (C) 2015 Dimitri Sabadie
-- License     : BSD3
--
-- Maintainer  : Dimitri Sabadie <dimitri.sabadie@gmail.com>
-- Stability   : experimental
-- Portability : portable
--
-- Position in space is a 3-float vector.
----------------------------------------------------------------------------

module Quaazar.Geometry.Position (
    -- * Position
    Position(..)
  , pos
  ) where

import Data.Aeson
import Data.Aeson.Types ( typeMismatch )
import Linear ( V3(..) )

-- |Position in space a.k.a. space coordinates.
newtype Position = Position { unPosition :: V3 Float } deriving (Eq,Ord,Show)

instance FromJSON Position where
  parseJSON v = do
    a <- parseJSON v
    case a of
      [x,y,z] -> return (pos x y z)
      _       -> typeMismatch "position" v

-- |Build a 'Position' from /x/, /y/ and /z/ components.
pos :: Float -> Float -> Float -> Position
pos x y z = Position (V3 x y z)
