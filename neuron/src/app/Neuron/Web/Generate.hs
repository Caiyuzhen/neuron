{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Main module for using neuron as a library, instead of as a CLI tool.
module Neuron.Web.Generate
  ( generateSite,
    loadZettelkasten,
    loadZettelkastenGraph,
  )
where

import Data.FileEmbed (embedOneStringFileOf)
import qualified Data.Map.Strict as Map
import Data.Tagged (untag)
import qualified Data.Text as T
import Data.Traversable
import Development.Shake (Action, need)
import Neuron.Config.Alias (Alias (..), getAliases)
import Neuron.Config.Type (Config)
import qualified Neuron.Config.Type as C
import Neuron.Reader (readerForZettelFormat)
import Neuron.Reader.Type (ZettelFormat, zettelFormatToExtension)
import Neuron.Version (neuronVersion, olderThan)
import qualified Neuron.Web.Cache as Cache
import Neuron.Web.Generate.Route ()
import qualified Neuron.Web.Route as Z
import qualified Neuron.Zettelkasten.Graph.Build as G
import Neuron.Zettelkasten.Graph.Type (ZettelGraph)
import Neuron.Zettelkasten.ID (ZettelID, getZettelID)
import Neuron.Zettelkasten.Query.Error (showQueryResultError)
import Neuron.Zettelkasten.Zettel
import Neuron.Zettelkasten.Zettel.Parser (extractQueriesWithContext)
import Options.Applicative
import Relude
import Rib.Route
import Rib.Shake (forEvery, ribInputDir)
import System.FilePath

-- | The contents of search.js
--
-- We specify an alternate path, that is relative to project root, so that
-- ghcide will be able to compile this module.
searchScript :: Text
searchScript = $(embedOneStringFileOf ["./src-js/search.js", "./neuron/src-js/search.js"])

-- | Generate the Zettelkasten site
generateSite ::
  Config ->
  (forall a. Z.Route a -> (ZettelGraph, a) -> Action ()) ->
  Action ZettelGraph
generateSite config writeHtmlRoute' = do
  when (olderThan $ C.minVersion config) $ do
    fail $
      toString $
        "Require neuron mininum version "
          <> C.minVersion config
          <> ", but your neuron version is "
          <> neuronVersion
  (zettelGraph, zettelContents, errors) <- loadZettelkasten config
  let writeHtmlRoute :: forall a. a -> Z.Route a -> Action ()
      writeHtmlRoute v r = writeHtmlRoute' r (zettelGraph, v)
  -- Generate HTML for every zettel
  forM_ zettelContents $ \val@(sansContent -> z) ->
    writeHtmlRoute val $ Z.Route_Zettel (zettelID z)
  -- Generate the z-index
  writeHtmlRoute errors Z.Route_ZIndex
  -- Generate search page
  writeHtmlRoute searchScript $ Z.Route_Search Nothing
  -- Write alias redirects, unless a zettel with that name exists.
  aliases <- getAliases config zettelGraph
  forM_ aliases $ \Alias {..} ->
    writeHtmlRoute targetZettel (Z.Route_Redirect aliasZettel)
  -- Report all errors
  forM_ (Map.toList errors) $ \(zid, err) -> do
    reportError (Z.Route_Zettel zid) $
      case err of
        ZettelError_ParseError (untag -> parseErr) ->
          parseErr :| []
        ZettelError_QueryResultErrors queryErrs ->
          showQueryResultError <$> queryErrs
        ZettelError_AmbiguousFiles filePaths ->
          ("Multiple zettels have the same ID: " <> T.intercalate ", " (fmap toText $ toList filePaths))
            :| []
  pure zettelGraph

-- | Report an error in the terminal
reportError :: (MonadIO m, IsRoute r) => r a -> NonEmpty Text -> m ()
reportError route errors = do
  path <- liftIO $ routeFile route
  putTextLn $ "E " <> toText path
  forM_ errors $ \err ->
    putText $ "  - " <> indentAllButFirstLine 4 err
  where
    indentAllButFirstLine :: Int -> Text -> Text
    indentAllButFirstLine n = unlines . go . lines
      where
        go [] = []
        go [x] = [x]
        go (x : xs) =
          x : fmap (toText . (take n (repeat ' ') <>) . toString) xs

-- | Like `loadZettelkasten` but without the content
--
-- Also allows retrieving the cached data for faster execution.
loadZettelkastenGraph ::
  Config ->
  Action (ZettelGraph, Map ZettelID ZettelError)
loadZettelkastenGraph config = do
  (g, _, errs) <- loadZettelkasten config
  pure (g, errs)

loadZettelkasten ::
  Config ->
  Action
    ( ZettelGraph,
      [ZettelC],
      Map ZettelID ZettelError
    )
loadZettelkasten config = do
  formats <- C.getZettelFormats config
  -- Experimental feature; see https://github.com/srid/neuron/issues/309
  let patternPrefix = bool "*" "**/*" $ C.recurseDir config
  zettelFiles <- forM formats $ \fmt -> do
    let pat = toString $ patternPrefix <> zettelFormatToExtension fmt
    files <- forEvery [pat] pure
    pure (fmt, files)
  res@(g, _, errs) <- loadZettelkastenFrom zettelFiles
  Cache.updateCache (g, errs)
  pure res

-- | Load the Zettelkasten from disk, using the given list of zettel files
loadZettelkastenFrom ::
  NonEmpty (ZettelFormat, [FilePath]) ->
  Action
    ( ZettelGraph,
      [ZettelC],
      Map ZettelID ZettelError
    )
loadZettelkastenFrom fs = do
  notesDir <- ribInputDir
  -- Use State monad to "gather" duplicate zettel files using same IDs, in the
  -- `Right` of the Either state value; with the `Left` collecting the actual
  -- zettel files to load into the graph.
  zidMap :: Map ZettelID (Either (ZettelFormat, (FilePath, Text)) (NonEmpty FilePath)) <-
    fmap snd $
      flip runStateT Map.empty $ do
        forM_ fs $ \(format, files) -> do
          forM_ files $ \relPath -> do
            case getZettelID format relPath of
              Nothing ->
                pure ()
              Just zid -> do
                fmap (Map.lookup zid) get >>= \case
                  Just (Left (_f, (oldPath, _s))) -> do
                    -- The zettel ID is already used by `oldPath`. Mark it as a dup.
                    modify $ Map.insert zid (Right $ relPath :| [oldPath])
                  Just (Right (toList -> ambiguities)) -> do
                    -- Third or later duplicate file with the same Zettel ID
                    modify $ Map.insert zid (Right $ relPath :| ambiguities)
                  Nothing -> do
                    let absPath = notesDir </> relPath
                    lift $ need [absPath]
                    s <- decodeUtf8With lenientDecode <$> readFileBS absPath
                    modify $ Map.insert zid (Left (format, (relPath, s)))
  let dups = fmap ZettelError_AmbiguousFiles $ Map.mapMaybe rightToMaybe zidMap
      files =
        fmap (first (id &&& readerForZettelFormat)) $
          Map.toList $
            Map.fromListWith (<>) $
              flip fmap (Map.toList $ Map.mapMaybe leftToMaybe zidMap) $
                \(zid, (fmt, (path, s))) ->
                  (fmt, [(zid, path, s)])
      (g, zs, gerrs) = G.buildZettelkasten extractQueriesWithContext files
      errs = Map.unions [dups, gerrs]
  pure (g, zs, errs)
