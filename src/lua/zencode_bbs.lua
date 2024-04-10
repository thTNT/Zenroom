--[[
--This file is part of zenroom
--
--Copyright (C) 2023-2024 Dyne.org foundation
--designed, written and maintained by Rebecca Selvaggini, Luca Di Domenico and Alberto Lerda
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
--]]

--[[

Right now the Zencode statements set the header parameter (used in the
signature, the verification, the creation of the proof and the
verification of the proof) as the default value, an empty octet.

In the zero knowledge proof context as we implemented it following
this draft, the header is created by the ISSUER and it is designed to
possibly contain pieces of information meant to be PUBLIC. For
example, an header MAY contain a set of messages meant to be ALWAYS
DISCLOSED in the proof creation.

To enable the use of the header inside Zencode, one should create at
least three new statements, considering the header parameter inside
the issuer credential signature, inside the proof creation and inside
the proof verification.

Right now, the presentation header (used in the creation of the proof
and the verification of the proof) is set as a random octet of fixed
length inside the Zencode examples. It is meant to mitigate the replay
attacks. It is created by the PARTICIPANT and it can be a nonce and/or
contain additional information, like an expiration date of the proof
(this is used to guarantee the freshness of the generated proof).

One can find a nice presentation regarding the BBS zero-knowledge
proof scheme here
https://grotto-networking.com/Presentations/BBSforVCs/BBSforVCsBasics.html#/title-slide

One may interactively test the functionality of the
BBS ZKP scheme directly on a browser here
https://www.grotto-networking.com/BBSDemo/

Our actual implementation of the BBS ZKP does not require the use of
participant's SECRET key to generate the proof. In certain use case
scenario, this allows the issuer to impersonate a given
participant. There are many possible solutions for such an issue
depending on the application. A possible variant of the BBS ZKP
assessing the lack of the participant's private key can be found here
https://basileioskal.github.io/bbs-bound-signatures/draft-bound-bbs-signatures.html

--]]

local BBS = require'crypto_bbs'

local function bbs_public_key_f(obj)
    local point = ECP2.from_zcash(obj)
    if point:isinf() then
        error('Invalid BBS public key (infinite)', 3) end
    -- TODO: restore this test using the right multiplier
    if not (point*ECP.order()):isinf() then
        error('Invalid BBS public key (point*order not infinite)',3) end
    return obj
end

