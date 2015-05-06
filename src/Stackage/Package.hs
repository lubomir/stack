{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}

-- | Dealing with Cabal.

module Stackage.Build.Cabal
  (readPackage
  ,Package
  ,PackageConfig)
  where

import           Control.Arrow
import           Control.Exception
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Logger (MonadLogger, logDebug)
import           Control.Monad.Loops
import           Data.Data
import           Data.Function
import           Data.List
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Maybe
import           Data.Monoid
import           Data.Set (Set)
import qualified Data.Set as S
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Yaml (ParseException)
import           Distribution.Compiler
import           Distribution.InstalledPackageInfo (PError)
import           Distribution.ModuleName as Cabal
import           Distribution.Package hiding (Package,PackageName)
import           Distribution.PackageDescription
import           Distribution.PackageDescription.Parse
import           Distribution.Simple.Utils
import           Distribution.System
import           Distribution.Version
import           Filesystem
import           Filesystem.Loc as FL
import qualified Filesystem.Path.CurrentOS as FP
import           Prelude hiding (FilePath)
import           Stackage.Constants
import           Stackage.PackageName

-- | All exceptions thrown by the library.
data FPException
  = FPConfigError ParseException
  | FPNoConfigFile
  | FPNoCabalFile (Loc Absolute Dir)
  | FPInvalidCabalFile (Loc Absolute File) PError
  | FPNoDeps (Loc Absolute File)
  | FPDepCycle PackageName
  | FPMissingDep Package PackageName VersionRange
  | FPDependencyIssues [FPException]
  | FPMissingTool Dependency
  | FPCouldn'tFindPkgId PackageName
  | FPStackagePackageVersionMismatch PackageName Version Version
  | FPStackageDepVerMismatch PackageName Version VersionRange
  deriving (Show,Typeable)
instance Exception FPException

-- | Some package info.
data Package =
  Package {pinfoName :: !PackageName                      -- ^ Name of the package.
          ,pinfoVersion :: !Version                       -- ^ Version of the package
          ,pinfoDir :: !(Loc Absolute Dir)                -- ^ Directory of the package.
          ,pinfoFiles :: !(Set (Loc Absolute File))       -- ^ Files that the package depends on.
          ,pinfoDeps :: !(Map PackageName VersionRange)   -- ^ Packages that the package depends on.
          ,pinfoTools :: ![Dependency]                    -- ^ A build tool name.
          ,pinfoAllDeps :: !(Set PackageName)             -- ^ Original dependencies (not sieved).
          ,pinfoFlags :: !(Map Text Bool)                 -- ^ Flags used on package.
          }
 deriving (Show,Typeable,Data)

-- | Package build configuration
data PackageConfig =
  PackageConfig {packageConfigEnableTests :: !Bool        -- ^ Are tests enabled?
                ,packageConfigEnableBenchmarks :: !Bool   -- ^ Are benchmarks enabled?
                ,packageConfigFlags :: !(Map Text Bool)   -- ^ Package config flags.
                }
 deriving (Show,Typeable,Data)

-- | Compares the package name.
instance Ord Package where
  compare = on compare pinfoName

-- | Compares the package name.
instance Eq Package where
  (==) = on (==) pinfoName

-- | Reads and exposes the package information
readPackage :: (MonadLogger m, MonadIO m, MonadThrow m)
            => PackageConfig
            -> Loc Absolute File
            -> m Package
