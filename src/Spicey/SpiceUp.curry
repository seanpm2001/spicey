-- Main module to generate the initial Spicey application

module Spicey.SpiceUp where

import Database.ERD         ( ERD(..), Entity(..), readERDTermFile )
import Database.ERD.Goodies ( erdName, storeERDFromProgram )
import Directory
import Distribution         ( installDir )
import FilePath             ( (</>), takeFileName )
import List                 ( isSuffixOf, last )
import System               ( setEnviron, system, getArgs, exitWith )

import Spicey.PackageConfig ( packagePath, packageVersion, packageLoadPath )
import Spicey.Scaffolding

systemBanner :: String
systemBanner =
  let bannerText = "Spicey Web Framework (Version " ++ packageVersion ++
                   " of 24/10/19)"
      bannerLine = take (length bannerText) (repeat '-')
   in bannerLine ++ "\n" ++ bannerText ++ "\n" ++ bannerLine

data FileMode = Exec | NoExec
 deriving Eq

setFileMode :: FileMode -> String -> IO ()
setFileMode fmode filename =
  if fmode==Exec then system ("chmod +x \"" ++ filename ++ "\"") >> done
                 else done

data DirTree =
   Directory String [DirTree] -- a directory to be created
 | ResourceFile FileMode String   -- a file to be copied from resource directory
 | ResourcePatchFile FileMode String (ERD -> String -> String)
    -- file to be copied from resource directory
    -- where its contents is patched by the given function
 | GeneratedFromERD (String -> ERD -> String -> String -> IO ())
   -- takes an operation to generate code from ERD specification

spiceyStructure :: String -> DirTree
spiceyStructure pkgname = 
  Directory "." [
    ResourceFile NoExec "README.txt",
    ResourcePatchFile NoExec "package.json" (replacePackageName pkgname),
    ResourcePatchFile NoExec "Makefile" patchMakeFile,
    Directory "src" [
      ResourceFile NoExec "Main.curry",
      Directory "System" [
        ResourceFile NoExec $ "System" </> "Spicey.curry",
        ResourceFile NoExec $ "System" </> "Routes.curry",
        ResourceFile NoExec $ "System" </> "SessionInfo.curry",
        ResourceFile NoExec $ "System" </> "Authorization.curry",
        ResourceFile NoExec $ "System" </> "Authentication.curry",
        ResourceFile NoExec $ "System" </> "Processes.curry",
        GeneratedFromERD createAuthorizations ],
      Directory "View" [
        ResourceFile NoExec $ "View" </> "SpiceySystem.curry",
        GeneratedFromERD createViews,
        GeneratedFromERD createHtmlHelpers ],
      Directory "Controller" [
        ResourceFile NoExec $ "Controller" </> "SpiceySystem.curry",
        GeneratedFromERD createControllers ],
      Directory "Model" [
        GeneratedFromERD createModels ],
      Directory "Config" [
        ResourceFile NoExec $ "Config" </> "Storage.curry",
        ResourceFile NoExec $ "Config" </> "UserProcesses.curry",
        GeneratedFromERD createRoutes,
        GeneratedFromERD createEntityRoutes ]
    ],
    Directory "data" [
      ResourceFile NoExec $ "data" </> "htaccess"
    ],
    Directory "public" [
      ResourceFile NoExec $ "public" </> "index.html",
      ResourceFile NoExec $ "public" </> "favicon.ico",
      Directory "css" [
        ResourceFile NoExec $ "css" </> "bootstrap.min.css",
        ResourceFile NoExec $ "css" </> "spicey.css"
      ],
      Directory "js" [
        ResourceFile NoExec $ "js" </> "bootstrap.min.js",
        ResourceFile NoExec $ "js" </> "jquery.min.js"
      ],
      Directory "fonts" [
        ResourceFile NoExec $ "fonts" </> "glyphicons-halflings-regular.eot",
        ResourceFile NoExec $ "fonts" </> "glyphicons-halflings-regular.svg",
        ResourceFile NoExec $ "fonts" </> "glyphicons-halflings-regular.ttf",
        ResourceFile NoExec $ "fonts" </> "glyphicons-halflings-regular.woff",
        ResourceFile NoExec $ "fonts" </> "glyphicons-halflings-regular.woff2"
      ],
      Directory "images" [
        ResourceFile NoExec $ "images" </> "spicey-logo.png",
        ResourceFile NoExec $ "images" </> "text.png",
        ResourceFile NoExec $ "images" </> "time.png",
        ResourceFile NoExec $ "images" </> "number.png",
        ResourceFile NoExec $ "images" </> "foreign.png"
      ]
    ]
  ]

-- Replace every occurrence of `XXXCURRYHOMEXXX` by `installDir` and
-- every occurrince of `XXXICONTROLLERXXX` by
-- `-i <controllermod1> ... -i <controllermodn>`.
patchMakeFile :: ERD -> String -> String
patchMakeFile _ [] = []
patchMakeFile erd@(ERD _ entities _) (c:cs)
  | c=='X' && take 14 cs == "XXCURRYHOMEXXX"
  = installDir ++ patchMakeFile erd (drop 14 cs)
  | c=='X' && take 16 cs == "XXICONTROLLERXXX"
  = unwords (map (\ (Entity ename _) -> "-i Controller." ++ ename) entities) ++
    patchMakeFile erd (drop 16 cs)
  | otherwise
  = c : patchMakeFile erd cs

