{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}

module PropertySale where

import           Control.Monad                hiding (fmap)
import qualified Data.Map                     as Map
import           Data.Aeson                   (FromJSON, ToJSON)
import           Data.Monoid                  (Last (..))
import           Data.Text                    (Text, pack)
import           GHC.Generics                 (Generic)
import           Plutus.Contract              as Contract
import           Plutus.Contract.StateMachine
import qualified PlutusTx
import           PlutusTx.Prelude             hiding (Semigroup(..), check, unless)
import           Ledger                       hiding (singleton)
import           Ledger.Ada                   as Ada
import           Ledger.Constraints           as Constraints
import qualified Ledger.Typed.Scripts         as Scripts
import           Ledger.Value                 as Value
import           Prelude                      (Semigroup (..), Show (..), String)
import           Text.Printf                  (printf)
import qualified Prelude

data MintParams = MintParams
    { mpTokenName :: !TokenName
    , mpAmount    :: !Integer
    } deriving (Show, Generic, ToJSON, FromJSON)

data PropertySale = PropertySale
    { psSeller :: !PubKeyHash
    , psToken  :: !AssetClass
    , psTT     :: !(Maybe ThreadToken)
    } deriving (Show, Generic, FromJSON, ToJSON, Prelude.Eq)

PlutusTx.makeLift ''PropertySale

type Price    = Integer
type Tokens   = Integer
type Lovelace = Integer

data PSRedeemer =
      SetPrice  Price -- To Do: use an oracle to determine the price
    | AddTokens Tokens
    | BuyTokens Tokens
    | Withdraw  Tokens Lovelace
    | Close
    deriving (Show, Generic, FromJSON, ToJSON, Prelude.Eq)

PlutusTx.unstableMakeIsData ''PSRedeemer

data TradeDatum = Trade Integer | Finished
    deriving Show

PlutusTx.unstableMakeIsData ''TradeDatum

--------------------------------------------------------------------------
-- | OnChain code | --

