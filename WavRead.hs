module WavRead (readWav,safelyRemoveFile,makeTemps) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL

import Data.Int
import Data.Char (chr)
import Data.Bits
import Data.Binary.Get
import Data.Word

import System.IO
import System.IO.Temp (openBinaryTempFile)
import System.Directory (removeFile,doesFileExist)
import Data.Conduit
import Control.Monad.IO.Class (liftIO)

import qualified Control.Exception as E
import System.IO.Error

import WavTypes


readWav :: FilePath -> IO WavFile
readWav path = do
    handle <- (openBinaryFile path ReadMode) `catchIOError` catcher
    parseHeader handle
        where
            catcher :: IOError -> IO Handle
            catcher e = let msg = if isDoesNotExistError e then ". El archivo no existe."
                                  else if isAlreadyInUseError e then ". El archivo está siendo usado."
                                  else "."
                        in error $ "No se pudo abrir el archivo "++(show path)++msg++"\nError: "++(show e)

-- Headers --

parseHeader :: Handle -> IO WavFile
parseHeader h = do rh <- parsehRIFF h
                   fh <- parsehFMT h
                   dh <- parsehDATA h rh fh
                   return W { riffheader = rh
                            , fmtheader = fh
                            , dataheader = dh
                            }

parsehRIFF :: Handle -> IO HRIFF
parsehRIFF h = do fields <- recursiveGet h riffS
                  return HR { chunkID   = getString (fields!!0)
                            , chunkSize = getInt (fields!!1)
                            , format    = getString (fields!!2)
                            }

parsehFMT :: Handle -> IO Hfmt
parsehFMT h = do dfields <- recursiveGet h defaultS
                 let id = getString (dfields!!0)
                     sz = getInt (dfields!!1)
                 if id/="fmt " then do hSeek h RelativeSeek (fromIntegral sz)
                                       putStrLn $ "    chunk descartado de ID:"++id++"."
                                       parsehFMT h --descarto todos los chunks opcionales del formato WAVE.
                 else do fields <- recursiveGet h fmtS
                         let format = getInt (fields!!0)
                         fieldsExt <- if format == -2 then recursiveGet h fmtExtS else return []
                         return HF { subchunk1ID   = id
                                   , subchunk1Size = sz
                                   , audioFormat   = format
                                   , numChannels   = getInt (fields!!1)
                                   , sampleRate    = getInt (fields!!2)
                                   , byteRate      = getInt (fields!!3)
                                   , blockAlign    = getInt (fields!!4)
                                   , bitsPerSample = getInt (fields!!5)
                                   , cbSize = if format == -2 then Just (getInt (fieldsExt!!0)) else Nothing
                                   , validBitsPerSample = if format == -2 then Just (getInt (fieldsExt!!1)) else Nothing
                                   , chMask = if format == -2 then Just (getInt (fieldsExt!!2)) else Nothing
                                   , subFormat = if format == -2 then Just (getInt (fieldsExt!!3)) else Nothing
                                   , check = if format == -2 then Just (getString (fieldsExt!!4)) else Nothing
                                   }

parsehDATA :: Handle -> HRIFF -> Hfmt -> IO Hdata
parsehDATA h rh fh = 
    let format = audioFormat fh
        format2 = case subFormat fh of
                       Just x -> x
                       Nothing -> 1
    in
        if format > 1 || (format == -2 && format2 > 1)
        then error $ "Archivo comprimido o de punto flotante no soportado por el programa. Formato de compresión "++(show $ audioFormat fh)
        else if bitsPerSample fh > 32 || mod (bitsPerSample fh) 8 /= 0
        then error $ "Profundidad de muestras no soportada por el programa. Sólo se admiten muestras de 8, 16, 24 y 32 bits. BitsPerSample "++(show $ bitsPerSample fh)
        else do
            fields <- recursiveGet h dataS
            let id = getString (fields!!0)
                sz = getInt (fields!!1)
            if id/="data" then do hSeek h RelativeSeek (fromIntegral sz)
                                  putStrLn $ "    chunk descartado de ID:"++id++"."
                                  parsehDATA h rh fh --descarto todos los chunks opcionales del formato WAVE.
                          else do
                              chFilePaths <- parseData sz fh h  --escribe los canales en archivos temporales separados (uno por canal)
                              return HD { chunk2ID   = id 
                                        , chunk2Size = sz
                                        , chFiles = chFilePaths
                                        }


-- Data --

parseData :: Int -> Hfmt -> Handle -> IO [FilePath]
parseData sz fh h = let sampsz = div (bitsPerSample fh) 8
                        nc = numChannels fh
                        nblocks = div sz (sampsz*nc)
                        wf = W { fmtheader = fh, dataheader=undefined, riffheader=undefined }
                    in E.bracketOnError
                       (makeTemps wf) --armo los archivos de canales temporales.
                       (\ chFiles -> sequence $ map (hClose.snd>>safelyRemoveFile.fst) chFiles) --si algo falla mientras los estoy llenando los borro.
                       (\ chFiles -> do getSamples nc sampsz h $$ parsePerCh nblocks chFiles
                                        return $ map fst chFiles )


