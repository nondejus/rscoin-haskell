{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE TupleSections         #-}

-- | Storage updates.

module RSCoin.Bank.Storage.Updates
       (
         Update
       , ExceptUpdate

       , addAddress
       , addMintette
       , addExplorer
       , removeMintette
       , removeExplorer
       , setExplorerPeriod
       , suspendExplorer
       , restoreExplorers
       , startNewPeriod
       ) where

import           Control.Lens                  (use, uses, view, (%%=), (%=),
                                                (+=), (.=), _3)
import           Control.Monad                 (forM_, guard, unless, when)
import           Control.Monad.Catch           (MonadThrow (throwM))
import           Control.Monad.Extra           (whenJust)
import           Control.Monad.State           (MonadState, execState, runState)
import           Data.Bifunctor                (first)
import qualified Data.HashMap.Lazy             as M
import qualified Data.HashSet                  as S
import           Data.List                     (unfoldr)
import qualified Data.Map                      as MP
import           Data.Maybe                    (fromJust, isJust, mapMaybe)
import           Safe                          (headMay)

import           Serokell.Util                 (enumerate)

import           RSCoin.Core                   (ActionLog,
                                                ActionLogEntry (CloseEpochEntry),
                                                AddrId, Address (..), Dpk,
                                                HBlock (..), MintetteId,
                                                Mintettes, NewPeriodData (..),
                                                PeriodId, PeriodResult,
                                                PublicKey, SecretKey,
                                                Transaction (..),
                                                checkActionLog, checkLBlock,
                                                computeOutputAddrids,
                                                emissionHash, hash,
                                                lbTransactions, mkGenesisHBlock,
                                                mkHBlock, owners)
import qualified RSCoin.Core                   as C

import           RSCoin.Bank.Error             (BankError (..))
import qualified RSCoin.Bank.Storage.Addresses as AS
import qualified RSCoin.Bank.Storage.Explorers as ES
import qualified RSCoin.Bank.Storage.Mintettes as MS
import qualified RSCoin.Bank.Storage.Queries   as Q
import           RSCoin.Bank.Storage.Storage   (Storage, addressesStorage,
                                                blocks, emissionHashes,
                                                explorersStorage,
                                                mintettesStorage, periodId,
                                                utxo)
import qualified RSCoin.Bank.Strategies        as Strategies

type Update a = forall m . MonadState Storage m => m a
type ExceptUpdate a = forall m . (MonadThrow m, MonadState Storage m) => m a

-- | Add given address to storage and associate given strategy with it.
addAddress :: Address -> C.TxStrategy -> Update ()
addAddress addr strategy =
    addressesStorage %= execState (AS.addAddress addr strategy)

-- | Add given mintette to storage and associate given key with it.
addMintette :: C.Mintette -> C.PublicKey -> ExceptUpdate ()
addMintette m k = do
    (exc,s') <- uses mintettesStorage $ runState (MS.addMintette m k)
    whenJust exc throwM
    mintettesStorage .= s'

-- | Add given explorer to storage and associate given PeriodId with
-- it. If explorer exists, it is updated.
addExplorer :: C.Explorer -> C.PeriodId -> Update ()
addExplorer e expectedPid =
    explorersStorage %= execState (ES.addExplorer e expectedPid)

-- | Given host and port, remove mintette from the list of mintettes added
removeMintette :: String -> Int -> ExceptUpdate ()
removeMintette h p = do
    (exc,s') <- uses mintettesStorage $ runState $ MS.removeMintette $ C.Mintette h p
    whenJust exc throwM
    mintettesStorage .= s'

-- | Given host and port, remove explorer from the list
removeExplorer :: String -> Int -> ExceptUpdate ()
removeExplorer h p = do
    (exc,s') <- uses explorersStorage $ runState $ ES.removeExplorer h p
    whenJust exc throwM
    explorersStorage .= s'

-- | Update expected period id of given explorer. Adds explorer if it
-- doesn't exist.
setExplorerPeriod :: C.Explorer -> C.PeriodId -> Update ()
setExplorerPeriod e expectedPid =
    explorersStorage %= execState (ES.setExplorerPeriod e expectedPid)

-- | Temporarily delete explorer from storage until `restoreExplorers`
-- is called.
suspendExplorer :: C.Explorer -> Update ()
suspendExplorer e = explorersStorage %= execState (ES.suspendExplorer e)

-- | Restore all suspended explorers.
restoreExplorers :: Update ()
restoreExplorers = explorersStorage %= execState ES.restoreExplorers

-- | When period finishes, Bank receives period results from
-- mintettes, updates storage and starts new period with potentially
-- different set of mintettes. Return value is a list of size (length
-- mintettes) of NewPeriodDatas that should be sent to mintettes.
startNewPeriod
    :: PublicKey
    -> SecretKey
    -> [Maybe PeriodResult]
    -> ExceptUpdate [NewPeriodData]
startNewPeriod bankPk sk results = do
    mintettes <- use Q.getMintettes
    unless (length mintettes == length results) $
        throwM $
        BEInconsistentResponse
            "Length of results is different from the length of mintettes"
    pId <- use periodId
    changedMintetteIx <- startNewPeriodDo bankPk sk pId results
    currentMintettes <- use Q.getMintettes
    payload' <- formPayload currentMintettes changedMintetteIx
    periodId' <- use periodId
    mintettes' <- use Q.getMintettes
    addresses <- use Q.getAddresses
    hblock' <- uses blocks head
    dpk <- use Q.getDpk
    let npdPattern pl = NewPeriodData periodId' mintettes' hblock' pl dpk
        usersNPDs =
          map (\i -> npdPattern ((i,,) <$> (i `MP.lookup` payload') <*> pure addresses))
              [0 .. length currentMintettes - 1]
    return usersNPDs

-- | Calls a startNewPeriodFinally, previously processing
-- PeriodResults, sorting them relatevely to logs and dpk. Also
-- merging LBlocks and adding generative transaction.
startNewPeriodDo
    :: PublicKey
    -> SecretKey
    -> PeriodId
    -> [Maybe PeriodResult]
    -> ExceptUpdate [MintetteId]
startNewPeriodDo bankPk sk 0 _ =
    startNewPeriodFinally sk [] (const $ mkGenesisHBlock genAddr) Nothing
  where
    genAddr = C.Address bankPk
startNewPeriodDo bankPk sk pId results = do
    lastHBlock <- head <$> use blocks
    curDpk <- use Q.getDpk
    logs <- use $ mintettesStorage . MS.getActionLogs
    let keys = map fst curDpk
    unless (length keys == length results) $
        throwM $
        BEInconsistentResponse
            "Length of keys is different from the length of results"
    mintettes <- use Q.getMintettes
    let checkedResults =
            map (checkResult pId lastHBlock) $ zip3 results keys logs
        filteredResults =
            mapMaybe filterCheckedResults (zip [0 ..] checkedResults)
        emissionTransaction = allocateCoins bankPk keys filteredResults pId
        checkEmission [(tid,_,_)] = return tid
        checkEmission _ = throwM $ BEInternal
            "Emission transaction should have one transaction hash"
        blockTransactions =
            emissionTransaction : mergeTransactions mintettes filteredResults
    emissionTransactionId <- checkEmission $ C.txInputs emissionTransaction
    startNewPeriodFinally
        sk
        filteredResults
        (mkHBlock blockTransactions lastHBlock)
        (Just emissionTransactionId)
  where
    filterCheckedResults (idx,mres) = (idx, ) <$> mres

-- | Finalize the period start. Update mintettes, addresses, create a
-- new block, add transactions to transaction resolving map. Return a
-- list of mintettes that should update their utxo.
startNewPeriodFinally
    :: SecretKey
    -> [(MintetteId, PeriodResult)]
    -> (C.AddressToTxStrategyMap -> SecretKey -> Dpk -> HBlock)
    -> C.EmissionId
    -> ExceptUpdate [MintetteId]
startNewPeriodFinally sk goodMintettes newBlockCtor emissionTid = do
    periodId += 1
    updateIds <- updateMintettes sk goodMintettes
    newAddrs <- updateAddresses
    newBlock <- newBlockCtor newAddrs sk <$> use Q.getDpk
    updateUtxo $ hbTransactions newBlock
    -- TODO: this can be written more elegantly !
    when
        (isJust emissionTid) $
        emissionHashes %= (fromJust emissionTid :)
    blocks %= (newBlock :)
    return updateIds

-- | Add pending addresses to addresses map (addr -> strategy), return
-- it as an argument.
updateAddresses :: Update C.AddressToTxStrategyMap
updateAddresses = addressesStorage %%= runState AS.updateAddresses

-- | Given a set of transactions, change utxo in a correspondent way
updateUtxo :: [Transaction] -> ExceptUpdate ()
updateUtxo newTxs = do
    let shouldBeAdded = concatMap computeOutputAddrids newTxs
        shouldBeDeleted = concatMap txInputs newTxs
    utxo %= MP.union (MP.fromList shouldBeAdded)
    forM_ shouldBeDeleted (\d -> utxo %= MP.delete d)

-- | Process a check over PeriodResult to filter them, includes checks
-- regarding pid and action logs check
checkResult :: PeriodId
            -> HBlock
            -> (Maybe PeriodResult, PublicKey, ActionLog)
            -> Maybe PeriodResult
checkResult expectedPid lastHBlock (r,key,storedLog) = do
    (pId,lBlocks,actionLog) <- r
    guard $ pId == expectedPid
    guard $ checkActionLog (headMay storedLog) actionLog
    let logsToCheck =
            formLogsToCheck $ dropWhile (not . isCloseEpoch) actionLog
    let g3 = length logsToCheck == length lBlocks
    guard g3
    mapM_
        (\(blk,lg) ->
              guard $ checkLBlock key (hbHash lastHBlock) lg blk) $
        zip lBlocks logsToCheck
    r
  where
    formLogsToCheck = unfoldr step
    step []        = Nothing
    step actionLog = Just (actionLog, dropEpoch actionLog)
    dropEpoch = dropWhile (not . isCloseEpoch) . drop 1
    isCloseEpoch (CloseEpochEntry _,_) = True
    isCloseEpoch _                     = False

-- | Perform coins allocation based on default allocation strategy
-- (hardcoded). Given the mintette's public keys it splits reward
-- among bank and mintettes.
allocateCoins
    :: PublicKey
    -> [PublicKey]
    -> [(MintetteId, PeriodResult)]
    -> PeriodId
    -> Transaction
allocateCoins bankPk mintetteKeys goodResults pId =
    Transaction
    { txInputs = [(emissionHash pId, 0, inputValue)]
    , txOutputs = (bankAddress, bankReward) : mintetteOutputs
    }
  where
    bankAddress = Address bankPk
    (bankReward,goodMintetteRewards) =
        Strategies.allocateCoins
            Strategies.AllocateCoinsDefault
            pId
            (map (view _3) . map snd $ goodResults)
    inputValue = sum (bankReward : goodMintetteRewards)
    idxInGoodToGlobal idxInGood = fst $ goodResults !! idxInGood
    mintetteOutputs =
        map (first $ Address . (mintetteKeys !!) . idxInGoodToGlobal) $
        enumerate goodMintetteRewards

-- | Return all transactions that appear in periodResults collected
-- from mintettes.
mergeTransactions :: Mintettes -> [(MintetteId, PeriodResult)] -> [Transaction]
mergeTransactions mts goodResults =
    M.foldrWithKey appendTxChecked [] txMap
  where
    txMap :: M.HashMap Transaction (S.HashSet MintetteId)
    txMap = foldr insertResult M.empty goodResults
    insertResult (mintId, (_, blks, _)) m = foldr (insertBlock mintId) m blks
    insertBlock mintId blk m = foldr (insertTx mintId) m (lbTransactions blk)
    insertTx mintId tx m = M.insertWith S.union tx (S.singleton mintId) m
    appendTxChecked :: Transaction
                    -> S.HashSet MintetteId
                    -> [Transaction]
                    -> [Transaction]
    appendTxChecked tx committedMintettes
      | checkMajority tx committedMintettes = (tx :)
      | otherwise = id
    checkMajority :: Transaction -> S.HashSet MintetteId -> Bool
    checkMajority tx committedMintettes =
        let ownersSet = S.fromList $ owners mts (hash tx)
        in S.size (ownersSet `S.intersection` committedMintettes) >
           (S.size ownersSet `div` 2)

-- | Given a list of mintettes with ids that changed it returns a map
-- from mintette id to utxo it should now adopt.
formPayload :: [a] -> [MintetteId] -> ExceptUpdate (MP.Map MintetteId C.Utxo)
formPayload mintettes' changedId = do
    curUtxo <- use utxo
    let payload = MP.foldlWithKey' gatherPayload MP.empty curUtxo
        gatherPayload :: MP.Map MintetteId C.Utxo
                      -> AddrId
                      -> Address
                      -> MP.Map MintetteId C.Utxo
        gatherPayload prev addrid@(txhash,_,_) address =
            MP.unionWith
                MP.union
                prev
                (MP.fromListWith MP.union $
                 mapMaybe
                     (\changed ->
                           if changed `elem` owners mintettes' txhash
                               then Just (changed, MP.singleton addrid address)
                               else Just (changed, MP.empty))
                     changedId)
    return payload

-- | Process mintettes, kick out some, return ids that changed (and
-- need to update their utxo).
updateMintettes :: SecretKey
                -> [(MintetteId, PeriodResult)]
                -> Update [MintetteId]
updateMintettes sk goodMintettes =
    mintettesStorage %%= runState (MS.updateMintettes sk goodMintettes)
