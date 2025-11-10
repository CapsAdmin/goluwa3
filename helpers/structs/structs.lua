local structs = {}
local string_split = require("helpers.string_split")
local ffi = require("ffi")
local istype = ffi.istype
local typeof = ffi.typeof
local tostring = tostring

function structs.Template(class_name)
	local META = {}
	META.ClassName = class_name
	return META
end

function structs.Register(META)
	META.__index = META
	META.Type = META.ClassName:lower()
	local i = 1
	local arg_lines = {}
	META.ByteSize = ffi.sizeof(META.NumberType) * #META.Args[1]
	i = i + 1
	local cdecl = "union {\n"

	for arg_i, arg in pairs(META.Args) do
		cdecl = cdecl .. "\tstruct {\n"

		for i, v in pairs(arg) do
			cdecl = cdecl .. "\t" .. META.NumberType .. " " .. v .. ";\n"
		end

		cdecl = cdecl .. "\t};\n"
	end

	cdecl = cdecl .. "}\n"
	META.CType = ffi.typeof(cdecl)
	return assert(ffi.metatype(META.CType, META))
end

-- helpers
function structs.AddGetFunc(META, name, name2)
	META["Get" .. (name2 or name)] = function(self, ...)
		return self[name](self:Copy(), ...)
	end
end

structs.OperatorTranslate = {
	["+"] = "__add",
	["-"] = "__sub",
	["*"] = "__mul",
	["/"] = "__div",
	["^"] = "__pow",
	["%"] = "__mod",
}

local function parse_args(META, lua, sep, protect)
	sep = sep or ", "
	local str = ""
	local count = #META.Args[1]

	for _, line in ipairs(string_split(lua, "\n")) do
		if line:find("KEY") or line:find("ARG") then
			local str = ""

			for i, trans in pairs(META.Args[1]) do
				local arg = trans

				if type(trans) == "table" then arg = trans[1] end

				if protect and META.ProtectedFields and META.ProtectedFields[arg] then
					str = str .. "PROTECT " .. arg
				elseif line:find("ARG") then
					str = str .. arg

					if i ~= count then str = str .. ", " end
				else
					str = str .. line:gsub("KEY", arg)
				end

				if i ~= count and not line:find("ARG") then str = str .. sep end

				if line:find("KEY") then str = str .. "\n" end
			end

			if line:find("ARG") then str = line:gsub("ARG", str) end

			line = str
		end

		str = str .. line .. "\n"
	end

	return str
end

