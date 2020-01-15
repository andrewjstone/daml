-- Copyright (c) 2019 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE OverloadedStrings #-}
module DAML.Assistant.Install
    ( InstallOptions (..)
    , InstallURL (..)
    , InstallEnv (..)
    , versionInstall
    , getLatestVersion
    , install
    ) where

import DAML.Assistant.Types
import DAML.Assistant.Util
import qualified DAML.Assistant.Install.Github as Github
import DAML.Assistant.Install.Path
import DAML.Project.Consts
import DAML.Project.Config
import DAML.Project.Util
import Safe
import Conduit
import qualified Data.Conduit.List as List
import qualified Data.Conduit.Tar.Extra as Tar
import qualified Data.Conduit.Zlib as Zlib
import Network.HTTP.Simple
import qualified Data.ByteString as BS
import qualified Data.ByteString.UTF8 as BS.UTF8
import System.Exit
import System.IO
import System.IO.Temp
import System.FilePath
import System.Directory
import Control.Monad.Extra
import Control.Exception.Safe
import System.ProgressBar
import System.Info.Extra (isWindows)

-- unix specific
import System.PosixCompat.Types ( FileMode )
import System.PosixCompat.Files
    ( removeLink
    , createSymbolicLink
    , fileMode
    , getFileStatus
    , setFileMode
    , intersectFileModes
    , unionFileModes
    , ownerReadMode
    , ownerWriteMode
    , ownerExecuteMode
    , groupReadMode
    , groupExecuteMode
    , otherReadMode
    , otherExecuteMode)

data InstallEnv = InstallEnv
    { options :: InstallOptions
    , targetVersionM :: Maybe SdkVersion
    , damlPath :: DamlPath
    , projectPathM :: Maybe ProjectPath
    , output :: String -> IO ()
    }

-- | Perform action unless user has passed --quiet flag.
unlessQuiet :: InstallEnv -> IO () -> IO ()
unlessQuiet InstallEnv{..} | QuietInstall b <- iQuiet options =
    unless b

-- | Execute action if --activate flag is set.
whenActivate :: InstallEnv -> IO () -> IO ()
whenActivate InstallEnv{..} | ActivateInstall b <- iActivate options =
    when b

-- | Set up .daml directory if it's missing.
setupDamlPath :: DamlPath -> IO ()
setupDamlPath (DamlPath path) = do
    createDirectoryIfMissing True (path </> "bin")
    createDirectoryIfMissing True (path </> "sdk")
    -- For now, we only ensure that the config file exists.
    appendFile (path </> damlConfigName) ""

-- | Install (extracted) SDK directory to the correct place, after performing
-- a version sanity check. Then run the sdk install hook if applicable.
installExtracted :: InstallEnv -> SdkPath -> IO ()
installExtracted env@InstallEnv{..} sourcePath =
    wrapErr "Installing extracted SDK release." $ do
        sourceConfig <- readSdkConfig sourcePath
        sourceVersion <- fromRightM throwIO (sdkVersionFromSdkConfig sourceConfig)

        -- Check that source version matches expected target version.
        whenJust targetVersionM $ \targetVersion -> do
            unless (sourceVersion == targetVersion) $ do
                throwIO $ assistantErrorBecause
                    "SDK release version mismatch."
                    ("Expected " <> versionToText targetVersion
                    <> " but got version " <> versionToText sourceVersion)

        -- Set file mode of files to install.
        requiredIO "Failed to set file modes for extracted SDK files." $
            walkRecursive (unwrapSdkPath sourcePath) WalkCallbacks
                { walkOnFile = setSdkFileMode
                , walkOnDirectoryPost = \path ->
                    when (path /= addTrailingPathSeparator (unwrapSdkPath sourcePath)) $
                        setSdkFileMode path
                , walkOnDirectoryPre = const (pure ())
                }

        setupDamlPath damlPath

        let targetPath = defaultSdkPath damlPath sourceVersion

        whenM (doesDirectoryExist (unwrapSdkPath targetPath)) $ do
            requiredIO "Failed to set file modes for SDK to remove." $ do
                walkRecursive (unwrapSdkPath targetPath) WalkCallbacks
                    { walkOnFile = setRemoveFileMode
                    , walkOnDirectoryPre = setRemoveFileMode
                    , walkOnDirectoryPost = const (pure ())
                    }

        when (sourcePath /= targetPath) $ do -- should be true 99.9% of the time,
                                            -- but in that 0.1% this check prevents us
                                            -- from deleting the sdk we want to install
                                            -- just because it's already in the right place.
            requiredIO "Failed to remove existing SDK installation." $
                removePathForcibly (unwrapSdkPath targetPath)
                -- Always removePathForcibly to uniformize renameDirectory behavior
                -- between windows and unices.
            requiredIO "Failed to move extracted SDK release to final location." $
                moveDirectory (unwrapSdkPath sourcePath) (unwrapSdkPath targetPath)

        requiredIO "Failed to set file mode of installed SDK directory." $
            setSdkFileMode (unwrapSdkPath targetPath)

        whenActivate env $ activateDaml env targetPath

