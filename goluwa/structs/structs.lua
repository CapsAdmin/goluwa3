local structs = {}
local ffi = require("ffi")
local istype = ffi.istype
local typeof = ffi.typeof
local tostring = tostring
local UNION_SWIZZLE = false
structs.NumberType = "float"
local codegen = import("goluwa/codegen.lua")

function structs.Template(class_name)
	local META = {}
	META.ClassName = class_name
	return META
end

function structs.Register(META)
	META.NumberType = structs.NumberType
	META.__index = META
	META.Type = META.ClassName:lower()
	local i = 1
	local arg_lines = {}
	META.ByteSize = ffi.sizeof(META.NumberType) * #META.Args[1]
	i = i + 1
	local cdecl

	if UNION_SWIZZLE then
		cdecl = "union {\n"

		for arg_i, arg in pairs(META.Args) do
			cdecl = cdecl .. "\tstruct {\n"

			for i, v in pairs(arg) do
				cdecl = cdecl .. "\t" .. META.NumberType .. " " .. v .. ";\n"
			end

			cdecl = cdecl .. "\t};\n"
		end

		cdecl = cdecl .. "}\n"
	else
		cdecl = "struct {\n"

		for i, v in pairs(META.Args[1]) do
			cdecl = cdecl .. "\t" .. META.NumberType .. " " .. v .. ";\n"
		end

		cdecl = cdecl .. "}\n"

		if true then
			local lookup = {}

			-- Build lookup table for swizzle aliases
			for arg_i = 2, #META.Args do
				local alt_args = META.Args[arg_i]

				for i, alt_key in ipairs(alt_args) do
					lookup[alt_key] = META.Args[1][i]
				end
			end

			function META:__index(key)
				-- Check if it's a swizzle alias
				local primary_key = lookup[key]

				if primary_key then return self[primary_key] end

				-- Otherwise, look up in the metatable itself
				return META[key]
			end

			function META:__newindex(key, value)
				local primary_key = lookup[key]

				if primary_key then
					self[primary_key] = value
				else
					self[key] = value
				end
			end
		end
	end

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

-- env for field expansion: {{KEY}} repeats its line per field, {{ARG}} joins field names
local function fields_env(META, sep, protect)
	local list = {}

	for i, v in ipairs(META.Args[1]) do
		list[i] = type(v) == "table" and v[1] or v
	end

	local key = codegen.each(list, sep)

	if protect then
		key = codegen.each(list, sep, function(name, line)
			if META.ProtectedFields and META.ProtectedFields[name] then
				return "a." .. name
			end

			return line
		end)
	end

	return {
		KEY = key,
		ARG = codegen.join(list, ", "),
	}
end

local operators = {}
operators.tostring = function(META, operator)
	local format = ""

	for i in pairs(META.Args[1]) do
		format = format .. "%f"

		if i ~= #META.Args[1] then format = format .. ", " end
	end

	local env = fields_env(META, ", ", false)
	env.CLASSNAME = META.ClassName
	env.LINE = format
	codegen.run(
		[==[
			local META, structs = ...
			local string_format = string.format
			META["__tostring"] = function(a)
					return
				string_format(
					"{{CLASSNAME}}({{LINE}})",
					a.{{KEY}}
				)
			end
		]==],
		"operator " .. operator,
		env,
		META,
		structs
	)
end
operators.unpack = function(META, operator)
	codegen.run(
		[==[
			local META, structs = ...
			META["Unpack"] = function(a,...)
					return
					a.{{KEY}}
					,...
				end
		]==],
		"operator " .. operator,
		fields_env(META, ", ", false),
		META,
		structs
	)
end
operators["=="] = function(META, operator)
	local env = fields_env(META, " and ", false)
	env.TYPE = ffi and "\"cdata\"" or "\"table\""
	codegen.run(
		[==[
			local META, structs, istype = ...
			local type = type
			META["__eq"] = function(a, b)
					return
				type(a) == {{TYPE}} and
				istype(a, b) and
				a.{{KEY}} == b.{{KEY}}
			end
		]==],
		"operator " .. operator,
		env,
		META,
		structs,
		istype
	)
	codegen.run(
		[==[
		local META, structs = ...
		META["IsEqual"] = function(self, {{ARG}})
			return
				self.{{KEY}} == {{KEY}}
			end
		]==],
		"operator IsEqual",
		fields_env(META, " and ", false),
		META,
		structs
	)