function structs.AddOperator(META, operator, ...)
	if operator == "tostring" then
		local lua = [==[
		local META, structs = ...
		local string_format = string.format
		META["__tostring"] = function(a)
				return
				string_format(
					"CLASSNAME(LINE)",
					a.KEY
				)
			end
		]==]
		local str = ""

		for i in pairs(META.Args[1]) do
			str = str .. "%%f"

			if i ~= #META.Args[1] then str = str .. ", " end
		end

		lua = lua:gsub("CLASSNAME", META.ClassName)
		lua = lua:gsub("LINE", str)
		lua = parse_args(META, lua, ", ")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs)
	elseif operator == "unpack" then
		local lua = [==[
		local META, structs = ...
		META["Unpack"] = function(a,...)
				return
				a.KEY
				,...
			end
		]==]
		lua = parse_args(META, lua, ", ")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs)
	elseif operator == "==" then
		local lua = [==[
		local META, structs, istype = ...
		local type = type
		META["__eq"] = function(a, b)
				return
				type(a) == "]==] .. (
				ffi and
				"cdata" or
				"table"
			) .. [==[" and
				istype(a, b) and
				a.KEY == b.KEY
			end
		]==]
		lua = parse_args(META, lua, " and ")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs, istype)
		local lua = [==[
		local META, structs = ...
		META["IsEqual"] = function(self, ARG)
			return
				self.KEY == KEY
			end
		]==]
		lua = parse_args(META, lua, " and ")
		assert(loadstring(lua, META.ClassName .. " operator IsEqual"))(META, structs)
	elseif operator == "unm" then
		local lua = [==[
		local META, structs = ...
		META["__unm"] = function(a)
				return
				CTOR(
					-a.KEY
				)
			end
		]==]
		lua = parse_args(META, lua, ", ", true)
		lua = lua:gsub("PROTECT", "a.")
		lua = lua:gsub("CTOR", "META.CType")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs)
	elseif operator == "zero" then
		local lua = [==[
		local META, structs = ...
		META["Zero"] = function(a)
				a.KEY = 0
				return a
			end
		]==]
		lua = parse_args(META, lua, "")
		lua = lua:gsub("CTOR", "structs." .. META.ClassName)
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs)
	elseif operator == "set" then
		local lua = [==[
		local META, structs = ...
		META["Set"] = function(a, ARG)
				a.KEY = KEY
				return a
			end
		]==]
		lua = parse_args(META, lua, "")
		lua = lua:gsub("CTOR", "META.CType")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs)
	elseif operator == "copy" then
		local lua = [==[
		local META, structs = ...
		META["Copy"] = function(a)
			return CTOR(
				a.KEY
			)
		end
		META["CopyTo"] = function(a, b)
			a:Set(b:Unpack())
			return a
		end
		META.__copy = META.Copy
		]==]
		lua = parse_args(META, lua, ", ")
		lua = lua:gsub("CTOR", "META.CType")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs)
	elseif operator == "math" then
		local args = {...}
		local func_name = args[1]
		local accessor_name = args[2]
		local accessor_name_get = args[3]
		local self_arg = args[4]
		local lua = [==[
		local META, structs, func = ...
		META["ACCESSOR_NAME"] = function(a, ]==] .. (
				self_arg and
				"b, c" or
				"..."
			) .. [==[)
			a.KEY = func(a.KEY, ]==] .. (
				self_arg and
				"b.KEY, c.KEY" or
				"..."
			) .. [==[)

			return a
		end
		]==]
		lua = parse_args(META, lua, "")
		lua = lua:gsub("CTOR", "META.CType")
		lua = lua:gsub("ACCESSOR_NAME", accessor_name)
		assert(loadstring(lua, META.ClassName .. " operator math." .. func_name))(META, structs, math[func_name])
		structs.AddGetFunc(META, accessor_name, accessor_name_get)
	elseif operator == "random" then
		local lua = [==[
		local META, structs, randomf = ...
		META["Random"] = function(a, ...)
				a.KEY = randomf(...)

				return a
			end
		]==]
		lua = parse_args(META, lua, "")
		lua = lua:gsub("CTOR", "META.CType")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs, math.randomf)
		structs.AddGetFunc(META, "Random")
	--_G[META.ClassName .. "Rand"] = function(min, max)
	--	return structs[META.ClassName]():GetRandom(min or -1, max or 1)
	--end
	elseif structs.OperatorTranslate[operator] then
		local lua = [==[
		local META, structs, istype = ...
		local type = type
		META[structs.OperatorTranslate["OPERATOR"]] = function(a, b)
			if type(b) == "number" then
				return CTOR(
					a.KEY OPERATOR b
				)
			elseif type(a) == "number" then
				return CTOR(
					a OPERATOR b.KEY
				)
			elseif a and istype(a, b) then
				return CTOR(
					a.KEY OPERATOR b.KEY
				)
			else
				error(("%s OPERATOR %s"):format(tostring(a), tostring(b)), 2)
			end
		end
		]==]
		lua = parse_args(META, lua, ", ", true)
		lua = lua:gsub("CTOR", "META.CType")
		lua = lua:gsub("OPERATOR", operator == "%" and "%%" or operator)
		lua = lua:gsub("PROTECT", "a.")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs, istype)
	elseif operator == "iszero" then
		local lua = [==[
		local META, structs = ...
		META["IsZero"] = function(a)
				return
				a.KEY == 0
			end
		]==]
		lua = parse_args(META, lua, " and ")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs)
	elseif operator == "isvalid" then
		local lua = [==[
		local META, structs, isvalid = ...
		META["IsValid"] = function(a)
				return
				isvalid(a.KEY)
			end
		]==]
		lua = parse_args(META, lua, " and ")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs, math.isvalid)
	elseif operator == "generic_vector" then
		local lua = [==[
		local META, structs = ...

		function META:SetLength(num)
			if num == 0 then
				self.KEY = 0

				return
			end

			local scale = math.sqrt(self:GetLengthSquared()) * num

			self.KEY = self.KEY / scale

			return self
		end

		function META:SetMaxLength(num)
			local length = self:GetLengthSquared()

			if length * length > num then
				local scale = math.sqrt(length) * num

				self.KEY = self.KEY / scale
			end

			return self
		end

		function META:Normalize(scale)
			scale = scale or 1

			local length = self:GetLengthSquared()

			if length == 0 then
				self.KEY = 0
				self.KEY = 0
				return self
			end

			local inverted_length = scale / math.sqrt(length)

			self.KEY = self.KEY * inverted_length

			return self
		end
		structs.AddGetFunc(META, "Normalize", "Normalized")
		]==]
		lua = parse_args(META, lua, "")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs)
		local lua = [[
		local META, structs = ...

		function META:GetLengthSquared()
			return
			self.KEY * self.KEY
		end

		function META.GetDot(a, b)
			return
			a.KEY * b.KEY
		end
		]]
		lua = parse_args(META, lua, " + ")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs)
		local lua = [[
		local META, structs = ...

		function META:GetVolume()
			return
			self.KEY
		end
		]]
		lua = parse_args(META, lua, " * ")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs)

		function META:GetLength()
			return math.sqrt(self:GetLengthSquared())
		end

		function META.Distance(a, b)
			return (a - b):GetLength()
		end

		META.__len = META.GetLength

		function META.__lt(a, b)
			if istype(META.CType, a) and type(b) == "number" then
				return a:GetLength() < b
			elseif istype(META.CType, b) and type(a) == "number" then
				return b:GetLength() < a
			end
		end

		function META.__le(a, b)
			if istype(META.CType, a) and type(b) == "number" then
				return a:GetLength() <= b
			elseif istype(META.CType, b) and type(a) == "number" then
				return b:GetLength() <= a
			end
		end
	elseif operator == "lerp" then
		local lua = [[
		local META, structs = ...

		function META.Lerp(a, mult, b)
			a.KEY = (b.KEY - a.KEY) * mult + a.KEY

			return a
		end
		]]
		lua = parse_args(META, lua, "")
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META, structs)
		structs.AddGetFunc(META, "Lerp", "Lerped")
	elseif operator == "cast" then
		local lua = [[
		local META = ...
		local ffi = require("ffi")

		function META:Cast(a)
			return ffi.cast(a, self)
		end
		]]
		assert(loadstring(lua, META.ClassName .. " operator " .. operator))(META)
	else
		logn("unhandled operator " .. operator)
	end
