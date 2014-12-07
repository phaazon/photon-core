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

module Photon.Render.GL.Trans (
    -- *
  ) where

import Control.Applicative
import Control.Lens hiding ( view )
import Control.Monad as M ( forM_, unless, when )
import Control.Monad.Trans ( MonadIO(..) )
import Control.Monad.Trans.State ( StateT, evalStateT )
import Data.Bits ( (.|.) )
import Data.Vector as V ( Vector, (!), forM_, fromList, length, zip )
import Foreign.Ptr ( nullPtr )
import Graphics.Rendering.OpenGL.Raw
import Linear
import Photon.Core.Color
import Photon.Core.Effect
import Photon.Core.Entity
import Photon.Core.Light
import Photon.Core.Material
import Photon.Core.Mesh
import Photon.Core.Projection ( projectionMatrix )
import Photon.Render.GL.Entity
import Photon.Render.GL.Framebuffer
import Photon.Render.GL.Mesh
import Photon.Render.GL.Offscreen
import Photon.Render.GL.Primitive
import Photon.Render.GL.Shader
import Photon.Render.GL.Texture
import Photon.Render.GL.VertexArray
import Photon.Render.Renderer ( RenderEffect(..) )
import Photon.Utils.FreeList
import Prelude hiding ( drop )

data SceneUniforms = SceneUniforms {
    _sceneUniEye        :: Uniform (V3 Float)
  , _sceneUniProjView   :: Uniform (M44 Float)
  , _sceneUniModel      :: Uniform (M44 Float)
  , _sceneUniMatDiffAlb :: Uniform (V3 Float)
  , _sceneUniMatSpecAlb :: Uniform (V3 Float)
  , _sceneUniMatShn     :: Uniform Float
  , _sceneUniLigPos     :: Uniform (V3 Float)
  , _sceneUniLigCol     :: Uniform (V3 Float)
  , _sceneUniLigPow     :: Uniform Float
  , _sceneUniLigRad     :: Uniform Float
  }

makeLenses ''SceneUniforms

data OpenGLSt = OpenGLSt {
    -- |A table that turns dispatch handles into specfic handles.
    -- That table is used per-type to resolve values at lookups.
    _glStDispatch      :: (FreeList,Vector Int)
    -- |OpenGL side lights are just lights.
  , _glStLights        :: (FreeList,Vector Light)
    -- |OpenGL side materiels are just materials as well.
  , _glStMaterials     :: (FreeList,Vector Material)
    -- |OpenGL meshes are gpu data glued with a material (through lookup).
  , _glStMeshes        :: (FreeList,Vector (GPUMesh,H Material))
    -- |The OpenGL mesh cache has the same size that the materials. The cache
    -- is used to instantiate meshes in space
  , _glStMeshCache     :: Vector [(H Mesh,Entity)]
    -- |The OpenGL light cache is used to instantiate lights in space.
  , _glStLightCache    :: Vector (H Light,Entity)
    -- |Accumulation buffer.
  , _glStAccumOff      :: Offscreen
    -- |Shadow buffer.
  , _glStShadowOff     :: Offscreen
    -- |Lighting shader.
  , _glStLightShader   :: Shader
    -- |Scene uniforms.
  , _glStSceneUniforms :: SceneUniforms
  }

makeLenses ''OpenGLSt

newtype OpenGLT m a = OpenGLT (StateT OpenGLSt m a) deriving (Applicative,Functor,Monad)

dispatchHandle :: (Monad m) => Managed a -> StateT OpenGLSt m Int
dispatchHandle (Managed (H h) _) = use $ singular $ glStDispatch . _2 . ix h

-------------------------------------------------------------------------------
-- Manager
instance (Functor m,Monad m) => Manager (OpenGLT m) where
  manage a = OpenGLT $ do
    (h,fl) <- uses (glStDispatch._1) nextFree
    glStDispatch . _1 .= fl
    sz <- uses (glStDispatch . _2) V.length
    unless (h < sz) (glStDispatch . _2 %= flip snoc 0)
    return (Managed (H h) a)
  drop (Managed (H h) _) = OpenGLT (glStDispatch . _1 %= recycleFree h)