end
operators.compare = function(META, operator)
	codegen.run(
		[==[
			local META, structs, istype = ...
			local type = type
			META["__lt"] = function(a, b)
				if type(b) == "number" then
					return
						a.{{KEY}} < b
				elseif type(a) == "number" then
					return
						a < b.{{KEY}}
				elseif istype(a, b) then
					return
						a.{{KEY}} < b.{{KEY}}
				end
				return false
			end
			META["__le"] = function(a, b)
				if type(b) == "number" then
					return
						a.{{KEY}} <= b
				elseif type(a) == "number" then
					return
						a <= b.{{KEY}}
				elseif istype(a, b) then
					return
						a.{{KEY}} <= b.{{KEY}}
				end
				return false
			end
		]==],
		"operator " .. operator,
		fields_env(META, " and ", false),
		META,
		structs,
		istype
	)
	codegen.run(
		[==[
			local META, structs = ...
			META["IsLess"] = function(self, {{ARG}})
				return
					self.{{KEY}} < {{KEY}}
			end
			META["IsLessOrEqual"] = function(self, {{ARG}})
				return
					self.{{KEY}} <= {{KEY}}
			end
			META["IsGreater"] = function(self, {{ARG}})
				return
					self.{{KEY}} > {{KEY}}
			end
			META["IsGreaterOrEqual"] = function(self, {{ARG}})
				return
					self.{{KEY}} >= {{KEY}}
			end
		]==],
		"operator compare methods",
		fields_env(META, " and ", false),
		META,
		structs
	)
end
operators.unm = function(META, operator)
	local env = fields_env(META, ", ", true)
	env.CTOR = "META.CType"
	codegen.run(
		[==[
			local META, structs = ...
			META["__unm"] = function(a)
				local result = {{CTOR}}(
					-a.{{KEY}}
				)
				return result
			end
		]==],
		"operator " .. operator,
		env,
		META,
		structs
	)
end
operators.zero = function(META, operator)
	codegen.run(
		[==[
			local META, structs = ...
			META["Zero"] = function(a)
				a.{{KEY}} = 0
				return a
			end
		]==],
		"operator " .. operator,
		fields_env(META, "", false),
		META,
		structs
	)
end
operators.set = function(META, operator)
	codegen.run(
		[==[
			local META, structs = ...
			META["Set"] = function(a, {{ARG}})
				a.{{KEY}} = {{KEY}}
				return a
			end
		]==],
		"operator " .. operator,
		fields_env(META, "", false),
		META,
		structs
	)
end
operators.copy = function(META, operator)
	local env = fields_env(META, " ", false)
	env.CTOR = "META.CType"
	codegen.run(
		[==[
			local META, structs = ...
			META["Copy"] = function(a)
				local c = {{CTOR}}()
				c.{{KEY}} = a.{{KEY}}
				return c
			end
			META["CopyTo"] = function(a, b)
				a:Set(b:Unpack())
				return a
			end
			META.__copy = META.Copy
		]==],
		"operator " .. operator,
		env,
		META,
		structs
	)
end
operators.math = function(META, operator, func_name, accessor_name, accessor_name_get, self_arg)
	local lua = [==[
		local META, structs, func = ...
		META["{{ACCESSOR_NAME}}"] = function(a, ]==] .. (
			self_arg and
			"b, c" or
			"..."
		) .. [==[)
			a.{{KEY}} = func(a.{{KEY}}, ]==] .. (
			self_arg and
			"b.KEY, c.KEY" or
			"..."
		) .. [==[)
			return a
		end
	]==]
	local env = fields_env(META, "", false)
	env.ACCESSOR_NAME = accessor_name
	codegen.run(lua, "operator math." .. func_name, env, META, structs, math[func_name])
	structs.AddGetFunc(META, accessor_name, accessor_name_get)
end
operators.random = function(META, operator)
	codegen.run(
		[==[
			local META, structs, randomf = ...
			META["Random"] = function(a, ...)
					a.{{KEY}} = randomf(...)

					return a
				end
		]==],
		"operator " .. operator,
		fields_env(META, "", false),
		META,
		structs,
		math.randomf
	)
	structs.AddGetFunc(META, "Random")
end
operators.translate = function(META, operator)
	local env = fields_env(META, ", ", true)
	env.CTOR = "META.CType"
	env.OPERATOR = operator
	codegen.run(
		[==[
			local META, structs, istype = ...
			local type = type
			META[structs.OperatorTranslate["{{OPERATOR}}"]] = function(a, b)
				if type(b) == "number" then
					return {{CTOR}}(
						a.{{KEY}} {{OPERATOR}} b
					)
				elseif type(a) == "number" then
					return {{CTOR}}(
						a {{OPERATOR}} b.{{KEY}}
					)
				elseif istype(a, b) then
					return {{CTOR}}(
						a.{{KEY}} {{OPERATOR}} b.{{KEY}}
					)
				end
				error(("%s {{OPERATOR}} %s"):format(tostring(a), tostring(b)), 2)
			end
		]==],
		"operator " .. operator,
		env,
		META,
		structs,
		istype
	)
end
operators.iszero = function(META, operator)
	codegen.run(
		[==[
			local META, structs = ...
			META["IsZero"] = function(a)
				return
				a.{{KEY}} == 0
			end
		]==],
		"operator " .. operator,
		fields_env(META, " and ", false),
		META,
		structs
	)