-- | Ensure the Minting policy can only occur once by utilising a eUTXO as a parameter
{-# INLINABLE mkPolicy #-}
mkPolicy :: TxOutRef -> () -> ScriptContext -> Bool
mkPolicy oref () ctx = traceIfFalse "UTxO not consumed" (any (\i -> txInInfoOutRef i == oref) $ txInfoInputs info)
    where
       info :: TxInfo
       info = scriptContextTxInfo ctx  
 
policy :: TxOutRef -> Scripts.MintingPolicy
policy oref = mkMintingPolicyScript $
    $$(PlutusTx.compile [|| \oref' -> Scripts.wrapMintingPolicy $ mkPolicy oref' ||])
    `PlutusTx.applyCode`
    PlutusTx.liftCode oref

curSymbol :: TxOutRef -> CurrencySymbol
curSymbol oref = scriptCurrencySymbol $ policy oref 

---------------------------------------

{-# INLINABLE lovelaces #-}
lovelaces :: Value -> Integer
lovelaces = Ada.getLovelace . Ada.fromValue

---------------------------------------
-- | State Machine

{-# INLINABLE transition #-}
transition :: PropertySale -> State TradeDatum -> PSRedeemer -> Maybe (TxConstraints Void Void, State TradeDatum)
transition ps s r = case (stateValue s, stateData s, r) of
    (v, Trade _, SetPrice p)   | p >= 0           -> Just ( Constraints.mustBeSignedBy (psSeller ps)
                                                    , State (Trade p) v
                                                    )
    (v, Trade p, AddTokens n)  | n > 0            -> Just ( Constraints.mustBeSignedBy (psSeller ps)
                                                    , State (Trade p) $
                                                      v <> assetClassValue (psToken ps) n
                                                    )
    (v, Trade p, BuyTokens n)  | n > 0            -> Just ( mempty
                                                    , State (Trade p) $
                                                      v <> assetClassValue (psToken ps) (negate n) <>
                                                      lovelaceValueOf (n * p)
                                                    )
    (v, Trade p, Withdraw n l) | n >= 0 && l >= 0 -> Just ( Constraints.mustBeSignedBy (psSeller ps)
                                                    , State (Trade p) $
                                                      v <> assetClassValue (psToken ps) (negate n) <>
                                                      lovelaceValueOf (negate l)
                                                    )
    (_, Trade _, Close)                           -> Just  ( Constraints.mustBeSignedBy (psSeller ps)
                                                    , State Finished mempty
                                                    )
    _                                             -> Nothing

{-# INLINABLE final #-}
final :: TradeDatum -> Bool
final Finished = True
final _        = False

{-# INLINABLE psStateMachine #-}
psStateMachine :: PropertySale -> StateMachine TradeDatum PSRedeemer
psStateMachine ps = mkStateMachine (psTT ps) (transition ps) final -- final sepcifies final state of the state machine

{-# INLINABLE mkPSValidator #-}
mkPSValidator :: PropertySale -> TradeDatum -> PSRedeemer -> ScriptContext -> Bool
mkPSValidator = mkValidator . psStateMachine

type PS = StateMachine TradeDatum PSRedeemer

psTypedValidator :: PropertySale -> Scripts.TypedValidator PS
psTypedValidator ps = Scripts.mkTypedValidator @PS
    ($$(PlutusTx.compile [|| mkPSValidator ||]) `PlutusTx.applyCode` PlutusTx.liftCode ps)
    $$(PlutusTx.compile [|| wrap ||])
  where
    wrap = Scripts.wrapValidator @TradeDatum @PSRedeemer

psValidator :: PropertySale  -> Validator
psValidator = Scripts.validatorScript . psTypedValidator

psAddress :: PropertySale  -> Ledger.Address
psAddress = scriptAddress . psValidator

-- | Allows for the starting and stepping of the state machine
psClient :: PropertySale  -> StateMachineClient TradeDatum PSRedeemer
psClient ps = mkStateMachineClient $ StateMachineInstance (psStateMachine ps) (psTypedValidator ps)

---------------------------------------------------------------------------
-- | Offchain Code | --

-- | Mint Property Tokens (Another possible solution...)
-- mintC :: MintParams -> Contract w s CurrencyError OneShotCurrency
-- mintC mp = mapErrorSM (mintContract pkh [((mpTokenName mp), (mpAmount mp))])

-- | Mint Property Tokens
mintPS :: MintParams -> Contract w PSMintSchema Text ()
mintPS mp = do
    pk    <- Contract.ownPubKey
    utxos <- utxoAt (pubKeyAddress pk)
    case Map.keys utxos of
        []       -> Contract.logError @String "no utxo found"
        oref : _ -> do
            let val     = Value.singleton (curSymbol oref) (mpTokenName mp) (mpAmount mp)
                lookups = Constraints.mintingPolicy (policy oref) <> Constraints.unspentOutputs utxos
                tx      = Constraints.mustMintValue val <> Constraints.mustSpendPubKeyOutput oref
            ledgerTx <- submitTxConstraintsWith @Void lookups tx
            void $ awaitTxConfirmed $ txId ledgerTx
            Contract.logInfo @String $ printf "forged %s" (show val)

-------------------------------------

-- | Starts the Property Sale by initialising the state machine
startPS :: AssetClass -> Bool -> Contract (Last PropertySale) s Text ()
startPS token useTT = do
    pkh <- pubKeyHash <$> Contract.ownPubKey
    tt  <- if useTT then Just <$> mapErrorSM getThreadToken else return Nothing
    let ps = PropertySale
            { psSeller = pkh
            , psToken  = token
            , psTT     = tt
            }
        client = psClient ps
    void $ mapErrorSM $ runInitialise client (Trade 0) mempty
    tell $ Last $ Just ps
    logInfo $ "Started Property Sale " ++ show ps

-- | Converts SMContractError from the state machine to a simple text error
mapErrorSM :: Contract w s SMContractError a -> Contract w s Text a
mapErrorSM = mapError $ pack . show

---------------------------------------

-- | Allows for the stepping of the state machine with the interactions SetPrice, AddTokens, BuyTokens, Withdraw and Close    
interactPS :: PropertySale  -> PSRedeemer -> Contract w s Text ()
interactPS ps r = void $ mapErrorSM $ runStep (psClient ps) r

---------------------------------------

-- | Define Schemas and EndPoints
type PSMintSchema =
        Endpoint "Mint"       MintParams
type PSStartSchema =
        Endpoint "Start"      (CurrencySymbol, TokenName, Bool)
type PSUseSchema =
        Endpoint "Interact"   PSRedeemer
 
mintEndpoint ::  Contract () PSMintSchema Text ()
mintEndpoint  = forever
              $ handleError logError
              $ awaitPromise
              $ endpoint @"Mint"  $ mintPS           

startEndpoint :: Contract (Last PropertySale ) PSStartSchema Text ()
startEndpoint = forever
              $ handleError logError
              $ awaitPromise
              $ endpoint @"Start" $ \(cs, tn, useTT) -> startPS (AssetClass (cs, tn)) useTT

useEndpoints :: PropertySale  -> Contract () PSUseSchema Text ()
useEndpoints ps = forever
                $ handleError logError
                $ awaitPromise
                $ endpoint @"Interact"  $ interactPS ps