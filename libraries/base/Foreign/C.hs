{-# OPTIONS -fno-implicit-prelude #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Foreign.C
-- Copyright   :  (c) The FFI task force 2001
-- License     :  BSD-style (see the file libraries/core/LICENSE)
-- 
-- Maintainer  :  ffi@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- Bundles the C specific FFI library functionality
--
-----------------------------------------------------------------------------

module Foreign.C
        ( module Foreign.C.Types
	, module Foreign.C.TypesISO
	, module Foreign.C.String
	, module Foreign.C.Error
        ) where

import Foreign.C.Types
import Foreign.C.TypesISO
import Foreign.C.String
import Foreign.C.Error