-- Replace every occurrence of "XXXPKGNAMEXXX" by first argument
replacePackageName :: String -> ERD -> String -> String
replacePackageName _ _ [] = []
replacePackageName pn erd (c:cs)
  | c=='X' && take 12 cs == "XXPKGNAMEXXX"
    = pn ++ replacePackageName pn erd (drop 12 cs)
  | otherwise = c : replacePackageName pn erd cs

-- checks if given path exists (file or directory) and executes
-- given action if not
ifNotExistsDo :: String -> IO () -> IO ()
ifNotExistsDo path cmd = do
  fileExists <- doesFileExist path
  dirExists  <- doesDirectoryExist path
  if fileExists || dirExists
    then putStrLn $ "Skipping '" ++ path ++ "'..."
    else cmd

--- Creates the structure of the source files of the new package.
createStructure :: String -> String -> ERD -> String -> String -> DirTree
                -> IO ()
createStructure target_path resource_dir _ _ _
                (ResourceFile fmode filename) = do
  let infile     = resource_dir </> filename
      targetfile = target_path  </> takeFileName filename
  ifNotExistsDo targetfile $ do
    putStrLn $ "Creating file '" ++ targetfile ++ "'..."
    system $ "cp \"" ++ infile ++ "\" \"" ++ targetfile ++ "\""
    setFileMode fmode targetfile

createStructure target_path resource_dir erd _ _
                (ResourcePatchFile fmode filename patchfun) = do
  let full_path = target_path </> filename
  ifNotExistsDo full_path $ do
    putStrLn ("Creating file '" ++ full_path ++ "'...")
    cnt <- readFile (resource_dir </> filename)
    let outfile = target_path </> filename
    writeFile outfile (patchfun erd cnt)
    setFileMode fmode outfile

createStructure target_path resource_dir erd termfile db_path
                (Directory dirname subtree) = do
  let full_path = target_path </> dirname
  ifNotExistsDo full_path $ do
    putStrLn $ "Creating directory '"++full_path++"'..."
    createDirectory full_path
  mapIO_ (createStructure full_path resource_dir erd termfile db_path) subtree

createStructure target_path _ erd termfile db_path
                (GeneratedFromERD generatorFunction) =
  generatorFunction termfile erd target_path db_path

--- The main operation to start the scaffolding.
main :: IO ()
main = do
  putStrLn systemBanner
  args <- getArgs
  case args of
    ["-h"]     -> spiceupHelp 0
    ["--help"] -> spiceupHelp 0
    ["-?"]     -> spiceupHelp 0
    ["--db",dbfile,orgfile] -> createStructureWith orgfile dbfile
    [orgfile]               -> createStructureWith orgfile ""
    _ -> putStrLn ("Wrong arguments!\n") >> spiceupHelp 1
 where
  createStructureWith orgfile dbfile = do
    -- set CURRYPATH in order to compile ERD model (which requires Database.ERD)
    unless (null packageLoadPath) $ setEnviron "CURRYPATH" packageLoadPath
    -- The directory containing the project generator:
    let resourcedir = packagePath </> "resource_files"
    exfile <- doesFileExist orgfile
    unless exfile $ error ("File `" ++ orgfile ++ "' does not exist!")
    termfile <- if ".curry" `isSuffixOf` orgfile ||
                   ".lcurry" `isSuffixOf` orgfile
                  then storeERDFromProgram orgfile
                  else return orgfile
    erd <- readERDTermFile termfile
    let pkgname = erdName erd
    createDirectoryIfMissing True pkgname
    createStructure pkgname resourcedir erd termfile dbfile
                    (spiceyStructure pkgname)
    when (orgfile /= termfile) $ do
      -- delete generated ERD term file:
      removeFile termfile
      -- save original ERD specification in src/Model directory:
      copyFile orgfile
               (pkgname </> "src" </> "Model" </> erdName erd ++ "_ERD.curry")
    putStrLn (helpText pkgname)

  helpText pkgname = unlines $
    [ take 70 (repeat '-')
    , "Source files for the application generated as Curry package '" ++
      pkgname ++ "'."
    , ""
    , "Please go into the package directory where the 'README.txt' file"
    , "contains some hints how to install the generated application."
    , ""
    , "IMPORTANT NOTE:"
    , "Before you deploy your web application (by 'make deploy'),"
    , "you should define the variable WEBSERVERDIR in the Makefile!"
    ]

spiceupHelp :: Int -> IO ()
spiceupHelp ecode = putStrLn helpText >> exitWith ecode
 where
  helpText = unlines $
   [ "Usage:"
   , ""
   , "    spiceup [--db <db file>] <ERD program file>"
   , ""
   , "Parameters:"
   , "--db <db file>    : name of the SQLite3 database file (default: <ERD name>.db)"
   , "<ERD program file>: name of Curry program file containing ERD definition"
   ]