--see function octets_to_signature in src/lua/crypto_bbs.lua
local function bbs_signature_f(obj)
    local expected_len = 80
    local signature_octets = obj:octet()
    if #signature_octets ~= expected_len then
        error("Invalid length of signature_octets: "..#signature_octets, 3) end
    local A_octets = signature_octets:sub(1, 48)
    local AA = ECP.from_zcash(A_octets)
    if AA == ECP.generator() then
        error("Invalid BBS signature: point equal order identity",3)
    end
    local BIG_0 = BIG.new(0)
    local index = 49
    local end_index = index + 31
    local e = BIG.new(signature_octets:sub(index, end_index))
    local PRIME_R = ECP.order()
    if not ( e ~= BIG_0 and e < PRIME_R ) then
        error("Invalid BBS signature: wrong e in deserialization",3)
    end
    -- index = index + 32
    -- end_index = index + 31
    -- local s = BIG.new(signature_octets:sub(index, end_index))
    -- if not ( s ~= BIG_0 and s < PRIME_R ) then
    --     error("Invalid BBS signature: wrong s in deserialization", 3)
    -- end
    return obj
end

ZEN:add_schema(
   {
      bbs_public_key = function(obj)
        return schema_get(obj, '.', bbs_public_key_f)
      end,
      bbs_signature = function(obj)
        return schema_get(obj, '.', bbs_signature_f)
      end,
      bbs_shake_public_key = function(obj)
        return schema_get(obj, '.', bbs_public_key_f)
      end,
      bbs_shake_signature = function(obj)
        return schema_get(obj, '.', bbs_signature_f)
      end
   }
)

--[[
    KeyGen takes as input an octet string (of length at least 32 bytes) IKM. 
    IKM MUST be infeasible to guess, e.g. generated by a trusted source of randomness.
    
    For this reason we generate IKM inside of the BBS.keygen() function (see src/lua/crypto_bbs.lua)
    
    KeyGen takes also an optional parameter, key_info. 
    This parameter MAY be used to derive multiple independent keys from the same IKM. 
    By default, key_info is the empty string.
--]]

-- generate the private key
When("create bbs key",function()
    initkeyring'bbs'
    local ciphersuite = BBS.ciphersuite('sha256')
    ACK.keyring.bbs = BBS.keygen(ciphersuite)
end)

-- generate the private key
When("create bbs shake key",function()
    initkeyring'bbs_shake'
    local ciphersuite = BBS.ciphersuite('shake256')
    ACK.keyring.bbs_shake = BBS.keygen(ciphersuite)
end)

-- generate the public key
When("create bbs public key",function()
    empty'bbs public key'
    local sk = havekey'bbs'
    ACK.bbs_public_key = BBS.sk2pk(sk)
    new_codec('bbs public key', { zentype = 'e'})
end)

-- generate the public key
When("create bbs shake public key",function()
    empty'bbs shake public key'
    local sk = havekey'bbs shake'
    ACK.bbs_shake_public_key = BBS.sk2pk(sk)
    new_codec('bbs shake public key', { zentype = 'e'})
end)

local function _key_from_secret(sec, path)
   local sk = have(sec)
   local name = uscore(path) or 'bbs'
   if name ~= 'bbs' and name ~= 'bbs_shake' then
       error('Unsupported BBS key format: '..name, 3) end
   initkeyring(name)
   -- Check if the user-provided sk is reasonable
   if type(sk) ~= "zenroom.big" then
           error("Invalid BBS secret key: must be a BIG integer", 2)
   end
   if sk >= ECP.order() then
       error("Invalid BBS secret key: scalar exceeds order", 2)
   end
   ACK.keyring[name] = sk
end

When("create bbs key with secret key ''", _key_from_secret)
When("create bbs key with secret ''", _key_from_secret)

When("create bbs shake key with secret key ''", function(sk) _key_from_secret(sk, 'bbs_shake') end)
When("create bbs shake key with secret ''", function(sk) _key_from_secret(sk, 'bbs_shake') end)

When("create bbs public key with secret key ''",function(sec)
    local sk = have(sec)
    -- Check if the user-provided sk is reasonable
    zencode_assert(type(sk) == "zenroom.big", "sk must have type integer")
    zencode_assert(sk < ECP.order(), "sk is not a scalar")
    empty'bbs public key'
    ACK.bbs_public_key = BBS.sk2pk(sk)
    new_codec('bbs public key', { zentype = 'e'})
end)
When("create bbs shake public key with secret key ''",function(sec)
    local sk = have(sec)
    -- Check if the user-provided sk is reasonable
    zencode_assert(type(sk) == "zenroom.big", "sk must have type integer")
    zencode_assert(sk < ECP.order(), "sk is not a scalar")
    empty'bbs shake public key'
    ACK.bbs_shake_public_key = BBS.sk2pk(sk)
    new_codec('bbs shake public key', { zentype = 'e'})
end)

--[[ The function BBS.sign may take as input also a string octet HEADER containing context 
     and application specific information. If not supplied, it defaults to an empty string.
--]]

local function generic_bbs_signature(doc, h)
    local obj, obj_codec = have(doc)
    local hash = O.to_string(mayhave(h)) or h or 'sha256'
    local name = fif(hash=='sha256', 'bbs')
        or fif(hash=='shake256','bbs_shake')
        or error("Invalid signature hash: "..hash)
    empty(name..' signature')
    local sk = havekey(name)
    local ciphersuite = BBS.ciphersuite(hash)
    -- first check on h, checks on nested table is done in BBS.sign for optimization
    zencode_assert(obj_codec.zentype == 'e' or obj_codec.zentype == 'a',
        'BBS signature can be done only on strings or an array of strings')
    if (luatype(obj) ~= 'table') then obj = {obj} end
    local pk = ACK[name..'_public_key'] or BBS.sk2pk(sk)
    ACK[name..'_signature'] = BBS.sign(ciphersuite, sk, pk, nil, obj)
    new_codec(name..' signature', { zentype = 'e'})
end

When("create bbs signature of ''", function(doc) generic_bbs_signature(doc, 'sha256') end)
When("create bbs shake signature of ''", function(doc) generic_bbs_signature(doc, 'shake256') end)

local function generic_verify(doc, sig, by, h)
    local s = have(sig)
    local obj = have(doc)
    local hash = O.to_string(mayhave(h)) or h or 'sha256'
    local name = fif(hash=='sha256', 'bbs')
        or fif(hash=='shake256','bbs_shake')
        or error("Invalid signature hash: "..hash)
    local pk = load_pubkey_compat(by, name)
    local ciphersuite = BBS.ciphersuite(hash)
    if (type(obj) ~= 'table') then obj = {obj} end
    zencode_assert(
        BBS.verify(ciphersuite, pk, s, nil, obj),
       'The '..space(name)..' signature by '..by..' is not authentic'
    )
end

IfWhen("verify '' has a bbs signature in '' by ''", function(doc, sig, by)
    return generic_verify(doc, sig, by, 'sha256')
end)
IfWhen("verify '' has a bbs shake signature in '' by ''", function(doc, sig, by)
    return generic_verify(doc, sig, by, 'shake256')
end)

--[[
    Participant generates proof with the function bbs.proof_gen(ciphersuite, pk, signature, 
    header, ph, messages_octets, disclosed_indexes)

    ph = presentation header, used to mitigate replay attack.
--]]

--see function octets_to_proof in src/lua/crypto_bbs.lua
local function bbs_proof_f(obj)
    local proof_octets = obj:octet()
    local proof_len_floor = 304
    zencode_assert(#proof_octets >= proof_len_floor,
        "proof_octets is too short"
    )
    local index = 1
    for i = 1, 3 do
        local end_index = index + 47
        local point = ECP.from_zcash(proof_octets:sub(index, end_index))
        zencode_assert(point ~= ECP.generator(),
            "Invalid point"
        )
        index = index + 48
    end
    local PRIME_R = ECP.order()
    while index < #proof_octets do
        local end_index = index + 31
        local sc = BIG.new(proof_octets:sub(index, end_index))
        zencode_assert( sc ~= BIG.new(0) and sc < PRIME_R,
            "Not a scalar in octets_proof"
        )
        index = index + 32
    end

    return obj
end

ZEN:add_schema(
    {
        bbs_proof = function(obj) return schema_get(obj, '.', bbs_proof_f) end,
        bbs_shake_proof = function(obj) return schema_get(obj, '.', bbs_proof_f) end,
        bbs_credential = function(obj) return schema_get(obj, '.', bbs_signature_f) end,
        bbs_shake_credential = function(obj) return schema_get(obj, '.', bbs_signature_f) end
    }
)

When("create bbs disclosed messages", function()
    local dis_ind = have'bbs disclosed indexes'
    local all_msgs = have'bbs messages'
    empty'bbs disclosed messages'
    local dis_msgs = {}
    for k,v in pairs(dis_ind) do
        dis_msgs[k] = all_msgs[tonumber(v)]
    end
    ACK.bbs_disclosed_messages = dis_msgs
    new_codec('bbs disclosed messages', { zentype = 'a', encoding = 'string'})
end)

When("create bbs proof", function()
    empty'bbs proof'
    local ph = have'bbs presentation header':octet()
    local message_octets = have'bbs messages'
    local float_indexes = have'bbs disclosed indexes'
    local pubk = have'bbs public key'
    local signature = have'bbs credential'
    local ciphersuite = BBS.ciphersuite('sha256')
    if(type(message_octets) ~= 'table') then
        message_octets = {message_octets}
    end
    local disclosed_indexes = {}
    for k,v in pairs(float_indexes) do
        disclosed_indexes[k] = tonumber(v)
    end
    ACK.bbs_proof = BBS.proof_gen(ciphersuite, pubk, signature, nil, ph, message_octets, disclosed_indexes)
    new_codec('bbs proof', { zentype = 'e'})
end)

When("create bbs shake proof", function()
    empty'bbs shake proof'
    local ph = have'bbs presentation header':octet()
    local message_octets = have'bbs messages'
    local float_indexes = have'bbs disclosed indexes'
    local pubk = have'bbs shake public key'
    local signature = have'bbs shake credential'
    local ciphersuite = BBS.ciphersuite('shake256')
    if(type(message_octets) ~= 'table') then
        message_octets = {message_octets}
    end
    local disclosed_indexes = {}
    for k,v in pairs(float_indexes) do
        disclosed_indexes[k] = tonumber(v)
    end
    ACK.bbs_shake_proof = BBS.proof_gen(ciphersuite, pubk, signature, nil, ph, message_octets, disclosed_indexes)
    new_codec('bbs shake proof', { zentype = 'e'})
end)

IfWhen("verify bbs proof", function()
    local ciphersuite = BBS.ciphersuite('sha256')
    local pubk = have'bbs public key'
    local proof = have'bbs proof'
    local ph = have'bbs presentation header':octet()
    local disclosed_messages_octets = have'bbs disclosed messages'
    local float_indexes = have'bbs disclosed indexes'
    local disclosed_indexes = {}
    for k,v in pairs(float_indexes) do
        disclosed_indexes[k] = tonumber(v)
    end
    zencode_assert(
        BBS.proof_verify(ciphersuite, pubk, proof, nil, ph, disclosed_messages_octets, disclosed_indexes),
       'The bbs proof is not valid')
end)

IfWhen("verify bbs shake proof", function()
    local ciphersuite = BBS.ciphersuite('shake256')
    local pubk = have'bbs shake public key'
    local proof = have'bbs shake proof'
    local ph = have'bbs presentation header':octet()
    local disclosed_messages_octets = have'bbs disclosed messages'
    local float_indexes = have'bbs disclosed indexes'
    local disclosed_indexes = {}
    for k,v in pairs(float_indexes) do
        disclosed_indexes[k] = tonumber(v)
    end
    zencode_assert(
        BBS.proof_verify(ciphersuite, pubk, proof, nil, ph, disclosed_messages_octets, disclosed_indexes),
       'The bbs shake proof is not valid')
end)

--bbs.proof_gen(ciphersuite, pk, signature, header, ph, messages_octets, disclosed_indexes)
When("create bbs proof of signature '' of messages '' with public key '' presentation header '' and disclosed indexes ''", function(sig, msg, pk, prh, dis_ind)
    empty'bbs proof'
    local message_octets = have(msg)
    local float_indexes = have(dis_ind)
    local pubk = have(pk)
    local signature = have(sig)
    local ciphersuite = BBS.ciphersuite('sha256')
    local ph = have(prh):octet()
    if(type(message_octets) ~= 'table') then
        message_octets = {message_octets}
    end
    local disclosed_indexes = {}
    for k,v in pairs(float_indexes) do
        disclosed_indexes[k] = tonumber(v)
    end
    ACK.bbs_proof = BBS.proof_gen(ciphersuite, pubk, signature, nil, ph, message_octets, disclosed_indexes)
    new_codec('bbs proof', { zentype = 'e'})
end)

--bbs.proof_gen(ciphersuite, pk, signature, header, ph, messages_octets, disclosed_indexes)
When("create bbs shake proof of signature '' of messages '' with public key '' presentation header '' and disclosed indexes ''", function(sig, msg, pk, prh, dis_ind)
    empty'bbs proof'
    local message_octets = have(msg)
    local float_indexes = have(dis_ind)
    local pubk = have(pk)
    local signature = have(sig)
    local ciphersuite = BBS.ciphersuite('shake256')
    local ph = have(prh):octet()
    if(type(message_octets) ~= 'table') then
        message_octets = {message_octets}
    end
    local disclosed_indexes = {}
    for k,v in pairs(float_indexes) do
        disclosed_indexes[k] = tonumber(v)
    end
    ACK.bbs_shake_proof = BBS.proof_gen(ciphersuite, pubk, signature, nil, ph, message_octets, disclosed_indexes)
    new_codec('bbs shake proof', { zentype = 'e'})
end)

--bbs.proof_verify(ciphersuite, pk, proof, header, ph, disclosed_messages_octets, disclosed_indexes)
IfWhen("verify bbs proof with public key '' presentation header '' disclosed messages '' and disclosed indexes ''",
       function(pk, prh, dis_msg, dis_ind)
    local pubk = have(pk)
    local proof = have'bbs proof'
    local ph = have(prh):octet()
    local disclosed_messages_octets = have(dis_msg)
    local float_indexes = have(dis_ind)
    local ciphersuite = BBS.ciphersuite('sha256')
    local disclosed_indexes = {}
    for k,v in pairs(float_indexes) do
        disclosed_indexes[k] = tonumber(v)
    end
    zencode_assert(
        BBS.proof_verify(ciphersuite, pubk, proof, nil, ph, disclosed_messages_octets, disclosed_indexes),
       'The bbs proof is not valid')
end)

--bbs.proof_verify(ciphersuite, pk, proof, header, ph, disclosed_messages_octets, disclosed_indexes)
IfWhen("verify bbs shake proof with public key '' presentation header '' disclosed messages '' and disclosed indexes ''",
       function(pk, prh, dis_msg, dis_ind)
    local pubk = have(pk)
    local proof = have'bbs shake proof'
    local ph = have(prh):octet()
    local disclosed_messages_octets = have(dis_msg)
    local float_indexes = have(dis_ind)
    local ciphersuite = BBS.ciphersuite('shake256')
    local disclosed_indexes = {}
    for k,v in pairs(float_indexes) do
        disclosed_indexes[k] = tonumber(v)
    end
    zencode_assert(
        BBS.proof_verify(ciphersuite, pubk, proof, nil, ph, disclosed_messages_octets, disclosed_indexes),
       'The bbs shake proof is not valid')
end)
