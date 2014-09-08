{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}

module Tests.JweSpec where

import Control.Applicative
import Data.Aeson (eitherDecode, decodeStrict')
import Data.Bits (xor)
import Data.Either.Combinators
import qualified Data.ByteString as B
import Test.Hspec
import Test.HUnit hiding (Test)
import Test.QuickCheck

import qualified Crypto.PubKey.RSA as RSA
import Crypto.PubKey.RSA.Prim (dp)
import Crypto.PubKey.MaskGenFunction
import Crypto.PubKey.HashDescr
import Crypto.Cipher.Types (AuthTag(..))
import Crypto.Random (CPRG(..))
import Jose.Jwt
import qualified Jose.Jwe as Jwe
import Jose.Jwa
import qualified Jose.Jwk as Jwk
import Jose.Internal.Crypto
import qualified Jose.Internal.Base64 as B64

--------------------------------------------------------------------------------
-- JWE Appendix Data Tests (plus quickcheck)
--------------------------------------------------------------------------------

spec :: Spec
spec =
  describe "JWE encoding and decoding" $ do
    context "when using JWE Appendix 1 data" $ do
      let a1Header = defJweHdr {jweAlg = RSA_OAEP, jweEnc = A256GCM}

      it "generates the expected IV and CMK from the RNG" $ do
        let g = RNG $ B.append a1cek a1iv
        generateCmkAndIV g A256GCM @?= (a1cek, a1iv, RNG "")

      it "generates the expected RSA-encrypted content key" $ do
        let g = RNG $ a1oaepSeed
        rsaEncrypt g RSA_OAEP a1PubKey a1cek @?= (a1jweKey, RNG "")

      it "encrypts the payload to the expected ciphertext and authentication tag" $ do
        let aad = B64.encode . encodeHeader $ a1Header
        encryptPayload A256GCM a1cek a1iv aad a1Payload @?= (a1Ciphertext, AuthTag a1Tag)

      it "encodes the payload to the expected JWT, leaving the RNG empty" $ do
        let g = RNG $ B.concat [a1cek, a1iv, a1oaepSeed]
        Jwe.rsaEncode g RSA_OAEP A256GCM a1PubKey a1Payload @?= (a1, RNG "")

      it "decodes the JWT to the expected header and payload" $ do
        (fst $ Jwe.rsaDecode blinderRNG a1PrivKey a1) @?= Right (a1Header, a1Payload)

      it "decodes the JWK to the correct RSA key values" $ do
        let Right (Jwk.RsaPrivateJwk (RSA.PrivateKey pubKey d 0 0 0 0 0) _ _ _) = eitherDecode a1jwk
        RSA.public_n pubKey  @?= a1RsaModulus
        RSA.public_e pubKey  @?= rsaExponent
        d                    @?= a1RsaPrivateExponent

      it "decodes the JWT using the JWK" $ do
        let Right k1 = eitherDecode a1jwk
            Just  k2 = decodeStrict' a2jwk
        (fst $ decode blinderRNG [k2, k1] a1) @?= (Right $ Jwe (a1Header, a1Payload))

    context "when using JWE Appendix 2 data" $ do
      let a2Header = defJweHdr {jweAlg = RSA1_5, jweEnc = A128CBC_HS256}
      let aad = B64.encode . encodeHeader $ a2Header

      it "generates the expected RSA-encrypted content key" $ do
        let g = RNG $ a2seed
        rsaEncrypt g RSA1_5 a2PubKey a2cek @?= (a2jweKey, RNG "")

      it "encrypts the payload to the expected ciphertext and authentication tag" $ do
        encryptPayload A128CBC_HS256 a2cek a2iv aad a2Payload @?= (a2Ciphertext, AuthTag a2Tag)

      it "encodes the payload to the expected JWT" $ do
        let g = RNG $ B.concat [a2cek, a2iv, a2seed]
        Jwe.rsaEncode g RSA1_5 A128CBC_HS256 a2PubKey a2Payload @?= (a2, RNG "")

      it "decrypts the ciphertext to the correct payload" $ do
        decryptPayload A128CBC_HS256 a2cek a2iv aad a2Tag a2Ciphertext @?= Right a2Payload

      it "decodes the JWT to the expected header and payload" $ do
        (fst $ Jwe.rsaDecode blinderRNG a2PrivKey a2) @?= Right (a2Header, a2Payload)

    context "when used with quickcheck" $ do
      it "padded msg is always a multiple of 16" $ property $
        \bs -> B.length (pad bs) `mod` 16 == 0
      it "unpad is the inverse of pad" $ property $
        \bs -> (fromRight' . unpad . pad) bs == bs
      it "jwe decode/decode returns the original payload" $ property $ jweRoundTrip

-- verboseQuickCheckWith quickCheckWith stdArgs {maxSuccess=10000}  jweRoundTrip
jweRoundTrip :: RNG -> JWEAlgs -> B.ByteString -> Bool
jweRoundTrip g (JWEAlgs a e) msg = encodeDecode == Right (defJweHdr {jweAlg = a, jweEnc = e}, msg)
  where
    encodeDecode = fst $ Jwe.rsaDecode blinderRNG a2PrivKey $ fst $ Jwe.rsaEncode g a e a2PubKey msg

-- A decidedly non-random, random number generator which allows specific
-- sequences of bytes to be supplied which match the JWE test data.
data RNG = RNG B.ByteString deriving (Eq, Show)

genBytes :: Int -> RNG -> (B.ByteString, RNG)
genBytes 0 g = (B.empty, g)
genBytes n (RNG bs) = (bytes, RNG next)
  where
    (bytes, next) = if B.null bs
                      then error "RNG is empty"
                      else B.splitAt n bs

instance CPRG RNG where
    cprgCreate   = undefined
    cprgSetReseedThreshold = undefined
    cprgGenerate = genBytes
    cprgGenerateWithEntropy = undefined
    cprgFork = undefined

blinderRNG = RNG $ B.replicate 2000 255

--------------------------------------------------------------------------------
-- JWE Appendix 1 Test Data
--------------------------------------------------------------------------------

a1 = "eyJhbGciOiJSU0EtT0FFUCIsImVuYyI6IkEyNTZHQ00ifQ.OKOawDo13gRp2ojaHV7LFpZcgV7T6DVZKTyKOMTYUmKoTCVJRgckCL9kiMT03JGeipsEdY3mx_etLbbWSrFr05kLzcSr4qKAq7YN7e9jwQRb23nfa6c9d-StnImGyFDbSv04uVuxIp5Zms1gNxKKK2Da14B8S4rzVRltdYwam_lDp5XnZAYpQdb76FdIKLaVmqgfwX7XWRxv2322i-vDxRfqNzo_tETKzpVLzfiwQyeyPGLBIO56YJ7eObdv0je81860ppamavo35UgoRdbYaBcoh9QcfylQr66oc6vFWXRcZ_ZT2LawVCWTIy3brGPi6UklfCpIMfIjf7iGdXKHzg.48V1_ALb6US04U3b.5eym8TW_c8SuK0ltJ3rpYIzOeDQz7TALvtu6UG9oMo4vpzs9tX_EFShS8iB7j6jiSdiwkIr3ajwQzaBtQD_A.XFBoMYUZodetZdvTiFvSkQ"

a1Payload = "The true sign of intelligence is not knowledge but imagination."

a1cek = B.pack [177, 161, 244, 128, 84, 143, 225, 115, 63, 180, 3, 255, 107, 154, 212, 246, 138, 7, 110, 91, 112, 46, 34, 105, 47, 130, 203, 46, 122, 234, 64, 252]

a1iv  = B.pack [227, 197, 117, 252, 2, 219, 233, 68, 180, 225, 77, 219]

a1aad = B.pack [101, 121, 74, 104, 98, 71, 99, 105, 79, 105, 74, 83, 85, 48, 69, 116, 84, 48, 70, 70, 85, 67, 73, 115, 73, 109, 86, 117, 89, 121, 73, 54, 73, 107, 69, 121, 78, 84, 90, 72, 81, 48, 48, 105, 102, 81]

a1Ciphertext = B.pack [229, 236, 166, 241, 53, 191, 115, 196, 174, 43, 73, 109, 39, 122, 233, 96, 140, 206, 120, 52, 51, 237, 48, 11, 190, 219, 186, 80, 111, 104, 50, 142, 47, 167, 59, 61, 181, 127, 196, 21, 40, 82, 242, 32, 123, 143, 168, 226, 73, 216, 176, 144, 138, 247, 106, 60, 16, 205, 160, 109, 64, 63, 192]

a1Tag = B.pack [92, 80, 104, 49, 133, 25, 161, 215, 173, 101, 219, 211, 136, 91, 210, 145]

Right a1jweKey = B64.decode "OKOawDo13gRp2ojaHV7LFpZcgV7T6DVZKTyKOMTYUmKoTCVJRgckCL9kiMT03JGeipsEdY3mx_etLbbWSrFr05kLzcSr4qKAq7YN7e9jwQRb23nfa6c9d-StnImGyFDbSv04uVuxIp5Zms1gNxKKK2Da14B8S4rzVRltdYwam_lDp5XnZAYpQdb76FdIKLaVmqgfwX7XWRxv2322i-vDxRfqNzo_tETKzpVLzfiwQyeyPGLBIO56YJ7eObdv0je81860ppamavo35UgoRdbYaBcoh9QcfylQr66oc6vFWXRcZ_ZT2LawVCWTIy3brGPi6UklfCpIMfIjf7iGdXKHzg"

a1jwk = "{\"kty\":\"RSA\", \"n\":\"oahUIoWw0K0usKNuOR6H4wkf4oBUXHTxRvgb48E-BVvxkeDNjbC4he8rUWcJoZmds2h7M70imEVhRU5djINXtqllXI4DFqcI1DgjT9LewND8MW2Krf3Spsk_ZkoFnilakGygTwpZ3uesH-PFABNIUYpOiN15dsQRkgr0vEhxN92i2asbOenSZeyaxziK72UwxrrKoExv6kc5twXTq4h-QChLOln0_mtUZwfsRaMStPs6mS6XrgxnxbWhojf663tuEQueGC-FCMfra36C9knDFGzKsNa7LZK2djYgyD3JR_MB_4NUJW_TqOQtwHYbxevoJArm-L5StowjzGy-_bq6Gw\", \"e\":\"AQAB\", \"d\":\"kLdtIj6GbDks_ApCSTYQtelcNttlKiOyPzMrXHeI-yk1F7-kpDxY4-WY5NWV5KntaEeXS1j82E375xxhWMHXyvjYecPT9fpwR_M9gV8n9Hrh2anTpTD93Dt62ypW3yDsJzBnTnrYu1iwWRgBKrEYY46qAZIrA2xAwnm2X7uGR1hghkqDp0Vqj3kbSCz1XyfCs6_LehBwtxHIyh8Ripy40p24moOAbgxVw3rxT_vlt3UVe4WO3JkJOzlpUf-KTVI2Ptgm-dARxTEtE-id-4OJr0h-K-VFs3VSndVTIznSxfyrj8ILL6MG_Uv8YAu7VILSB3lOW085-4qE3DzgrTjgyQ\" }"

a1RsaModulus = 20407373051396142380600281265251892119308905183562582378265551916401741797298132714477564366125574073854325621181754666299468042787718090965019045494120492365709229334674806858420600185271825023335981142192553851711447185679749878133484409202142610505370119489349112667599681596271324052456163162582257897587607185901342235063647947816589525124013368466111231306949063172170503467209564034546753006291531308789606255762727496010190006847721118463557533668762287451483156476421856126198680670740028037673487624895510756370816101325723975021588898704953504010419555312457504338174094966173304768490140232017447246019099

rsaExponent = 65537 :: Integer

a1RsaPrivateExponent = 18268766796654718362565236454995853620820821188251417451980738596264305499270399136757621249007756005599271096771478165267306874014871487538744562309757162619646837295513011635819128008143685281506609665247035139326775637222412463191989209202137797209813686014322033219332678022668756745556718137625135245640638710814390273901357613670762406363679831247433360271391936119294533419667412739496199381069233394069901435128732415071218792819358792459421008659625326677236263304891550388749907992141902573512326268421915766834378108391128385175130554819679860804655689526143903449732010240859012168194104458903308465660105

a1oaepSeed = extractOaepSeed a1PrivKey a1jweKey

(a1PubKey, a1PrivKey) = createKeyPair a1RsaModulus a1RsaPrivateExponent


--------------------------------------------------------------------------------
-- JWE Appendix 2 Test Data
--------------------------------------------------------------------------------

a2Payload = "Live long and prosper."

a2cek = B.pack [4, 211, 31, 197, 84, 157, 252, 254, 11, 100, 157, 250, 63, 170, 106, 206, 107, 124, 212, 45, 111, 107, 9, 219, 200, 177, 0, 240, 143, 156, 44, 207]

--a2cek = B.pack [203, 165, 180, 113, 62, 195, 22, 98, 91, 153, 210, 38, 112, 35, 230, 236]

--a2cik = B.pack [218, 24, 160, 17, 160, 50, 235, 35, 216, 209, 100, 174, 155, 163, 10, 117, 180, 111, 172, 200, 127, 201, 206, 173, 40, 45, 58, 170, 35, 93, 9, 60]

a2iv = B.pack [3, 22, 60, 12, 43, 67, 104, 105, 108, 108, 105, 99, 111, 116, 104, 101]

a2Ciphertext = B.pack [40, 57, 83, 181, 119, 33, 133, 148, 198, 185, 243, 24, 152, 230, 6, 75, 129, 223, 127, 19, 210, 82, 183, 230, 168, 33, 215, 104, 143, 112, 56, 102]

a2Tag = B.pack [246, 17, 244, 190, 4, 95, 98, 3, 231, 0, 115, 157, 242, 203, 100, 191]

Right a2jweKey = B64.decode "UGhIOguC7IuEvf_NPVaXsGMoLOmwvc1GyqlIKOK1nN94nHPoltGRhWhw7Zx0-kFm1NJn8LE9XShH59_i8J0PH5ZZyNfGy2xGdULU7sHNF6Gp2vPLgNZ__deLKxGHZ7PcHALUzoOegEI-8E66jX2E4zyJKx-YxzZIItRzC5hlRirb6Y5Cl_p-ko3YvkkysZIFNPccxRU7qve1WYPxqbb2Yw8kZqa2rMWI5ng8OtvzlV7elprCbuPhcCdZ6XDP0_F8rkXds2vE4X-ncOIM8hAYHHi29NX0mcKiRaD0-D-ljQTP-cFPgwCp6X-nZZd9OHBv-B3oWh2TbqmScqXMR4gp_A"

a2jwk = "{\"kty\":\"RSA\", \"n\":\"sXchDaQebHnPiGvyDOAT4saGEUetSyo9MKLOoWFsueri23bOdgWp4Dy1WlUzewbgBHod5pcM9H95GQRV3JDXboIRROSBigeC5yjU1hGzHHyXss8UDprecbAYxknTcQkhslANGRUZmdTOQ5qTRsLAt6BTYuyvVRdhS8exSZEy_c4gs_7svlJJQ4H9_NxsiIoLwAEk7-Q3UXERGYw_75IDrGA84-lA_-Ct4eTlXHBIY2EaV7t7LjJaynVJCpkv4LKjTTAumiGUIuQhrNhZLuF_RJLqHpM2kgWFLU7-VTdL1VbC2tejvcI2BlMkEpk1BzBZI0KQB0GaDWFLN-aEAw3vRw\", \"e\":\"AQAB\", \"d\":\"VFCWOqXr8nvZNyaaJLXdnNPXZKRaWCjkU5Q2egQQpTBMwhprMzWzpR8Sxq1OPThh_J6MUD8Z35wky9b8eEO0pwNS8xlh1lOFRRBoNqDIKVOku0aZb-rynq8cxjDTLZQ6Fz7jSjR1Klop-YKaUHc9GsEofQqYruPhzSA-QgajZGPbE_0ZaVDJHfyd7UUBUKunFMScbflYAAOYJqVIVwaYR5zWEEceUjNnTNo_CVSj-VvXLO5VZfCUAVLgW4dpf1SrtZjSt34YLsRarSb127reG_DUwg9Ch-KyvjT1SkHgUWRVGcyly7uvVGRSDwsXypdrNinPA4jlhoNdizK2zF2CWQ\" }"

a2RsaModulus =  22402924734748322419583087865046136971812964522608965289668050862528140628890468829261358173206844190609885548664216273129288787509446229835492005268681636400878070687042995563617837593077316848511917526886594334868053765054121327206058496913599608196082088434862911200952954663261204130886151917541465131565772711448256433529200865576041706962504490609565420543616528240562874975930318078653328569211055310553145904641192292907110395318778917935975962359665382660933281263049927785938817901532807037136641587608303638483543899849101763615990006657357057710971983052920787558713523025279998057051825799400286243909447

a2RsaPrivateExponent = 10643756465292254988457796463889735064030094089452909840615134957452106668931481879498770304395097541282329162591478128330968231330113176654221501869950411410564116254672288216799191435916328405513154035654178369543717138143188973636496077305930253145572851787483810154020967535132278148578697716656066036003388130625459567907864689911133288140117207430454310073863484450086676106606775792171446149215594844607410066899028283290532626577379520547350399030663657813726123700613989625283009134539244470878688076926304079342487789922656366430636978871435674556143884272163840709196449089335092169596187792960067104244313

a2 = "eyJhbGciOiJSU0ExXzUiLCJlbmMiOiJBMTI4Q0JDLUhTMjU2In0.UGhIOguC7IuEvf_NPVaXsGMoLOmwvc1GyqlIKOK1nN94nHPoltGRhWhw7Zx0-kFm1NJn8LE9XShH59_i8J0PH5ZZyNfGy2xGdULU7sHNF6Gp2vPLgNZ__deLKxGHZ7PcHALUzoOegEI-8E66jX2E4zyJKx-YxzZIItRzC5hlRirb6Y5Cl_p-ko3YvkkysZIFNPccxRU7qve1WYPxqbb2Yw8kZqa2rMWI5ng8OtvzlV7elprCbuPhcCdZ6XDP0_F8rkXds2vE4X-ncOIM8hAYHHi29NX0mcKiRaD0-D-ljQTP-cFPgwCp6X-nZZd9OHBv-B3oWh2TbqmScqXMR4gp_A.AxY8DCtDaGlsbGljb3RoZQ.KDlTtXchhZTGufMYmOYGS4HffxPSUrfmqCHXaI9wOGY.9hH0vgRfYgPnAHOd8stkvw"

(a2PubKey, a2PrivKey) = createKeyPair a2RsaModulus a2RsaPrivateExponent

a2seed = extractPKCS15Seed a2PrivKey a2jweKey


--------------------------------------------------------------------------------
-- Quickcheck Stuff
--------------------------------------------------------------------------------

-- Valid JWE Alg/Enc combinations
data JWEAlgs = JWEAlgs JweAlg Enc deriving Show

instance Arbitrary B.ByteString where
    arbitrary = B.pack <$> arbitrary

instance Arbitrary Enc where
    arbitrary = elements [A128CBC_HS256, A256CBC_HS512, A128GCM, A256GCM]

instance Arbitrary JWEAlgs where
  arbitrary = do
    a <- elements [RSA1_5, RSA_OAEP]
    e <- elements [A128CBC_HS256, A256CBC_HS512, A128GCM, A256GCM]
    return $ JWEAlgs a e

instance Arbitrary RNG where
  arbitrary = (RNG . B.pack) <$> vector 600



--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

createKeyPair n d = (pubKey, privKey)
  where
    privKey = RSA.PrivateKey
                { RSA.private_pub = pubKey
                , RSA.private_d = d
                , RSA.private_q = 0
                , RSA.private_p = 0
                , RSA.private_dP = 0
                , RSA.private_dQ = 0
                , RSA.private_qinv = 0
                }
    pubKey = RSA.PublicKey
                { RSA.public_size = 256
                , RSA.public_n = n
                , RSA.public_e = rsaExponent
                }

 -- Extracts the random padding bytes from the decrypted content key
 -- allowing them to be used in the test RNG
extractOaepSeed :: RSA.PrivateKey -> B.ByteString -> B.ByteString
extractOaepSeed key ct = B.pack $ B.zipWith xor maskedSeed seedMask
  where
    em       = dp Nothing key ct
    sha1     = hashFunction hashDescrSHA1
    hashLen  = B.length $ sha1 B.empty
    em0      = B.tail em
    (maskedSeed, maskedDB) = B.splitAt hashLen em0
    seedMask = mgf1 sha1 maskedDB hashLen

 -- Decrypt, drop the 02 at the start and take the bytes up to the next 0
extractPKCS15Seed :: RSA.PrivateKey -> B.ByteString -> B.ByteString
extractPKCS15Seed key ct = B.takeWhile (/= 0) . B.drop 2 $ dp Nothing key ct

