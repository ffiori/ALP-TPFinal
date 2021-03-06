module WavWrite (writeWav) where

import WavTypes
import Utilities (safelyRemoveFile)

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL

import Data.Char (ord)
import Data.Binary.Put  -- uso la mónada Put para aprovechar las funciones que me dejan escribir en little-endian. O bien se podría haber usado fromSampletoByteString.
import Data.Word
import System.IO
import Control.Monad.IO.Class (liftIO)
import Data.Conduit
import System.Directory (removeFile, doesFileExist)

import qualified Control.Exception as E
import System.IO.Error


writeWav :: FilePath -> WavFile -> IO ()
writeWav path wf = 
  E.bracketOnError
  ((openBinaryFile path WriteMode) `catchIOError` iocatcher)
  (\ handle -> do 
    borrarTemps wf
    hClose handle
    error $ "No se pudo construir el archivo de salida "++(show path) )
  (\ handle -> do 
    (BS.hPut handle $ (BL.toStrict $ runPut $ buildWavHeader wf)) `E.catch` catcher
    (putWaves wf handle) `E.catch` catcher )
  where
    catcher :: E.SomeException -> IO ()
    catcher e = putStrLn (show e) >> E.throw e
  
    iocatcher :: IOError -> IO Handle
    iocatcher e = 
      let msg = if isAlreadyExistsError e then ". El archivo no existe." else "."
      in do borrarTemps wf
            putStrLn $ "No se pudo crear el archivo "++(show path)++msg
            E.throw e

    borrarTemps :: WavFile -> IO [()]
    borrarTemps wf = sequence $ map safelyRemoveFile (chFiles $ dataheader wf)


buildWavHeader :: WavFile -> Put
buildWavHeader wf = do putRIFF wf
                       putfmt wf
                       putdata wf

putRIFF :: WavFile -> Put
putRIFF wf =
  let rc = riffheader wf
  in do putByteString . BS.pack $ map (fromIntegral.ord) $ chunkID rc
        putWord32le . fromIntegral $ chunkSize rc
        putByteString . BS.pack $ map (fromIntegral.ord) $ format rc

putfmt :: WavFile -> Put
putfmt wf = 
  let fc = fmtheader wf
  in do putByteString $ BS.pack $ map (fromIntegral.ord) $ subchunk1ID fc
        putWord32le $ fromIntegral $ subchunk1Size fc
        putWord16le $ fromIntegral $ audioFormat fc
        putWord16le $ fromIntegral $ numChannels fc
        putWord32le $ fromIntegral $ sampleRate fc
        putWord32le $ fromIntegral $ byteRate fc
        putWord16le $ fromIntegral $ blockAlign fc
        putWord16le $ fromIntegral $ bitsPerSample fc
        let action :: String -> Put
            action section = if audioFormat fc == wave_format_extended 
                               then error ("Format header dañado en "++section)
                               else return ()
        case cbSize fc of
                   Just x -> putWord16le $ fromIntegral x
                   Nothing -> action "cbSize"
        case validBitsPerSample fc of
                   Just x -> putWord16le $ fromIntegral x
                   Nothing -> action "validBitsPerSample"
        case chMask fc of
                   Just x -> putWord32le $ fromIntegral x
                   Nothing -> action "chMask"
        case subFormat fc of
                   Just x -> putWord16le $ fromIntegral x
                   Nothing -> action "subFormat"
        case check fc of
                   Just s -> putByteString $ BS.pack $ map (fromIntegral.ord) s
                   Nothing -> action "check string"


putdata :: WavFile -> Put
putdata wf =
  let dc = dataheader wf
  in do putByteString . BS.pack $ map (fromIntegral.ord) $ chunk2ID dc
        putWord32le . fromIntegral $ chunk2Size dc

putWaves :: WavFile -> Handle -> IO ()
putWaves wf outHandle =
  let chs = chFiles $ dataheader wf
      bps = bitsPerSample $ fmtheader wf
      sampsz = fromIntegral $ div bps 8
      catcher :: [Handle] -> E.SomeException -> IO ()
      catcher chHandles e = do
          sequence $ map hClose chHandles
          sequence $ map safelyRemoveFile $ chs
          E.throw e
  in do
    chHandles <- sequence [ openBinaryFile c ReadMode | c<-chs ]
    (getBlock sampsz chHandles $$ putBlock outHandle) `E.catch` (catcher chHandles)
    sequence $ map removeFile chs --una vez que escribí los canales en el archivo final, borro los temporales.
    return ()

--SOURCE
--Obtiene los samples de tamaño sampsz bytes de cada canal.
getBlock :: Int -> [Handle] -> Source IO [BS.ByteString]
getBlock _ [] = error "No hay canales en putWaves"
getBlock sampsz chHandles = 
  let leer h = do eof <- liftIO $ hIsEOF h
                  if eof
                    then return Nothing
                    else do str <- BS.hGet h (fromIntegral sampsz)
                            return $ Just str
  in do res <- liftIO $ sequence $ map leer chHandles
        case sequence res of
            Just samples -> do yield samples
                               getBlock sampsz chHandles
            Nothing -> do liftIO $ sequence $ map hClose chHandles
                          return ()

--SINK                                         
--escribe un sample de cada canal, o sea que conforma un bloque en el archivo.
putBlock :: Handle -> Sink [BS.ByteString] IO ()
putBlock handle = do
  mx <- await
  case mx of
    Nothing -> liftIO $ (hFlush>>hClose) handle
    Just samples -> do 
      liftIO $ sequence $ map (BS.hPut handle) samples
      putBlock handle


{-
-- función que falta de la familia putWordnle, por si en algún momento aparece
-- un campo de 24 bits en el estándar.
putWord24le :: Word32 -> Put
putWord24le xle = let xbe = toBE32 xle
                  in do putWord8 $ fromIntegral xbe
                        putWord8 $ fromIntegral (shiftR xbe 8)
                        putWord8 $ fromIntegral (shiftR xbe 16)
-}
