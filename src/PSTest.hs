{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE NumericUnderscores    #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

module PSTest where


import           Control.Monad              hiding (fmap)
import           Control.Monad.Freer.Extras as Extras
import           Data.Default               (Default (..))
import qualified Data.Map                   as Map
import           Data.Monoid                (Last (..))
import           Ledger
import           Ledger.Value
import           Ledger.Ada                 as Ada
import           Plutus.Contract.Test
import           Plutus.Trace.Emulator      as Emulator
import           PlutusTx.Prelude
import           Prelude                    (IO, String, Show (..))


import           PropertySale

runMyTrace :: IO ()
runMyTrace = runEmulatorTraceIO' def emCfg myTrace

emCfg :: EmulatorConfig
emCfg = EmulatorConfig (Left $ Map.fromList [(Wallet w, v) | w <- [1 .. 3]]) def def
  where
    v :: Value
    v = Ada.lovelaceValueOf 1_000_000_000 <> assetClassValue token 1000

currency :: CurrencySymbol
currency = "aa"

name :: TokenName
name = "A"

token :: AssetClass
token = AssetClass (currency, name)

myTrace :: EmulatorTrace ()
myTrace = do
    h <- activateContractWallet (Wallet 1) startEndpoint
    callEndpoint @"Start" h (currency, name, True)
    void $ Emulator.waitNSlots 5
    Last m <- observableState h
    case m of
        Nothing -> Extras.logError @String "Error starting property sale"
        Just ps -> do
            Extras.logInfo $ "Started Property Sale " ++ show ps

            h1 <- activateContractWallet (Wallet 1) $ useEndpoints ps
            h2 <- activateContractWallet (Wallet 2) $ useEndpoints ps
            h3 <- activateContractWallet (Wallet 3) $ useEndpoints ps

            callEndpoint @"Interact" h1 $ SetPrice 1_000_000
            void $ Emulator.waitNSlots 5

            callEndpoint @"Interact" h1 $ AddTokens 100
            void $ Emulator.waitNSlots 5

            callEndpoint @"Interact" h2 $ BuyTokens 20
            void $ Emulator.waitNSlots 5

            callEndpoint @"Interact" h3 $ BuyTokens 5
            void $ Emulator.waitNSlots 5

            callEndpoint @"Interact" h1 $ Withdraw 40 10_000_000
            void $ Emulator.waitNSlots 5

            callEndpoint @"Interact" h1 Close
            void $ Emulator.waitNSlots 2