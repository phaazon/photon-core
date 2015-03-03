{-# LANGUAGE BangPatterns, StandaloneDeriving, UndecidableInstances #-}

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

module Quaazar.Utils.Scoped (
    -- * Scoped monad
    MonadScoped(..)
    -- * IO scoped monad transformer
  , IOScopedT
  , runIOScopedT
    -- * Re-exported
  , module Control.Monad.Base
  ) where

import Control.Applicative ( Applicative )
import Control.Monad.Base ( MonadBase(..) )
import Control.Monad.Error.Class ( MonadError )
import Control.Monad.Journal ( MonadJournal )
import Control.Monad.Reader ( MonadReader )
import Control.Monad.State ( MonadState )
import Control.Monad.Trans ( MonadIO(..), MonadTrans )
-- import Control.Monad.Trans.Control ( MonadBaseControl(..) )
import Control.Monad.Trans.State ( StateT, modify, runStateT )
import Data.Monoid ( Monoid )

class (MonadBase b m) => MonadScoped b m where
  scoped :: b () -> m ()

newtype IOScopedT m a = IOScopedT { unIOScopedT :: StateT (IO ()) m a } deriving (Applicative,Functor,Monad,MonadTrans)

deriving instance (MonadBase b m) => MonadBase b (IOScopedT m)
deriving instance (MonadIO m) => MonadIO (IOScopedT m)
deriving instance (MonadJournal w m,Monoid w) => MonadJournal w (IOScopedT m)
deriving instance (MonadError e m) => MonadError e (IOScopedT m)
deriving instance (MonadReader r m) => MonadReader r (IOScopedT m)
-- deriving instance (MonadState s m) => MonadState s (IOScopedT m)

instance (MonadBase IO m) => MonadScoped IO (IOScopedT m) where
  scoped a = IOScopedT $ modify (>>a)

runIOScopedT :: (MonadIO m) => IOScopedT m a -> m a
runIOScopedT scope = do
  (a,cleanup) <- runStateT (unIOScopedT scope) (return ())
  liftIO cleanup
  return a