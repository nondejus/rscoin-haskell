{-# LANGUAGE Rank2Types      #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Storage for Bank data

module Storage
       ( Storage
       , mkStorage
       , getMintettes
       , getPeriodId
       , addMintette
       ) where

import           Control.Lens        (Getter, makeLenses, (%=))
import           Control.Monad.State (State)
import           Data.Typeable       (Typeable)

import           RSCoin.Core         (Mintette, Mintettes, PeriodId)

data Storage = Storage
    { _mintettes :: Mintettes
    , _periodId  :: PeriodId
    } deriving (Typeable)

$(makeLenses ''Storage)

mkStorage :: Storage
mkStorage = Storage [] 0

type Query a = Getter Storage a

getMintettes :: Query Mintettes
getMintettes = mintettes

getPeriodId :: Query PeriodId
getPeriodId = periodId

type Update = State Storage

addMintette :: Mintette -> Update ()
addMintette m = mintettes %= (m:)