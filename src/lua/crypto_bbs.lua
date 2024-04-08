--[[
--This file is part of zenroom
--
--Copyright (C) 2023 Dyne.org foundation
--designed, written and maintained by Luca Di Domenico, Rebecca Selvaggini and Alberto Lerda
--
--This program is free software: you can redistribute it and/or modify
--it under the terms of the GNU Affero General Public License v3.0
--
--This program is distributed in the hope that it will be useful,
--but WITHOUT ANY WARRANTY; without even the implied warranty of
--MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--GNU Affero General Public License for more details.
--
--Along with this program you should have received a copy of the
--GNU Affero General Public License v3.0
--If not, see http://www.gnu.org/licenses/agpl.txt
--
--]]

--[[

# Optimization notes

The create_generators function (see Section 4.2 of this draft
https://identity.foundation/bbs-signature/draft-irtf-cfrg-bbs-signatures.html)
is rather slow.  The function takes an integer count and returns count
points on the curve G1 .  It is fully deterministic, and after the
first call it caches its output, so that in successive calls we
generate none or less points.  The sequence of points produced by the
function is always the same for a fixed hash function.

Hence, one could simply cache the first n points for SHA and the first
n points for SHAKE.  In this scenario, these 2n points should be
loaded as ciphersuite parameters.

One could also make the function itself faster by implementing some of
its operations in C.  In particular, one such operation could be
hash_to_curve and its subfunctions.  hash_to_curve is called by
create_generators. It is a uniform encoding from byte strings to
points in G1. That is, the distribution of its output is statistically
close to uniform in G1 (see Section 3 of this draft
https://datatracker.ietf.org/doc/html/draft-irtf-cfrg-hash-to-curve-16).
hash_to_curve should become faster when implented in C since
hashtopoint (which behaves somewhat similarly to hash_to_curve) is
implemented in C and it is rather fast.

--]]

local bbs = {}
local OCTET_SCALAR_LENGTH = 32 -- ceil(log2(PRIME_R)/8)
local OCTET_POINT_LENGTH = 48 --ceil(log2(p)/8)

--see draft-irtf-cfrg-bbs-signatures-latest Appendix A.1
local PRIME_R = ECP.order()

--draft-irtf-cfrg-pairing-friendly-curves-11 Section 4.2.1
local IDENTITY_G1 = ECP.generator()

local K = nil -- see function K_INIT() below

-- Added api_id

local CIPHERSUITE_SHAKE = {
    expand = HASH.expand_message_xof,
    ciphersuite_ID = O.from_string("BBS_BLS12381G1_XOF:SHAKE-256_SSWU_RO_"),
    api_ID =  O.from_string("BBS_BLS12381G1_XOF:SHAKE-256_SSWU_RO_H2G_HM2S_"),
    generator_seed = O.from_string("BBS_BLS12381G1_XOF:SHAKE-256_SSWU_RO_H2G_HM2S_MESSAGE_GENERATOR_SEED"),
    seed_dst = O.from_string("BBS_BLS12381G1_XOF:SHAKE-256_SSWU_RO_H2G_HM2S_SIG_GENERATOR_SEED_"),
    generator_dst = O.from_string("BBS_BLS12381G1_XOF:SHAKE-256_SSWU_RO_H2G_HM2S_SIG_GENERATOR_DST_"),
    hash_to_scalar_dst = O.from_string('BBS_BLS12381G1_XOF:SHAKE-256_SSWU_RO_H2G_HM2S_H2S_'),
    map_msg_to_scalar_as_hash_dst = O.from_string('BBS_BLS12381G1_XOF:SHAKE-256_SSWU_RO_H2G_HM2S_MAP_MSG_TO_SCALAR_AS_HASH_'),
    expand_dst = O.from_string('BBS_BLS12381G1_XOF:SHAKE-256_SSWU_RO_SIG_DET_DST_'),
    P1 = ECP.from_zcash(O.from_hex('8929dfbc7e6642c4ed9cba0856e493f8b9d7d5fcb0c31ef8fdcd34d50648a56c795e106e9eada6e0bda386b414150755')),
    GENERATORS = {},
    GENERATOR_V = HASH.expand_message_xof(O.from_string("BBS_BLS12381G1_XOF:SHAKE-256_SSWU_RO_H2G_HM2S_MESSAGE_GENERATOR_SEED"),
    O.from_string("BBS_BLS12381G1_XOF:SHAKE-256_SSWU_RO_H2G_HM2S_SIG_GENERATOR_SEED_"), 48)
}

local CIPHERSUITE_SHA = {
    expand = HASH.expand_message_xmd,
    ciphersuite_ID = O.from_string("BBS_BLS12381G1_XMD:SHA-256_SSWU_RO_"),
    api_ID = O.from_string("BBS_BLS12381G1_XMD:SHA-256_SSWU_RO_H2G_HM2S_"),
    generator_seed = O.from_string("BBS_BLS12381G1_XMD:SHA-256_SSWU_RO_H2G_HM2S_MESSAGE_GENERATOR_SEED"),
    seed_dst = O.from_string("BBS_BLS12381G1_XMD:SHA-256_SSWU_RO_H2G_HM2S_SIG_GENERATOR_SEED_"),
    generator_dst = O.from_string("BBS_BLS12381G1_XMD:SHA-256_SSWU_RO_H2G_HM2S_SIG_GENERATOR_DST_"),
    hash_to_scalar_dst = O.from_string('BBS_BLS12381G1_XMD:SHA-256_SSWU_RO_H2G_HM2S_H2S_'),
    map_msg_to_scalar_as_hash_dst = O.from_string('BBS_BLS12381G1_XMD:SHA-256_SSWU_RO_H2G_HM2S_MAP_MSG_TO_SCALAR_AS_HASH_'),
    expand_dst = O.from_string('BBS_BLS12381G1_XMD:SHA-256_SSWU_RO_SIG_DET_DST_'),
    P1 = ECP.from_zcash(O.from_hex('a8ce256102840821a3e94ea9025e4662b205762f9776b3a766c872b948f1fd225e7c59698588e70d11406d161b4e28c9')),
    GENERATORS = {},
    GENERATOR_V = HASH.expand_message_xmd(O.from_string("BBS_BLS12381G1_XMD:SHA-256_SSWU_RO_H2G_HM2S_MESSAGE_GENERATOR_SEED"),
    O.from_string("BBS_BLS12381G1_XMD:SHA-256_SSWU_RO_H2G_HM2S_SIG_GENERATOR_SEED_"), 48)
}
-- Take as input the hash as string and return a table with the corresponding parameters
function bbs.ciphersuite(hash_name)
    -- seed_len = 48
    if hash_name:lower() == 'sha256' then
        return CIPHERSUITE_SHA

    elseif hash_name:lower() == 'shake256' then
        return CIPHERSUITE_SHAKE
    else
        error('Invalid hash: use sha256 or shake256', 2)
    end

end

-- draft-irtf-cfrg-hash-to-curve-16 Appendix E.2
-- Constants used for the 11-isogeny map.
local function K_INIT()
    return {{ -- K[1][i]
    BIG.new(O.from_hex('11a05f2b1e833340b809101dd99815856b303e88a2d7005ff2627b56cdb4e2c85610c2d5f2e62d6eaeac1662734649b7')),
        BIG.new(O.from_hex('17294ed3e943ab2f0588bab22147a81c7c17e75b2f6a8417f565e33c70d1e86b4838f2a6f318c356e834eef1b3cb83bb')),
        BIG.new(O.from_hex('0d54005db97678ec1d1048c5d10a9a1bce032473295983e56878e501ec68e25c958c3e3d2a09729fe0179f9dac9edcb0')), --
        BIG.new(O.from_hex('1778e7166fcc6db74e0609d307e55412d7f5e4656a8dbf25f1b33289f1b330835336e25ce3107193c5b388641d9b6861')),
        BIG.new(O.from_hex('0e99726a3199f4436642b4b3e4118e5499db995a1257fb3f086eeb65982fac18985a286f301e77c451154ce9ac8895d9')), --
        BIG.new(O.from_hex('1630c3250d7313ff01d1201bf7a74ab5db3cb17dd952799b9ed3ab9097e68f90a0870d2dcae73d19cd13c1c66f652983')),
        BIG.new(O.from_hex('0d6ed6553fe44d296a3726c38ae652bfb11586264f0f8ce19008e218f9c86b2a8da25128c1052ecaddd7f225a139ed84')),--
        BIG.new(O.from_hex('17b81e7701abdbe2e8743884d1117e53356de5ab275b4db1a682c62ef0f2753339b7c8f8c8f475af9ccb5618e3f0c88e')),
        BIG.new(O.from_hex('080d3cf1f9a78fc47b90b33563be990dc43b756ce79f5574a2c596c928c5d1de4fa295f296b74e956d71986a8497e317')),--
        BIG.new(O.from_hex('169b1f8e1bcfa7c42e0c37515d138f22dd2ecb803a0c5c99676314baf4bb1b7fa3190b2edc0327797f241067be390c9e')),
        BIG.new(O.from_hex('10321da079ce07e272d8ec09d2565b0dfa7dccdde6787f96d50af36003b14866f69b771f8c285decca67df3f1605fb7b')),
        BIG.new(O.from_hex('06e08c248e260e70bd1e962381edee3d31d79d7e22c837bc23c0bf1bc24c6b68c24b1b80b64d391fa9c8ba2e8ba2d229'))--
    },--

        { -- K[2][i]
            BIG.new(O.from_hex('08ca8d548cff19ae18b2e62f4bd3fa6f01d5ef4ba35b48ba9c9588617fc8ac62b558d681be343df8993cf9fa40d21b1c')),--
        BIG.new(O.from_hex('12561a5deb559c4348b4711298e536367041e8ca0cf0800c0126c2588c48bf5713daa8846cb026e9e5c8276ec82b3bff')),
        BIG.new(O.from_hex('0b2962fe57a3225e8137e629bff2991f6f89416f5a718cd1fca64e00b11aceacd6a3d0967c94fedcfcc239ba5cb83e19')),--
        BIG.new(O.from_hex('03425581a58ae2fec83aafef7c40eb545b08243f16b1655154cca8abc28d6fd04976d5243eecf5c4130de8938dc62cd8')),--
        BIG.new(O.from_hex('13a8e162022914a80a6f1d5f43e7a07dffdfc759a12062bb8d6b44e833b306da9bd29ba81f35781d539d395b3532a21e')),
        BIG.new(O.from_hex('0e7355f8e4e667b955390f7f0506c6e9395735e9ce9cad4d0a43bcef24b8982f7400d24bc4228f11c02df9a29f6304a5')),--
        BIG.new(O.from_hex('0772caacf16936190f3e0c63e0596721570f5799af53a1894e2e073062aede9cea73b3538f0de06cec2574496ee84a3a')),--
        BIG.new(O.from_hex('14a7ac2a9d64a8b230b3f5b074cf01996e7f63c21bca68a81996e1cdf9822c580fa5b9489d11e2d311f7d99bbdcc5a5e')),
        BIG.new(O.from_hex('0a10ecf6ada54f825e920b3dafc7a3cce07f8d1d7161366b74100da67f39883503826692abba43704776ec3a79a1d641')),--
        BIG.new(O.from_hex('095fc13ab9e92ad4476d6e3eb3a56680f682b4ee96f7d03776df533978f31c1593174e4b4b7865002d6384d168ecdd0a')), --
        BIG.new(1)
     },

         { -- K[3][i]
            BIG.new(O.from_hex('090d97c81ba24ee0259d1f094980dcfa11ad138e48a869522b52af6c956543d3cd0c7aee9b3ba3c2be9845719707bb33')),--
         BIG.new(O.from_hex('134996a104ee5811d51036d776fb46831223e96c254f383d0f906343eb67ad34d6c56711962fa8bfe097e75a2e41c696')),
         BIG.new(O.from_hex('cc786baa966e66f4a384c86a3b49942552e2d658a31ce2c344be4b91400da7d26d521628b00523b8dfe240c72de1f6')),
         BIG.new(O.from_hex('01f86376e8981c217898751ad8746757d42aa7b90eeb791c09e4a3ec03251cf9de405aba9ec61deca6355c77b0e5f4cb')),--
         BIG.new(O.from_hex('08cc03fdefe0ff135caf4fe2a21529c4195536fbe3ce50b879833fd221351adc2ee7f8dc099040a841b6daecf2e8fedb')),--
         BIG.new(O.from_hex('16603fca40634b6a2211e11db8f0a6a074a7d0d4afadb7bd76505c3d3ad5544e203f6326c95a807299b23ab13633a5f0')),
         BIG.new(O.from_hex('04ab0b9bcfac1bbcb2c977d027796b3ce75bb8ca2be184cb5231413c4d634f3747a87ac2460f415ec961f8855fe9d6f2')),--
         BIG.new(O.from_hex('0987c8d5333ab86fde9926bd2ca6c674170a05bfe3bdd81ffd038da6c26c842642f64550fedfe935a15e4ca31870fb29')),--
         BIG.new(O.from_hex('09fc4018bd96684be88c9e221e4da1bb8f3abd16679dc26c1e8b6e6a1f20cabe69d65201c78607a360370e577bdba587')),--
         BIG.new(O.from_hex('0e1bba7a1186bdb5223abde7ada14a23c42a0ca7915af6fe06985e7ed1e4d43b9b3f7055dd4eba6f2bafaaebca731c30')),--
         BIG.new(O.from_hex('19713e47937cd1be0dfd0b8f1d43fb93cd2fcbcb6caf493fd1183e416389e61031bf3a5cce3fbafce813711ad011c132')),
         BIG.new(O.from_hex('18b46a908f36f6deb918c143fed2edcc523559b8aaf0c2462e6bfe7f911f643249d9cdf41b44d606ce07c8a4d0074d8e')),
         BIG.new(O.from_hex('0b182cac101b9399d155096004f53f447aa7b12a3426b08ec02710e807b4633f06c851c1919211f20d4c04f00b971ef8')),--
         BIG.new(O.from_hex('0245a394ad1eca9b72fc00ae7be315dc757b3b080d4c158013e6632d3c40659cc6cf90ad1c232a6442d9d3f5db980133')),--
         BIG.new(O.from_hex('05c129645e44cf1102a159f748c4a3fc5e673d81d7e86568d9ab0f5d396a7ce46ba1049b6579afb7866b1e715475224b')),--
         BIG.new(O.from_hex('15e6be4e990f03ce4ea50b3b42df2eb5cb181d8f84965a3957add4fa95af01b2b665027efec01c7704b456be69c8b604'))},

        { -- K[4][i]
            BIG.new(O.from_hex('16112c4c3a9c98b252181140fad0eae9601a6de578980be6eec3232b5be72e7a07f3688ef60c206d01479253b03663c1')),
        BIG.new(O.from_hex('1962d75c2381201e1a0cbd6c43c348b885c84ff731c4d59ca4a10356f453e01f78a4260763529e3532f6102c2e49a03d')),
        BIG.new(O.from_hex('058df3306640da276faaae7d6e8eb15778c4855551ae7f310c35a5dd279cd2eca6757cd636f96f891e2538b53dbf67f2')),--
        BIG.new(O.from_hex('16b7d288798e5395f20d23bf89edb4d1d115c5dbddbcd30e123da489e726af41727364f2c28297ada8d26d98445f5416')),
        BIG.new(O.from_hex('0be0e079545f43e4b00cc912f8228ddcc6d19c9f0f69bbb0542eda0fc9dec916a20b15dc0fd2ededda39142311a5001d')),--
        BIG.new(O.from_hex('08d9e5297186db2d9fb266eaac783182b70152c65550d881c5ecd87b6f0f5a6449f38db9dfa9cce202c6477faaf9b7ac')),--
        BIG.new(O.from_hex('166007c08a99db2fc3ba8734ace9824b5eecfdfa8d0cf8ef5dd365bc400a0051d5fa9c01a58b1fb93d1a1399126a775c')),
        BIG.new(O.from_hex('16a3ef08be3ea7ea03bcddfabba6ff6ee5a4375efa1f4fd7feb34fd206357132b920f5b00801dee460ee415a15812ed9')),
        BIG.new(O.from_hex('1866c8ed336c61231a1be54fd1d74cc4f9fb0ce4c6af5920abc5750c4bf39b4852cfe2f7bb9248836b233d9d55535d4a')),
        BIG.new(O.from_hex('167a55cda70a6e1cea820597d94a84903216f763e13d87bb5308592e7ea7d4fbc7385ea3d529b35e346ef48bb8913f55')),
        BIG.new(O.from_hex('04d2f259eea405bd48f010a01ad2911d9c6dd039bb61a6290e591b36e636a5c871a5c29f4f83060400f8b49cba8f6aa8')),--
        BIG.new(O.from_hex('0accbb67481d033ff5852c1e48c50c477f94ff8aefce42d28c0f9a88cea7913516f968986f7ebbea9684b529e2561092')),--
        BIG.new(O.from_hex('0ad6b9514c767fe3c3613144b45f1496543346d98adf02267d5ceef9a00d9b8693000763e3b90ac11e99b138573345cc')),--
        BIG.new(O.from_hex('02660400eb2e4f3b628bdd0d53cd76f2bf565b94e72927c1cb748df27942480e420517bd8714cc80d1fadc1326ed06f7')),--
        BIG.new(O.from_hex('0e0fa1d816ddc03e6b24255e0d7819c171c40f65e273b853324efcd6356caa205ca2f570f13497804415473a1d634b8f')),--
        BIG.new(1)}
    }
end

-- RFC8017 section 4
-- converts a nonnegative integer to an octet string of a specified length.
local function i2osp(x, x_len)
    return O.new(BIG.new(x)):pad(x_len)
end

-- RFC8017 section 4
-- converts an octet string to a nonnegative integer.
local function os2ip(oct)
    return BIG.new(oct)
end

-- HASH TO SCALAR FUNCTION

-- It converts a message written in octects into a BIG modulo PRIME_R (order of subgroup)

--[[ 
INPUT: ciphersuite (a table), msg_octects (as zenroom.octet), dst (as zenroom.octet)
OUTPUT: hashed_scalar (as zenroom.BIG), represents an integer between 1 and ECP.order() - 1
]]
local function hash_to_scalar(ciphersuite, msg_octects, dst)
    local BIG_0 = BIG.new(0)
    -- draft-irtf-cfrg-bbs-signatures-latest Section 3.4.3
    local EXPAND_LEN = 48

    -- Default value of DST when not provided (see also Section 6.2.2)
    dst = dst or ciphersuite.hash_to_scalar_dst
    local uniform_bytes = ciphersuite.expand(msg_octects, dst, EXPAND_LEN)
    local hashed_scalar = BIG.mod(uniform_bytes, PRIME_R) -- = os2ip(uniform_bytes) % PRIME_R
    return hashed_scalar
end

-- SECRET KEY GENERATION FUNCTION AND PUBLIC KEY GENERATION FUNCTION

--[[ 
INPUT: key_material, key_info, key_dst (all as zenroom.octet), ciphersuite (as a table that should contained all informations of the
table shown at lines 14 and 30)
OUTPUT: sk (as zenroom.octet), it represents a scalar between 1 and the order of the EC minus 1
]]
function bbs.keygen(ciphersuite, key_material, key_info, key_dst)
    key_material = key_material or O.random(32) -- O.random is a secure RNG.


    -- TODO: add warning on curve must be BLS12-381
    if not key_info then
        key_info = O.empty()
    elseif type(key_info) == 'string' then
        key_info = O.from_string(key_info)
    end
    if not key_dst then
        key_dst = ciphersuite.ciphersuite_ID .. O.from_string('KEYGEN_DST_')
    elseif type(key_info) == 'string' then
        key_dst = O.from_string(key_info)
    end
    if #key_material < 32 then error('INVALID',2) end
    if #key_info > 65535 then error('INVALID',2) end

    -- using BLS381
    -- 254 < log2(PRIME_R) < 255
    -- ceil((3 * ceil(log2(PRIME_R))) / 16)
    local derive_input = key_material .. i2osp(#key_info,2) .. key_info
    local sk = hash_to_scalar(ciphersuite, derive_input, key_dst)

    return sk
end

function bbs.sk2pk(sk)
    return (ECP2.generator() * sk):to_zcash()
end

-----------------------------------------------
-----------------------------------------------
-----------------------------------------------

-- THE FOLLOWING MULTI-LINE COMMENT CONTAINS GENERIC VERSIONS OF THE hash_to_field function.

-- draft-irtf-cfrg-hash-to-curve-16 section 5.2
--it returns u a table of tables containing big integers representing elements of the field
--[[
function bbs.hash_to_field(msg, count, DST)
    -- draft-irtf-cfrg-hash-to-curve-16 section 8.8.1 (BLS12-381 parameters)
    -- BLS12381G1_XMD:SHA-256_SSWU_RO_
    local m = 1
    local L = 64

    local len_in_bytes = count*m*L
    local uniform_bytes = HASH.expand_message_xmd(msg, DST, len_in_bytes)
    local u = {}
    for i = 0, (count-1) do
        local u_i = {}
        for j = 0, (m-1) do
            local elm_offset = L*(j+i*m)
            local tv = uniform_bytes:sub(elm_offset+1,L+elm_offset)
            local e_j = BIG.mod(tv, p) --local e_j = os2ip(tv) % p
            u_i[j+1] = e_j
        end
        u[i+1] = u_i
    end

    return u
end

--hash_to_field CASE m = 1
function bbs.hash_to_field_m1(msg, count, DST)
    -- draft-irtf-cfrg-hash-to-curve-16 section 8.8.1 (BLS12-381 parameters)
    -- BLS12381G1_XMD:SHA-256_SSWU_RO_
    local L = 64

    local len_in_bytes = count*L
    local uniform_bytes = HASH.expand_message_xmd(msg, DST, len_in_bytes)
    local u = {}
    for i = 0, (count-1) do
        local elm_offset = L*i
        local tv = uniform_bytes:sub(elm_offset+1,L+elm_offset)
        u[i+1] = BIG.mod(tv, p) --local e_j = os2ip(tv) % p
    end

    return u
end
--]]

-- draft-irtf-cfrg-hash-to-curve-16 section 5.2
-- It returns u a table of tables containing big integers representing elements of the field (SPECIFIC CASE m = 1, count = 2)
function bbs.hash_to_field_m1_c2(ciphersuite, msg, dst)
    local p = ECP.prime()
    local L = 64

    local uniform_bytes = ciphersuite.expand(msg, dst, 2*L)
    local u = {}
    u[1] = BIG.mod(uniform_bytes:sub(1,L), p)
    u[2] = BIG.mod(uniform_bytes:sub(L+1,2*L), p)
    return u
end

-- draft-irtf-cfrg-hash-to-curve-16 Section 4
-- If the third argument is FALSE, it returns the first argument, otherwise it returns the second argument
local function CMOV(arg1, arg2, bool)
    if bool then
        return arg2
    else
        return arg1
    end
end

-- draft-irtf-cfrg-hash-to-curve-16 Appendix F.2.1.2
-- It returns EITHER (true, sqrt(u/v)) OR (false, sqrt(Z * (u/v))
local function sqrt_ratio_3mod4(u, v)
    local p = ECP.prime()

    -- draft-irtf-cfrg-hash-to-curve-16 Appendix I.1
    -- SPECIALISED FOR OUR CASE (m=1, p = 3 mod 4)
    local cc1 = BIG.div( BIG.new(O.from_hex('1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaac')), BIG.new(4)) -- (p+1)/4 INTEGER ARITHMETIC
    -- draft-irtf-cfrg-hash-to-curve-16 Appendix F.2.1.2
    local c1 = BIG.div(BIG.modsub(p, BIG.new(3), p), BIG.new(4)) -- (p-3)/4 INTEGER ARITHMETIC
    local c2 = (BIG.modsub(p, BIG.new(11), p)):modpower(cc1, p) -- Sqrt(-Z) in curve where q = 3 mod 4

    local tv1 = v:modsqr(p)
    local tv2 = BIG.modmul(u, v, p)
    tv1 = BIG.modmul(tv1, tv2, p)
    local y1 = tv1:modpower(c1, p)

    y1 = BIG.modmul(y1, tv2, p)
    local y2 = BIG.modmul( y1, c2, p)
    local tv3 = y1:modsqr(p)
    tv3 = BIG.modmul(tv3, v, p)

    local isQR = tv3 == u
    return isQR, CMOV(y2, y1, isQR)
end

-- draft-irtf-cfrg-hash-to-curve-16 Appendix F.2
-- It returns the (x,y) coordinate of a point over E' (isogenous curve)
local function map_to_curve_simple_swu(u)
    local p = ECP.prime()
    local Z = BIG.new(11)
    -- Coefficient A',B' for the isogenous curve.
    local A = BIG.new(O.from_hex('144698a3b8e9433d693a02c96d4982b0ea985383ee66a8d8e8981aefd881ac98936f8da0e0f97f5cf428082d584c1d'))
    local B = BIG.new(O.from_hex('12e2908d11688030018b12e8753eee3b2016c1f0f24f4070a0b9c14fcef35ef55a23215a316ceaa5d1cc48e98e172be0'))

    -- u is of type BIG.
    local tv1 = u:modsqr(p)
    tv1 = BIG.modmul(Z, tv1, p)
    local tv2 = tv1:modsqr(p)
    tv2 = (tv2 + tv1) % p

    local tv3 = (tv2 + BIG.new(1)) % p
    tv3 = BIG.modmul(B, tv3, p)
    local tv4 = CMOV( Z, BIG.modsub( p, tv2, p), tv2 ~= BIG.new(0) )
    tv4 = BIG.modmul(A, tv4, p)

    tv2 = tv3:modsqr(p)
    local tv6 = tv4:modsqr(p)
    local tv5 = BIG.modmul(A, tv6, p)
    tv2 = (tv2 + tv5) % p

    tv2 = BIG.modmul(tv2, tv3, p)
    tv6 = BIG.modmul(tv6, tv4, p)
    tv5 = BIG.modmul(B, tv6, p)
    tv2 = (tv2 + tv5) % p

    local x = BIG.modmul(tv1, tv3, p)
    local is_gx1_square, y1 = sqrt_ratio_3mod4(tv2, tv6)
    local y = BIG.modmul(tv1, u, p)
    y = BIG.modmul(y, y1, p)

    x = CMOV(x, tv3, is_gx1_square)
    y = CMOV(y, y1, is_gx1_square)
    y = CMOV( BIG.modsub(p, y, p), y, (u:parity()) == (y:parity()))

    return {['x'] = BIG.moddiv( x, tv4, p), ['y'] = y}
end

--polynomial evaluation using Horner's rule
local function pol_evaluation(x, K_array)
    local p = ECP.prime()

    local len = #K_array
    local y = K_array[len]
    for i = len-1, 1, -1 do
        y = (K_array[i] + y:modmul(x, p)) % p
    end
    return y
end

--draft-irtf-cfrg-hash-to-curve-16 Appendix E.2
-- It maps a point to BLS12-381 from an isogenous curve.
local function iso_map(point)
    local p = ECP.prime()
    K = K or K_INIT()

    local x_num = pol_evaluation(point.x, K[1])
    local x_den = pol_evaluation(point.x, K[2])
    local y_num = pol_evaluation(point.x, K[3])
    local y_den = pol_evaluation(point.x, K[4])
    local x = BIG.moddiv(x_num, x_den, p)
    local y = y_num:modmul(point.y, p)
    y = y:moddiv(y_den, p)
    return ECP.new(x,y)
end

-- draft-irtf-cfrg-hash-to-curve-16 Section 6.6.3
-- It returns a point in the curve BLS12-381.
function bbs.map_to_curve(u)
    return iso_map(map_to_curve_simple_swu(u))
end

-- draft-irtf-cfrg-hash-to-curve-16 Section 7
-- It returns a point in the correct subgroup.
local function clear_cofactor(ecp_point)
    local h_eff = BIG.new(O.from_hex('d201000000010001'))
    return ecp_point * h_eff
end

--HASH TO CURVE AND CREATE GENERATORS ARE VERY SLOW, MAYBE BETTER TO IMPLEMENT SOMETHING IN C SEE https://github.com/dyne/Zenroom/issues/642  
-- draft-irtf-cfrg-hash-to-curve-16 Section 3
-- It returns a point in the correct subgroup.
function bbs.hash_to_curve(ciphersuite, msg, dst)
    -- local u = bbs.hash_to_field_m1(msg, 2, DST)
    local u = bbs.hash_to_field_m1_c2(ciphersuite, msg, dst)
    local Q0 = bbs.map_to_curve(u[1])
    local Q1 = bbs.map_to_curve(u[2])
    return clear_cofactor(Q0 + Q1)
end

--draft-irtf-cfrg-bbs-signatures Section 4.2
--It returns an array of generators.
function bbs.create_generators(ciphersuite, count)
    if count > 2^64 -1 then error("Message's number too big. At most 2^64-1 message allowed") end

    if #ciphersuite.GENERATORS < count then
        -- local seed_len = 48 --ceil((ceil(log2(PRIME_R)) + k)/8)
        local v = ciphersuite.GENERATOR_V

        for i = #ciphersuite.GENERATORS + 1, count do
            v = ciphersuite.expand(v..i2osp(i,8), ciphersuite.seed_dst, 48)
            local generator = bbs.hash_to_curve(ciphersuite, v, ciphersuite.generator_dst)
            table.insert(ciphersuite.GENERATORS, generator)
        end

        ciphersuite.GENERATOR_V = v
        return ciphersuite.GENERATORS
    else
        return {table.unpack(ciphersuite.GENERATORS, 1, count)}
    end
end


--[[ 
DESCRIPTION: the function bbs.messages_to_scalars is the new version of the function bbs.MapMessageToScalarAsHash.
The main difference is that in the new verison we can transform a set of messages into a scalar instead of transforming one message.
INPUT: messages (a vector of zenroom.octet where index starts from 1), api_id (as zenroom.octet) which FOR NOW is stored in the ciphersuite for simplicity.
OUTPUT: msg_scalars (a vector of scalars stored as zenroom.octet)
]]

function bbs.messages_to_scalars(ciphersuite, messages)

    local L = #messages

    -- for now api_id is in the ciphersuite so we already know it is always given as input since ciphersuite is always given
    -- later we may add a check: if api_id is unknown use an empty string

    local msg_scalars = {}

    for i = 1, L do
        msg_scalars[i] = hash_to_scalar(ciphersuite,messages[i],ciphersuite.map_msg_to_scalar_as_hash_dst)
    end

    return msg_scalars

end

--[[
DESCRIPTION: The following function takes in input an array of elements that can be points on the EC (as zenroom.ecp or zenroom.ecp2),
    big integers (as zenroom.big) and integers (as number). It converts each element of the array into an octet string (zenroom.octet) and
    output the concatenation of all such strings.
    INPUT: array of elements in "zenroom.ecp", "zenroom.ecp2", "zenroom.big" or "number"
    OUTPUT: octet_result as "zenroom.octet"
]]
local function serialization(input_array)
    local octet_result = O.empty()
    local el_octs = O.empty()
    for i=1, #input_array do
        local elt = input_array[i]
        local elt_type = type(elt)
        if (elt_type == "zenroom.ecp") or (elt_type == "zenroom.ecp2") then
            el_octs = elt:to_zcash()
        elseif (elt_type == "zenroom.big") then
            el_octs = i2osp(elt, OCTET_SCALAR_LENGTH)
        elseif (elt_type == "number") then
            el_octs = i2osp(elt, 8)
        else
            error("Invalid type passed inside serialize", 2)
        end

        octet_result = octet_result .. el_octs

    end

    return octet_result
end

--[[
DESCRIPTION: It calculates a domain value, distillating all essential contextual information for a signature.
INPUT: PK (as zenroom.octet) representing the public key, Q1 (as zenroom.ecp) representing a point on the EC, H_points (an array of points
on the subgroup stored as zenroom.ecp), header (as zenroom.octet)
OUTPUT: a scalar represented as zenroom.octet
]]
local function calculate_domain(ciphersuite, pk_octet, Q1, H_points, header)

    header = header or O.empty()

    local len = #H_points
    -- assert(#(header) < 2^64)
    -- assert(L < 2^64)

    local dom_array = {len, Q1, table.unpack(H_points)}
    local dom_octs = serialization(dom_array) .. ciphersuite.api_ID
    local dom_input = pk_octet .. dom_octs .. i2osp(#header, 8) .. header
    local domain = hash_to_scalar(ciphersuite, dom_input,ciphersuite.hash_to_scalar_dst)

    return domain
end

--[[
DESCRIPTION:  This operation computes a deterministic signature from a secret key(SK), a set of generators (points of G1) and
optionally a header and a vector of messages.
INPUT: ciphersuite, SK as (zenroom.octet), PK (as zenroom.octet) representing the public key, messages( an array of scalars representing the messages,
stored as zenroom.big), generators ( an array of points on the subgroup of EC1 stored as zenroom.ecp), header (as zenroom.octet)
OUTPUT: a pair (A,e) represented as zenroom.octet
]]
local function core_sign(ciphersuite, sk, pk, header, messages, generators)

    -- Deserialization
    local LEN = #messages
    if (#generators ~= (LEN +1)) then
        error("The numbers of generators must be #messages +1")
    end

    local Q_1 = generators[1]
    local H_array = { table.unpack(generators, 2, LEN + 1) }

    --Procedure
    local domain = calculate_domain(ciphersuite, pk , Q_1, H_array, header)

    local serialize_array = {sk, domain, table.unpack(messages)}
    local e = hash_to_scalar(ciphersuite, serialization(serialize_array))

    local BB = ciphersuite.P1 + Q_1* domain
    if (LEN > 0) then
        for i = 1,LEN do
            BB = BB + (H_array[i]* messages[i])
        end
    end

    if (BIG.mod(sk + e, PRIME_R) == BIG.new(0))  then
        error("Invalid value for e",2)   
    end
    local AA = BB * BIG.moddiv(BIG.new(1), sk + e, PRIME_R)
    return serialization({AA, e})
end


--[[
DESCRIPTION: The Sign operation returns a BBS signature from a secret key (SK), over a header and a set of messages.
INPUT: ciphersuite , sk (as zenroom.octet), pk (as zenroom.octet), header (as zenroom.octet), messages (array of octet strings stored as zenroom.octet),
header (as zenroom.octet).
OUTPUT: the signature (A,e)
]]
function bbs.sign(ciphersuite, sk, pk, header, messages_octets)

    -- Default values for header and messages.
    header = header or O.empty()
    messages_octets = messages_octets or {}

    local messages = bbs.messages_to_scalars(ciphersuite,messages_octets)

    local generators = bbs.create_generators(ciphersuite, #messages +1)
    local signature = core_sign(ciphersuite, sk, pk, header, messages, generators)
    return signature

end

--draft-irtf-cfrg-bbs-signatures Section 4.7.3
-- It is the opposite function of "serialize" with input "(POINT, SCALAR, SCALAR)"
local function octets_to_signature(signature_octets)
    local expected_len = OCTET_SCALAR_LENGTH + OCTET_POINT_LENGTH
    if (#signature_octets ~= expected_len) then
        error("Wrong length of signature_octets", 2)
    end
    local A_octets = signature_octets:sub(1, OCTET_POINT_LENGTH)
    local AA = ECP.from_zcash(A_octets:octet())
    if (AA == IDENTITY_G1) then
        error("Point is identity", 2)
    end

    local index = OCTET_POINT_LENGTH + 1
    local end_index = index + OCTET_SCALAR_LENGTH - 1
    -- os1ip transform a string into a BIG
    local s = os2ip(signature_octets:sub(index, end_index))
    if (s == BIG.new(0)) or (s >= PRIME_R) then
        error("Wrong s in deserialization", 2)
    end

    return {AA, s}
end

--draft-irtf-cfrg-bbs-signatures Section 4.7.6
function bbs.octets_to_pub_key(pk)
    local W = ECP2.from_zcash(pk)

    -- ECP2.infinity == Identity_G2
    if (W == ECP2.infinity()) then
        error("W is identity G2", 2)
    end
    if (W * PRIME_R ~= ECP2.infinity()) then
        error("W is not in subgroup", 2)
    end

    return W
end


--[[
DESCRIPTION: Given the signature, the set of messages associated and the public key, the following function verify if the signature is valid
INPUT: ciphersuite (a table), pk (as zenroom.octet), signature (as zenroom.octet), generators (array of points on the subgroup of EC1 as
zenroom.ecp), messages (array of scalars stored as zenroom.octet), header (as zenroom.octet).
OUTPUT: a boolean, true or false 
]]
local function core_verify(ciphersuite, pk, signature, generators, messages, header)

    -- Default values
    header = header or O.empty()

    -- Deserialization
    local signature_result = octets_to_signature(signature) -- transform octet into a table {AA, s}: with entries in zenroom.ecp and zenroom.BIG
    local AA, s = table.unpack(signature_result)
    local W = bbs.octets_to_pub_key(pk)
    local LEN = #messages
    local Q_1 = table.unpack(generators, 1)
    local H_points = { table.unpack(generators, 2, LEN + 1) }
    -- Procedure
    local domain = calculate_domain(ciphersuite, pk, Q_1, H_points, header)
    local BB = ciphersuite.P1 + (Q_1 * domain)
    if (LEN > 0) then
        for i = 1, LEN do
            BB = BB + (H_points[i] * messages[i])
        end
    end
    local LHS = ECP2.ate(W + (ECP2.generator() * s), AA)
    local RHS = ECP2.ate(ECP2.generator(), BB)
    return LHS == RHS
end


--[[
DESCRIPTION: The Verify operation validates a BBS signature, given a public key (PK), a header and a set of messages.
INPUT: ciphersuite (a table), pk (as zenroom.octet), signature (as zenroom.octet), messages (array of octet strings as zenroom.octet), header (as zenroom.octet).
OUTPUT: a boolean, true or false 
]]
function bbs.verify(ciphersuite, pk ,signature, header, messages_octets)
    messages_octets = messages_octets or O.empty{}
    local messages = bbs.messages_to_scalars(ciphersuite,messages_octets)
    local generators = bbs.create_generators(ciphersuite, #messages +1)
    return core_verify(ciphersuite, pk,signature, generators, messages, header)
end




---------------------------------
-- Credentials:ProofGen,ProofVerify -------
---------------------------------
---------------------------------
---------------------------------
---------------------------------
---------------------------------

-- draft-irtf-cfrg-bbs-signatures-latest Section 4.1
-- It returns count random scalar.
function bbs.calculate_random_scalars(count)
    local scalar_array = {}
    local scalar = nil
    --[[ This does not seem uniformly random:
    for i = 1, count do
        scalar_array[i] = BIG.mod(O.random(48), PRIME_R)
    end
    --]]
    -- We leave it like this because it should yield a more uniform distribution.
    while #scalar_array < count do
        scalar = os2ip(O.random(32)) -- è un BIG
        if scalar < PRIME_R then 
            table.insert(scalar_array, scalar)
        end
    end
    return scalar_array
end

--[[
DESCRIPTION: This function calculates the challange scalar value needed for both the CoreProofGen and the CoreProofVerify
INPUT: ciphersuite (a table), init_res (a vector consisting of five points of G1 and a scalar value in that order), disclosed_messages (vector of scalar values), 
disclosed_indexes (vector of non-negative integers in ascending order), ph( an octet string)

OUTPUT: challenge, a scalar
]]

local function proof_challenge_calculate(ciphersuite, init_res, disclosed_messages, disclosed_indexes, ph)
    
    ph = ph or O.empty()

    local R_len = #disclosed_indexes
    -- We avoid the check R_len < 2^64
    if R_len ~= #disclosed_messages then
        error("disclosed_indexes length is not equal to disclosed_me length", 2)
    end
    -- We avoid the check #(ph) < 2^64
    local c_array = {}

    if R_len ~= 0 then
        c_array = {table.unpack(init_res, 1, 5)}
        table.insert(c_array,R_len)
        for i = 1, R_len do
            c_array[i+6] = disclosed_indexes[i] -1
        end
        for i = 1, R_len do
            c_array[i+6+R_len] = disclosed_messages[i]
            
        end
        c_array[7+2*R_len] = init_res[6]
    else
        c_array = {table.unpack(init_res,1,5), R_len, init_res[6]}
    end
    local c_octs = serialization(c_array) .. i2osp(#ph, 8) .. ph
    

    local challenge = hash_to_scalar(ciphersuite, c_octs)

    return challenge
end

--[[
INPUT: pk (zenroom.octet), signature_result (a pair zenroom.ecp, zenroom.BIG), generators (vector of points of G1 in zenroom.ecp),
random_scalars (vector zenroom.BIG) header (zenroom.octet), messages (vector of scalars in zenroom.BIG), undisclosed_indexes (vector of numbers),
ciphersuite (table).
OUTPUT: init_res a table with 5 points on G1 (zenroom.ecp) and a scalar (zenroom.BIG)
]]

local function proof_init(ciphersuite, pk, signature_result, generators, random_scalars, header, messages, undisclosed_indexes)
    local AA, e = table.unpack(signature_result)
    local L = #messages
    local U = #undisclosed_indexes
    local j = {table.unpack(undisclosed_indexes)}
    local r1, r2, et, r1t, r3t = table.unpack(random_scalars,1,5)
    local mjt = {table.unpack(random_scalars, 6, 5 + U)}

    if #generators ~= L+1 then error('Wrong generators length') end
    local Q_1 = table.unpack(generators, 1)
    local MsgGenerators = {table.unpack(generators, 2, 1 + L)}
    local H_j = {}
    for i = 1, U do
        H_j[i] = MsgGenerators[j[i]]
    end
    
    if U > L then error('number of undisclosed indexes is bigger than the number of messages') end
    for i = 1, U do
        if undisclosed_indexes[i] <= 0 or undisclosed_indexes[i] > L then error('Wrong undisclosed indexes') end
    end
    
    local domain = calculate_domain(ciphersuite, pk, Q_1, MsgGenerators, header)
    
    local BB = ciphersuite.P1 + (Q_1 * domain)
    for i = 1, L do
        BB = BB + (MsgGenerators[i] * messages[i])
    end
    
    local D = BB * r2
    local Abar = AA * (r1 * r2)
    local Bbar = (D * r1) - (Abar * e)
    local T1 = (Abar * et) + (D * r1t)
    local T2 = (D * r3t)
    for i = 1, U do
        T2 = T2 + H_j[i] * mjt[i]
    end
    local init_res = {Abar, Bbar, D, T1, T2, domain}
    return init_res

end

--[[
INPUT: init_res (output of ProofInit), challenge (output of ProofChallengeCalculate), e_value (scalar zenroom.BIG), random_scalars (vector of
scalars, zenroom.BIG), undisclosed_messages (vector of scalars, zenroom.BIG)
OUTPUT:
]]

local function proof_finalize(init_res, challenge, e_value, random_scalars, undisclosed_messages)
    local U = #undisclosed_messages

    if #random_scalars ~= U + 5 then error('Wrong number of random scalars') end
    
    local r1, r2, et, r1t, r3t = table.unpack(random_scalars,1,5)

    local mjt = {table.unpack(random_scalars, 6, 5 + U)}
    

    local Abar, Bbar, D = table.unpack(init_res)
    local r3 = BIG.moddiv(BIG.new(1), r2, PRIME_R)
    local es = BIG.mod(et + BIG.modmul(e_value, challenge, PRIME_R),PRIME_R)
    local r1s = BIG.mod(r1t - BIG.modmul(r1, challenge,PRIME_R),PRIME_R)
    local r3s = BIG.mod(r3t - BIG.modmul(r3,challenge,PRIME_R),PRIME_R)
    local ms = {}
    for j = 1, U do
        ms[j] = BIG.mod(mjt[j] + (undisclosed_messages[j] * challenge), PRIME_R)
    end
    local proof = {Abar, Bbar, D, es, r1s, r3s} --ms, challenge
    for i = 1, U do
        proof[6 + i] = ms[i]
    end
    proof[6 + U + 1] = challenge
    return serialization(proof)
end

--[[
INPUT: ciphersuite (table), pk (zenroom.octet), signature (zenroom.octet), generators (vector of zenroom.ecp on G1), header (zenroom.octet),
ph (zenroom.octet), messages (vector of scalars in zenroom.BIG), disclosed_indexes (vector of numbers)
OUTPUT: proof (output of ProofFinalize)
]]

local function core_proof_gen(ciphersuite, pk, signature, generators, header, ph, messages, disclosed_indexes)
    local L = #messages
    local R = #disclosed_indexes
    if R > L then error('number of disclosed indexes is bigger than the number of messages') end
    local U = L - R
    local signature_result = octets_to_signature(signature)
    local AA, e = table.unpack(signature_result)
    local undisclosed_indexes = {}
    local index = 1
    local j = 1
    for i = 1, L do
        if i ~= disclosed_indexes[j] then
            undisclosed_indexes[index] = i
            index = index + 1
        else
            j = j + 1
        end
    end
    
    local disclosed_messages = {}
    local undisclosed_messages = {}
    for i = 1, #disclosed_indexes do
        disclosed_messages[i] = messages[disclosed_indexes[i]]
    end
    for i = 1, #undisclosed_indexes do
        undisclosed_messages[i] = messages[undisclosed_indexes[i]]
    end
    
    local random_scalars = bbs.calculate_random_scalars(5 + U)

    local init_res = proof_init(ciphersuite, pk, signature_result, generators, random_scalars, header, messages, undisclosed_indexes)
    
    local challenge =  proof_challenge_calculate(ciphersuite, init_res, disclosed_messages, disclosed_indexes, ph)
    
    local proof = proof_finalize(init_res, challenge, e, random_scalars, undisclosed_messages)

    return proof
end

--[[
INPUT: ciphersuite (table), pk (zenroom.octet), signature (zenroom.octet), header (zenroom.octet), ph (zenroom.octet), messages (vector of
zenroom.octet), disclosed_indexes (vector of number)
OUTPUT: proof (output of CoreProofGen)
]]

function bbs.proof_gen(ciphersuite, pk, signature, header, ph, messages, disclosed_indexes)
    header = header or O.empty()
    ph = ph or O.empty()
    local messages = bbs.messages_to_scalars(ciphersuite,messages)
    local generators = bbs.create_generators(ciphersuite, #messages + 1)
    local proof = core_proof_gen(ciphersuite, pk, signature, generators, header, ph, messages, disclosed_indexes)

    return proof
end

--[[
DESCRIPTION: Decode an octet string representing the proof
INPUT: proof_octets (an octet string)
OUTPUT: proof ( an array of 3 points of G1 and 4 + U scalars)
]]
local function octets_to_proof(proof_octets)
    local proof_len_floor = 3*OCTET_POINT_LENGTH + 4*OCTET_SCALAR_LENGTH
    if #proof_octets < proof_len_floor then
        error("proof_octets is too short", 2)
    end
    local index = 1
    local return_array = {}
    for i = 1, 3 do
        local end_index = index + OCTET_POINT_LENGTH - 1
        return_array[i] = ECP.from_zcash(proof_octets:sub(index, end_index))
        if return_array[i] == IDENTITY_G1 then
            error("Invalid point", 2)
        end
        index = index + OCTET_POINT_LENGTH
    end

    local j = 4
    while index < #proof_octets do
        local end_index = index + OCTET_SCALAR_LENGTH -1
        return_array[j] = os2ip(proof_octets:sub(index, end_index))
        if (return_array[j] == BIG.new(0)) or (return_array[j]>=PRIME_R) then
            print(j)
            error("Not a scalar in octets_to_proof", 2)
        end
        index = index + OCTET_SCALAR_LENGTH
        j = j+1
    end

    if index ~= #proof_octets +1 then
        error("Index is not right length",2)
    end

    local msg_commitments = {}
    if j > 7 then
        msg_commitments = {table.unpack(return_array, 7, j-2)}
    end
    local ret_array = {table.unpack(return_array, 1, 6)}
    ret_array[7] = msg_commitments
    table.insert(ret_array,return_array[j-1])
    return ret_array

end

--[[
DESCRIPTION: This operations initializes the proof verification and return one of the inputs of the challenge calculation operation 
INPUT: ciphersuite (a table), pk (as zenroom.octet), Abar, Bbar, D (G1 points), ehat, r1hat ,r3hat (scalars), commitments (a scalar vector), c(a scalar)
generators ( an array of G1 points), header (as zenroom.octet), disclosed_messages (array of octet strings), disclosed_indexes( an array of positive integers) .
OUTPUT: an array consisting of 4 G1 points and a scalar   
]]
local function proof_verify_init(ciphersuite, pk, Abar, Bbar, D , ehat, r1hat, r3hat , commitments, c, generators, header, disclosed_messages, disclosed_indexes)

    local len_U = #commitments
    local len_R = #disclosed_indexes
    local len_L = len_R + len_U

    --Preconditions
    for _,i in pairs(disclosed_indexes) do
        if (i < 1) or (i > len_L) then
            error("disclosed_indexes out of range",2)
        end
    end
    if #disclosed_messages ~= len_R then
        error("Unmatching indexes and messages", 2)
    end

    local Q_1 = generators[1]
    local MsgGenerators = {table.unpack(generators, 2, len_L+1)}

    local disclosed_H = {}
    local secret_H = {}
    local counter_d = 1
    for i = 1, len_L do
        if i == disclosed_indexes[counter_d] then
            table.insert(disclosed_H, MsgGenerators[i])
            counter_d = counter_d +1
        else
            table.insert(secret_H, MsgGenerators[i])
        end
    end

    local domain = calculate_domain(ciphersuite, pk, Q_1, MsgGenerators, header)

    local T_1 = Bbar* c + Abar* ehat + D* r1hat
 
    local Bv = ciphersuite.P1 + Q_1*domain
    for i = 1, len_R do
        Bv = Bv + disclosed_H[i]*disclosed_messages[i]
    end

    local T_2 = Bv*c + D* r3hat
    for i = 1, len_U do
        T_2 = T_2 + secret_H[i]*commitments[i]
    end
    return {Abar, Bbar, D, T_1, T_2, domain}


end

--[[
DESCRIPTION: This operations checks the validity of the proof
INPUT: ciphersuite (a table), pk (as zenroom.octet), proof (as zenroom.octet), generators ( an array of G1 points), header (as zenroom.octet), ph( as zenroom.octet)
disclosed_messages (array of octet strings), disclosed_indexes( an array of positive integers) .
OUTPUT: a boolean true or false   
]]
local function core_proof_verify(ciphersuite, pk , proof, generators, header, ph, disclosed_messages, disclosed_indexes)

    local proof_result = octets_to_proof(proof)
    local Abar, Bbar, D , ehat, r1hat, r3hat , commitments, cp = table.unpack(proof_result)
    local W = bbs.octets_to_pub_key(pk)

    local init_res = proof_verify_init(ciphersuite, pk , Abar, Bbar, D , ehat, r1hat, r3hat , commitments, cp, generators, header, disclosed_messages, disclosed_indexes)
    local challenge = proof_challenge_calculate(ciphersuite, init_res, disclosed_messages, disclosed_indexes, ph)
    if (cp ~= challenge) then
        return false
    end

    local LHS = ECP2.ate(W, Abar)
    local RHS = ECP2.ate(ECP2.generator(), Bbar)
    return  LHS == RHS

end

--[[
DESCRIPTION: This function validates a BBS proof
INPUT: ciphersuite (a table), pk (as zenroom.octet), proof (as zenroom.octet), header (as zenroom.octet), ph( as zenroom.octet)
disclosed_messages (array of octet strings), disclosed_indexes( an array of positive integers) .
OUTPUT: a boolean true or false   
]]
function bbs.proof_verify(ciphersuite, pk, proof, header, ph, disclosed_messages_octets, disclosed_indexes)

    local proof_len_floor = 3*OCTET_POINT_LENGTH + 4*OCTET_SCALAR_LENGTH
    if #proof < proof_len_floor then
        error("proof_octets is too short", 2)
    end
    header = header or O.empty()
    ph = ph or O.empty()
    disclosed_messages_octets = disclosed_messages_octets or {}
    disclosed_indexes = disclosed_indexes or {}
    local len_U = math.floor((#proof-proof_len_floor)/OCTET_SCALAR_LENGTH)
    local len_R = #disclosed_indexes

    local message_scalars = bbs.messages_to_scalars(ciphersuite, disclosed_messages_octets)
    local generators = bbs.create_generators(ciphersuite, len_U+len_R+1)

    return core_proof_verify(ciphersuite, pk, proof, generators, header, ph, message_scalars, disclosed_indexes)

end

return bbs

