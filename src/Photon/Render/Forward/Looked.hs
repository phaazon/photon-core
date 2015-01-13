-----------------------------------------------------------------------------
-- |
-- Copyright   : (C) 2014 Dimitri Sabadie
-- License     : BSD3
--
-- Maintainer  : Dimitri Sabadie <dimitri.sabadie@gmail.com>
-- Stability   : experimental
-- Portability : portable
--
----------------------------------------------------------------------------

module Photon.Render.Forward.Looked where

import Photon.Render.Camera ( GPUCamera )
import Photon.Render.Forward.Accumulation
import Photon.Render.Forward.Lighting
import Photon.Render.Forward.Lit ( Lit(..) )
import Photon.Render.Forward.Shadowing

newtype Looked = Looked { unLooked :: Lighting -> Shadowing -> Accumulation -> IO () }

look :: GPUCamera -> Lit -> Looked
look gpucam lit = Looked look_
  where
    look_ lighting shadowing accumulation = do
      purgeAccumulationFramebuffer accumulation
      pushCameraToLighting lighting gpucam
      unLit lit lighting shadowing accumulation