end

function structs.AddAllOperators(META)
	structs.AddOperator(META, "+")
	structs.AddOperator(META, "-")
	structs.AddOperator(META, "*")
	structs.AddOperator(META, "/")
	structs.AddOperator(META, "^")
	structs.AddOperator(META, "unm")
	structs.AddOperator(META, "%")
	structs.AddOperator(META, "==")
	structs.AddOperator(META, "copy")
	structs.AddOperator(META, "iszero")
	structs.AddOperator(META, "isvalid")
	structs.AddOperator(META, "unpack")
	structs.AddOperator(META, "tostring")
	structs.AddOperator(META, "zero")
	structs.AddOperator(META, "random")
	structs.AddOperator(META, "lerp")
	structs.AddOperator(META, "set")
	structs.AddOperator(META, "cast")
	structs.AddOperator(META, "math", "abs", "Abs")
	structs.AddOperator(META, "math", "round", "Round", "Rounded")
	structs.AddOperator(META, "math", "ceil", "Ceil", "Ceiled")
	structs.AddOperator(META, "math", "floor", "Floor", "Floored")
	structs.AddOperator(META, "math", "min", "Min", "Min")
	structs.AddOperator(META, "math", "max", "Max", "Max")
	structs.AddOperator(META, "math", "clamp", "Clamp", "Clamped", true)
end

function structs.Swizzle(META, arg_count, ctor) -- todo
end

return structs
