-- Formato WAV general
-- http://web.archive.org/web/20141213140451/https://ccrma.stanford.edu/courses/422/projects/WaveFormat/

-- Explicados algunos detalles
-- http://web.archive.org/web/19991115123323/http://www.borg.com/~jglatt/tech/wave.htm

-- buena documentación y ejemplos
-- http://www-mmsp.ece.mcgill.ca/documents/audioformats/wave/wave.html

{-
    En el programa se usará la versión canónica del formato WAVE,
    es decir, que sólo se divide en tres partes (RIFF, fmt, data).
-}
{-# LANGUAGE BangPatterns #-}

module WavTypes where


import qualified Data.Foldable as Foldable


data WavFile = W { riffheader :: HRIFF
                 , fmtheader :: Hfmt
                 , dataheader :: Hdata
                 }

type Sample = Int


-- Headers --

data HRIFF = HR { chunkID :: String --big endian
                , chunkSize :: Int  --tamaño en bytes del archivo a partir de acá (o sea sin incluir los 4 bytes de chunkID ni los 4 bytes de chunkSize)
                , format :: String  --big endian
                }

data Hfmt = HF { subchunk1ID :: String  --big endian
               , subchunk1Size :: Int
               , audioFormat :: Int
               , numChannels :: Int
               , sampleRate :: Int
               , byteRate :: Int
               , blockAlign :: Int 
               , bitsPerSample :: Int
               , cbSize :: Maybe Int
               , validBitsPerSample :: Maybe Int
               , chMask :: Maybe Int
               , subFormat :: Maybe Int
               , check :: Maybe String
               }

data Hdata = HD { chunk2ID :: String    --big endian
                , chunk2Size :: Int
                , chFiles :: [FilePath]
                }


-- Constantes --

headerSz :: Int
headerSz = riffSz + fmtSz + hdataSz

riffSz :: Int
riffSz = sum riffS

fmtSz :: Int
fmtSz = sum fmtS

hdataSz :: Int
hdataSz = sum dataS

riffS :: [Int]    --tamaños de los campos del header RIFF
riffS = [4,4,4]

fmtS :: [Int]     --tamaños de los campos del header fmt
fmtS = [2,2,4,4,2,2]

fmtExtS :: [Int]
fmtExtS = [2,2,4,2,14]

dataS :: [Int]    --tamaños de los campos del header data
dataS = [4,4]

defaultS :: [Int] --tamaños de los campos chunkID, chunkSize que los tienen que tener todos los chunks.
defaultS = [4,4]