activateDaml :: InstallEnv -> SdkPath -> IO ()
activateDaml env@InstallEnv{..} targetPath = do

    let damlSourceName = if isWindows then "daml.exe" else "daml"
        damlTargetName = if isWindows then "daml.cmd" else "daml"
        damlBinarySourcePath = unwrapSdkPath targetPath </> "daml" </> damlSourceName
        damlBinaryTargetDir  = unwrapDamlPath damlPath </> "bin"
        damlBinaryTargetPath = damlBinaryTargetDir </> damlTargetName

    unlessM (doesFileExist damlBinarySourcePath) $
        throwIO $ assistantErrorBecause
            "daml binary is missing from SDK release."
            ("expected path = " <> pack damlBinarySourcePath)

    whenM (doesFileExist damlBinaryTargetPath) $
        requiredIO "Failed to delete existing daml binary link." $
            if isWindows
                then removePathForcibly damlBinaryTargetPath
                else removeLink damlBinaryTargetPath

    requiredIO ("Failed to link daml binary in " <> pack damlBinaryTargetDir) $
        if isWindows
            then writeFile damlBinaryTargetPath $ unlines
                     [ "@echo off"
                     , damlBinarySourcePath <> " %*"
                     ]
            else createSymbolicLink damlBinarySourcePath damlBinaryTargetPath

    updatePath options (\s -> unlessQuiet env (output s)) damlBinaryTargetDir

data WalkCallbacks = WalkCallbacks
    { walkOnFile :: FilePath -> IO ()
        -- ^ Callback to be called on files.
    , walkOnDirectoryPre  :: FilePath -> IO ()
        -- ^ Callback to be called on directories before recursion.
    , walkOnDirectoryPost :: FilePath -> IO ()
        -- ^ Callback to be called on directories after recursion.
    }

-- | Walk directory tree recursively, calling the callbacks specified in
-- the WalkCallbacks record. Each callback path is prefixed with the
-- query path. Directory callback paths have trailing path separator.
--
-- Edge case: If walkRecursive is called on a non-existant path, it will
-- call the walkOnFile callback.
walkRecursive :: FilePath -> WalkCallbacks -> IO ()
walkRecursive path callbacks = do
    isDirectory <- doesDirectoryExist path
    if isDirectory
        then do
            let dirPath = addTrailingPathSeparator path -- for uniformity
            walkOnDirectoryPre callbacks dirPath
            children <- listDirectory dirPath
            forM_ children $ \child -> do
                walkRecursive (dirPath </> child) callbacks
            walkOnDirectoryPost callbacks dirPath
        else do
            walkOnFile callbacks path

-- | Restrict file modes of installed sdk files to read and execute.
setSdkFileMode :: FilePath -> IO ()
setSdkFileMode path = do
    sourceMode <- fileMode <$> getFileStatus path
    setFileMode path (intersectFileModes fileModeMask sourceMode)

-- | Add write permissions to allow for removal.
setRemoveFileMode :: FilePath -> IO ()
setRemoveFileMode path = do
    sourceMode <- fileMode <$> getFileStatus path
    setFileMode path (unionFileModes ownerWriteMode sourceMode)

-- | File mode mask to be applied to installed SDK files.
fileModeMask :: FileMode
fileModeMask = foldl1 unionFileModes
    [ ownerReadMode
    , ownerExecuteMode
    , groupReadMode
    , groupExecuteMode
    , otherReadMode
    , otherExecuteMode
    ]

-- | Copy an extracted SDK release directory and install it.
copyAndInstall :: InstallEnv -> FilePath -> IO ()
copyAndInstall env sourcePath =
    wrapErr "Copying SDK release directory." $ do
        withSystemTempDirectory "daml-update" $ \tmp -> do
            let copyPath = tmp </> "release"
                prefixLen = length (addTrailingPathSeparator sourcePath)
                newPath path = copyPath </> drop prefixLen path

            walkRecursive sourcePath WalkCallbacks
                { walkOnFile = \path -> copyFileWithMetadata path (newPath path)
                , walkOnDirectoryPre = \path -> createDirectory (newPath path)
                , walkOnDirectoryPost = \_ -> pure ()
                }

            installExtracted env (SdkPath copyPath)

-- | Extract a tarGz bytestring and install it.
extractAndInstall :: InstallEnv
    -> ConduitT () BS.ByteString (ResourceT IO) () -> IO ()
extractAndInstall env source =
    wrapErr "Extracting SDK release tarball." $ do
        withSystemTempDirectory "daml-update" $ \tmp -> do
            let extractPath = tmp </> "release"
            createDirectory extractPath
            runConduitRes
                $ source
                .| Zlib.ungzip
                .| Tar.untar (Tar.restoreFile throwError extractPath)
            installExtracted env (SdkPath extractPath)
    where throwError msg e = liftIO $ throwIO $ assistantErrorBecause ("Invalid SDK release: " <> msg) e