readPackage packageConfig cabalfp =
  do chars <-
       liftIO (Prelude.readFile (FL.encodeString cabalfp))
     case parsePackageDescription chars of
       ParseFailed per ->
         liftedThrowIO (FPInvalidCabalFile cabalfp per)
       ParseOk _ gpkg ->
         let pkgId =
               package (packageDescription gpkg)
             name = fromCabalPackageName (pkgName pkgId)
             pkgFlags =
               packageConfigFlags packageConfig
             pkg =
               resolvePackage packageConfig gpkg
         in case packageDependencies pkg of
              deps
                | M.null deps ->
                  liftedThrowIO (FPNoDeps cabalfp)
                | otherwise ->
                  do let dir = FL.parent cabalfp
                     pkgFiles <-
                       liftIO (packageFiles dir pkg)
                     let files = cabalfp : pkgFiles
                         deps' =
                           M.filterWithKey (const . (/= name))
                                           deps
                     return (Package {pinfoName = name
                                   ,pinfoVersion = pkgVersion pkgId
                                   ,pinfoDeps = deps'
                                   ,pinfoDir = dir
                                   ,pinfoFiles = S.fromList files
                                   ,pinfoTools = packageTools pkg
                                   ,pinfoFlags = pkgFlags
                                   ,pinfoAllDeps =
                                      S.fromList (M.keys deps')})
  where liftedThrowIO = liftIO . throwIO

-- | Get all dependencies of the package (buildable targets only).
packageDependencies :: PackageDescription -> Map PackageName VersionRange
packageDependencies =
  M.fromList .
  concatMap (map (\dep -> ((depName dep),depRange dep)) .
             targetBuildDepends) .
  allBuildInfo

-- | Get all dependencies of the package (buildable targets only).
packageTools :: PackageDescription -> [Dependency]
packageTools = concatMap buildTools . allBuildInfo

-- | Get all files referenced by the package.
packageFiles :: Loc Absolute Dir -> PackageDescription -> IO [Loc Absolute File]
packageFiles dir pkg =
  do libfiles <- fmap concat
                      (mapM (libraryFiles dir)
                            (maybe [] return (library pkg)))
     exefiles <- fmap concat
                      (mapM (executableFiles dir)
                            (executables pkg))
     dfiles <- resolveGlobFiles dir
                                (dataFiles pkg)
     srcfiles <- resolveGlobFiles dir
                                  (extraSrcFiles pkg)
     tmpfiles <- resolveGlobFiles dir
                                  (extraTmpFiles pkg)
     docfiles <- resolveGlobFiles dir
                                  (extraDocFiles pkg)
     return (concat [libfiles,exefiles,dfiles,srcfiles,tmpfiles,docfiles])

-- | Resolve globbing of files (e.g. data files) to absolute paths.
resolveGlobFiles :: Loc Absolute Dir -> [String] -> IO [Loc Absolute File]
resolveGlobFiles dir = fmap concat . mapM resolve
  where resolve name =
          if any (== '*') name
             then explode name
             else return [(either (error . show)
                                  (appendLoc dir)
                                  (FL.parseRelativeFileLoc (FP.decodeString name)))]
        explode name =
          fmap (map (either (error . show) (appendLoc dir) .
                     FL.parseRelativeFileLoc . FP.decodeString))
               (matchDirFileGlob (FL.encodeString dir)
                                 name)

-- | Get all files referenced by the executable.
executableFiles :: Loc Absolute Dir -> Executable -> IO [Loc Absolute File]
executableFiles dir exe =
  do exposed <- resolveFiles
                  (map (either (error . show)
                               (appendLoc dir) .
                        FL.parseRelativeDirLoc . FP.decodeString)
                       (hsSourceDirs build) ++
                   [dir])
                  [Right (modulePath exe)]
                  haskellFileExts
     bfiles <- buildFiles dir build
     return (concat [bfiles,exposed])
  where build = buildInfo exe

-- | Get all files referenced by the library.
libraryFiles :: Loc Absolute Dir -> Library -> IO [Loc Absolute File]
libraryFiles dir lib =
  do exposed <- resolveFiles
                  (map (either (error . show) (appendLoc dir) .
                        FL.parseRelativeDirLoc . FP.decodeString)
                       (hsSourceDirs build) ++
                   [dir])
                  (map Left (exposedModules lib))
                  haskellFileExts
     bfiles <- buildFiles dir build
     return (concat [bfiles,exposed])
  where build = libBuildInfo lib

-- | Get all files in a build.
buildFiles :: Loc Absolute Dir -> BuildInfo -> IO [Loc Absolute File]
buildFiles dir build =
  do other <- resolveFiles
                (map (either (error . show) (appendLoc dir) .
                      FL.parseRelativeDirLoc . FP.decodeString)
                     (hsSourceDirs build) ++
                 [dir])
                (map Left (otherModules build))
                haskellFileExts
     return (concat [other
                    ,map (either (error . show) (appendLoc dir) .
                          FL.parseRelativeFileLoc . FP.decodeString)
                         (cSources build)])

-- | Get all dependencies of a package, including library,
-- executables, tests, benchmarks.
resolvePackage :: PackageConfig
               -> GenericPackageDescription
               -> PackageDescription
resolvePackage packageConfig (GenericPackageDescription desc defaultFlags mlib exes tests benches) =
  desc {library =
          fmap (resolveConditions flags' updateLibDeps) mlib
       ,executables =
          map (resolveConditions flags' updateExeDeps .
               snd)
              exes
       ,testSuites =
          map (resolveConditions flags' updateTestDeps .
               snd)
              tests
       ,benchmarks =
          map (resolveConditions flags' updateBenchmarkDeps .
               snd)
              benches}
  where flags =
          M.union (packageConfigFlags packageConfig)
                  (flagMap defaultFlags)
        flags' =
          (map (FlagName . T.unpack)
               (map fst (filter snd (M.toList flags))))
        updateLibDeps lib deps =
          lib {libBuildInfo =
                 ((libBuildInfo lib) {targetBuildDepends =
                                        deps})}
        updateExeDeps exe deps =
          exe {buildInfo =
                 (buildInfo exe) {targetBuildDepends = deps}}
        updateTestDeps test deps =
          test {testBuildInfo =
                  (testBuildInfo test) {targetBuildDepends = deps}
               ,testEnabled = packageConfigEnableTests packageConfig}
        updateBenchmarkDeps benchmark deps =
          benchmark {benchmarkBuildInfo =
                       (benchmarkBuildInfo benchmark) {targetBuildDepends = deps}
                    ,benchmarkEnabled = packageConfigEnableBenchmarks packageConfig}

-- | Make a map from a list of flag specifications.
--
-- What is @flagManual@ for?
flagMap :: [Flag] -> Map Text Bool
flagMap = M.fromList . map pair
  where pair :: Flag -> (Text, Bool)
        pair (MkFlag (unName -> name) _desc def _manual) = (name,def)
        unName (FlagName t) = T.pack t

-- | Resolve the condition tree for the library.
resolveConditions :: (Monoid target,Show target)
                  => [FlagName]
                  -> (target -> cs -> target)
                  -> CondTree ConfVar cs target
                  -> target
resolveConditions flags addDeps (CondNode lib deps cs) = basic <> children
  where basic = addDeps lib deps
        children = mconcat (map apply cs)
          where apply (cond,node,mcs) =
                  if (condSatisfied cond)
                     then resolveConditions flags addDeps node
                     else maybe mempty (resolveConditions flags addDeps) mcs
                condSatisfied c =
                  case c of
                    Var v -> varSatisifed v
                    Lit b -> b
                    CNot c' ->
                      not (condSatisfied c')
                    COr cx cy ->
                      or [condSatisfied cx,condSatisfied cy]
                    CAnd cx cy ->
                      and [condSatisfied cx,condSatisfied cy]
                varSatisifed v =
                  case v of
                    OS os -> os == buildOS
                    Arch arch -> arch == buildArch
                    Flag flag -> elem flag flags
                    Impl flavor range ->
                      case buildCompilerId of
                        CompilerId flavor' ver ->
                          flavor' == flavor &&
                          withinRange ver range

-- | Get the name of a dependency.
depName :: Dependency -> PackageName
depName = \(Dependency n _) -> fromCabalPackageName n

-- | Get the version range of a dependency.
depRange :: Dependency -> VersionRange
depRange = \(Dependency _ r) -> r

-- | Try to resolve the list of base names in the given directory by
-- looking for unique instances of base names applied with the given
-- extensions.
resolveFiles :: [Loc Absolute Dir] -- ^ Directories to look in.
             -> [Either ModuleName String] -- ^ Base names.
             -> [Text] -- ^ Extentions.
             -> IO [Loc Absolute File]
resolveFiles dirs names exts =
  fmap catMaybes (forM names makeNameCandidates)
  where makeNameCandidates name =
          firstM (isFile . FL.toFilePath)
                 (concatMap (makeDirCandidates name) dirs)
        makeDirCandidates :: Either ModuleName String
                          -> Loc Absolute Dir
                          -> [Loc Absolute File]
        makeDirCandidates name dir =
          map (\ext ->
                 case name of
                   Left mn ->
                     (either (error . show)
                             (appendLoc dir)
                             (FL.parseRelativeFileLoc
                                (FP.addExtension (FP.decodeString (Cabal.toFilePath mn))
                                                 ext)))
                   Right fp ->
                     either (error . show)
                            (appendLoc dir)
                            (FL.parseRelativeFileLoc (FP.decodeString fp)))
              exts
