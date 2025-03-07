module Hasura.Backends.Postgres.DDL.RunSQL
  (withMetadataCheck) where

import           Hasura.Prelude

import qualified Data.HashMap.Strict                 as M
import qualified Data.HashMap.Strict.InsOrd          as OMap
import qualified Data.HashSet                        as HS
import qualified Data.List.NonEmpty                  as NE
import qualified Database.PG.Query                   as Q

import           Control.Lens                        ((.~))
import           Control.Monad.Trans.Control         (MonadBaseControl)
import           Data.Aeson.TH
import           Data.List.Extended                  (duplicates)
import           Data.Text.Extended

import qualified Hasura.SQL.AnyBackend               as AB

import           Hasura.Backends.Postgres.DDL.Source (ToMetadataFetchQuery, fetchTableMetadata)
import           Hasura.Backends.Postgres.DDL.Table
import           Hasura.Backends.Postgres.SQL.Types  hiding (TableName)
import           Hasura.Base.Error
import           Hasura.RQL.DDL.Deps                 (reportDepsExt)
import           Hasura.RQL.DDL.Schema.Common
import           Hasura.RQL.DDL.Schema.Function
import           Hasura.RQL.DDL.Schema.Rename
import           Hasura.RQL.DDL.Schema.Table
import           Hasura.RQL.Types                    hiding (ConstraintName, fmFunction,
                                                      tmComputedFields, tmTable)


data FunctionMeta
  = FunctionMeta
  { fmOid      :: !OID
  , fmFunction :: !QualifiedFunction
  , fmType     :: !FunctionVolatility
  } deriving (Show, Eq)
$(deriveJSON hasuraJSON ''FunctionMeta)

data ComputedFieldMeta
  = ComputedFieldMeta
  { ccmName         :: !ComputedFieldName
  , ccmFunctionMeta :: !FunctionMeta
  } deriving (Show, Eq)
$(deriveJSON hasuraJSON{omitNothingFields=True} ''ComputedFieldMeta)

data TableMeta (b :: BackendType)
  = TableMeta
  { tmTable          :: !QualifiedTable
  , tmInfo           :: !(DBTableMetadata b)
  , tmComputedFields :: ![ComputedFieldMeta]
  } deriving (Show, Eq)

