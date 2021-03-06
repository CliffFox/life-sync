-- | Utilities to work with GitHub repositories using "hub".

module Life.Github
       ( Owner (..)
       , Repo  (..)

         -- * Repository utils
       , checkRemoteSync
       , cloneRepo
       , insideRepo
       , withSynced

         -- * Repository manipulation commands
       , CopyDirection (..)
       , copyLife
       , addToRepo
       , createRepository
       , pullUpdateFromRepo
       , removeFromRepo
       , updateDotfilesRepo
       , updateFromRepo
       ) where

import Control.Exception (throwIO)
import Path (Abs, Dir, File, Path, Rel, toFilePath, (</>))
import Path.IO (copyDirRecur, copyFile, getHomeDir, withCurrentDir)
import System.IO.Error (IOError, isDoesNotExistError)

import Life.Configuration (LifeConfiguration (..), lifeConfigMinus, parseRepoLife)
import Life.Message (chooseYesNo, errorMessage, infoMessage, warningMessage)
import Life.Shell (lifePath, relativeToHome, repoName, ($|))

newtype Owner = Owner { getOwner :: Text } deriving (Show)
newtype Repo  = Repo  { getRepo  :: Text } deriving (Show)

----------------------------------------------------------------------------
-- VSC commands
----------------------------------------------------------------------------

askToPushka :: Text -> IO ()
askToPushka commitMsg = do
    "git" ["add", "."]
    infoMessage "The following changes are going to be pushed:"
    "git" ["diff", "--name-status", "HEAD"]
    continue <- chooseYesNo "Would you like to proceed?"
    if continue
    then pushka commitMsg
    else errorMessage "Abort pushing" >> exitFailure

-- | Make a commit and push it.
pushka :: Text -> IO ()
pushka commitMsg = do
    "git" ["add", "."]
    "git" ["commit", "-m", commitMsg]
    "git" ["push", "-u", "origin", "master"]

-- | Creates repository on GitHub inside given folder.
createRepository :: Owner -> Repo -> IO ()
createRepository (Owner owner) (Repo repo) = do
    let description = ":computer: Configuration files"
    "git" ["init"]
    "hub" ["create", "-d", description, owner <> "/" <> repo]
    pushka "Create the project"

----------------------------------------------------------------------------
-- dotfiles workflow
----------------------------------------------------------------------------

-- | Executes action with 'repoName' set as pwd.
insideRepo :: (MonadIO m, MonadMask m) => m a -> m a
insideRepo action = do
    repoPath <- relativeToHome repoName
    withCurrentDir repoPath action

-- | Commits all changes inside 'repoName' and pushes to remote.
pushRepo :: Text -> IO ()
pushRepo = insideRepo . askToPushka

-- | Clones @dotfiles@ repository assuming it doesn't exist.
cloneRepo :: Owner -> IO ()
cloneRepo (Owner owner) = do
    homeDir <- getHomeDir
    withCurrentDir homeDir $ do
        infoMessage "Using SSH to clone repo..."
        "git" ["clone", "git@github.com:" <> owner <> "/dotfiles.git"]

-- | Returns true if local @dotfiles@ repository is synchronized with remote repo.
checkRemoteSync :: IO Bool
checkRemoteSync = do
    "git" ["fetch", "origin", "master"]
    localHash  <- "git" $| ["rev-parse", "master"]
    remoteHash <- "git" $| ["rev-parse", "origin/master"]
    pure $ localHash == remoteHash

withSynced :: IO a -> IO a
withSynced action = insideRepo $ do
    infoMessage "Checking if repo is synchnorized..."
    isSynced <- checkRemoteSync
    if isSynced then do
        infoMessage "Repo is up-to-date"
        action
    else do
        warningMessage "Local version of repository is out of date"
        shouldSync <- chooseYesNo "Do you want to sync repo with remote?"
        if shouldSync then do
            "git" ["rebase", "origin/master"]
            action
        else do
            errorMessage "Aborting current command because repository is not synchronized with remote"
            exitFailure

----------------------------------------------------------------------------
-- File manipulation
----------------------------------------------------------------------------

data CopyDirection = FromHomeToRepo | FromRepoToHome

pullUpdateFromRepo :: LifeConfiguration -> IO ()
pullUpdateFromRepo life = do
    insideRepo $ "git" ["pull", "-r"]
    updateFromRepo life

updateFromRepo :: LifeConfiguration -> IO ()
updateFromRepo excludeLife = insideRepo $ do
    infoMessage "Copying files from repo to local machine..."

    repoLife <- parseRepoLife
    let lifeToLive = lifeConfigMinus repoLife excludeLife

    copyLife FromRepoToHome lifeToLive

updateDotfilesRepo :: Text -> LifeConfiguration -> IO ()
updateDotfilesRepo commitMsg life = do
    copyLife FromHomeToRepo life
    pushRepo commitMsg

copyLife :: CopyDirection -> LifeConfiguration -> IO ()
copyLife direction LifeConfiguration{..} = do
    copyFiles direction (toList lifeConfigurationFiles)
    copyDirs  direction (toList lifeConfigurationDirectories)

-- | Copy files to repository and push changes to remote repository.
copyFiles :: CopyDirection -> [Path Rel File] -> IO ()
copyFiles = copyPathList copyFile

-- | Copy dirs to repository.
copyDirs :: CopyDirection -> [Path Rel Dir] -> IO ()
copyDirs = copyPathList copyDirRecur

copyPathList :: (Path Abs t -> Path Abs t -> IO ())
             -- ^ Copying action
             -> CopyDirection
             -- ^ Describes in which direction files should be copied
             -> [Path Rel t]
             -- ^ List of paths to copy
             -> IO ()
copyPathList copyAction direction pathList = do
    homeDir    <- getHomeDir
    let repoDir = homeDir </> repoName

    for_ pathList $ \entryPath -> do
        let homePath = homeDir </> entryPath
        let repoPath = repoDir </> entryPath
        case direction of
            FromHomeToRepo -> copyAction homePath repoPath
            FromRepoToHome -> copyAction repoPath homePath

-- | Adds file or directory to the repository and commits
addToRepo :: (Path Abs t -> Path Abs t -> IO ()) -> Path Rel t -> IO ()
addToRepo copyFun path = do
    -- copy file
    sourcePath <- relativeToHome path
    destinationPath <- relativeToHome (repoName </> path)
    copyFun sourcePath destinationPath

    -- update .life file
    lifeFile <- relativeToHome lifePath
    repoLifeFile <- relativeToHome (repoName </> lifePath)
    copyFile lifeFile repoLifeFile

    let commitMsg = "Add: " <> toText (toFilePath path)
    pushRepo commitMsg

-- | Removes file or directory from the repository and commits
removeFromRepo :: (Path Abs t -> IO ()) -> Path Rel t -> IO ()
removeFromRepo removeFun path = do
    absPath <- relativeToHome (repoName </> path)
    catch (removeFun absPath) handleNotExist

    -- update .life file
    lifeFile <- relativeToHome lifePath
    repoLifeFile <- relativeToHome (repoName </> lifePath)
    copyFile lifeFile repoLifeFile

    let commitMsg = "Remove: " <> pathTextName
    pushRepo commitMsg
  where
    pathTextName :: Text
    pathTextName = toText $ toFilePath path

    handleNotExist :: IOError -> IO ()
    handleNotExist e = if isDoesNotExistError e
        then errorMessage ("File/directory " <> pathTextName <> " is not found") >> exitFailure
        else throwIO e