-- | Download an sdk tarball and install it.
httpInstall :: InstallEnv -> InstallURL -> IO ()
httpInstall env@InstallEnv{..} (InstallURL url) = do
    unlessQuiet env $ output "Downloading SDK release."
    request <- requiredAny "Failed to parse HTTPS request." $ parseRequest ("GET " <> unpack url)
    requiredAny "Failed to download SDK release." $ withResponse request $ \response -> do
        when (getResponseStatusCode response /= 200) $
            throwIO . assistantErrorBecause "Failed to download release."
                    . pack . show $ getResponseStatus response
        let totalSizeM = readMay . BS.UTF8.toString =<< headMay
                (getResponseHeader "Content-Length" response)
        extractAndInstall env
            . maybe id (\s -> (.| observeProgress s)) totalSizeM
            $ getResponseBody response
    where
        observeProgress :: MonadResource m =>
            Int -> ConduitT BS.ByteString BS.ByteString m ()
        observeProgress totalSize = do
            pb <- liftIO $ newProgressBar defStyle 10 (Progress 0 totalSize ())
            List.mapM $ \bs -> do
                liftIO $ incProgress pb (BS.length bs)
                pure bs

-- | Install SDK from a path. If the path is a tarball, extract it first.
pathInstall :: InstallEnv -> FilePath -> IO ()
pathInstall env@InstallEnv{..} sourcePath = do
    isDirectory <- doesDirectoryExist sourcePath
    if isDirectory
        then do
            unlessQuiet env $ output "Installing SDK release from directory."
            copyAndInstall env sourcePath
        else do
            unlessQuiet env $ output "Installing SDK release from tarball."
            extractAndInstall env (sourceFileBS sourcePath)

-- | Install a specific SDK version.
versionInstall :: InstallEnv -> SdkVersion -> IO ()
versionInstall env@InstallEnv{..} version = do

    let SdkPath path = defaultSdkPath damlPath version
    alreadyInstalled <- doesDirectoryExist path

    let forceFlag = unForceInstall (iForce options)
        activateFlag = unActivateInstall (iActivate options)
        performInstall = not alreadyInstalled || forceFlag

    unlessQuiet env . output . concat $
        if alreadyInstalled then
            [ "SDK version "
            , versionToString version
            , " is already installed."
            , if performInstall
                then " Reinstalling."
                else ""
            ]
        else
            [ "Installing SDK version "
            , versionToString version
            ]

    when performInstall $
        httpInstall env { targetVersionM = Just version }
            (Github.versionURL version)

    -- Need to activate here if we aren't performing the full install.
    when (not performInstall && activateFlag) $ do
        unlessQuiet env . output $
            "Activating assistant version " <> versionToString version
        activateDaml env (SdkPath path)

-- | Install the latest stable version of the SDK.
latestInstall :: InstallEnv -> IO ()
latestInstall env = do
    version <- getLatestVersion
    versionInstall env version

-- | Get the latest stable version.
getLatestVersion :: IO SdkVersion
getLatestVersion = Github.getLatestVersion

-- | Install the SDK version of the current project.
projectInstall :: InstallEnv -> ProjectPath -> IO ()
projectInstall env projectPath = do
    projectConfig <- readProjectConfig projectPath
    versionM <- fromRightM throwIO $ sdkVersionFromProjectConfig projectConfig
    version <- required "SDK version missing from project config (daml.yaml)." versionM
    versionInstall env version

-- | Run install command.
install :: InstallOptions -> DamlPath -> Maybe ProjectPath -> IO ()
install options damlPath projectPathM = do
    let targetVersionM = Nothing -- determined later
        output = putStrLn -- Output install messages to stdout.
        env = InstallEnv {..}
    case iTargetM options of
        Nothing -> do
            hPutStrLn stderr $ unlines
                [ "ERROR: daml install requires a target."
                , ""
                , "Available install targets:"
                , "    daml install latest     Install the latest stable SDK version."
                , "    daml install project    Install the project SDK version."
                , "    daml install VERSION    Install a specific SDK version."
                , "    daml install PATH       Install SDK from an SDK release tarball."
                ]
            exitFailure

        Just (RawInstallTarget "project") -> do
            projectPath <- required "'daml install project' must be run from within a project."
                projectPathM
            projectInstall env projectPath

        Just (RawInstallTarget "latest") ->
            latestInstall env

        Just (RawInstallTarget arg) | Right version <- parseVersion (pack arg) ->
            versionInstall env version

        Just (RawInstallTarget arg) -> do
            testD <- doesDirectoryExist arg
            testF <- doesFileExist arg
            if testD || testF then
                pathInstall env arg
            else
                throwIO (assistantErrorBecause "Invalid install target. Expected version, path, 'project' or 'latest'." ("target = " <> pack arg))