end
operators.isvalid = function(META, operator)
	codegen.run(
		[==[
			local META, structs, isvalid = ...
			META["IsValid"] = function(a)
				return
				isvalid(a.{{KEY}})
			end
		]==],
		"operator " .. operator,
		fields_env(META, " and ", false),
		META,
		structs,
		math.isvalid
	)
end
operators.generic_vector = function(META, operator)
	codegen.run(
		[==[
			local META, structs = ...

			function META:SetLength(num)
				if num == 0 then
					self.{{KEY}} = 0

					return
				end

				local scale = math.sqrt(self:GetLengthSquared()) * num

				self.{{KEY}} = self.{{KEY}} / scale

				return self
			end

			function META:SetMaxLength(num)
				local length = self:GetLengthSquared()

				if length * length > num then
					local scale = math.sqrt(length) * num

					self.{{KEY}} = self.{{KEY}} / scale
				end

				return self
			end

			function META:Normalize(scale)
				scale = scale or 1

				local length = self:GetLengthSquared()

				if length == 0 then
					self.{{KEY}} = 0
					self.{{KEY}} = 0
					return self
				end

				local inverted_length = scale / math.sqrt(length)

				self.{{KEY}} = self.{{KEY}} * inverted_length

				return self
			end
			structs.AddGetFunc(META, "Normalize", "Normalized")
		]==],
		"operator " .. operator,
		fields_env(META, "", false),
		META,
		structs
	)
	codegen.run(
		[[
			local META, structs = ...

			function META:GetLengthSquared()
				return
				self.{{KEY}} * self.{{KEY}}
			end

			function META.GetDot(a, b)
				return
				a.{{KEY}} * b.{{KEY}}
			end
		]],
		"operator " .. operator,
		fields_env(META, " + ", false),
		META,
		structs
	)
	codegen.run(
		[[
			local META, structs = ...

			function META:GetVolume()
				return
				self.{{KEY}}
			end
		]],
		"operator " .. operator,
		fields_env(META, " * ", false),
		META,
		structs
	)

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
end
operators.lerp = function(META, operator)
	codegen.run(
		[[
			local META, structs = ...

			function META.Lerp(a, mult, b)
				a.{{KEY}} = (b.{{KEY}} - a.{{KEY}}) * mult + a.{{KEY}}

				return a
			end
		]],
		"operator " .. operator,
		fields_env(META, "", false),
		META,
		structs
	)
	structs.AddGetFunc(META, "Lerp", "Lerped")
end
operators.cast = function(META, operator)
	codegen.run(
		[[
			local META = ...
			local ffi = require("ffi")

			function META:Cast(a)
				return ffi.cast(a, self)
			end
		]],
		"operator " .. operator,
		nil,
		META
	)
end
operators.float = function(META, operator)
	local lua = [=[
		local META = ...
		local ffi = require("ffi")

		local float_array = ffi.typeof("float[]=] .. #META.Args[1] .. [=[]")
		local double_array = ffi.typeof("double[]=] .. #META.Args[1] .. [=[]")
		local double_ptr = ffi.typeof("double*")
		local float_ptr = ffi.typeof("float*")

		function META.GetFloatCopy(a)
			return float_array(
				a.{{KEY}}
			)
		end

		function META.GetDoubleCopy(a)
			return double_array(
				a.{{KEY}}
			)
		end

		local ffi_cast = ffi.cast
		local ffi_copy = ffi.copy
		local float_array = ffi.sizeof(float_array)
		if META.NumberType == "float" then
			function META:GetFloatPointer()
				return ffi_cast(float_ptr, self)
			end

			function META:GetDoublePointer()
				return self:GetDoubleCopy()
			end

			function META:CopyToFloatPointer(ptr)
				ffi_copy(ptr, ffi_cast(float_ptr, self), float_array)
				return self
			end
		else
			function META:GetFloatPointer()
				return self:GetFloatCopy()
			end

			function META:GetDoublePointer()
				return ffi_cast(double_ptr, self)
			end

			function META:CopyToFloatPointer(ptr)
				ffi_copy(ptr, self:GetFloatPointer(), float_array)
				return self
			end
		end

	]=]
	codegen.run(lua, "operator " .. operator, fields_env(META, ", ", false), META)
end

function structs.AddOperator(META, operator, ...)
	if not META.NumberType then META.NumberType = structs.NumberType end

	local handler = operators[operator]

	if not handler and structs.OperatorTranslate[operator] then
		handler = operators.translate
	end

	if not handler then
		logn("unhandled operator " .. operator)
		return
	end

	handler(META, operator, ...)
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
	structs.AddOperator(META, "compare")
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
	structs.AddOperator(META, "float")
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