--SOURCE
--parsea una muestra para cada canal. Hay n canales, muestras de tamaño sampsz.
getSamples :: Int -> Int -> Handle -> Source IO [BS.ByteString]
getSamples n sampsz hsource = do
        eof <- liftIO $ hIsEOF hsource
        if eof
            then error $ "Falta obtener "++(show n)++" samples! Como mínimo..."
            else do
                samples <- liftIO $ sequence [ BS.hGet hsource sampsz | j<-[1..n] ] --sequence :: Monad m => [m a] -> m [a]
                yield samples
                getSamples n sampsz hsource

--SINK
--escribe una muestra en cada canal (o sea un bloque de muestras), nblocks veces.
parsePerCh :: Int -> [(FilePath,Handle)] -> Sink [BS.ByteString] IO ()
parsePerCh 0       chFiles = do liftIO $ sequence $ map (hFlush.snd>>hClose.snd) chFiles --flusheo y cierro los handles.
                                return ()
parsePerCh nblocks chFiles = do x <- await
                                case x of
                                     Nothing -> error "No hay más samples!"
                                     Just samples -> 
                                         if null chFiles
                                         then error "No hay canales!"
                                         else do
                                             liftIO $ sequence $ map (\((_,h),smpl) -> BS.hPut h smpl) (zip chFiles samples)
                                             parsePerCh (nblocks-1) chFiles


-- Utilidades --

--devuelve los campos que se quieren parsear con tamaños en hS en una lista de LazyByteStrings.
recursiveGet :: Handle -> [Int] -> IO [BS.ByteString]
recursiveGet h [] = return []
recursiveGet h hS = do field <- BS.hGet h (head hS)
                       fs <- recursiveGet h (tail hS)
                       return (field:fs)


--parsea un signed Int de 32bits en little-endian.
getInt :: BS.ByteString -> Int
getInt le = case BS.length le of
                1 -> fromIntegral (runGet getWord8 (BL.fromStrict le)) - 128                     --el estándar dice que muestras de 8bits son unsigned. De todos modos las paso a signed con el -128.
                2 -> fromIntegral (fromIntegral (runGet getWord16le (BL.fromStrict le))::Int16) --primero parseo como Int16 y después como Int para preservar el signo.
                3 -> fromIntegral $ runGet getWord24le (BL.fromStrict le)                       --getWord24le devuelve signed.
                4 -> fromIntegral $ runGet getWord32le (BL.fromStrict le)
                _ -> error $ "getInt: longitud mayor a 4 bytes o 0 bytes. " ++ (show le)
                
getString :: BS.ByteString -> String
getString bs = map (chr.fromIntegral) (BS.unpack bs)

--función no definida en la familia getWordnle.
getWord24le :: Get Word32
getWord24le = do x <- getWord8
                 y <- getWord8
                 z <- getWord8
                 let z' = shiftR (shiftL ((fromIntegral z)::Int32) 24) 8 --lo corro 24 y vuelvo 8 para mantener el signo (en vez de correrlo 16 de una)
                     y' = shiftL ((fromIntegral y)::Int32) 8
                 return $ fromIntegral (z' .|. y') .|. (fromIntegral x)


{-
-- versión no segura
makeTemps :: WavFile -> IO [(FilePath,Handle)]
makeTemps wf = let nc = numChannels $ fmtheader wf
               in sequence [ openBinaryTempFile "." ("ch"++(show i)++"_.tmp") | i<-[0..nc-1] ]
-}

-- genera nuevos temporales para tantos canales como tenga wf.
makeTemps :: WavFile -> IO [(FilePath,Handle)]
makeTemps wf = let nc = numChannels $ fmtheader wf
                   
                   makeTemps' :: Int -> IO [(FilePath,Handle)]
                   makeTemps' 0 = return []
                   makeTemps' n = E.bracketOnError
                                  (openBinaryTempFile "." ("ch"++(show (nc-n))++"_.tmp")) 
                                  (\ (path,_) -> do safelyRemoveFile path
                                                    sequence $ map safelyRemoveFile (chFiles $ dataheader wf) )
                                  (\ tmp -> do tmps <- makeTemps' (n-1)
                                               return $ tmp:tmps )
               in makeTemps' nc

--borra un archivo si es que existe
safelyRemoveFile :: FilePath -> IO ()
safelyRemoveFile path = removeFile path `catchIOError` catcher
    where catcher :: IOError -> IO ()
          catcher e = if isDoesNotExistError e then return () else E.throw e
