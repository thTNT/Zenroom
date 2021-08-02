-- This file is part of Zenroom (https://zenroom.dyne.org)
--
-- Copyright (C) 2018-2021 Dyne.org foundation designed, written and
-- maintained by Denis Roio <jaromil@dyne.org>
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as
-- published by the Free Software Foundation, either version 3 of the
-- License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful, but
-- WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
-- Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public
-- License along with this program.  If not, see
-- <https://www.gnu.org/licenses/>.

-- init script embedded at compile time.  executed in
-- zen_load_extensions(L) usually after zen_init()

-- -- remap fatal and error
function fatal(msg)
	if type(msg) == 'string' then
		warn(trim(msg), 2)
	end
	debug.traceback()
	--	  if ZEN_traceback ~= "" then ZEN:debug() end
	if DEBUG > 1 then
		-- TODO: ZEN:backtrace() and traceback as sorted array
		warn(ZEN_traceback)
	end
	if DEBUG > 2 then
		-- TODO: ZEN:dump()
		I.warn(
			{
				HEAP = {
					IN = IN,
					TMP = TMP,
					ACK = ACK,
					OUT = OUT
				}
			}
		)
	end
	ZEN:debug()
	msg = msg or 'fatal error'
	error(msg, 2)
end

-- global
_G['REQUIRED'] = {}
-- avoid duplicating requires (internal includes)
function require_once(ninc)
	local class = REQUIRED[ninc]
	if type(class) == 'table' then
		return class
	end
	-- new require
	class = require(ninc)
	if type(class) == 'table' then
		REQUIRED[ninc] = class
	end
	return class
end

-- error = zen_error -- from zen_io

-- ZEN = { assert = assert } -- zencode shim when not loaded
require('zenroom_common')
INSPECT = require('inspect')
CBOR = require('zenroom_cbor')
JSON = require('zenroom_json')
OCTET = require('zenroom_octet')
BIG = require'big'
ECDH = require'ecdh'
AES = require'aes'
ECP = require('zenroom_ecp')
ECP2 = require('zenroom_ecp2')
HASH = require('zenroom_hash')
BENCH = require('zenroom_bench')
MACHINE = require('statemachine')
TIME = require('timetable')
O = OCTET -- alias
INT = BIG -- alias
I = INSPECT -- alias
H = HASH -- alias
PAIR = ECP2 -- alias
PAIR.ate = ECP2.miller --alias
V = require('semver')
ZENROOM_VERSION = V(VERSION)

ZEN = require('zencode')
-- the global ZEN context

-- base zencode functions and schemas
require('zencode_data') -- pick/in, conversions etc.
require('zencode_given')
require('zencode_when')
require('zencode_hash') -- when extension
require('zencode_array') -- when extension
require('zencode_random') -- when extension
require('zencode_dictionary') -- when extension
require('zencode_verify') -- when extension
require('zencode_then')
require('zencode_keys')
-- this is to evaluate expressions or derivate a column
-- it would execute lua code inside the zencode and is
-- therefore dangerous, switched off by default
-- require('zencode_eval')
if DEBUG > 0 then
	require('zencode_debug')
end

-- scenario are loaded on-demand
-- scenarios can only implement "When ..." steps
_G['Given'] = nil
_G['Then'] = nil

-----------
-- defaults
_G['CONF'] = {
	-- goldilocks is our favorite ECDH/DSA curve
	-- other choices here include secp256k1 or ed25519 or bls383
	-- beware this choice affects only the ECDH object
	-- and ECDH public keys cannot function as ECP
	-- because of IANA 7303
	input = {
		encoding = input_encoding('base64'),
		format = get_format('json'),
		tagged = false
	},
	output = {
		encoding = output_encoding('base64'),
		format = get_format('json'),
		versioning = false
	},
	parser = {strict_match = true},
	hash = 'sha256',
}
-- turn on heapguard when DEBUG or linux-debug build
if DEBUG > 1 or MAKETARGET == "linux-debug" then
	_G['CONF'].heapguard = true
else
	_G['CONF'].heapguard = false
end

-- do not modify
_G['LICENSE'] =
	[[
Licensed under the terms of the GNU Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.  Unless required by applicable
law or agreed to in writing, software distributed under the License
is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied.
]]
_G['COPYRIGHT'] =
	[[
Forked by Jaromil on 18 January 2020 from Coconut Petition
]]
SALT = ECP.hashtopoint(OCTET.from_string(COPYRIGHT .. LICENSE))
-- Calculate a system-wide crypto challenge for ZKP operations
-- returns a BIG INT
-- this is a sort of salted hash for advanced ZKP operations and
-- should not be changed. It may be made configurable in future.
function ZKP_challenge(list)
	local challenge =
		ECP.generator():octet() .. ECP2.generator():octet() .. SALT:octet()
	local ser = serialize(list)
	return INT.new(
		sha256(challenge .. ser.octets .. OCTET.from_string(ser.strings))
	) % ECP.order()
end

-- encoding base64url (RFC4648) is the fastest and most portable in zenroom
-- set_encoding('url64')
-- set_format('json')

collectgarbage 'collect'