-------------------------------------------------------------------------------
-- Light support
instance (Functor m,Monad m) => Effect LightSpawned (OpenGLT m) where
  react (LightSpawned (Managed (H dHandle) l)) = OpenGLT $ do
    -- light handle
    (lightHandle,lightFL) <- uses (glStLights._1) nextFree
    glStLights . _1 .= lightFL
    -- double indirection
    glStDispatch . _2 . ix dHandle .= lightHandle
    -- storing
    sz <- uses (glStLights._2) V.length
    if lightHandle < sz then
      glStLights . _2 . ix lightHandle .= l
      else
        glStLights . _2 %= flip snoc l

instance (Functor m,Monad m) => Effect LightLost (OpenGLT m) where
  react (LightLost lig) = OpenGLT $ do
    lightHandle <- dispatchHandle lig
    glStLights . _1 %= recycleFree lightHandle

instance (Functor m,Monad m) => Effect LightEffect (OpenGLT m) where
  react e = OpenGLT $ case e of
    ColorChanged lig col -> do
      lh <- dispatchHandle lig
      glStLights . _2 . ix lh . ligColor .= col
    PowerChanged lig power -> do
      lh <- dispatchHandle lig
      glStLights . _2 . ix lh . ligPower .= power
    RadiusChanged lig radius -> do
      lh <- dispatchHandle lig
      glStLights . _2 . ix lh . ligRadius .= radius
    CastShadowsChanged lig sh -> do
      lh <- dispatchHandle lig
      glStLights . _2 . ix lh . ligCastShadows .= sh

-------------------------------------------------------------------------------
-- Material support
initMaterials :: (FreeList,Vector Material)
initMaterials = (freeListMin 1,fromList [Material diff spec 10])
  where
    diff = albedo 0.6 0.6 0.6
    spec = albedo 0.6 0.6 0.6

instance (Functor m,Monad m) => Effect MaterialSpawned (OpenGLT m) where
  react (MaterialSpawned (Managed (H dHandle) m)) = OpenGLT $ do
    -- material handle
    (matHandle,matFL) <- uses (glStMaterials._1) nextFree
    glStMaterials . _1 .= matFL
    -- double indirection
    glStDispatch . _2 . ix dHandle .= matHandle
    -- storing
    sz <- uses (glStMaterials._2) V.length
    if matHandle < sz then
      glStMaterials . _2 . ix matHandle .= m
      else do
        glStMaterials . _2 %= flip snoc m
        glStMeshCache %= flip snoc []

instance (Functor m,Monad m) => Effect MaterialLost (OpenGLT m) where
  react (MaterialLost m) = OpenGLT $ do
    matHandle <- dispatchHandle m
    glStMaterials . _1 %= recycleFree matHandle

instance (Functor m,Monad m) => Effect MaterialEffect (OpenGLT m) where
  react e = OpenGLT $ case e of
    DiffuseChanged m diff -> do
      mh <- dispatchHandle m
      glStMaterials . _2 . ix mh . matDiffuseAlbedo .= diff
    SpecularChanged m spec -> do
      mh <- dispatchHandle m
      glStMaterials . _2 . ix mh . matSpecularAlbedo .= spec
    ShininessChanged m shn -> do
      mh <- dispatchHandle m
      glStMaterials . _2 . ix mh . matShininess .= shn

-------------------------------------------------------------------------------
-- Mesh support
instance (Functor m,MonadIO m) => Effect MeshSpawned (OpenGLT m) where
  react (MeshSpawned (Managed (H dHandle) m)) = OpenGLT $ do
    -- mesh handle
    (meshHandle,meshFL) <- uses (glStMeshes._1) nextFree
    glStMeshes . _1 .= meshFL
    -- double indirection
    glStDispatch . _2 . ix dHandle .= meshHandle
    -- storing
    gpuData <- liftIO (gpuMesh m)
    sz <- uses (glStMeshes._2) V.length
    if meshHandle < sz then
      glStMeshes . _2 . ix meshHandle . _1 .= gpuData
      else
        glStMeshes . _2 %= flip snoc (gpuData,H 0)

instance (Functor m,Monad m) => Effect MeshLost (OpenGLT m) where
  react (MeshLost m) = OpenGLT $ do
    meshHandle <- dispatchHandle m
    glStMeshes . _1 %= recycleFree meshHandle

