{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TupleSections #-}

-- | Module for detecting if recompilation is required
module GHC.Iface.Recomp
   ( checkOldIface
   , RecompileRequired(..)
   , recompileRequired
   , addFingerprints
   )
where

import GHC.Prelude

import GHC.Driver.Backend
import GHC.Driver.Config.Finder
import GHC.Driver.Env
import GHC.Driver.Session
import GHC.Driver.Ppr
import GHC.Driver.Plugins ( PluginRecompile(..), PluginWithArgs(..), pluginRecompile', plugins )

import GHC.Iface.Syntax
import GHC.Iface.Recomp.Binary
import GHC.Iface.Load
import GHC.Iface.Recomp.Flags
import GHC.Iface.Env

import GHC.Core
import GHC.Tc.Utils.Monad
import GHC.Hs

import GHC.Data.Graph.Directed
import GHC.Data.Maybe
import GHC.Data.FastString

import GHC.Utils.Error
import GHC.Utils.Panic
import GHC.Utils.Panic.Plain
import GHC.Utils.Outputable as Outputable
import GHC.Utils.Misc as Utils hiding ( eqListBy )
import GHC.Utils.Binary
import GHC.Utils.Fingerprint
import GHC.Utils.Exception
import GHC.Utils.Logger
import GHC.Utils.Constants (debugIsOn)
import GHC.Utils.Trace

import GHC.Types.Annotations
import GHC.Types.Name
import GHC.Types.Name.Set
import GHC.Types.SrcLoc
import GHC.Types.Unique
import GHC.Types.Unique.Set
import GHC.Types.Fixity.Env

import GHC.Unit.External
import GHC.Unit.Finder
import GHC.Unit.State
import GHC.Unit.Home
import GHC.Unit.Module
import GHC.Unit.Module.ModIface
import GHC.Unit.Module.ModSummary
import GHC.Unit.Module.Warnings
import GHC.Unit.Module.Deps

import Control.Monad
import Data.Function
import Data.List (sortBy, sort)
import qualified Data.Map as Map
import Data.Word (Word64)
import Data.Either

--Qualified import so we can define a Semigroup instance
-- but it doesn't clash with Outputable.<>
import qualified Data.Semigroup
import GHC.List (uncons)
import Data.Ord
import Data.Containers.ListUtils

{-
  -----------------------------------------------
          Recompilation checking
  -----------------------------------------------

A complete description of how recompilation checking works can be
found in the wiki commentary:

 https://gitlab.haskell.org/ghc/ghc/wikis/commentary/compiler/recompilation-avoidance

Please read the above page for a top-down description of how this all
works.  Notes below cover specific issues related to the implementation.

Basic idea:

  * In the mi_usages information in an interface, we record the
    fingerprint of each free variable of the module

  * In mkIface, we compute the fingerprint of each exported thing A.f.
    For each external thing that A.f refers to, we include the fingerprint
    of the external reference when computing the fingerprint of A.f.  So
    if anything that A.f depends on changes, then A.f's fingerprint will
    change.
    Also record any dependent files added with
      * addDependentFile
      * #include
      * -optP-include

  * In checkOldIface we compare the mi_usages for the module with
    the actual fingerprint for all each thing recorded in mi_usages
-}

data RecompileRequired
  = UpToDate
       -- ^ everything is up to date, recompilation is not required
  | MustCompile
       -- ^ The .hs file has been modified, or the .o/.hi file does not exist
  | RecompBecause String
       -- ^ The .o/.hi files are up to date, but something else has changed
       -- to force recompilation; the String says what (one-line summary)
   deriving (Eq, Show)

instance Semigroup RecompileRequired where
  UpToDate <> r = r
  mc <> _       = mc

instance Monoid RecompileRequired where
  mempty = UpToDate

recompileRequired :: RecompileRequired -> Bool
recompileRequired UpToDate = False
recompileRequired _ = True

-- | Top level function to check if the version of an old interface file
-- is equivalent to the current source file the user asked us to compile.
-- If the same, we can avoid recompilation. We return a tuple where the
-- first element is a bool saying if we should recompile the object file
-- and the second is maybe the interface file, where Nothing means to
-- rebuild the interface file and not use the existing one.
checkOldIface
  :: HscEnv
  -> ModSummary
  -> Maybe ModIface         -- Old interface from compilation manager, if any
  -> IO (RecompileRequired, Maybe ModIface)

checkOldIface hsc_env mod_summary maybe_iface
  = do  let dflags = hsc_dflags hsc_env
        let logger = hsc_logger hsc_env
        showPass logger $
            "Checking old interface for " ++
              (showPpr dflags $ ms_mod mod_summary) ++
              " (use -ddump-hi-diffs for more details)"
        initIfaceCheck (text "checkOldIface") hsc_env $
            check_old_iface hsc_env mod_summary maybe_iface

check_old_iface
  :: HscEnv
  -> ModSummary
  -> Maybe ModIface
  -> IfG (RecompileRequired, Maybe ModIface)

check_old_iface hsc_env mod_summary maybe_iface
  = let dflags = hsc_dflags hsc_env
        logger = hsc_logger hsc_env
        getIface =
            case maybe_iface of
                Just _  -> do
                    trace_if logger (text "We already have the old interface for" <+>
                      ppr (ms_mod mod_summary))
                    return maybe_iface
                Nothing -> loadIface

        loadIface = do
             let iface_path = msHiFilePath mod_summary
             let ncu        = hsc_NC hsc_env
             read_result <- readIface dflags ncu (ms_mod mod_summary) iface_path
             case read_result of
                 Failed err -> do
                     trace_if logger (text "FYI: cannot read old interface file:" $$ nest 4 err)
                     trace_hi_diffs logger (text "Old interface file was invalid:" $$ nest 4 err)
                     return Nothing
                 Succeeded iface -> do
                     trace_if logger (text "Read the interface file" <+> text iface_path)
                     return $ Just iface

        src_changed
            | gopt Opt_ForceRecomp dflags    = True
            | otherwise = False
    in do
        when src_changed $
            liftIO $ trace_hi_diffs logger (nest 4 $ text "Recompilation check turned off")

        case src_changed of
            -- If the source has changed and we're in interactive mode,
            -- avoid reading an interface; just return the one we might
            -- have been supplied with.
            True | not (backendProducesObject $ backend dflags) ->
                return (MustCompile, maybe_iface)

            -- Try and read the old interface for the current module
            -- from the .hi file left from the last time we compiled it
            True -> do
                maybe_iface' <- liftIO $ getIface
                return (MustCompile, maybe_iface')

            False -> do
                maybe_iface' <- liftIO $ getIface
                case maybe_iface' of
                    -- We can't retrieve the iface
                    Nothing    -> return (MustCompile, Nothing)

                    -- We have got the old iface; check its versions
                    -- even in the SourceUnmodifiedAndStable case we
                    -- should check versions because some packages
                    -- might have changed or gone away.
                    Just iface ->
                      checkVersions hsc_env mod_summary iface

-- | Check if a module is still the same 'version'.
--
-- This function is called in the recompilation checker after we have
-- determined that the module M being checked hasn't had any changes
-- to its source file since we last compiled M. So at this point in general
-- two things may have changed that mean we should recompile M:
--   * The interface export by a dependency of M has changed.
--   * The compiler flags specified this time for M have changed
--     in a manner that is significant for recompilation.
-- We return not just if we should recompile the object file but also
-- if we should rebuild the interface file.
checkVersions :: HscEnv
              -> ModSummary
              -> ModIface       -- Old interface
              -> IfG (RecompileRequired, Maybe ModIface)
checkVersions hsc_env mod_summary iface
  = do { liftIO $ trace_hi_diffs logger
                        (text "Considering whether compilation is required for" <+>
                        ppr (mi_module iface) <> colon)

       -- readIface will have verified that the UnitId matches,
       -- but we ALSO must make sure the instantiation matches up.  See
       -- test case bkpcabal04!
       ; hsc_env <- getTopEnv
       ; if mi_src_hash iface /= ms_hs_hash mod_summary
            then return (RecompBecause "Source file changed", Nothing) else do {
       ; if not (isHomeModule home_unit (mi_module iface))
            then return (RecompBecause "-this-unit-id changed", Nothing) else do {
       ; recomp <- liftIO $ checkFlagHash hsc_env iface
       ; if recompileRequired recomp then return (recomp, Nothing) else do {
       ; recomp <- liftIO $ checkOptimHash hsc_env iface
       ; if recompileRequired recomp then return (recomp, Nothing) else do {
       ; recomp <- liftIO $ checkHpcHash hsc_env iface
       ; if recompileRequired recomp then return (recomp, Nothing) else do {
       ; recomp <- liftIO $ checkMergedSignatures hsc_env mod_summary iface
       ; if recompileRequired recomp then return (recomp, Nothing) else do {
       ; recomp <- liftIO $ checkHsig logger home_unit mod_summary iface
       ; if recompileRequired recomp then return (recomp, Nothing) else do {
       ; recomp <- pure (checkHie dflags mod_summary)
       ; if recompileRequired recomp then return (recomp, Nothing) else do {
       ; recomp <- checkDependencies hsc_env mod_summary iface
       ; if recompileRequired recomp then return (recomp, Just iface) else do {
       ; recomp <- checkPlugins hsc_env iface
       ; if recompileRequired recomp then return (recomp, Nothing) else do {


       -- Source code unchanged and no errors yet... carry on
       --
       -- First put the dependent-module info, read from the old
       -- interface, into the envt, so that when we look for
       -- interfaces we look for the right one (.hi or .hi-boot)
       --
       -- It's just temporary because either the usage check will succeed
       -- (in which case we are done with this module) or it'll fail (in which
       -- case we'll compile the module from scratch anyhow).

       when (isOneShot (ghcMode (hsc_dflags hsc_env))) $ do {
          ; updateEps_ $ \eps  -> eps { eps_is_boot = mkModDeps $ (dep_boot_mods (mi_deps iface)) }
       }
       ; recomp <- checkList [checkModUsage (hsc_FC hsc_env) (homeUnitAsUnit home_unit) u
                             | u <- mi_usages iface]
       ; return (recomp, Just iface)
    }}}}}}}}}}}
  where
    logger = hsc_logger hsc_env
    dflags = hsc_dflags hsc_env
    home_unit = hsc_home_unit hsc_env




-- | Check if any plugins are requesting recompilation
checkPlugins :: HscEnv -> ModIface -> IfG RecompileRequired
checkPlugins hsc_env iface = liftIO $ do
  new_fingerprint <- fingerprintPlugins hsc_env
  let old_fingerprint = mi_plugin_hash (mi_final_exts iface)
  pr <- mconcat <$> mapM pluginRecompile' (plugins hsc_env)
  return $
    pluginRecompileToRecompileRequired old_fingerprint new_fingerprint pr

fingerprintPlugins :: HscEnv -> IO Fingerprint
fingerprintPlugins hsc_env =
  fingerprintPlugins' $ plugins hsc_env

fingerprintPlugins' :: [PluginWithArgs] -> IO Fingerprint
fingerprintPlugins' plugins = do
  res <- mconcat <$> mapM pluginRecompile' plugins
  return $ case res of
      NoForceRecompile -> fingerprintString "NoForceRecompile"
      ForceRecompile   -> fingerprintString "ForceRecompile"
      -- is the chance of collision worth worrying about?
      -- An alternative is to fingerprintFingerprints [fingerprintString
      -- "maybeRecompile", fp]
      (MaybeRecompile fp) -> fp


pluginRecompileToRecompileRequired
    :: Fingerprint -> Fingerprint -> PluginRecompile -> RecompileRequired
pluginRecompileToRecompileRequired old_fp new_fp pr
  | old_fp == new_fp =
    case pr of
      NoForceRecompile  -> UpToDate

      -- we already checked the fingerprint above so a mismatch is not possible
      -- here, remember that: `fingerprint (MaybeRecomp x) == x`.
      MaybeRecompile _  -> UpToDate

      -- when we have an impure plugin in the stack we have to unconditionally
      -- recompile since it might integrate all sorts of crazy IO results into
      -- its compilation output.
      ForceRecompile    -> RecompBecause "Impure plugin forced recompilation"

  | old_fp `elem` magic_fingerprints ||
    new_fp `elem` magic_fingerprints
    -- The fingerprints do not match either the old or new one is a magic
    -- fingerprint. This happens when non-pure plugins are added for the first
    -- time or when we go from one recompilation strategy to another: (force ->
    -- no-force, maybe-recomp -> no-force, no-force -> maybe-recomp etc.)
    --
    -- For example when we go from ForceRecomp to NoForceRecomp
    -- recompilation is triggered since the old impure plugins could have
    -- changed the build output which is now back to normal.
    = RecompBecause "Plugins changed"

  | otherwise =
    let reason = "Plugin fingerprint changed" in
    case pr of
      -- even though a plugin is forcing recompilation the fingerprint changed
      -- which would cause recompilation anyways so we report the fingerprint
      -- change instead.
      ForceRecompile   -> RecompBecause reason

      _                -> RecompBecause reason

 where
   magic_fingerprints =
       [ fingerprintString "NoForceRecompile"
       , fingerprintString "ForceRecompile"
       ]


-- | Check if an hsig file needs recompilation because its
-- implementing module has changed.
checkHsig :: Logger -> HomeUnit -> ModSummary -> ModIface -> IO RecompileRequired
checkHsig logger home_unit mod_summary iface = do
    let outer_mod = ms_mod mod_summary
        inner_mod = homeModuleNameInstantiation home_unit (moduleName outer_mod)
    massert (isHomeModule home_unit outer_mod)
    case inner_mod == mi_semantic_module iface of
        True -> up_to_date logger (text "implementing module unchanged")
        False -> return (RecompBecause "implementing module changed")

-- | Check if @.hie@ file is out of date or missing.
checkHie :: DynFlags -> ModSummary -> RecompileRequired
checkHie dflags mod_summary =
    let hie_date_opt = ms_hie_date mod_summary
        hi_date = ms_iface_date mod_summary
    in if not (gopt Opt_WriteHie dflags)
      then UpToDate
      else case (hie_date_opt, hi_date) of
             (Nothing, _) -> RecompBecause "HIE file is missing"
             (Just hie_date, Just hi_date)
                 | hie_date < hi_date
                 -> RecompBecause "HIE file is out of date"
             _ -> UpToDate

-- | Check the flags haven't changed
checkFlagHash :: HscEnv -> ModIface -> IO RecompileRequired
checkFlagHash hsc_env iface = do
    let logger   = hsc_logger hsc_env
    let old_hash = mi_flag_hash (mi_final_exts iface)
    new_hash <- fingerprintDynFlags hsc_env (mi_module iface) putNameLiterally
    case old_hash == new_hash of
        True  -> up_to_date logger (text "Module flags unchanged")
        False -> out_of_date_hash logger "flags changed"
                     (text "  Module flags have changed")
                     old_hash new_hash

-- | Check the optimisation flags haven't changed
checkOptimHash :: HscEnv -> ModIface -> IO RecompileRequired
checkOptimHash hsc_env iface = do
    let logger   = hsc_logger hsc_env
    let old_hash = mi_opt_hash (mi_final_exts iface)
    new_hash <- fingerprintOptFlags (hsc_dflags hsc_env)
                                               putNameLiterally
    if | old_hash == new_hash
         -> up_to_date logger (text "Optimisation flags unchanged")
       | gopt Opt_IgnoreOptimChanges (hsc_dflags hsc_env)
         -> up_to_date logger (text "Optimisation flags changed; ignoring")
       | otherwise
         -> out_of_date_hash logger "Optimisation flags changed"
                     (text "  Optimisation flags have changed")
                     old_hash new_hash

-- | Check the HPC flags haven't changed
checkHpcHash :: HscEnv -> ModIface -> IO RecompileRequired
checkHpcHash hsc_env iface = do
    let logger   = hsc_logger hsc_env
    let old_hash = mi_hpc_hash (mi_final_exts iface)
    new_hash <- fingerprintHpcFlags (hsc_dflags hsc_env)
                                               putNameLiterally
    if | old_hash == new_hash
         -> up_to_date logger (text "HPC flags unchanged")
       | gopt Opt_IgnoreHpcChanges (hsc_dflags hsc_env)
         -> up_to_date logger (text "HPC flags changed; ignoring")
       | otherwise
         -> out_of_date_hash logger "HPC flags changed"
                     (text "  HPC flags have changed")
                     old_hash new_hash

-- Check that the set of signatures we are merging in match.
-- If the -unit-id flags change, this can change too.
checkMergedSignatures :: HscEnv -> ModSummary -> ModIface -> IO RecompileRequired
checkMergedSignatures hsc_env mod_summary iface = do
    let logger     = hsc_logger hsc_env
    let unit_state = hsc_units hsc_env
    let old_merged = sort [ mod | UsageMergedRequirement{ usg_mod = mod } <- mi_usages iface ]
        new_merged = case Map.lookup (ms_mod_name mod_summary)
                                     (requirementContext unit_state) of
                        Nothing -> []
                        Just r -> sort $ map (instModuleToModule unit_state) r
    if old_merged == new_merged
        then up_to_date logger (text "signatures to merge in unchanged" $$ ppr new_merged)
        else return (RecompBecause "signatures to merge in changed")

-- If the direct imports of this module are resolved to targets that
-- are not among the dependencies of the previous interface file,
-- then we definitely need to recompile.  This catches cases like
--   - an exposed package has been upgraded
--   - we are compiling with different package flags
--   - a home module that was shadowing a package module has been removed
--   - a new home module has been added that shadows a package module
-- See bug #1372.
--
-- Returns (RecompBecause <textual reason>) if recompilation is required.
checkDependencies :: HscEnv -> ModSummary -> ModIface -> IfG RecompileRequired
checkDependencies hsc_env summary iface
 = do
    res <- liftIO $ traverse (\(mb_pkg, L _ mod) ->
              let reason = moduleNameString mod ++ " changed"
              in classify reason <$> findImportedModule fc fopts units home_unit mod (mb_pkg))
              (ms_imps summary ++ ms_srcimps summary)
    case sequence (res ++ [Right (fake_ghc_prim_import)| ms_ghc_prim_import summary]) of
      Left recomp -> return recomp
      Right es -> do
        let (hs, ps) = partitionEithers es
        res1 <- liftIO $ check_mods (sort hs) prev_dep_mods

        let allPkgDeps = sortBy (comparing snd) $ nubOrdOn snd (ps ++ implicit_deps ++ bkpk_units)
        res2 <- liftIO $ check_packages allPkgDeps prev_dep_pkgs
        return (res1 `mappend` res2)
 where
   dflags        = hsc_dflags hsc_env
   fopts         = initFinderOpts dflags
   logger        = hsc_logger hsc_env
   fc            = hsc_FC hsc_env
   home_unit     = hsc_home_unit hsc_env
   units         = hsc_units hsc_env
   prev_dep_mods = map gwib_mod $ dep_direct_mods (mi_deps iface)
   prev_dep_pkgs = sort (dep_direct_pkgs (mi_deps iface))
   bkpk_units    = map (("Signature",) . indefUnit . instUnitInstanceOf . moduleUnit) (requirementMerges units (moduleName (mi_module iface)))

   implicit_deps = map ("Implicit",) (implicitPackageDeps dflags)

   -- GHC.Prim is very special and doesn't appear in ms_textual_imps but
   -- ghc-prim will appear in the package dependencies still. In order to not confuse
   -- the recompilation logic we need to not forget we imported GHC.Prim.
   fake_ghc_prim_import = if homeUnitId home_unit == primUnitId
                            then Left (mkModuleName "GHC.Prim")
                            else Right ("GHC.Prim", primUnitId)


   classify _ (Found _ mod)
    | isHomeUnit home_unit (moduleUnit mod) = Right (Left (moduleName mod))
    | otherwise = Right (Right (moduleNameString (moduleName mod), toUnitId $ moduleUnit mod))
   classify reason _ = Left (RecompBecause reason)

   check_mods [] [] = return UpToDate
   check_mods [] (old:_) = do
     -- This case can happen when a module is change from HPT to package import
     trace_hi_diffs logger $
      text "module no longer " <> quotes (ppr old) <>
        text "in dependencies"
     return (RecompBecause (moduleNameString old ++ " removed"))
   check_mods (new:news) olds
    | Just (old, olds') <- uncons olds
    , new == old = check_mods (dropWhile (== new) news) olds'
    | otherwise = do
        trace_hi_diffs logger $
           text "imported module " <> quotes (ppr new) <>
           text " not among previous dependencies"
        return (RecompBecause (moduleNameString new ++ " added"))

   check_packages :: [(String, UnitId)] -> [UnitId] -> IO RecompileRequired
   check_packages [] [] = return UpToDate
   check_packages [] (old:_) = do
     trace_hi_diffs logger $
      text "package " <> quotes (ppr old) <>
        text "no longer in dependencies"
     return (RecompBecause (unitString old ++ " removed"))
   check_packages (new:news) olds
    | Just (old, olds') <- uncons olds
    , snd new == old = check_packages (dropWhile ((== (snd new)) . snd) news) olds'
    | otherwise = do
        trace_hi_diffs logger $
           text "imported package " <> quotes (ppr new) <>
           text " not among previous dependencies"
        return (RecompBecause ((fst new) ++ " package changed"))


needInterface :: Module -> (ModIface -> IO RecompileRequired)
             -> IfG RecompileRequired
needInterface mod continue
  = do
      mb_recomp <- getFromModIface
        "need version info for"
        mod
        continue
      case mb_recomp of
        Nothing -> return MustCompile
        Just recomp -> return recomp

getFromModIface :: String -> Module -> (ModIface -> IO a)
              -> IfG (Maybe a)
getFromModIface doc_msg mod getter
  = do  -- Load the imported interface if possible
    logger <- getLogger
    let doc_str = sep [text doc_msg, ppr mod]
    liftIO $ trace_hi_diffs logger (text "Checking interface for module" <+> ppr mod)

    mb_iface <- loadInterface doc_str mod ImportBySystem
        -- Load the interface, but don't complain on failure;
        -- Instead, get an Either back which we can test

    case mb_iface of
      Failed _ -> do
        liftIO $ trace_hi_diffs logger (sep [text "Couldn't load interface for module", ppr mod])
        return Nothing
                  -- Couldn't find or parse a module mentioned in the
                  -- old interface file.  Don't complain: it might
                  -- just be that the current module doesn't need that
                  -- import and it's been deleted
      Succeeded iface -> Just <$> liftIO (getter iface)

-- | Given the usage information extracted from the old
-- M.hi file for the module being compiled, figure out
-- whether M needs to be recompiled.
checkModUsage :: FinderCache -> Unit -> Usage -> IfG RecompileRequired
checkModUsage _ _this_pkg UsagePackageModule{
                                usg_mod = mod,
                                usg_mod_hash = old_mod_hash } = do
  logger <- getLogger
  needInterface mod $ \iface -> do
    let reason = moduleNameString (moduleName mod) ++ " changed"
    checkModuleFingerprint logger reason old_mod_hash (mi_mod_hash (mi_final_exts iface))
        -- We only track the ABI hash of package modules, rather than
        -- individual entity usages, so if the ABI hash changes we must
        -- recompile.  This is safe but may entail more recompilation when
        -- a dependent package has changed.

checkModUsage _ _ UsageMergedRequirement{ usg_mod = mod, usg_mod_hash = old_mod_hash } = do
  logger <- getLogger
  needInterface mod $ \iface -> do
    let reason = moduleNameString (moduleName mod) ++ " changed (raw)"
    checkModuleFingerprint logger reason old_mod_hash (mi_mod_hash (mi_final_exts iface))
checkModUsage _ this_pkg UsageHomeModuleInterface{ usg_mod_name = mod_name, usg_iface_hash = old_mod_hash } = do
  let mod = mkModule this_pkg mod_name
  logger <- getLogger
  needInterface mod $ \iface -> do
    let reason = moduleNameString (moduleName mod) ++ " changed (interface)"
    checkIfaceFingerprint logger reason old_mod_hash (mi_iface_hash (mi_final_exts iface))

checkModUsage _ this_pkg UsageHomeModule{
                                usg_mod_name = mod_name,
                                usg_mod_hash = old_mod_hash,
                                usg_exports = maybe_old_export_hash,
                                usg_entities = old_decl_hash }
  = do
    let mod = mkModule this_pkg mod_name
    logger <- getLogger
    needInterface mod $ \iface -> do
     let
         new_mod_hash    = mi_mod_hash (mi_final_exts iface)
         new_decl_hash   = mi_hash_fn  (mi_final_exts iface)
         new_export_hash = mi_exp_hash (mi_final_exts iface)

         reason = moduleNameString mod_name ++ " changed"

     liftIO $ do
           -- CHECK MODULE
       recompile <- checkModuleFingerprint logger reason old_mod_hash new_mod_hash
       if not (recompileRequired recompile)
         then return UpToDate
         else
           -- CHECK EXPORT LIST
           checkMaybeHash logger reason maybe_old_export_hash new_export_hash
               (text "  Export list changed") $ do

                 -- CHECK ITEMS ONE BY ONE
                 !recompile <- checkList [ checkEntityUsage logger reason new_decl_hash u
                                          | u <- old_decl_hash]
                 if recompileRequired recompile
                   then return recompile     -- This one failed, so just bail out now
                   else up_to_date logger (text "  Great!  The bits I use are up to date")

checkModUsage fc _this_pkg UsageFile{ usg_file_path = file,
                                   usg_file_hash = old_hash,
                                   usg_file_label = mlabel } =
  liftIO $
    handleIO handler $ do
      new_hash <- lookupFileCache fc file
      if (old_hash /= new_hash)
         then return recomp
         else return UpToDate
 where
   reason = file ++ " changed"
   recomp  = RecompBecause (fromMaybe reason mlabel)
   handler = if debugIsOn
      then \e -> pprTrace "UsageFile" (text (show e)) $ return recomp
      else \_ -> return recomp -- if we can't find the file, just recompile, don't fail

------------------------
checkModuleFingerprint
  :: Logger
  -> String
  -> Fingerprint
  -> Fingerprint
  -> IO RecompileRequired
checkModuleFingerprint logger reason old_mod_hash new_mod_hash
  | new_mod_hash == old_mod_hash
  = up_to_date logger (text "Module fingerprint unchanged")

  | otherwise
  = out_of_date_hash logger reason (text "  Module fingerprint has changed")
                     old_mod_hash new_mod_hash

checkIfaceFingerprint
  :: Logger
  -> String
  -> Fingerprint
  -> Fingerprint
  -> IO RecompileRequired
checkIfaceFingerprint logger reason old_mod_hash new_mod_hash
  | new_mod_hash == old_mod_hash
  = up_to_date logger (text "Iface fingerprint unchanged")

  | otherwise
  = out_of_date_hash logger reason (text "  Iface fingerprint has changed")
                     old_mod_hash new_mod_hash

------------------------
checkMaybeHash
  :: Logger
  -> String
  -> Maybe Fingerprint
  -> Fingerprint
  -> SDoc
  -> IO RecompileRequired
  -> IO RecompileRequired
checkMaybeHash logger reason maybe_old_hash new_hash doc continue
  | Just hash <- maybe_old_hash, hash /= new_hash
  = out_of_date_hash logger reason doc hash new_hash
  | otherwise
  = continue

------------------------
checkEntityUsage :: Logger
                 -> String
                 -> (OccName -> Maybe (OccName, Fingerprint))
                 -> (OccName, Fingerprint)
                 -> IO RecompileRequired
checkEntityUsage logger reason new_hash (name,old_hash) = do
  case new_hash name of
    -- We used it before, but it ain't there now
    Nothing       -> out_of_date logger reason (sep [text "No longer exported:", ppr name])
    -- It's there, but is it up to date?
    Just (_, new_hash)
      | new_hash == old_hash
      -> do trace_hi_diffs logger (text "  Up to date" <+> ppr name <+> parens (ppr new_hash))
            return UpToDate
      | otherwise
      -> out_of_date_hash logger reason (text "  Out of date:" <+> ppr name) old_hash new_hash

up_to_date :: Logger -> SDoc -> IO RecompileRequired
up_to_date logger msg = trace_hi_diffs logger msg >> return UpToDate

out_of_date :: Logger -> String -> SDoc -> IO RecompileRequired
out_of_date logger reason msg = trace_hi_diffs logger msg >> return (RecompBecause reason)

out_of_date_hash :: Logger -> String -> SDoc -> Fingerprint -> Fingerprint -> IO RecompileRequired
out_of_date_hash logger reason msg old_hash new_hash
  = out_of_date logger reason (hsep [msg, ppr old_hash, text "->", ppr new_hash])

----------------------
checkList :: Monad m => [m RecompileRequired] -> m RecompileRequired
-- This helper is used in two places
checkList []             = return UpToDate
checkList (check:checks) = do recompile <- check
                              if recompileRequired recompile
                                then return recompile
                                else checkList checks


-- ---------------------------------------------------------------------------
-- Compute fingerprints for the interface

{-
Note [Fingerprinting IfaceDecls]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The general idea here is that we first examine the 'IfaceDecl's and determine
the recursive groups of them. We then walk these groups in dependency order,
serializing each contained 'IfaceDecl' to a "Binary" buffer which we then
hash using MD5 to produce a fingerprint for the group.

However, the serialization that we use is a bit funny: we override the @putName@
operation with our own which serializes the hash of a 'Name' instead of the
'Name' itself. This ensures that the fingerprint of a decl changes if anything
in its transitive closure changes. This trick is why we must be careful about
traversing in dependency order: we need to ensure that we have hashes for
everything referenced by the decl which we are fingerprinting.

Moreover, we need to be careful to distinguish between serialization of binding
Names (e.g. the ifName field of a IfaceDecl) and non-binding (e.g. the ifInstCls
field of a IfaceClsInst): only in the non-binding case should we include the
fingerprint; in the binding case we shouldn't since it is merely the name of the
thing that we are currently fingerprinting.


Note [Fingerprinting recursive groups]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The fingerprinting of a single recursive group is a rather subtle affair, as
seen in #18733.

How not to fingerprint
----------------------

Prior to fixing #18733 we used the following (flawed) scheme to fingerprint a
group in hash environment `hash_env0`:

 1. extend hash_env0, giving each declaration in the group the fingerprint 0
 2. use this environment to hash the declarations' ABIs, resulting in
    group_fingerprint
 3. produce the final hash environment by extending hash_env0, mapping each
    declaration of the group to group_fingerprint

However, this is wrong. Consider, for instance, a program like:

    data A = ARecu B | ABase String deriving (Show)
    data B = BRecu A | BBase Int deriving (Show)

    info :: B
    info = BBase 1

A consequence of (3) is that A and B will have the same fingerprint. This means
that if the user changes `info` to:

    info :: A
    info = ABase "hello"

The program's ABI fingerprint will not change despite `info`'s type, and
therefore ABI, being clearly different.

However, the incorrectness doesn't end there: (1) means that all recursive
occurrences of names within the group will be given the same fingerprint. This
means that the group's fingerprint won't change if we change an occurrence of A
to B.

Surprisingly, this bug (#18733) lurked for many years before being uncovered.

How we now fingerprint
----------------------

As seen above, the fingerprinting function must ensure that a groups
fingerprint captures the structure of within-group occurrences. The scheme that
we use is:

 0. To ensure determinism, sort the declarations into a stable order by
    declaration name

 1. Extend hash_env0, giving each declaration in the group a sequential
    fingerprint (e.g. 0, 1, 2, ...).

 2. Use this environment to hash the declarations' ABIs, resulting in
    group_fingerprint.

    Since we included the sequence number in step (1) programs identical up to
    transposition of recursive occurrences are distinguisable, avoiding the
    second issue mentioned above.

 3. Produce the final environment by extending hash_env, mapping each
    declaration of the group to the hash of (group_fingerprint, i), where
    i is the position of the declaration in the stable ordering.

    Including i in the hash ensures that the first issue noted above is
    avoided.

-}

-- | Add fingerprints for top-level declarations to a 'ModIface'.
--
-- See Note [Fingerprinting IfaceDecls]
addFingerprints
        :: HscEnv
        -> PartialModIface
        -> IO ModIface
addFingerprints hsc_env iface0
 = do
   eps <- hscEPS hsc_env
   let
       decls = mi_decls iface0
       warn_fn = mkIfaceWarnCache (mi_warns iface0)
       fix_fn = mkIfaceFixCache (mi_fixities iface0)

        -- The ABI of a declaration represents everything that is made
        -- visible about the declaration that a client can depend on.
        -- see IfaceDeclABI below.
       declABI :: IfaceDecl -> IfaceDeclABI
       -- TODO: I'm not sure if this should be semantic_mod or this_mod.
       -- See also Note [Identity versus semantic module]
       declABI decl = (this_mod, decl, extras)
        where extras = declExtras fix_fn ann_fn non_orph_rules non_orph_insts
                                  non_orph_fis top_lvl_name_env decl

       -- This is used for looking up the Name of a default method
       -- from its OccName. See Note [default method Name]
       top_lvl_name_env =
         mkOccEnv [ (nameOccName nm, nm)
                  | IfaceId { ifName = nm } <- decls ]

       -- Dependency edges between declarations in the current module.
       -- This is computed by finding the free external names of each
       -- declaration, including IfaceDeclExtras (things that a
       -- declaration implicitly depends on).
       edges :: [ Node Unique IfaceDeclABI ]
       edges = [ DigraphNode abi (getUnique (getOccName decl)) out
               | decl <- decls
               , let abi = declABI decl
               , let out = localOccs $ freeNamesDeclABI abi
               ]

       name_module n = assertPpr (isExternalName n) (ppr n) (nameModule n)
       localOccs =
         map (getUnique . getParent . getOccName)
                        -- NB: names always use semantic module, so
                        -- filtering must be on the semantic module!
                        -- See Note [Identity versus semantic module]
                        . filter ((== semantic_mod) . name_module)
                        . nonDetEltsUniqSet
                   -- It's OK to use nonDetEltsUFM as localOccs is only
                   -- used to construct the edges and
                   -- stronglyConnCompFromEdgedVertices is deterministic
                   -- even with non-deterministic order of edges as
                   -- explained in Note [Deterministic SCC] in GHC.Data.Graph.Directed.
          where getParent :: OccName -> OccName
                getParent occ = lookupOccEnv parent_map occ `orElse` occ

        -- maps OccNames to their parents in the current module.
        -- e.g. a reference to a constructor must be turned into a reference
        -- to the TyCon for the purposes of calculating dependencies.
       parent_map :: OccEnv OccName
       parent_map = foldl' extend emptyOccEnv decls
          where extend env d =
                  extendOccEnvList env [ (b,n) | b <- ifaceDeclImplicitBndrs d ]
                  where n = getOccName d

        -- Strongly-connected groups of declarations, in dependency order
       groups :: [SCC IfaceDeclABI]
       groups = stronglyConnCompFromEdgedVerticesUniq edges

       global_hash_fn = mkHashFun hsc_env eps

        -- How to output Names when generating the data to fingerprint.
        -- Here we want to output the fingerprint for each top-level
        -- Name, whether it comes from the current module or another
        -- module.  In this way, the fingerprint for a declaration will
        -- change if the fingerprint for anything it refers to (transitively)
        -- changes.
       mk_put_name :: OccEnv (OccName,Fingerprint)
                   -> BinHandle -> Name -> IO  ()
       mk_put_name local_env bh name
          | isWiredInName name  =  putNameLiterally bh name
           -- wired-in names don't have fingerprints
          | otherwise
          = assertPpr (isExternalName name) (ppr name) $
            let hash | nameModule name /= semantic_mod =  global_hash_fn name
                     -- Get it from the REAL interface!!
                     -- This will trigger when we compile an hsig file
                     -- and we know a backing impl for it.
                     -- See Note [Identity versus semantic module]
                     | semantic_mod /= this_mod
                     , not (isHoleModule semantic_mod) = global_hash_fn name
                     | otherwise = return (snd (lookupOccEnv local_env (getOccName name)
                           `orElse` pprPanic "urk! lookup local fingerprint"
                                       (ppr name $$ ppr local_env)))
                -- This panic indicates that we got the dependency
                -- analysis wrong, because we needed a fingerprint for
                -- an entity that wasn't in the environment.  To debug
                -- it, turn the panic into a trace, uncomment the
                -- pprTraces below, run the compile again, and inspect
                -- the output and the generated .hi file with
                -- --show-iface.
            in hash >>= put_ bh

        -- take a strongly-connected group of declarations and compute
        -- its fingerprint.

       fingerprint_group :: (OccEnv (OccName,Fingerprint),
                             [(Fingerprint,IfaceDecl)])
                         -> SCC IfaceDeclABI
                         -> IO (OccEnv (OccName,Fingerprint),
                                [(Fingerprint,IfaceDecl)])

       fingerprint_group (local_env, decls_w_hashes) (AcyclicSCC abi)
          = do let hash_fn = mk_put_name local_env
                   decl = abiDecl abi
               --pprTrace "fingerprinting" (ppr (ifName decl) ) $ do
               hash <- computeFingerprint hash_fn abi
               env' <- extend_hash_env local_env (hash,decl)
               return (env', (hash,decl) : decls_w_hashes)

       fingerprint_group (local_env, decls_w_hashes) (CyclicSCC abis)
          = do let stable_abis = sortBy cmp_abiNames abis
                   stable_decls = map abiDecl stable_abis
               local_env1 <- foldM extend_hash_env local_env
                                   (zip (map mkRecFingerprint [0..]) stable_decls)
                -- See Note [Fingerprinting recursive groups]
               let hash_fn = mk_put_name local_env1
               -- pprTrace "fingerprinting" (ppr (map ifName decls) ) $ do
                -- put the cycle in a canonical order
               hash <- computeFingerprint hash_fn stable_abis
               let pairs = zip (map (bumpFingerprint hash) [0..]) stable_decls
                -- See Note [Fingerprinting recursive groups]
               local_env2 <- foldM extend_hash_env local_env pairs
               return (local_env2, pairs ++ decls_w_hashes)

       -- Make a fingerprint from the ordinal position of a binding in its group.
       mkRecFingerprint :: Word64 -> Fingerprint
       mkRecFingerprint i = Fingerprint 0 i

       bumpFingerprint :: Fingerprint -> Word64 -> Fingerprint
       bumpFingerprint fp n = fingerprintFingerprints [ fp, mkRecFingerprint n ]

       -- we have fingerprinted the whole declaration, but we now need
       -- to assign fingerprints to all the OccNames that it binds, to
       -- use when referencing those OccNames in later declarations.
       --
       extend_hash_env :: OccEnv (OccName,Fingerprint)
                       -> (Fingerprint,IfaceDecl)
                       -> IO (OccEnv (OccName,Fingerprint))
       extend_hash_env env0 (hash,d) =
          return (foldr (\(b,fp) env -> extendOccEnv env b (b,fp)) env0
                 (ifaceDeclFingerprints hash d))

   --
   (local_env, decls_w_hashes) <-
       foldM fingerprint_group (emptyOccEnv, []) groups

   -- when calculating fingerprints, we always need to use canonical
   -- ordering for lists of things.  In particular, the mi_deps has various
   -- lists of modules and suchlike, so put these all in canonical order:
   let sorted_deps :: Dependencies
       sorted_deps = sortDependencies (mi_deps iface0)

   -- The export hash of a module depends on the orphan hashes of the
   -- orphan modules below us in the dependency tree.  This is the way
   -- that changes in orphans get propagated all the way up the
   -- dependency tree.
   --
   -- Note [A bad dep_orphs optimization]
   -- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   -- In a previous version of this code, we filtered out orphan modules which
   -- were not from the home package, justifying it by saying that "we'd
   -- pick up the ABI hashes of the external module instead".  This is wrong.
   -- Suppose that we have:
   --
   --       module External where
   --           instance Show (a -> b)
   --
   --       module Home1 where
   --           import External
   --
   --       module Home2 where
   --           import Home1
   --
   -- The export hash of Home1 needs to reflect the orphan instances of
   -- External. It's true that Home1 will get rebuilt if the orphans
   -- of External, but we also need to make sure Home2 gets rebuilt
   -- as well.  See #12733 for more details.
   let orph_mods
        = filter (/= this_mod) -- Note [Do not update EPS with your own hi-boot]
        $ dep_orphs sorted_deps
   dep_orphan_hashes <- getOrphanHashes hsc_env orph_mods

   -- Note [Do not update EPS with your own hi-boot]
   -- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   -- (See also #10182).  When your hs-boot file includes an orphan
   -- instance declaration, you may find that the dep_orphs of a module you
   -- import contains reference to yourself.  DO NOT actually load this module
   -- or add it to the orphan hashes: you're going to provide the orphan
   -- instances yourself, no need to consult hs-boot; if you do load the
   -- interface into EPS, you will see a duplicate orphan instance.

   orphan_hash <- computeFingerprint (mk_put_name local_env)
                                     (map ifDFun orph_insts, orph_rules, orph_fis)

   -- Hash of the transitive things in dependencies
   dep_hash <- computeFingerprint putNameLiterally
                       (dep_sig_mods (mi_deps iface0),
                        dep_boot_mods (mi_deps iface0),
                        -- Trusted packages are like orphans
                        dep_trusted_pkgs (mi_deps iface0),
                       -- See Note [Export hash depends on non-orphan family instances]
                        dep_finsts (mi_deps iface0) )

   -- the export list hash doesn't depend on the fingerprints of
   -- the Names it mentions, only the Names themselves, hence putNameLiterally.
   export_hash <- computeFingerprint putNameLiterally
                      (mi_exports iface0,
                       orphan_hash,
                       dep_hash,
                       dep_orphan_hashes,
                       mi_trust iface0)
                        -- Make sure change of Safe Haskell mode causes recomp.

   -- Note [Export hash depends on non-orphan family instances]
   -- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
   --
   -- Suppose we have:
   --
   --   module A where
   --       type instance F Int = Bool
   --
   --   module B where
   --       import A
   --
   --   module C where
   --       import B
   --
   -- The family instance consistency check for C depends on the dep_finsts of
   -- B.  If we rename module A to A2, when the dep_finsts of B changes, we need
   -- to make sure that C gets rebuilt. Effectively, the dep_finsts are part of
   -- the exports of B, because C always considers them when checking
   -- consistency.
   --
   -- A full discussion is in #12723.
   --
   -- We do NOT need to hash dep_orphs, because this is implied by
   -- dep_orphan_hashes, and we do not need to hash ordinary class instances,
   -- because there is no eager consistency check as there is with type families
   -- (also we didn't store it anywhere!)
   --

   -- put the declarations in a canonical order, sorted by OccName
   let sorted_decls :: [(Fingerprint, IfaceDecl)]
       sorted_decls = Map.elems $ Map.fromList $
                          [(getOccName d, e) | e@(_, d) <- decls_w_hashes]

   -- the flag hash depends on:
   --   - (some of) dflags
   -- it returns two hashes, one that shouldn't change
   -- the abi hash and one that should
   flag_hash <- fingerprintDynFlags hsc_env this_mod putNameLiterally

   opt_hash <- fingerprintOptFlags dflags putNameLiterally

   hpc_hash <- fingerprintHpcFlags dflags putNameLiterally

   plugin_hash <- fingerprintPlugins hsc_env

   -- the ABI hash depends on:
   --   - decls
   --   - export list
   --   - orphans
   --   - deprecations
   --   - flag abi hash
   mod_hash <- computeFingerprint putNameLiterally
                      (map fst sorted_decls,
                       export_hash,  -- includes orphan_hash
                       mi_warns iface0)

   -- The interface hash depends on:
   --   - the ABI hash, plus
   --   - the source file hash,
   --   - the module level annotations,
   --   - usages
   --   - deps (home and external packages, dependent files)
   --   - hpc
   iface_hash <- computeFingerprint putNameLiterally
                      (mod_hash,
                       mi_src_hash iface0,
                       ann_fn (mkVarOcc "module"),  -- See mkIfaceAnnCache
                       mi_usages iface0,
                       sorted_deps,
                       mi_hpc iface0)

   let
    final_iface_exts = ModIfaceBackend
      { mi_iface_hash  = iface_hash
      , mi_mod_hash    = mod_hash
      , mi_flag_hash   = flag_hash
      , mi_opt_hash    = opt_hash
      , mi_hpc_hash    = hpc_hash
      , mi_plugin_hash = plugin_hash
      , mi_orphan      = not (   all ifRuleAuto orph_rules
                                   -- See Note [Orphans and auto-generated rules]
                              && null orph_insts
                              && null orph_fis)
      , mi_finsts      = not (null (mi_fam_insts iface0))
      , mi_exp_hash    = export_hash
      , mi_orphan_hash = orphan_hash
      , mi_warn_fn     = warn_fn
      , mi_fix_fn      = fix_fn
      , mi_hash_fn     = lookupOccEnv local_env
      }
    final_iface = iface0 { mi_decls = sorted_decls, mi_final_exts = final_iface_exts }
   --
   return final_iface

  where
    this_mod = mi_module iface0
    semantic_mod = mi_semantic_module iface0
    dflags = hsc_dflags hsc_env
    (non_orph_insts, orph_insts) = mkOrphMap ifInstOrph    (mi_insts iface0)
    (non_orph_rules, orph_rules) = mkOrphMap ifRuleOrph    (mi_rules iface0)
    (non_orph_fis,   orph_fis)   = mkOrphMap ifFamInstOrph (mi_fam_insts iface0)
    ann_fn = mkIfaceAnnCache (mi_anns iface0)

-- | Retrieve the orphan hashes 'mi_orphan_hash' for a list of modules
-- (in particular, the orphan modules which are transitively imported by the
-- current module).
--
-- Q: Why do we need the hash at all, doesn't the list of transitively
-- imported orphan modules suffice?
--
-- A: If one of our transitive imports adds a new orphan instance, our
-- export hash must change so that modules which import us rebuild.  If we just
-- hashed the [Module], the hash would not change even when a new instance was
-- added to a module that already had an orphan instance.
--
-- Q: Why don't we just hash the orphan hashes of our direct dependencies?
-- Why the full transitive closure?
--
-- A: Suppose we have these modules:
--
--      module A where
--          instance Show (a -> b) where
--      module B where
--          import A -- **
--      module C where
--          import A
--          import B
--
-- Whether or not we add or remove the import to A in B affects the
-- orphan hash of B.  But it shouldn't really affect the orphan hash
-- of C.  If we hashed only direct dependencies, there would be no
-- way to tell that the net effect was a wash, and we'd be forced
-- to recompile C and everything else.
getOrphanHashes :: HscEnv -> [Module] -> IO [Fingerprint]
getOrphanHashes hsc_env mods = do
  eps <- hscEPS hsc_env
  let
    hpt        = hsc_HPT hsc_env
    dflags     = hsc_dflags hsc_env
    pit        = eps_PIT eps
    ctx        = initSDocContext dflags defaultUserStyle
    get_orph_hash mod =
          case lookupIfaceByModule hpt pit mod of
            Just iface -> return (mi_orphan_hash (mi_final_exts iface))
            Nothing    -> do -- similar to 'mkHashFun'
                iface <- initIfaceLoad hsc_env . withException ctx
                            $ loadInterface (text "getOrphanHashes") mod ImportBySystem
                return (mi_orphan_hash (mi_final_exts iface))

  --
  mapM get_orph_hash mods


sortDependencies :: Dependencies -> Dependencies
sortDependencies d
 = Deps { dep_direct_mods = sortBy (lexicalCompareFS `on` (moduleNameFS . gwib_mod)) (dep_direct_mods d),
          dep_direct_pkgs   = sort (dep_direct_pkgs d),
          dep_sig_mods      = sort (dep_sig_mods d),
          dep_trusted_pkgs  = sort (dep_trusted_pkgs d),
          dep_boot_mods   = sort (dep_boot_mods d),
          dep_orphs  = sortBy stableModuleCmp (dep_orphs d),
          dep_finsts = sortBy stableModuleCmp (dep_finsts d) }

{-
************************************************************************
*                                                                      *
          The ABI of an IfaceDecl
*                                                                      *
************************************************************************

Note [The ABI of an IfaceDecl]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The ABI of a declaration consists of:

   (a) the full name of the identifier (inc. module and package,
       because these are used to construct the symbol name by which
       the identifier is known externally).

   (b) the declaration itself, as exposed to clients.  That is, the
       definition of an Id is included in the fingerprint only if
       it is made available as an unfolding in the interface.

   (c) the fixity of the identifier (if it exists)
   (d) for Ids: rules
   (e) for classes: instances, fixity & rules for methods
   (f) for datatypes: instances, fixity & rules for constrs

Items (c)-(f) are not stored in the IfaceDecl, but instead appear
elsewhere in the interface file.  But they are *fingerprinted* with
the declaration itself. This is done by grouping (c)-(f) in IfaceDeclExtras,
and fingerprinting that as part of the declaration.
-}

type IfaceDeclABI = (Module, IfaceDecl, IfaceDeclExtras)

data IfaceDeclExtras
  = IfaceIdExtras IfaceIdExtras

  | IfaceDataExtras
       (Maybe Fixity)           -- Fixity of the tycon itself (if it exists)
       [IfaceInstABI]           -- Local class and family instances of this tycon
                                -- See Note [Orphans] in GHC.Core.InstEnv
       [AnnPayload]             -- Annotations of the type itself
       [IfaceIdExtras]          -- For each constructor: fixity, RULES and annotations

  | IfaceClassExtras
       (Maybe Fixity)           -- Fixity of the class itself (if it exists)
       [IfaceInstABI]           -- Local instances of this class *or*
                                --   of its associated data types
                                -- See Note [Orphans] in GHC.Core.InstEnv
       [AnnPayload]             -- Annotations of the type itself
       [IfaceIdExtras]          -- For each class method: fixity, RULES and annotations
       [IfExtName]              -- Default methods. If a module
                                -- mentions a class, then it can
                                -- instantiate the class and thereby
                                -- use the default methods, so we must
                                -- include these in the fingerprint of
                                -- a class.

  | IfaceSynonymExtras (Maybe Fixity) [AnnPayload]

  | IfaceFamilyExtras   (Maybe Fixity) [IfaceInstABI] [AnnPayload]

  | IfaceOtherDeclExtras

data IfaceIdExtras
  = IdExtras
       (Maybe Fixity)           -- Fixity of the Id (if it exists)
       [IfaceRule]              -- Rules for the Id
       [AnnPayload]             -- Annotations for the Id

-- When hashing a class or family instance, we hash only the
-- DFunId or CoAxiom, because that depends on all the
-- information about the instance.
--
type IfaceInstABI = IfExtName   -- Name of DFunId or CoAxiom that is evidence for the instance

abiDecl :: IfaceDeclABI -> IfaceDecl
abiDecl (_, decl, _) = decl

cmp_abiNames :: IfaceDeclABI -> IfaceDeclABI -> Ordering
cmp_abiNames abi1 abi2 = getOccName (abiDecl abi1) `compare`
                         getOccName (abiDecl abi2)

freeNamesDeclABI :: IfaceDeclABI -> NameSet
freeNamesDeclABI (_mod, decl, extras) =
  freeNamesIfDecl decl `unionNameSet` freeNamesDeclExtras extras

freeNamesDeclExtras :: IfaceDeclExtras -> NameSet
freeNamesDeclExtras (IfaceIdExtras id_extras)
  = freeNamesIdExtras id_extras
freeNamesDeclExtras (IfaceDataExtras  _ insts _ subs)
  = unionNameSets (mkNameSet insts : map freeNamesIdExtras subs)
freeNamesDeclExtras (IfaceClassExtras _ insts _ subs defms)
  = unionNameSets $
      mkNameSet insts : mkNameSet defms : map freeNamesIdExtras subs
freeNamesDeclExtras (IfaceSynonymExtras _ _)
  = emptyNameSet
freeNamesDeclExtras (IfaceFamilyExtras _ insts _)
  = mkNameSet insts
freeNamesDeclExtras IfaceOtherDeclExtras
  = emptyNameSet

freeNamesIdExtras :: IfaceIdExtras -> NameSet
freeNamesIdExtras (IdExtras _ rules _) = unionNameSets (map freeNamesIfRule rules)

instance Outputable IfaceDeclExtras where
  ppr IfaceOtherDeclExtras       = Outputable.empty
  ppr (IfaceIdExtras  extras)    = ppr_id_extras extras
  ppr (IfaceSynonymExtras fix anns) = vcat [ppr fix, ppr anns]
  ppr (IfaceFamilyExtras fix finsts anns) = vcat [ppr fix, ppr finsts, ppr anns]
  ppr (IfaceDataExtras fix insts anns stuff) = vcat [ppr fix, ppr_insts insts, ppr anns,
                                                ppr_id_extras_s stuff]
  ppr (IfaceClassExtras fix insts anns stuff defms) =
    vcat [ppr fix, ppr_insts insts, ppr anns,
          ppr_id_extras_s stuff, ppr defms]

ppr_insts :: [IfaceInstABI] -> SDoc
ppr_insts _ = text "<insts>"

ppr_id_extras_s :: [IfaceIdExtras] -> SDoc
ppr_id_extras_s stuff = vcat (map ppr_id_extras stuff)

ppr_id_extras :: IfaceIdExtras -> SDoc
ppr_id_extras (IdExtras fix rules anns) = ppr fix $$ vcat (map ppr rules) $$ vcat (map ppr anns)

-- This instance is used only to compute fingerprints
instance Binary IfaceDeclExtras where
  get _bh = panic "no get for IfaceDeclExtras"
  put_ bh (IfaceIdExtras extras) = do
   putByte bh 1; put_ bh extras
  put_ bh (IfaceDataExtras fix insts anns cons) = do
   putByte bh 2; put_ bh fix; put_ bh insts; put_ bh anns; put_ bh cons
  put_ bh (IfaceClassExtras fix insts anns methods defms) = do
   putByte bh 3
   put_ bh fix
   put_ bh insts
   put_ bh anns
   put_ bh methods
   put_ bh defms
  put_ bh (IfaceSynonymExtras fix anns) = do
   putByte bh 4; put_ bh fix; put_ bh anns
  put_ bh (IfaceFamilyExtras fix finsts anns) = do
   putByte bh 5; put_ bh fix; put_ bh finsts; put_ bh anns
  put_ bh IfaceOtherDeclExtras = putByte bh 6

instance Binary IfaceIdExtras where
  get _bh = panic "no get for IfaceIdExtras"
  put_ bh (IdExtras fix rules anns)= do { put_ bh fix; put_ bh rules; put_ bh anns }

declExtras :: (OccName -> Maybe Fixity)
           -> (OccName -> [AnnPayload])
           -> OccEnv [IfaceRule]
           -> OccEnv [IfaceClsInst]
           -> OccEnv [IfaceFamInst]
           -> OccEnv IfExtName          -- lookup default method names
           -> IfaceDecl
           -> IfaceDeclExtras

declExtras fix_fn ann_fn rule_env inst_env fi_env dm_env decl
  = case decl of
      IfaceId{} -> IfaceIdExtras (id_extras n)
      IfaceData{ifCons=cons} ->
                     IfaceDataExtras (fix_fn n)
                        (map ifFamInstAxiom (lookupOccEnvL fi_env n) ++
                         map ifDFun         (lookupOccEnvL inst_env n))
                        (ann_fn n)
                        (map (id_extras . occName . ifConName) (visibleIfConDecls cons))
      IfaceClass{ifBody = IfConcreteClass { ifSigs=sigs, ifATs=ats }} ->
                     IfaceClassExtras (fix_fn n) insts (ann_fn n) meths defms
          where
            insts = (map ifDFun $ (concatMap at_extras ats)
                                    ++ lookupOccEnvL inst_env n)
                           -- Include instances of the associated types
                           -- as well as instances of the class (#5147)
            meths = [id_extras (getOccName op) | IfaceClassOp op _ _ <- sigs]
            -- Names of all the default methods (see Note [default method Name])
            defms = [ dmName
                    | IfaceClassOp bndr _ (Just _) <- sigs
                    , let dmOcc = mkDefaultMethodOcc (nameOccName bndr)
                    , Just dmName <- [lookupOccEnv dm_env dmOcc] ]
      IfaceSynonym{} -> IfaceSynonymExtras (fix_fn n)
                                           (ann_fn n)
      IfaceFamily{} -> IfaceFamilyExtras (fix_fn n)
                        (map ifFamInstAxiom (lookupOccEnvL fi_env n))
                        (ann_fn n)
      _other -> IfaceOtherDeclExtras
  where
        n = getOccName decl
        id_extras occ = IdExtras (fix_fn occ) (lookupOccEnvL rule_env occ) (ann_fn occ)
        at_extras (IfaceAT decl _) = lookupOccEnvL inst_env (getOccName decl)


{- Note [default method Name] (see also #15970)

The Names for the default methods aren't available in Iface syntax.

* We originally start with a DefMethInfo from the class, contain a
  Name for the default method

* We turn that into Iface syntax as a DefMethSpec which lacks a Name
  entirely. Why? Because the Name can be derived from the method name
  (in GHC.IfaceToCore), so doesn't need to be serialised into the interface
  file.

But now we have to get the Name back, because the class declaration's
fingerprint needs to depend on it (this was the bug in #15970).  This
is done in a slightly convoluted way:

* Then, in addFingerprints we build a map that maps OccNames to Names

* We pass that map to declExtras which laboriously looks up in the map
  (using the derived occurrence name) to recover the Name we have just
  thrown away.
-}

lookupOccEnvL :: OccEnv [v] -> OccName -> [v]
lookupOccEnvL env k = lookupOccEnv env k `orElse` []

{-
-- for testing: use the md5sum command to generate fingerprints and
-- compare the results against our built-in version.
  fp' <- oldMD5 dflags bh
  if fp /= fp' then pprPanic "computeFingerprint" (ppr fp <+> ppr fp')
               else return fp

oldMD5 dflags bh = do
  tmp <- newTempName dflags CurrentModule "bin"
  writeBinMem bh tmp
  tmp2 <- newTempName dflags CurrentModule "md5"
  let cmd = "md5sum " ++ tmp ++ " >" ++ tmp2
  r <- system cmd
  case r of
    ExitFailure _ -> throwGhcExceptionIO (PhaseFailed cmd r)
    ExitSuccess -> do
        hash_str <- readFile tmp2
        return $! readHexFingerprint hash_str
-}

----------------------
-- mkOrphMap partitions instance decls or rules into
--      (a) an OccEnv for ones that are not orphans,
--          mapping the local OccName to a list of its decls
--      (b) a list of orphan decls
mkOrphMap :: (decl -> IsOrphan) -- Extract orphan status from decl
          -> [decl]             -- Sorted into canonical order
          -> (OccEnv [decl],    -- Non-orphan decls associated with their key;
                                --      each sublist in canonical order
              [decl])           -- Orphan decls; in canonical order
mkOrphMap get_key decls
  = foldl' go (emptyOccEnv, []) decls
  where
    go (non_orphs, orphs) d
        | NotOrphan occ <- get_key d
        = (extendOccEnv_Acc (:) Utils.singleton non_orphs occ d, orphs)
        | otherwise = (non_orphs, d:orphs)

-- -----------------------------------------------------------------------------
-- Look up parents and versions of Names

-- This is like a global version of the mi_hash_fn field in each ModIface.
-- Given a Name, it finds the ModIface, and then uses mi_hash_fn to get
-- the parent and version info.

mkHashFun
        :: HscEnv                       -- needed to look up versions
        -> ExternalPackageState         -- ditto
        -> (Name -> IO Fingerprint)
mkHashFun hsc_env eps name
  | isHoleModule orig_mod
  = lookup (mkHomeModule home_unit (moduleName orig_mod))
  | otherwise
  = lookup orig_mod
  where
      home_unit = hsc_home_unit hsc_env
      dflags = hsc_dflags hsc_env
      hpt = hsc_HPT hsc_env
      pit = eps_PIT eps
      ctx = initSDocContext dflags defaultUserStyle
      occ = nameOccName name
      orig_mod = nameModule name
      lookup mod = do
        massertPpr (isExternalName name) (ppr name)
        iface <- case lookupIfaceByModule hpt pit mod of
                  Just iface -> return iface
                  Nothing ->
                      -- This can occur when we're writing out ifaces for
                      -- requirements; we didn't do any /real/ typechecking
                      -- so there's no guarantee everything is loaded.
                      -- Kind of a heinous hack.
                      initIfaceLoad hsc_env . withException ctx
                          $ withoutDynamicNow
                            -- For some unknown reason, we need to reset the
                            -- dynamicNow bit, otherwise only dynamic
                            -- interfaces are looked up and some tests fail
                            -- (e.g. T16219).
                          $ loadInterface (text "lookupVers2") mod ImportBySystem
        return $ snd (mi_hash_fn (mi_final_exts iface) occ `orElse`
                  pprPanic "lookupVers1" (ppr mod <+> ppr occ))


-- | Creates cached lookup for the 'mi_anns' field of ModIface
-- Hackily, we use "module" as the OccName for any module-level annotations
mkIfaceAnnCache :: [IfaceAnnotation] -> OccName -> [AnnPayload]
mkIfaceAnnCache anns
  = \n -> lookupOccEnv env n `orElse` []
  where
    pair (IfaceAnnotation target value) =
      (case target of
          NamedTarget occn -> occn
          ModuleTarget _   -> mkVarOcc "module"
      , [value])
    -- flipping (++), so the first argument is always short
    env = mkOccEnv_C (flip (++)) (map pair anns)