fetchMeta
  :: (ToMetadataFetchQuery pgKind, BackendMetadata ('Postgres pgKind), MonadTx m)
  => TableCache ('Postgres pgKind)
  -> FunctionCache ('Postgres pgKind)
  -> m ([TableMeta ('Postgres pgKind)], [FunctionMeta])
fetchMeta tables functions = do
  tableMetaInfos <- fetchTableMetadata
  functionMetaInfos <- fetchFunctionMetadata

  let getFunctionMetas function =
        let mkFunctionMeta rawInfo =
              FunctionMeta (rfiOid rawInfo) function (rfiFunctionType rawInfo)
        in maybe [] (map mkFunctionMeta) $ M.lookup function functionMetaInfos

      mkComputedFieldMeta computedField =
        let function = _cffName $ _cfiFunction computedField
        in map (ComputedFieldMeta (_cfiName computedField)) $ getFunctionMetas function

      tableMetas = flip map (M.toList tableMetaInfos) $ \(table, tableMetaInfo) ->
                   TableMeta table tableMetaInfo $ fromMaybe [] $
                     M.lookup table tables <&> \tableInfo ->
                     let tableCoreInfo  = _tiCoreInfo tableInfo
                         computedFields = getComputedFieldInfos $ _tciFieldInfoMap tableCoreInfo
                     in  concatMap mkComputedFieldMeta computedFields

      functionMetas = concatMap getFunctionMetas $ M.keys functions

  pure (tableMetas, functionMetas)

getOverlap :: (Eq k, Hashable k) => (v -> k) -> [v] -> [v] -> [(v, v)]
getOverlap getKey left right =
  M.elems $ M.intersectionWith (,) (mkMap left) (mkMap right)
  where
    mkMap = M.fromList . map (\v -> (getKey v, v))

getDifference :: (Eq k, Hashable k) => (v -> k) -> [v] -> [v] -> [v]
getDifference getKey left right =
  M.elems $ M.difference (mkMap left) (mkMap right)
  where
    mkMap = M.fromList . map (\v -> (getKey v, v))

data ComputedFieldDiff
  = ComputedFieldDiff
  { _cfdDropped    :: [ComputedFieldName]
  , _cfdAltered    :: [(ComputedFieldMeta, ComputedFieldMeta)]
  , _cfdOverloaded :: [(ComputedFieldName, QualifiedFunction)]
  } deriving (Show, Eq)

data TableDiff (b :: BackendType)
  = TableDiff
  { _tdNewName         :: !(Maybe QualifiedTable)
  , _tdDroppedCols     :: ![Column b]
  , _tdAddedCols       :: ![RawColumnInfo b]
  , _tdAlteredCols     :: ![(RawColumnInfo b, RawColumnInfo b)]
  , _tdDroppedFKeyCons :: ![ConstraintName]
  , _tdComputedFields  :: !ComputedFieldDiff
  -- The final list of uniq/primary constraint names
  -- used for generating types on_conflict clauses
  -- TODO: this ideally should't be part of TableDiff
  , _tdUniqOrPriCons   :: ![ConstraintName]
  , _tdNewDescription  :: !(Maybe PGDescription)
  }

getTableDiff
  :: (Backend ('Postgres pgKind), BackendMetadata ('Postgres pgKind))
  => TableMeta ('Postgres pgKind)
  -> TableMeta ('Postgres pgKind)
  -> TableDiff ('Postgres pgKind)
getTableDiff oldtm newtm =
  TableDiff mNewName droppedCols addedCols alteredCols
  droppedFKeyConstraints computedFieldDiff uniqueOrPrimaryCons mNewDesc
  where
    mNewName = bool (Just $ tmTable newtm) Nothing $ tmTable oldtm == tmTable newtm
    oldCols = _ptmiColumns $ tmInfo oldtm
    newCols = _ptmiColumns $ tmInfo newtm

    uniqueOrPrimaryCons = map _cName $
      maybeToList (_pkConstraint <$> _ptmiPrimaryKey (tmInfo newtm))
        <> toList (_ptmiUniqueConstraints $ tmInfo newtm)

    mNewDesc = _ptmiDescription $ tmInfo newtm

    droppedCols = map prciName $ getDifference prciPosition oldCols newCols
    addedCols = getDifference prciPosition newCols oldCols
    existingCols = getOverlap prciPosition oldCols newCols
    alteredCols = filter (uncurry (/=)) existingCols

    -- foreign keys are considered dropped only if their oid
    -- and (ref-table, column mapping) are changed
    droppedFKeyConstraints = map (_cName . _fkConstraint) $ HS.toList $
      droppedFKeysWithOid `HS.intersection` droppedFKeysWithUniq
    tmForeignKeys = fmap unForeignKeyMetadata . toList . _ptmiForeignKeys . tmInfo
    droppedFKeysWithOid = HS.fromList $
      (getDifference (_cOid . _fkConstraint) `on` tmForeignKeys) oldtm newtm
    droppedFKeysWithUniq = HS.fromList $
      (getDifference mkFKeyUniqId `on` tmForeignKeys) oldtm newtm
    mkFKeyUniqId (ForeignKey _ reftn colMap) = (reftn, colMap)

    -- calculate computed field diff
    oldComputedFieldMeta = tmComputedFields oldtm
    newComputedFieldMeta = tmComputedFields newtm

    droppedComputedFields = map ccmName $
      getDifference (fmOid . ccmFunctionMeta) oldComputedFieldMeta newComputedFieldMeta

    alteredComputedFields =
      getOverlap (fmOid . ccmFunctionMeta) oldComputedFieldMeta newComputedFieldMeta

    overloadedComputedFieldFunctions =
      let getFunction = fmFunction . ccmFunctionMeta
          getSecondElement (_ NE.:| list) = listToMaybe list
      in mapMaybe (fmap ((&&&) ccmName getFunction) . getSecondElement) $
         flip NE.groupBy newComputedFieldMeta $ \l r ->
         ccmName l == ccmName r && getFunction l == getFunction r

    computedFieldDiff = ComputedFieldDiff droppedComputedFields alteredComputedFields
                      overloadedComputedFieldFunctions

getTableChangeDeps
  :: forall pgKind m. (Backend ('Postgres pgKind), QErrM m, CacheRM m)
  => SourceName -> QualifiedTable -> TableDiff ('Postgres pgKind) -> m [SchemaObjId]
getTableChangeDeps source tn tableDiff = do
  sc <- askSchemaCache
  -- for all the dropped columns
  droppedColDeps <- fmap concat $ forM droppedCols $ \droppedCol -> do
    let objId = SOSourceObj source
                  $ AB.mkAnyBackend
                  $ SOITableObj @('Postgres pgKind) tn
                  $ TOCol @('Postgres pgKind) droppedCol
    return $ getDependentObjs sc objId
  -- for all dropped constraints
  droppedConsDeps <- fmap concat $ forM droppedFKeyConstraints $ \droppedCons -> do
    let objId = SOSourceObj source
                  $ AB.mkAnyBackend
                  $ SOITableObj @('Postgres pgKind) tn
                  $ TOForeignKey @('Postgres pgKind) droppedCons
    return $ getDependentObjs sc objId
  return $ droppedConsDeps <> droppedColDeps <> droppedComputedFieldDeps
  where
    TableDiff _ droppedCols _ _ droppedFKeyConstraints computedFieldDiff _ _ = tableDiff
    droppedComputedFieldDeps =
      map
        (SOSourceObj source
          . AB.mkAnyBackend
          . SOITableObj @('Postgres pgKind) tn
          . TOComputedField)
        $ _cfdDropped computedFieldDiff

data SchemaDiff (b :: BackendType)
  = SchemaDiff
  { _sdDroppedTables :: ![QualifiedTable]
  , _sdAlteredTables :: ![(QualifiedTable, TableDiff b)]
  }

getSchemaDiff
  :: BackendMetadata ('Postgres pgKind)
  => [TableMeta ('Postgres pgKind)]
  -> [TableMeta ('Postgres pgKind)]
  -> SchemaDiff ('Postgres pgKind)
getSchemaDiff oldMeta newMeta =
  SchemaDiff droppedTables survivingTables
  where
    droppedTables = map tmTable $ getDifference (_ptmiOid . tmInfo) oldMeta newMeta
    survivingTables =
      flip map (getOverlap (_ptmiOid . tmInfo) oldMeta newMeta) $ \(oldtm, newtm) ->
      (tmTable oldtm, getTableDiff oldtm newtm)

getSchemaChangeDeps
  :: forall pgKind m. (Backend ('Postgres pgKind), QErrM m, CacheRM m)
  => SourceName -> SchemaDiff ('Postgres pgKind) -> m [SourceObjId ('Postgres pgKind)]
getSchemaChangeDeps source schemaDiff = do
  -- Get schema cache
  sc <- askSchemaCache
  let tableIds =
        map
          (SOSourceObj source . AB.mkAnyBackend . SOITable @('Postgres pgKind))
          droppedTables
  -- Get the dependent of the dropped tables
  let tableDropDeps = concatMap (getDependentObjs sc) tableIds
  tableModDeps <- concat <$> traverse (uncurry (getTableChangeDeps source)) alteredTables
  -- return $ filter (not . isDirectDep) $
  return $ mapMaybe getIndirectDep $
    HS.toList $ HS.fromList $ tableDropDeps <> tableModDeps
  where
    SchemaDiff droppedTables alteredTables = schemaDiff

    getIndirectDep :: SchemaObjId -> Maybe (SourceObjId ('Postgres pgKind))
    getIndirectDep (SOSourceObj s exists) =
      AB.unpackAnyBackend exists >>= \case
        srcObjId@(SOITableObj tn _) ->
          -- Indirect dependancy shouldn't be of same source and not among dropped tables
          if not (s == source && tn `HS.member` HS.fromList droppedTables)
            then Just srcObjId
            else Nothing
        srcObjId -> Just srcObjId
    getIndirectDep _ = Nothing

data FunctionDiff
  = FunctionDiff
  { fdDropped :: ![QualifiedFunction]
  , fdAltered :: ![(QualifiedFunction, FunctionVolatility)]
  } deriving (Show, Eq)

getFuncDiff :: [FunctionMeta] -> [FunctionMeta] -> FunctionDiff
getFuncDiff oldMeta newMeta =
  FunctionDiff droppedFuncs alteredFuncs
  where
    droppedFuncs = map fmFunction $ getDifference fmOid oldMeta newMeta
    alteredFuncs = mapMaybe mkAltered $ getOverlap fmOid oldMeta newMeta
    mkAltered (oldfm, newfm) =
      let isTypeAltered = fmType oldfm /= fmType newfm
          alteredFunc = (fmFunction oldfm, fmType newfm)
      in bool Nothing (Just alteredFunc) $ isTypeAltered

getOverloadedFuncs
  :: [QualifiedFunction] -> [FunctionMeta] -> [QualifiedFunction]
getOverloadedFuncs trackedFuncs newFuncMeta =
  toList $ duplicates $ map fmFunction trackedMeta
  where
    trackedMeta = flip filter newFuncMeta $ \fm ->
      fmFunction fm `elem` trackedFuncs

-- | @'withMetadataCheck' cascade action@ runs @action@ and checks if the schema changed as a
-- result. If it did, it checks to ensure the changes do not violate any integrity constraints, and
-- if not, incorporates them into the schema cache.
withMetadataCheck
  :: forall (pgKind :: PostgresKind) a m
   . ( Backend ('Postgres pgKind)
     , BackendMetadata ('Postgres pgKind)
     , ToMetadataFetchQuery pgKind
     , CacheRWM m
     , HasServerConfigCtx m
     , MetadataM m
     , MonadBaseControl IO m
     , MonadError QErr m
     , MonadIO m
     )
  => SourceName -> Bool -> Q.TxAccess -> LazyTxT QErr m a -> m a
withMetadataCheck source cascade txAccess action = do
  SourceInfo _ preActionTables preActionFunctions sourceConfig <- askSourceInfo @('Postgres pgKind) source

  (actionResult, metadataUpdater) <-
    liftEitherM $ runExceptT $ runLazyTx (_pscExecCtx sourceConfig) txAccess $ do
      -- Drop event triggers so no interference is caused to the sql query
      forM_ (M.elems preActionTables) $ \tableInfo -> do
        let eventTriggers = _tiEventTriggerInfoMap tableInfo
        forM_ (M.keys eventTriggers) (liftTx . delTriggerQ)

      -- Get the metadata before the sql query, everything, need to filter this
      (preActionTableMeta, preActionFunctionMeta) <- fetchMeta preActionTables preActionFunctions

      -- Run the action
      actionResult <- action
      -- Get the metadata after the sql query
      (postActionTableMeta, postActionFunctionMeta) <- fetchMeta preActionTables preActionFunctions

      let preActionTableMeta' = filter (flip M.member preActionTables . tmTable) preActionTableMeta
          schemaDiff = getSchemaDiff preActionTableMeta' postActionTableMeta
          FunctionDiff droppedFuncs alteredFuncs = getFuncDiff preActionFunctionMeta postActionFunctionMeta
          overloadedFuncs = getOverloadedFuncs (M.keys preActionFunctions) postActionFunctionMeta

      -- Do not allow overloading functions
      unless (null overloadedFuncs) $
        throw400 NotSupported $ "the following tracked function(s) cannot be overloaded: "
        <> commaSeparated overloadedFuncs

      indirectSourceDeps <- getSchemaChangeDeps source schemaDiff

      let indirectDeps =
            map
              (SOSourceObj source . AB.mkAnyBackend)
              indirectSourceDeps
      -- Report back with an error if cascade is not set
      when (indirectDeps /= [] && not cascade) $ reportDepsExt indirectDeps []

      metadataUpdater <- execWriterT $ do
        -- Purge all the indirect dependents from state
        mapM_ (purgeDependentObject source >=> tell) indirectSourceDeps

        -- Purge all dropped functions
        let purgedFuncs = flip mapMaybe indirectSourceDeps $ \case
              SOIFunction qf -> Just qf
              _              -> Nothing

        forM_ (droppedFuncs \\ purgedFuncs) $ tell . dropFunctionInMetadata @('Postgres pgKind) source

        -- Process altered functions
        forM_ alteredFuncs $ \(qf, newTy) -> do
          when (newTy == FTVOLATILE) $
            throw400 NotSupported $
            "type of function " <> qf <<> " is altered to \"VOLATILE\" which is not supported now"

        -- update the metadata with the changes
        processSchemaChanges preActionTables schemaDiff

      pure (actionResult, metadataUpdater)

  -- Build schema cache with updated metadata
  withNewInconsistentObjsCheck $
    buildSchemaCacheWithInvalidations mempty{ciSources = HS.singleton source} metadataUpdater

  postActionSchemaCache <- askSchemaCache

  -- Recreate event triggers in hdb_catalog
  let postActionTables = fromMaybe mempty $ unsafeTableCache @('Postgres pgKind) source $ scSources postActionSchemaCache
  serverConfigCtx <- askServerConfigCtx
  liftEitherM $ runPgSourceWriteTx sourceConfig $
    forM_ (M.elems postActionTables) $ \(TableInfo coreInfo _ eventTriggers) -> do
      let table = _tciName coreInfo
          columns = getCols $ _tciFieldInfoMap coreInfo
      forM_ (M.toList eventTriggers) $ \(triggerName, eti) -> do
        let opsDefinition = etiOpsDef eti
        flip runReaderT serverConfigCtx $ mkAllTriggersQ triggerName table columns opsDefinition

  pure actionResult
  where
    processSchemaChanges
      :: ( MonadError QErr m'
         , CacheRM m'
         , MonadWriter MetadataModifier m'
         )
      => TableCache ('Postgres pgKind) -> SchemaDiff ('Postgres pgKind) -> m' ()
    processSchemaChanges preActionTables schemaDiff = do
      -- Purge the dropped tables
      forM_ droppedTables $
        \tn -> tell $ MetadataModifier $ metaSources.ix source.(toSourceMetadata @('Postgres pgKind)).smTables %~ OMap.delete tn

      for_ alteredTables $ \(oldQtn, tableDiff) -> do
        ti <- onNothing
          (M.lookup oldQtn preActionTables)
          (throw500 $ "old table metadata not found in cache : " <>> oldQtn)
        processTableChanges source (_tiCoreInfo ti) tableDiff
      where
        SchemaDiff droppedTables alteredTables = schemaDiff

processTableChanges
  :: forall pgKind m
   . ( Backend ('Postgres pgKind)
     , BackendMetadata ('Postgres pgKind)
     , MonadError QErr m
     , CacheRM m
     , MonadWriter MetadataModifier m
     )
  => SourceName -> TableCoreInfo ('Postgres pgKind) -> TableDiff ('Postgres pgKind) -> m ()
processTableChanges source ti tableDiff = do
  -- If table rename occurs then don't replace constraints and
  -- process dropped/added columns, because schema reload happens eventually
  sc <- askSchemaCache
  let tn = _tciName ti
      withOldTabName = do
        procAlteredCols sc tn

      withNewTabName newTN = do
        let tnGQL = snakeCaseQualifiedObject newTN
        -- check for GraphQL schema conflicts on new name
        checkConflictingNode sc tnGQL
        procAlteredCols sc tn
        -- update new table in metadata
        renameTableInMetadata @('Postgres pgKind) source newTN tn

  -- Process computed field diff
  processComputedFieldDiff tn
  -- Drop custom column names for dropped columns
  possiblyDropCustomColumnNames tn
  maybe withOldTabName withNewTabName mNewName
  where
    TableDiff mNewName droppedCols _ alteredCols _ computedFieldDiff _ _ = tableDiff

    possiblyDropCustomColumnNames tn = do
      let TableConfig customFields customColumnNames customName = _tciCustomConfig ti
          modifiedCustomColumnNames = foldl' (flip M.delete) customColumnNames droppedCols
      when (modifiedCustomColumnNames /= customColumnNames) $
        tell $ MetadataModifier $
          tableMetadataSetter @('Postgres pgKind) source tn.tmConfiguration .~ TableConfig customFields modifiedCustomColumnNames customName

    procAlteredCols sc tn = for_ alteredCols $
      \( RawColumnInfo oldName _ oldType _ _
       , RawColumnInfo newName _ newType _ _ ) -> do
        if | oldName /= newName ->
             renameColumnInMetadata oldName newName source tn (_tciFieldInfoMap ti)

           | oldType /= newType -> do
              let colId =
                    SOSourceObj source
                      $ AB.mkAnyBackend
                      $ SOITableObj @('Postgres pgKind) tn
                      $ TOCol @('Postgres pgKind) oldName
                  typeDepObjs = getDependentObjsWith (== DROnType) sc colId

              unless (null typeDepObjs) $ throw400 DependencyError $
                "cannot change type of column " <> oldName <<> " in table "
                <> tn <<> " because of the following dependencies : " <>
                reportSchemaObjs typeDepObjs

           | otherwise -> pure ()

    processComputedFieldDiff table  = do
      let ComputedFieldDiff _ altered overloaded = computedFieldDiff
          getFunction = fmFunction . ccmFunctionMeta
      forM_ overloaded $ \(columnName, function) ->
        throw400 NotSupported $ "The function " <> function
        <<> " associated with computed field" <> columnName
        <<> " of table " <> table <<> " is being overloaded"
      forM_ altered $ \(old, new) ->
        if | (fmType . ccmFunctionMeta) new == FTVOLATILE ->
             throw400 NotSupported $ "The type of function " <> getFunction old
             <<> " associated with computed field " <> ccmName old
             <<> " of table " <> table <<> " is being altered to \"VOLATILE\""
           | otherwise -> pure ()
