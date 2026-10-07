local opcode_checker

do
	local bcnames = require("jit.vmdef").bcnames
	local jutil = require("jit.util")
	local band = bit.band
	local opcodes = {}

	for str in bcnames:gmatch("......") do
		str = str:gsub("%s", "")
		table.insert(opcodes, str)
	end

	local function getopnum(opname)
		for k, v in next, opcodes do
			if v == opname then return k end
		end

		error("not found: " .. opname)
	end

	local function getop(func, pc)
		local ins = jutil.funcbc(func, pc)
		return ins and (band(ins, 0xff) + 1)
	end

	opcode_checker = function(white)
		local opwhite = {}

		for i = 0, #opcodes do
			table.insert(opwhite, false)
		end

		local function iswhitelisted(opnum)
			local ret = opwhite[opnum]

			if ret == nil then error("opcode not found " .. opnum) end

			return ret
		end

		local function add_whitelist(num)
			if opwhite[num] == nil then error("invalid opcode num") end

			opwhite[num] = true
		end

		for line in white:gmatch("[^\r\n]+") do
			local opstr_towhite = line:match("[%w]+")

			if opstr_towhite and opstr_towhite:len() > 0 then
				local whiteopnum = getopnum(opstr_towhite)
				add_whitelist(whiteopnum)
				assert(iswhitelisted(whiteopnum))
			end
		end

		local function checker_function(func, max_opcodes)
			max_opcodes = max_opcodes or math.huge

			for i = 1, max_opcodes do
				local ret = getop(func, i)

				if not ret then return true end

				if not iswhitelisted(ret) then
					return false, "non-whitelisted: " .. opcodes[ret]
				end
			end

			return false, "checked max_opcodes"
		end

		return checker_function
	end
end

local whitelist = [[TNEW
TDUP

TSETV
TSETS
TSETB
TSETM

KSTR
KCDATA
KSHORT
KNUM
KPRI
KNIL

UNM

GGET
CALL
RET1]]
local is_func_ok = opcode_checker(whitelist)
local ffi = require("ffi")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local luadata = library()
luadata.file_extensions = {"luadata"}
local s = luadata
luadata.is_func_ok = is_func_ok

local function format_number(var)
	if var ~= var then error("cannot encode nan", 0) end

	if var == math.huge then return "1e999" end

	if var == -math.huge then return "-1e999" end

	if var == math.floor(var) and math.abs(var) < 1e15 then
		return ("%d"):format(var)
	end

	for precision = 15, 17 do
		local str = ("%." .. precision .. "g"):format(var)

		if tonumber(str) == var then return str end
	end
end

local float32 = ffi.typeof("float[1]")

local function format_float32(var)
	if var ~= var or var == math.huge or var == -math.huge then
		return format_number(var)
	end

	for precision = 6, 9 do
		local str = ("%." .. precision .. "g"):format(var)
		local a, b = float32(var), float32(tonumber(str))

		if a[0] == b[0] then return str end
	end
end

luadata.Types = {
	["number"] = format_number,
	["string"] = function(var)
		return ("%q"):format(var)
	end,
	["boolean"] = function(var)
		return var and "true" or "false"
	end,
	["vec2"] = function(var)
		return ("Vec2(%s, %s)"):format(format_float32(var.x), format_float32(var.y))
	end,
	["vec3"] = function(var)
		return (
			"Vec3(%s, %s, %s)"
		):format(format_float32(var.x), format_float32(var.y), format_float32(var.z))
	end,
	["quat"] = function(var)
		return (
			"Quat(%s, %s, %s, %s)"
		):format(
			format_float32(var.x),
			format_float32(var.y),
			format_float32(var.z),
			format_float32(var.w)
		)
	end,
	["color"] = function(var)
		return (
			"Color(%s, %s, %s, %s)"
		):format(
			format_float32(var.r),
			format_float32(var.g),
			format_float32(var.b),
			format_float32(var.a)
		)
	end,
}

function luadata.SetModifier(type, callback)
	luadata.Types[type] = callback
end

function luadata.Type(var)
	return typex(var)
end

local function compare_keys(a, b)
	local type_a, type_b = type(a), type(b)

	if type_a ~= type_b then return type_a < type_b end

	if type_a == "number" or type_a == "string" then return a < b end

	return tostring(a) < tostring(b)
end

local function encode_key(key)
	if type(key) == "string" and key:find("^[%a_][%w_]*$") and not luadata.Keywords[key] then
		return key
	end

	return "[" .. luadata.ToString(key) .. "]"
end

luadata.Keywords = {}

for word in (
	"and break do else elseif end false for function goto if in local nil not or repeat return then true until while"
):gmatch("%a+") do
	luadata.Keywords[word] = true
end

local encode_table

local function encode_value(value, depth)
	if type(value) == "table" and not luadata.Types[typex(value)] then
		return encode_table(value, depth)
	end

	return luadata.ToString(value)
end

encode_table = function(tbl, depth)
	local indent = ("\t"):rep(depth + 1)
	local lines = {}
	local array_count = 0

	for i = 1, #tbl do
		if tbl[i] == nil then break end

		array_count = i
	end

	for i = 1, array_count do
		local value = encode_value(tbl[i], depth + 1)

		if value == nil then
			error("cannot encode value of type " .. typex(tbl[i]) .. " at index " .. i, 0)
		end

		lines[#lines + 1] = indent .. value .. ","
	end

	local keys = {}

	for key in pairs(tbl) do
		if
			not (
				type(key) == "number" and
				key >= 1 and
				key <= array_count and
				key == math.floor(key)
			)
		then
			keys[#keys + 1] = key
		end
	end

	table.sort(keys, compare_keys)

	for _, key in ipairs(keys) do
		local value = encode_value(tbl[key], depth + 1)

		if value == nil then
			error(
				"cannot encode value of type " .. typex(tbl[key]) .. " at key " .. tostring(key),
				0
			)
		end

		lines[#lines + 1] = indent .. encode_key(key) .. " = " .. value .. ","
	end

	if #lines == 0 then return "{}" end

	return "{\n" .. table.concat(lines, "\n") .. "\n" .. ("\t"):rep(depth) .. "}"
end

function luadata.ToString(var)
	local func = s.Types[s.Type(var)]
	return func and func(var)
end

function luadata.Encode(tbl)
	if luadata.Hushed then return end

	return (encode_table(tbl, 0):sub(4, -3):gsub("\n\t", "\n"))
end

local env = {
	Vec2 = Vec2,
	Vec3 = Vec3,
	Quat = Quat,
	Color = Color,
}

-- TODO: Bytecode analysis for bad loop and string functions?
function luadata.Decode(str, nojail)
	local func, err = loadstring(string.format("return { %s }", str), "luadata_decode")

	if not func then return nil, func end

	if not nojail then
		setfenv(func, env)
	elseif type(nojail) == "table" then
		setfenv(func, nojail)
	elseif type(nojail) == "function" then
		nojail(func)
	end

	local ok, err = is_func_ok(func)

	if not ok or err then
		err = err or "invalid opcodes detected"
		return nil, err
	end

	local ok, err = xpcall(func, debug.traceback)

	if not ok then return nil, err end

	if type(nojail) == "function" then nojail(func, err) end

	return err
end

return luadata