instance (Functor m,MonadIO m) => Effect MeshEffect (OpenGLT m) where
  react e = OpenGLT $ case e of
    UseMaterial msh mat -> do
      h <- dispatchHandle msh
      m <- dispatchHandle mat
      glStMeshes . _2 . ix h . _2 .= H m
    RenderMesh m ent -> do
      mshh <- dispatchHandle m
      H math <- use (singular $ glStMeshes . _2 . ix mshh . _2)
      glStMeshCache . ix math %= flip snoc (H mshh,ent)

-------------------------------------------------------------------------------
-- Render support
instance (Functor m,MonadIO m) => Effect RenderEffect (OpenGLT m) where
  react e = OpenGLT $ do
      accumOff <- use glStAccumOff
      lightShader <- use glStLightShader
      ligs <- use (glStLights._2)
      meshCache <- use glStMeshCache
      ligCache <- use glStLightCache
      meshes <- use (glStMeshes._2)
      materials <- use (glStMaterials._2)
      sceneUnis <- use glStSceneUniforms
      shadowOff <- use glStShadowOff
      case e of
        Display cr cg cb proj view -> do
          -- clear the accumulation buffer before starting
          liftIO $ do
            bindFramebuffer (accumOff^.offscreenFB) Write
            glClearColor 0 0 0 1
            glClear gl_COLOR_BUFFER_BIT
            -- FIXME: we could also enable blending here, and set ONE ZERO for each light

            -- first, send camera information
            useShader lightShader
            let
              projMatrix = projectionMatrix proj
              viewMatrix = cameraTransform view
            sceneUnis^.sceneUniEye @= view^.entityPosition
            sceneUnis^.sceneUniProjView @= projMatrix !*! viewMatrix

            V.forM_ ligCache $ \(H ligh,ligE) -> do
              let lig = ligs ! ligh
              useShader lightShader
              sceneUnis^.sceneUniLigCol @= unColor (lig^.ligColor)
              sceneUnis^.sceneUniLigPow @= lig^.ligPower
              sceneUnis^.sceneUniLigRad @= lig^.ligRadius

              -- clear the shadow offscreen
              bindFramebuffer (shadowOff^.offscreenFB) Write
              glClearColor 1 1 1 1
              glClear (gl_DEPTH_BUFFER_BIT .|. gl_COLOR_BUFFER_BIT)

              -- if the light casts shadows, we can modify the shadow map
              -- TODO: this can be preprocessed while generating the cache
              when (lig^.ligCastShadows) $ do
                return ()
 
              -- prepare the render of the scene
              bindFramebuffer (accumOff^.offscreenFB) Write
              bindTextureAt (shadowOff^.offscreenTex) 0

              -- this part ensures we leave the scene framebuffer clean and that
              -- no blending will occur during the scene render
              glEnable gl_DEPTH_TEST
              glDisable gl_BLEND
              glClearColor (realToFrac cr) (realToFrac cb) (realToFrac cg) 1
              glClear (gl_COLOR_BUFFER_BIT .|. gl_DEPTH_BUFFER_BIT)

              sceneUnis^.sceneUniLigPos @= ligE^.entityPosition

              -- the zip might be slow
              V.forM_ (V.zip materials meshCache) $ \(mat,mshs) -> do
                -- send the material
                let Material dalb salb shn = mat
                sceneUnis^.sceneUniMatDiffAlb @= unAlbedo dalb
                sceneUnis^.sceneUniMatSpecAlb @= unAlbedo salb
                sceneUnis^.sceneUniMatShn @= shn
                -- then proceed to the render of all concerned meshes
                M.forM_ mshs $ \(H mshh,mshE) -> do
                  let
                    msh = fst (meshes ! mshh)
                    vnb = fromIntegral (msh^.gpuMeshVertNB)
                  bindVertexArray (msh^.gpuMeshVAO)
                  sceneUnis^.sceneUniModel @= entityTransform mshE
                  glDrawElements (fromPrimitive $ msh^.gpuMeshPrim) vnb gl_UNSIGNED_INT nullPtr
                  
-------------------------------------------------------------------------------
-- Miscellaneous
empty2 :: (FreeList,Vector a)
empty2 = (freeList,empty)
