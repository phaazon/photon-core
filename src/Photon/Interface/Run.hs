{-# LANGUAGE RankNTypes #-}

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

module Photon.Interface.Run (
    -- * Running photon sessions
    runPhoton
  ) where

import Control.Applicative
import Control.Lens
import Control.Concurrent.STM ( atomically )
import Control.Concurrent.STM.TVar ( TVar, modifyTVar, newTVarIO, readTVar
                                   , writeTVar )
import Control.Monad ( forM_, void )
import Control.Monad.Error.Class ( throwError )
import Control.Monad.Free ( Free(..) )
import Control.Monad.Trans ( lift, liftIO )
import Control.Monad.Trans.Either ( EitherT, hoistEither, runEitherT )
import Control.Monad.Trans.Journal ( evalJournalT )
import Control.Monad.Trans.State ( get, modify, runStateT )
import Data.Bits ( (.|.) )
import qualified Data.Either as Either (Either(..) )
import Data.IORef ( IORef, newIORef, readIORef, writeIORef )
import Data.List ( intercalate )
import Data.Tuple ( swap )
import Graphics.Rendering.OpenGL.Raw
import Graphics.UI.GLFW as GLFW
import Linear hiding ( E )
import Numeric.Natural ( Natural )
import Photon.Core.Color ( Color )
import Photon.Core.Entity
import Photon.Core.Light ( Light )
import Photon.Core.Loader ( Load(..) )
import Photon.Core.Material ( Albedo, Material )
import Photon.Core.Mesh ( Mesh )
import Photon.Core.PostFX ( PostFX )
import Photon.Core.Projection ( Projection )
import Photon.Interface.Command ( Photon )
import qualified Photon.Interface.Command as PC ( PhotonCmd(..) )
import Photon.Interface.Event as E
import Photon.Interface.Shaders ( accumVS, accumFS, lightCubeDepthmapFS
                                , lightCubeDepthmapGS, lightCubeDepthmapVS
                                , lightFS, lightVS )
import Photon.Render.Camera ( GPUCamera(..), gpuCamera )
import Photon.Render.GL.Entity ( cameraTransform, entityTransform )
import Photon.Render.GL.Framebuffer
import Photon.Render.GL.GLObject
import Photon.Render.GL.Offscreen
import Photon.Render.GL.Shader
import Photon.Render.GL.Texture as Tex
import Photon.Render.GL.VertexArray
import Photon.Render.Light ( GPULight(..), gpuLight )
import Photon.Render.Material ( GPUMaterial(..), gpuMaterial )
import Photon.Render.Mesh ( GPUMesh(..), gpuMesh )
import Photon.Render.PostFX ( GPUPostFX(..), gpuPostFX )
import Photon.Render.Shader ( GPUProgram )
import Photon.Utils.Log ( Log(..), LogCommitter(..), LogType(..), sinkLogs )
import Prelude hiding ( Either(Left,Right) )

-- |Helper function to show 'GLSL.Version' type, because they didn’t pick the
-- one from "Data.Version"…
showGLFWVersion :: Version -> String
showGLFWVersion (Version major minor rev) = intercalate "." $ map show [major,minor,rev]

data PhotonDriver = PhotonDriver {
    drvRegisterMesh     :: Mesh -> IO GPUMesh
  , drvRegisterMaterial :: Material -> IO GPUMaterial
  , drvRegisterLight    :: Light -> IO GPULight
  , drvRegisterCamera   :: Projection -> Entity -> IO GPUCamera
  , drvRegisterPostFX   :: PostFX -> IO (Maybe GPUPostFX)
  , drvLoadObject       :: (Load a) => String -> IO (Maybe a)
  , drvRender           :: GPUCamera -> [(GPULight,Entity)] -> [(GPUMaterial,[(GPUMesh,Entity)])] -> IO ()
  , drvPostProcess      :: [GPUPostFX] -> IO ()
  , drvDisplay          :: IO ()
  , drvLog              :: Log -> IO ()
  }

-- |'Lighting' gathers information about lighting in the scene.
data Lighting = Lighting {
    _omniLightProgram :: GPUProgram
  , _lightOff         :: Offscreen
  , _lightUniforms    :: LightingUniforms
  }

data LightingUniforms = LightingUniforms {
    _lightCamProjViewU :: Uniform (M44 Float)
  , _lightModelU       :: Uniform (M44 Float)
  , _lightEyeU         :: Uniform (V3 Float)
  , _lightMatDiffAlbU  :: Uniform Albedo
  , _lightMatSpecAlbU  :: Uniform Albedo
  , _lightMatShnU      :: Uniform Float
  , _lightPosU         :: Uniform (V3 Float) -- FIXME: github issue #22
  , _lightColU         :: Uniform Color
  , _lightPowU         :: Uniform Float
  , _lightRadU         :: Uniform Float
  }

data Shadowing = Shadowing {
    _shadowCubeDepthFB :: Framebuffer
  , _shadowCubeRender          :: Cubemap
  , _shadowCubeDepthmap        :: Cubemap
  , _shadowCubeDepthmapProgram :: GPUProgram
  , _shadowUniforms            :: ShadowingUniforms
  }

data ShadowingUniforms = ShadowingUniforms {
    _shadowLigProjViewsU :: Uniform [M44 Float]
  , _shadowModelU        :: Uniform (M44 Float)
  , _shadowLigPosU       :: Uniform (V3 Float)
  , _shadowLigIRadU      :: Uniform Float
  }

data Accumulation = Accumulation {
    _accumProgram :: GPUProgram
  , _accumOff     :: Offscreen
  , _accumVA      :: VertexArray
  }

makeLenses ''Lighting
makeLenses ''LightingUniforms
makeLenses ''Shadowing
makeLenses ''ShadowingUniforms
makeLenses ''Accumulation

-------------------------------------------------------------------------------
-- Run photon

-- |Run a photon session. This is the entry point of a photon-powered
-- application. It spawns a standalone window in windowed or fullscreen mode.
-- If you want to embed **photon** in a /GUI/ container, you shouldn’t use
-- 'runPhoton'.
--
-- You’ll be asked for an event poller. This is optional; if you don’t want
-- any specific events, just use @return []@. If you do, you’ll be placed in
-- 'IO' so that you can do whatever you want, like socket-based communication
-- or anything 'IO'-related.
--
-- Nevertheless, **photon** does generate core events. You have to react to
-- them if you want your application to correctly behave. That’s done via an
-- /event handler/ which type is 'EventHandler u a', where 'u' is your event
-- type and 'a' your application.
--
-- The application runs in a special isolated monad, 'Photon'. That type gives
-- you everything you need for game-development. Feel free to read the 'Photon'
-- documentation for further understanding.
runPhoton :: Natural -- ^ Width of the window
          -> Natural -- ^ Height of the window
          -> Bool -- ^ Should the window be fullscreen?
          -> String -- ^ Title of the window
          -> IO [u] -- ^ User-spefic events poller
          -> EventHandler u a -- ^ Event handler
          -> (Log -> IO ()) -- log sink
          -> Photon a -- ^ Initial application
          -> (a -> Photon a) -- ^ Your application logic
          -> IO ()
runPhoton w h fullscreen title pollUserEvents eventHandler logSink app step = do
    initiated <- GLFW.init
    if initiated then do
      glfwVersion <- fmap showGLFWVersion getVersion
      print (Log InfoLog CoreLog $ "GLFW " ++ glfwVersion ++ " initialized!")
      windowHint (WindowHint'ContextVersionMajor 3)
      windowHint (WindowHint'ContextVersionMinor 3)
      createWindow (fromIntegral w) (fromIntegral h) title Nothing Nothing >>= \win -> case win of
        Just window -> makeContextCurrent win >> runWithWindow w h fullscreen window pollUserEvents eventHandler logSink app step
        -- TODO: display OpenGL information
        Nothing -> print (Log ErrorLog CoreLog "unable to create window :(")
      print (Log InfoLog CoreLog "bye!")
      terminate
      else do
        print (Log ErrorLog CoreLog "unable to init :(")

runWithWindow :: Natural -> Natural -> Bool -> Window -> IO [u] -> EventHandler u a -> (Log -> IO ()) -> Photon a -> (a -> Photon a) -> IO ()
runWithWindow w h fullscreen window pollUserEvents eventHandler logSink initializedApp step = do
    -- transaction variables
    events <- newTVarIO []
    mouseXY <- newTVarIO (0,0)

    -- callbacks
    setKeyCallback window (Just $ handleKey events)
    setMouseButtonCallback window (Just $ handleMouseButton events)
    setCursorPosCallback window (Just $ handleMouseMotion mouseXY events)
    setWindowCloseCallback window (Just $ handleWindowClose events)
    setWindowFocusCallback window (Just $ handleWindowFocus events)

    -- pre-process
    getCursorPos window >>= atomically . writeTVar mouseXY
    initGL

    -- photon
    gdrv <- photonDriver w h fullscreen logSink
    case gdrv of
      Nothing -> print (Log ErrorLog CoreLog "unable to create photon driver")
      Just drv -> startFrame drv events initializedApp
  where
    startFrame drv events app = do
        -- poll user events then GLFW ones and sink shared events
        userEvs <- fmap (map UserEvent) pollUserEvents
        GLFW.pollEvents
        evs <- fmap (userEvs++) . atomically $ readTVar events <* writeTVar events []
        -- route events to photon and interpret it; if it has to go on then simply loop
        interpretPhoton drv (routeEvents (app >>= step) evs) >>= maybe (return ()) endFrame
      where
        endFrame app' = do
          swapBuffers window
          startFrame drv events (return app')
    routeEvents = foldl (\a e -> a >>= eventHandler e)

initGL :: IO ()
initGL = do
  glEnable gl_DEPTH_TEST
  glClearColor 0 0 0 0

-------------------------------------------------------------------------------
-- Photon interpreter

-- |This function generates the 'PhotonDriver'. It uses **OpenGL** to get all the
-- required functions. The width and the height of the window are required in
-- order to be able to generate framebuffers, textures or any kind of object
-- viewport-related.
--
-- If the window’s dimensions change, the photon driver should be recreated.
photonDriver :: Natural
             -> Natural
             -> Bool
             -> (Log -> IO ())
             -> IO (Maybe PhotonDriver)
photonDriver w h _ logHandler = do
  gdrv <- runEitherT $ do
    lighting <- getLighting w h
    shadowing <- getShadowing w h
    accumulation <- getAccumulation w h
    -- post-process IORef to track the post image
    postImage <- liftIO $ newIORef (accumulation^.accumOff.offscreenTex)
    return $ PhotonDriver gpuMesh gpuMaterial gpuLight gpuCamera
      registerPostFX loadObject (render_ lighting shadowing accumulation)
      (applyPostFXChain lighting accumulation postImage)
      (display_ accumulation postImage) logHandler
  either (\e -> print e >> return Nothing) (return . Just) gdrv

getLighting :: Natural -> Natural -> EitherT Log IO Lighting
getLighting w h = do
  program <- evalJournalT $ buildProgram lightVS Nothing lightFS <* sinkLogs
  liftIO . print $ Log InfoLog CoreLog "generating light offscreen"
  off <- liftIO (genOffscreen w h RGB32F RGB (ColorAttachment 0) Depth32F DepthAttachment) >>= hoistEither
  uniforms <- liftIO (getLightingUniforms program)
  return (Lighting program off uniforms)

getLightingUniforms :: GPUProgram -> IO LightingUniforms
getLightingUniforms program = do
    useProgram program
    sem "ligDepthmap" >>= (@= (0 :: Int))
    LightingUniforms
      <$> sem "projView"
      <*> sem "model"
      <*> sem "eye"
      <*> sem "matDiffAlb"
      <*> sem "matSpecAlb"
      <*> sem "matShn"
      <*> sem "ligPos"
      <*> sem "ligCol"
      <*> sem "ligPow"
      <*> sem "ligRad"
  where
    sem :: (Uniformable a) => String -> IO (Uniform a)
    sem = getUniform program

getShadowing :: Natural -> Natural -> EitherT Log IO Shadowing
getShadowing w h = do
  liftIO . print $ Log InfoLog CoreLog "generating light cube depthmap offscreen"
  program <- evalJournalT $
    buildProgram lightCubeDepthmapVS (Just lightCubeDepthmapGS) lightCubeDepthmapFS <* sinkLogs
  uniforms <- liftIO (getShadowingUniforms program)
  (colormap,depthmap) <- liftIO $ do
    -- TODO: refactoring
    colormap <- genObject
    bindTexture colormap
    setTextureWrap colormap ClampToEdge
    setTextureFilters colormap Nearest
    setTextureNoImage colormap R32F w h Tex.R
    setTextureMaxLevel colormap 0
    unbindTexture colormap

    -- TODO: refactoring
    depthmap <- genObject
    bindTexture depthmap
    setTextureWrap depthmap ClampToEdge
    setTextureFilters depthmap Nearest
    setTextureNoImage depthmap Depth32F w h Depth
    --setTextureCompareFunc depthmap (Just LessOrEqual)
    setTextureMaxLevel depthmap 0
    unbindTexture depthmap

    return (colormap,depthmap)

  fb' <- liftIO $ buildFramebuffer Write $ \_ -> do
    attachTexture Write colormap (ColorAttachment 0)
    attachTexture Write depthmap DepthAttachment
    glDrawBuffer gl_COLOR_ATTACHMENT0
  fb <- hoistEither fb'
  return (Shadowing fb colormap depthmap program uniforms)

getShadowingUniforms :: GPUProgram -> IO ShadowingUniforms
getShadowingUniforms program = do
    ShadowingUniforms
      <$> sem "ligProjViews"
      <*> sem "model"
      <*> sem "ligPos"
      <*> sem "ligIRad"
  where
    sem :: (Uniformable a) => String -> IO (Uniform a)
    sem = getUniform program

getAccumulation :: Natural -> Natural -> EitherT Log IO Accumulation
getAccumulation w h = do
  program <- evalJournalT $ buildProgram accumVS Nothing accumFS <* sinkLogs
  liftIO . print $ Log InfoLog CoreLog "generating accumulation offscreen"
  off <- liftIO (genOffscreen w h RGB32F RGB (ColorAttachment 0) Depth32F DepthAttachment) >>= hoistEither
  va <- liftIO genAttributelessVertexArray
  liftIO $ do
    useProgram program
    getUniform program "source" >>= (@= (0 :: Int))
  return (Accumulation program off va)

registerPostFX :: PostFX -> IO (Maybe GPUPostFX)
registerPostFX pfx = evalJournalT $ do
  gpfx <- runEitherT (gpuPostFX pfx)
  case gpfx of
    Either.Left gpfxError -> liftIO (print gpfxError) >> return Nothing
    Either.Right gpfx' -> return (Just gpfx')

loadObject :: (Load a) => String -> IO (Maybe a)
loadObject name = evalJournalT (load name <* sinkLogs)

render_ :: Lighting
        -> Shadowing
        -> Accumulation
        -> GPUCamera
        -> [(GPULight,Entity)]
        -> [(GPUMaterial,[(GPUMesh,Entity)])]
        -> IO ()
render_ lighting shadowing accumulation gcam gpuligs meshes = do
  purgeAccumulationFramebuffer accumulation
  pushCameraToLighting lighting gcam
  forM_ gpuligs $ \(lig,lent) -> do
    purgeShadowingFramebuffer shadowing
    generateLightDepthmap shadowing (cameraProjection gcam)
      (concatMap snd meshes) lig lent
    purgeLightingFramebuffer lighting
    renderWithLight lighting shadowing meshes lig lent
    accumulateRender lighting accumulation

purgeAccumulationFramebuffer :: Accumulation -> IO ()
purgeAccumulationFramebuffer accumulation = do
  bindFramebuffer (accumulation^.accumOff.offscreenFB) Write
  glClearColor 0 0 0 0
  glClear $ gl_DEPTH_BUFFER_BIT .|. gl_COLOR_BUFFER_BIT

pushCameraToLighting :: Lighting -> GPUCamera -> IO ()
pushCameraToLighting lighting gcam = do
  useProgram (lighting^.omniLightProgram)
  runCamera gcam projViewU eyeU
  where
    projViewU = unis^.lightCamProjViewU
    eyeU = unis^.lightEyeU
    unis = lighting^.lightUniforms

purgeShadowingFramebuffer :: Shadowing -> IO ()
purgeShadowingFramebuffer shadowing = do
  bindFramebuffer (shadowing^.shadowCubeDepthFB) Write
  glClearColor 1 1 1 1
  glClear $ gl_COLOR_BUFFER_BIT .|. gl_DEPTH_BUFFER_BIT

purgeLightingFramebuffer :: Lighting -> IO ()
purgeLightingFramebuffer lighting = do
  bindFramebuffer (lighting^.lightOff.offscreenFB) Write
  glClearColor 0 0 0 0
  glClear $ gl_DEPTH_BUFFER_BIT .|. gl_COLOR_BUFFER_BIT

generateLightDepthmap :: Shadowing
                      -> M44 Float
                      -> [(GPUMesh,Entity)]
                      -> GPULight
                      -> Entity
                      -> IO ()
generateLightDepthmap shadowing proj meshes lig lent = do
    genDepthmap lig $ do
      useProgram (shadowing^.shadowCubeDepthmapProgram)
      ligProjViewsU @= lightProjViews
      ligPosU @= (lent^.entityPosition)
      ligIRadU @= 1 / lightRadius lig
      glDisable gl_BLEND
      glEnable gl_DEPTH_TEST
      forM_ meshes $ \(gmsh,ment) -> renderMesh gmsh modelU ment
  where
    sunis = shadowing^.shadowUniforms
    ligProjViewsU = sunis^.shadowLigProjViewsU
    ligPosU = sunis^.shadowLigPosU
    ligIRadU = sunis^.shadowLigIRadU
    modelU = sunis^.shadowModelU
    lightProjViews = map ((proj !*!) . cameraTransform)
      [
        lent' & entityOrientation .~ axisAngle yAxis (-pi/2) -- positive x
      , lent' & entityOrientation .~ axisAngle yAxis (pi/2) -- negative x
      , lent' & entityOrientation .~ axisAngle xAxis (pi/2) -- positive y
      , lent' & entityOrientation .~ axisAngle xAxis (-pi/2) -- negative y
      , lent' & entityOrientation .~ axisAngle yAxis 0 -- positive z
      , lent' & entityOrientation .~ axisAngle yAxis pi -- negative z
      ]
    lent' = origin & entityPosition .~ (lent^.entityPosition)

renderWithLight :: Lighting
                -> Shadowing
                -> [(GPUMaterial,[(GPUMesh,Entity)])]
                -> GPULight
                -> Entity
                -> IO ()
renderWithLight lighting shadowing meshes lig lent = do
    useProgram (lighting^.omniLightProgram)
    glDisable gl_BLEND
    glEnable gl_DEPTH_TEST
    shadeWithLight lig (lunis^.lightColU) (lunis^.lightPowU) (lunis^.lightRadU)
      (lunis^.lightPosU) unused lent
    bindTextureAt (shadowing^.shadowCubeDepthmap) 0
    forM_ meshes $ \(gmat,msh) -> do
      runMaterial gmat (lunis^.lightMatDiffAlbU) (lunis^.lightMatSpecAlbU)
        (lunis^.lightMatShnU)
      forM_ msh $ \(gmsh,ment) -> renderMesh gmsh (lunis^.lightModelU) ment
  where
    lunis = lighting^.lightUniforms

accumulateRender :: Lighting -> Accumulation -> IO ()
accumulateRender lighting accumulation = do
  useProgram (accumulation^.accumProgram)
  bindFramebuffer (accumulation^.accumOff.offscreenFB) Write
  glClear gl_DEPTH_BUFFER_BIT -- FIXME: glDisable gl_DEPTH_TEST ?
  glEnable gl_BLEND
  glBlendFunc gl_ONE gl_ONE
  bindTextureAt (lighting^.lightOff.offscreenTex) 0
  bindVertexArray (accumulation^.accumVA)
  glDrawArrays gl_TRIANGLE_STRIP 0 4

applyPostFXChain :: Lighting
                 -> Accumulation
                 -> IORef Texture2D
                 -> [GPUPostFX]
                 -> IO ()
applyPostFXChain lighting accumulation postImage pfxs = do
  glDisable gl_BLEND
  bindVertexArray (accumulation^.accumVA)
  void . flip runStateT (accumulation^.accumOff,lighting^.lightOff) $ do
    forM_ pfxs $ \pfx -> do
      (sourceOff,targetOff) <- get
      modify swap
      lift $ do
        usePostFX pfx (sourceOff^.offscreenTex)
        bindFramebuffer (targetOff^.offscreenFB) Write
        glClear gl_DEPTH_BUFFER_BIT
        glDrawArrays gl_TRIANGLE_STRIP 0 4
        writeIORef postImage (targetOff^.offscreenTex)

display_ :: Accumulation -> IORef Texture2D -> IO ()
display_ accumulation postImage = do
  useProgram (accumulation^.accumProgram)
  unbindFramebuffer Write
  glClear $ gl_DEPTH_BUFFER_BIT .|. gl_COLOR_BUFFER_BIT
  post <- readIORef postImage
  bindTextureAt post 0
  bindVertexArray (accumulation^.accumVA)
  glDrawArrays gl_TRIANGLE_STRIP 0 4

-- |Photon interpreter. This function turns the pure 'Photon a' structure into
-- 'IO a'.
interpretPhoton :: PhotonDriver -> Photon a -> IO (Maybe a)
interpretPhoton drv = interpret_
  where
    interpret_ g = case g of
      Pure x -> return (Just x)
      Free g' -> case g' of
        PC.RegisterMesh m f -> drvRegisterMesh drv m >>= interpret_ . f
        PC.LoadObject name f -> drvLoadObject drv name >>= interpret_ . f
        PC.RegisterMaterial m f -> drvRegisterMaterial drv m >>= interpret_ . f
        PC.RegisterLight l f -> drvRegisterLight drv l >>= interpret_ . f
        PC.RegisterCamera proj ent f -> drvRegisterCamera drv proj ent >>= interpret_ . f
        PC.RegisterPostFX pfx f -> drvRegisterPostFX drv pfx >>= interpret_ . f
        PC.Render gcam gpulig meshes nxt -> drvRender drv gcam gpulig meshes >> interpret_ nxt
        PC.PostProcess pfxs nxt -> drvPostProcess drv pfxs >> interpret_ nxt
        PC.Display nxt -> drvDisplay drv >> interpret_ nxt
        PC.Log lt msg nxt -> drvLog drv (Log lt UserLog msg) >> interpret_ nxt
        PC.Destroy -> return Nothing

-------------------------------------------------------------------------------
-- Callbacks
handleKey :: TVar [Event u] -> Window -> GLFW.Key -> Int -> GLFW.KeyState -> ModifierKeys -> IO ()
handleKey events _ k _ s _ = atomically . modifyTVar events $ (++ keys)
  where
    keys = case s of
      KeyState'Pressed   -> key KeyPressed
      KeyState'Released  -> key KeyReleased
      KeyState'Repeating -> key KeyReleased
    key st = case k of
        Key'Unknown      -> []
        Key'Space        -> r Space
        Key'Apostrophe   -> r Apostrophe
        Key'Comma        -> r Comma
        Key'Minus        -> r Minus
        Key'Period       -> r Period
        Key'Slash        -> r Slash
        Key'0            -> r Zero
        Key'1            -> r One
        Key'2            -> r Two
        Key'3            -> r Three
        Key'4            -> r Four
        Key'5            -> r Five
        Key'6            -> r Six
        Key'7            -> r Seven
        Key'8            -> r Eight
        Key'9            -> r Nine
        Key'Semicolon    -> r Semicolon
        Key'Equal        -> r E.Equal
        Key'A            -> r A
        Key'B            -> r B
        Key'C            -> r C
        Key'D            -> r D
        Key'E            -> r E
        Key'F            -> r F
        Key'G            -> r G
        Key'H            -> r H
        Key'I            -> r I
        Key'J            -> r J
        Key'K            -> r K
        Key'L            -> r L
        Key'M            -> r M
        Key'N            -> r N
        Key'O            -> r O
        Key'P            -> r P
        Key'Q            -> r Q
        Key'R            -> r E.R
        Key'S            -> r S
        Key'T            -> r T
        Key'U            -> r U
        Key'V            -> r V
        Key'W            -> r W
        Key'X            -> r X
        Key'Y            -> r Y
        Key'Z            -> r Z
        Key'LeftBracket  -> r LeftBracket
        Key'Backslash    -> r Backslash
        Key'RightBracket -> r RightBracket
        Key'GraveAccent  -> r GraveAccent
        Key'World1       -> r World1
        Key'World2       -> r World2
        Key'Escape       -> r Escape
        Key'Enter        -> r Enter
        Key'Tab          -> r Tab
        Key'Backspace    -> r Backspace
        Key'Insert       -> r Insert
        Key'Delete       -> r Delete
        Key'Right        -> r Right
        Key'Left         -> r Left
        Key'Down         -> r Down
        Key'Up           -> r Up
        Key'PageUp       -> r PageUp
        Key'PageDown     -> r PageDown
        Key'Home         -> r Home
        Key'End          -> r End
        Key'CapsLock     -> r CapsLock
        Key'ScrollLock   -> r ScrollLock
        Key'NumLock      -> r NumLock
        Key'PrintScreen  -> r PrintScreen
        Key'Pause        -> r Pause
        Key'F1           -> r F1
        Key'F2           -> r F2
        Key'F3           -> r F3
        Key'F4           -> r F4
        Key'F5           -> r F5
        Key'F6           -> r F6
        Key'F7           -> r F7
        Key'F8           -> r F8
        Key'F9           -> r F9
        Key'F10          -> r F10
        Key'F11          -> r F11
        Key'F12          -> r F12
        Key'F13          -> r F13
        Key'F14          -> r F14
        Key'F15          -> r F15
        Key'F16          -> r F16
        Key'F17          -> r F17
        Key'F18          -> r F18
        Key'F19          -> r F19
        Key'F20          -> r F20
        Key'F21          -> r F21
        Key'F22          -> r F22
        Key'F23          -> r F23
        Key'F24          -> r F24
        Key'F25          -> r F25
        Key'Pad0         -> r Pad0
        Key'Pad1         -> r Pad1
        Key'Pad2         -> r Pad2
        Key'Pad3         -> r Pad3
        Key'Pad4         -> r Pad4
        Key'Pad5         -> r Pad5
        Key'Pad6         -> r Pad6
        Key'Pad7         -> r Pad7
        Key'Pad8         -> r Pad8
        Key'Pad9         -> r Pad9
        Key'PadDecimal   -> r PadDecimal
        Key'PadDivide    -> r PadDivide
        Key'PadMultiply  -> r PadMultiply
        Key'PadSubtract  -> r PadSubtract
        Key'PadAdd       -> r PadAdd
        Key'PadEnter     -> r PadEnter
        Key'PadEqual     -> r PadEqual
        Key'LeftShift    -> r LeftShift
        Key'LeftControl  -> r LeftControl
        Key'LeftAlt      -> r LeftAlt
        Key'LeftSuper    -> r LeftSuper
        Key'RightShift   -> r RightShift
        Key'RightControl -> r RightControl
        Key'RightAlt     -> r RightAlt
        Key'RightSuper   -> r RightSuper
        Key'Menu         -> r Menu
      where
        r x = [CoreEvent . KeyEvent $ st x]

handleMouseButton :: TVar [Event u] -> Window -> GLFW.MouseButton -> GLFW.MouseButtonState -> ModifierKeys -> IO ()
handleMouseButton events _ b s _ = atomically . modifyTVar events $ (++ [CoreEvent $ MouseButtonEvent mouseEvent])
  where
    mouseEvent = case s of
      MouseButtonState'Pressed -> ButtonPressed button
      MouseButtonState'Released -> ButtonReleased button
    button = case b of
      MouseButton'1 -> MouseLeft
      MouseButton'2 -> MouseRight
      MouseButton'3 -> MouseMiddle
      MouseButton'4 -> Mouse4
      MouseButton'5 -> Mouse5
      MouseButton'6 -> Mouse6
      MouseButton'7 -> Mouse7
      MouseButton'8 -> Mouse8

handleMouseMotion :: TVar (Double,Double) -> TVar [Event u] -> Window -> Double -> Double -> IO ()
handleMouseMotion xy' events _ x y = do
    (x',y') <- atomically $ readTVar xy' <* writeTVar xy' (x,y)
    atomically . modifyTVar events $ (++ [CoreEvent . MouseMotionEvent $ MouseMotion x y (x-x') (y-y')])

handleWindowClose :: TVar [Event u] -> Window -> IO ()
handleWindowClose events _ = atomically . modifyTVar events $ (++ map CoreEvent [WindowEvent Closed,SystemEvent Quit])

handleWindowFocus :: TVar [Event u] -> Window -> FocusState -> IO ()
handleWindowFocus events _ f = atomically . modifyTVar events $ (++ [CoreEvent $ WindowEvent focusEvent])
  where
    focusEvent = case f of
      FocusState'Focused -> FocusGained
      FocusState'Defocused -> FocusLost
