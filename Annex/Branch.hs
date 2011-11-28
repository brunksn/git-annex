{- management of the git-annex branch
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Annex.Branch (
	create,
	update,
	disableUpdate,
	get,
	change,
	commit,
	files,
	refExists,
	hasOrigin,
	hasSomeBranch,
	name	
) where

import System.IO.Binary
import System.Exit
import qualified Data.ByteString.Lazy.Char8 as L

import Common.Annex
import Annex.Exception
import Types.BranchState
import qualified Git
import qualified Git.UnionMerge
import qualified Annex
import Annex.CatFile

{- Name of the branch that is used to store git-annex's information. -}
name :: Git.Ref
name = Git.Ref "git-annex"

{- Fully qualified name of the branch. -}
fullname :: Git.Ref
fullname = Git.Ref $ "refs/heads/" ++ show name

{- Branch's name in origin. -}
originname :: Git.Ref
originname = Git.Ref $ "origin/" ++ show name

{- A separate index file for the branch. -}
index :: Git.Repo -> FilePath
index g = gitAnnexDir g </> "index"

{- Populates the branch's index file with the current branch contents.
 - 
 - Usually, this is only done when the index doesn't yet exist, and
 - the index is used to build up changes to be commited to the branch,
 - and merge in changes from other branches.
 -}
genIndex :: Git.Repo -> IO ()
genIndex g = Git.UnionMerge.stream_update_index g
	[Git.UnionMerge.ls_tree fullname g]

{- Runs an action using the branch's index file. -}
withIndex :: Annex a -> Annex a
withIndex = withIndex' False
withIndex' :: Bool -> Annex a -> Annex a
withIndex' bootstrapping a = do
	f <- fromRepo index
	bracketIO (Git.useIndex f) id $ do
		unlessM (liftIO $ doesFileExist f) $ do
			unless bootstrapping create
			liftIO $ createDirectoryIfMissing True $ takeDirectory f
			unless bootstrapping $ inRepo genIndex
		a

withIndexUpdate :: Annex a -> Annex a
withIndexUpdate a = update >> withIndex a

getState :: Annex BranchState
getState = Annex.getState Annex.branchstate

setState :: BranchState -> Annex ()
setState state = Annex.changeState $ \s -> s { Annex.branchstate = state }

setCache :: FilePath -> String -> Annex ()
setCache file content = do
	state <- getState
	setState state { cachedFile = Just file, cachedContent = content }

invalidateCache :: Annex ()
invalidateCache = do
	state <- getState
	setState state { cachedFile = Nothing, cachedContent = "" }

getCache :: FilePath -> Annex (Maybe String)
getCache file = getState >>= go
	where
		go state
			| cachedFile state == Just file =
				return $ Just $ cachedContent state
			| otherwise = return Nothing

{- Creates the branch, if it does not already exist. -}
create :: Annex ()
create = unlessM hasBranch $ do
	e <- hasOrigin
	if e
		then inRepo $ Git.run "branch"
			[Param $ show name, Param $ show originname]
		else withIndex' True $
			inRepo $ Git.commit "branch created" fullname []

{- Stages the journal, and commits staged changes to the branch. -}
commit :: String -> Annex ()
commit message = whenM journalDirty $ lockJournal $ do
	stageJournalFiles
	withIndex $ inRepo $ Git.commit message fullname [fullname]

{- Ensures that the branch is up-to-date; should be called before data is
 - read from it. Runs only once per git-annex run.
 -
 - Before refs are merged into the index, it's important to first stage the
 - journal into the index. Otherwise, any changes in the journal would
 - later get staged, and might overwrite changes made during the merge.
 -
 - (It would be cleaner to handle the merge by updating the journal, not the
 - index, with changes from the branches.)
 -
 - The index is always updated using a union merge, as that's the most
 - efficient way to update it. However, if the branch can be
 - fast-forwarded, that is then done, rather than adding an unnecessary
 - commit to it.
 -}
update :: Annex ()
update = onceonly $ do
	-- ensure branch exists
	create
	-- check what needs updating before taking the lock
	dirty <- journalDirty
	c <- filterM (changedBranch name . snd) =<< siblingBranches
	let (refs, branches) = unzip c
	unless (not dirty && null refs) $ withIndex $ lockJournal $ do
		when dirty stageJournalFiles
		let merge_desc = if null branches
			then "update" 
			else "merging " ++
				(unwords $ map (show . Git.refDescribe) branches) ++ 
				" into " ++ show name
		unless (null branches) $ do
			showSideAction merge_desc
			{- Note: This merges the branches into the index.
			 - Any unstaged changes in the git-annex branch
			 - (if it's checked out) will be removed. So,
			 - documentation advises users not to directly
			 - modify the branch.
			 -}
			h <- catFileHandle
			inRepo $ \g -> Git.UnionMerge.merge_index h g branches
		ff <- if dirty then return False else tryFastForwardTo refs
		unless ff $ inRepo $
			Git.commit merge_desc fullname (nub $ fullname:refs)
		invalidateCache
	where
		onceonly a = unlessM (branchUpdated <$> getState) $ do
			r <- a
			disableUpdate
			return r

{- Checks if the second branch has any commits not present on the first
 - branch. -}
changedBranch :: Git.Branch -> Git.Branch -> Annex Bool
changedBranch origbranch newbranch = not . L.null <$> diffs
	where
		diffs = inRepo $ Git.pipeRead
			[ Param "log"
			, Param (show origbranch ++ ".." ++ show newbranch)
			, Params "--oneline -n1"
			]

{- Given a set of refs that are all known to have commits not
 - on the git-annex branch, tries to update the branch by a
 - fast-forward.
 -
 - In order for that to be possible, one of the refs must contain
 - every commit present in all the other refs, as well as in the
 - git-annex branch.
 -}
tryFastForwardTo :: [Git.Ref] -> Annex Bool
tryFastForwardTo [] = return True
tryFastForwardTo (first:rest) = do
	-- First, check that the git-annex branch does not contain any
	-- new commits that are in the first other branch. If it does,
	-- cannot fast-forward.
	diverged <- changedBranch first fullname
	if diverged
		then no_ff
		else maybe no_ff do_ff =<< findbest first rest
	where
		no_ff = return False
		do_ff branch = do
			inRepo $ Git.run "update-ref" [Param $ show fullname, Param $ show branch]
			return True
		findbest c [] = return $ Just c
		findbest c (r:rs)
			| c == r = findbest c rs
			| otherwise = do
			better <- changedBranch c r
			worse <- changedBranch r c
			case (better, worse) of
				(True, True) -> return Nothing -- divergent fail
				(True, False) -> findbest r rs -- better
				(False, True) -> findbest c rs -- worse
				(False, False) -> findbest c rs -- same
			
{- Avoids updating the branch. A useful optimisation when the branch
 - is known to have not changed, or git-annex won't be relying on info
 - from it. -}
disableUpdate :: Annex ()
disableUpdate = Annex.changeState setupdated
	where
		setupdated s = s { Annex.branchstate = new }
			where
				new = old { branchUpdated = True }
				old = Annex.branchstate s

{- Checks if a git ref exists. -}
refExists :: Git.Ref -> Annex Bool
refExists ref = inRepo $ Git.runBool "show-ref"
	[Param "--verify", Param "-q", Param $ show ref]

{- Does the main git-annex branch exist? -}
hasBranch :: Annex Bool
hasBranch = refExists fullname

{- Does origin/git-annex exist? -}
hasOrigin :: Annex Bool
hasOrigin = refExists originname

{- Does the git-annex branch or a foo/git-annex branch exist? -}
hasSomeBranch :: Annex Bool
hasSomeBranch = not . null <$> siblingBranches

{- List of git-annex (refs, branches), including the main one and any
 - from remotes. Duplicate refs are filtered out. -}
siblingBranches :: Annex [(Git.Ref, Git.Branch)]
siblingBranches = do
	r <- inRepo $ Git.pipeRead [Param "show-ref", Param $ show name]
	return $ nubBy uref $ map (gen . words . L.unpack) (L.lines r)
	where
		gen l = (Git.Ref $ head l, Git.Ref $ last l)
		uref (a, _) (b, _) = a == b

{- Applies a function to modifiy the content of a file.
 -
 - Note that this does not cause the branch to be merged, it only
 - modifes the current content of the file on the branch.
 -}
change :: FilePath -> (String -> String) -> Annex ()
change file a = lockJournal $ getStale file >>= return . a >>= set file

{- Records new content of a file into the journal. -}
set :: FilePath -> String -> Annex ()
set file content = do
	setJournalFile file content
	setCache file content

{- Gets the content of a file on the branch, or content from the journal, or
 - staged in the index.
 -
 - Returns an empty string if the file doesn't exist yet. -}
get :: FilePath -> Annex String
get = get' False

{- Like get, but does not merge the branch, so the info returned may not
 - reflect changes in remotes. (Changing the value this returns, and then
 - merging is always the same as using get, and then changing its value.) -}
getStale :: FilePath -> Annex String
getStale = get' True

get' :: Bool -> FilePath -> Annex String
get' staleok file = fromcache =<< getCache file
	where
		fromcache (Just content) = return content
		fromcache Nothing = fromjournal =<< getJournalFile file
		fromjournal (Just content) = cache content
		fromjournal Nothing
			| staleok = withIndex frombranch
			| otherwise = withIndexUpdate $ frombranch >>= cache
		frombranch = L.unpack <$> catFile fullname file
		cache content = do
			setCache file content
			return content

{- Lists all files on the branch. There may be duplicates in the list. -}
files :: Annex [FilePath]
files = withIndexUpdate $ do
	bfiles <- inRepo $ Git.pipeNullSplit
		[Params "ls-tree --name-only -r -z", Param $ show fullname]
	jfiles <- getJournalledFiles
	return $ jfiles ++ bfiles

{- Records content for a file in the branch to the journal.
 -
 - Using the journal, rather than immediatly staging content to the index
 - avoids git needing to rewrite the index after every change. -}
setJournalFile :: FilePath -> String -> Annex ()
setJournalFile file content = do
	g <- gitRepo
	liftIO $ doRedo (write g) $ do
		createDirectoryIfMissing True $ gitAnnexJournalDir g
		createDirectoryIfMissing True $ gitAnnexTmpDir g
	where
		-- journal file is written atomically
		write g = do
			let jfile = journalFile g file
			let tmpfile = gitAnnexTmpDir g </> takeFileName jfile
			writeBinaryFile tmpfile content
			moveFile tmpfile jfile

{- Gets any journalled content for a file in the branch. -}
getJournalFile :: FilePath -> Annex (Maybe String)
getJournalFile file = inRepo $ \g -> catchMaybeIO $
	readFileStrict $ journalFile g file

{- List of files that have updated content in the journal. -}
getJournalledFiles :: Annex [FilePath]
getJournalledFiles = map fileJournal <$> getJournalFiles

{- List of existing journal files. -}
getJournalFiles :: Annex [FilePath]
getJournalFiles = do
	g <- gitRepo
	fs <- liftIO $
		catchDefaultIO (getDirectoryContents $ gitAnnexJournalDir g) []
	return $ filter (`notElem` [".", ".."]) fs

{- Stages the specified journalfiles. -}
stageJournalFiles :: Annex ()
stageJournalFiles = do
	fs <- getJournalFiles
	g <- gitRepo
	withIndex $ liftIO $ do
		let dir = gitAnnexJournalDir g
		let paths = map (dir </>) fs
		-- inject all the journal files directly into git
		-- in one quick command
		(pid, fromh, toh) <- hPipeBoth "git" $ toCommand $ git_hash_object g
		_ <- forkProcess $ do
			hPutStr toh $ unlines paths
			hClose toh
			exitSuccess
		hClose toh
		shas <- map Git.Ref . lines <$> hGetContents fromh
		-- update the index, also in just one command
		Git.UnionMerge.update_index g $
			index_lines shas (map fileJournal fs)
		hClose fromh
		forceSuccess pid
		mapM_ removeFile paths
	where
		index_lines shas = map genline . zip shas
		genline (sha, file) = Git.UnionMerge.update_index_line sha file
		git_hash_object = Git.gitCommandLine
			[Param "hash-object", Param "-w", Param "--stdin-paths"]


{- Checks if there are changes in the journal. -}
journalDirty :: Annex Bool
journalDirty = not . null <$> getJournalFiles

{- Produces a filename to use in the journal for a file on the branch.
 -
 - The journal typically won't have a lot of files in it, so the hashing
 - used in the branch is not necessary, and all the files are put directly
 - in the journal directory.
 -}
journalFile :: Git.Repo -> FilePath -> FilePath
journalFile repo file = gitAnnexJournalDir repo </> concatMap mangle file
	where
		mangle '/' = "_"
		mangle '_' = "__"
		mangle c = [c]

{- Converts a journal file (relative to the journal dir) back to the
 - filename on the branch. -}
fileJournal :: FilePath -> FilePath
fileJournal = replace "//" "_" . replace "_" "/"

{- Runs an action that modifies the journal, using locking to avoid
 - contention with other git-annex processes. -}
lockJournal :: Annex a -> Annex a
lockJournal a = do
	file <- fromRepo gitAnnexJournalLock
	bracketIO (lock file) unlock a
	where
		lock file = do
			l <- doRedo (createFile file stdFileMode) $
				createDirectoryIfMissing True $ takeDirectory file
			waitToSetLock l (WriteLock, AbsoluteSeek, 0, 0)
			return l
		unlock = closeFd

{- Runs an action, catching failure and running something to fix it up, and
 - retrying if necessary. -}
doRedo :: IO a -> IO b -> IO a
doRedo a b = catch a $ const $ b >> a
