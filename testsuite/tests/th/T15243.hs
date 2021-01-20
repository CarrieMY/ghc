{-# LANGUAGE Haskell2010 #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -ddump-splices #-}
module T15243 where

data Unit = Unit

$([d| type family F (a :: k) :: k where
        F 'Unit = 'Unit
        F '(,)  = '(,)
        F '[]   = '[]
        F '(:)  = '(:)
    |])
