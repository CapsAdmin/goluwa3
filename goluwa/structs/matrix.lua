local structs = import("goluwa/structs/structs.lua")
local ffi = require("ffi")
local orientation = import("goluwa/render3d/orientation.lua")
local codegen = import("goluwa/codegen.lua")
local MATRIX_TEMPLATE = [==[
	local structs = ...

	local ffi = require("ffi")
	local META = structs.Template("matrix{{DIMS}}")
	META.__index = META

	META.NumberType = "{{NUMTYPE}}"

	META.Args = {
		{
			{{FIELDS_QUOTED}}
		}
	}

	function META:GetI(i)
		return self[META.Args[1][i+1]]
	end

	function META:SetI(i, val)
		self[META.Args[1][i+1]] = val

		return self
	end

	do
		local tr = {}

		for x = 0, {{XMINUS1}} do
			tr[x] = tr[x] or {}
			for y = 0, {{YMINUS1}} do
				tr[x][y] = "m" .. y .. x
			end
		end

		function META:GetField(r, c)
			return self[tr[r][c]]
		end

		function META:SetField(r, c, v)
			self[tr[r][c]] = v
			return self
		end
	end

	function META:SetColumn(i, {{COLUMN_ARGS}})
		{{COLUMN_BODY}}
		return self
	end

	function META:GetColumn(i)
		return
		{{GET_COLUMN}}
	end

	function META:GetRow(i)
		return
		{{GET_ROW}}
	end

	function META:SetRow(i, {{ROW_ARGS}})
		{{ROW_BODY}}
		return self
	end

	function META.Identity(m)
		{{IDENTITY_LINES}}
		return m
	end

	META.LoadIdentity = META.Identity

	structs.AddOperator(META, "==")

	META.CType = ffi.typeof("struct { $ {{FIELDS}}; }", ffi.typeof(META.NumberType))

	do
		local ffi_cast = ffi.cast

		do
			local float_array = ffi.typeof("float[{{SIZE}}]")
			local float_ptr = ffi.typeof("float*")

			function META:GetFloatCopy()
				return float_array(
					{{SELF_FIELDS}}
				)
			end

			local float_array_size = ffi.sizeof(float_array)

			if META.NumberType == "float" then
				function META:GetFloatPointer()
					return ffi_cast(float_ptr, self)
				end

				function META:CopyToFloatPointer(ptr)
					ffi.copy(ptr, self, float_array_size)
					return self
				end
			else
				function META:GetFloatPointer()
					return self:GetFloatCopy()
				end

				function META:CopyToFloatPointer(ptr)
					ffi.copy(ptr, self:GetFloatCopy(), float_array_size)
					return self
				end
			end
		end

		do
			local double_array = ffi.typeof("double[{{SIZE}}]")
			local double_ptr = ffi.typeof("double*")

			function META:GetDoubleCopy()
				return double_array(
					{{SELF_FIELDS}}
				)
			end

			if META.NumberType == "double" then
				function META:GetDoublePointer()
					return ffi_cast(double_ptr, self)
				end
			else
				function META:GetDoublePointer()
					return self:GetDoubleCopy()
				end
			end

		end
	end

	function META.Unpack(m)
		return
		{{M_FIELDS}}
	end

	function META.CopyTo(a, b)
		{{COPYTO_LINES}}
		return a
	end

	function META.Copy(m)
		return META.CType(
			{{M_FIELDS}}
		)
	end

	META.__copy = META.Copy

	function META.__tostring(m)
		return string.format("matrix{{DIMS}}[%p]:\n" .. (("%f "):rep({{X}}) .. "\n"):rep({{Y}}), m,
			{{M_FIELDS}}
		)
	end

	function META:Lerp(alpha, other)
		for i = 0, {{SIZE_MINUS_1}} do
			self:SetI(i, math.lerp(alpha, self:GetI(i), other:GetI(i)))
		end
	end

	function META.GetMultiplied(a, b, o)
		o = o or META.CType({{IDENTITY}})

		local temp = {}
		{{MULTIPLY_TERMS}}
		{{MULTIPLY_ASSIGN}}

		return o
	end

	function META:__mul(b)
		return self:GetMultiplied(b)
	end

	function META:Multiply(b, out)
		return self:GetMultiplied(b, out or self)
	end

	function META.GetTransposed(m, o)
		o = o or META.CType({{IDENTITY}})

		{{TRANSPOSE_LINES}}

		return o
	end

	function META:__new(...)
		if ... then
			return ffi.new(self, ...)
		end

		return ffi.new(self, {{IDENTITY}})
	end

	return META
]==]

local function matrix_template(X, Y, identity)
	local fields = {}

	for x = 0, X - 1 do
		for y = 0, Y - 1 do
			fields[#fields + 1] = "m" .. x .. y
		end
	end

	local quoted_fields = {}

	for i, f in ipairs(fields) do
		quoted_fields[i] = "\"" .. f .. "\""
	end

	local function field_refs(prefix)
		local refs = {}

		for i, f in ipairs(fields) do
			refs[i] = prefix .. f
		end

		return table.concat(refs, ", ")
	end

	local identity_lines = {}
	local copyto_lines = {}
	local transpose_lines = {}
	local multiply_terms = {}
	local multiply_assign = {}
	local column_body = {}
	local row_body = {}
	local i = 1

	for x = 0, X - 1 do
		for y = 0, Y - 1 do
			identity_lines[i] = "m." .. fields[i] .. " = " .. identity[i]
			copyto_lines[i] = "b." .. fields[i] .. " = a." .. fields[i]
			transpose_lines[i] = "o." .. fields[i] .. " = m.m" .. y .. x
			local term = "a.m" .. x .. "0 * b.m0" .. y

			for n = 1, Y - 1 do
				term = term .. " + a.m" .. x .. n .. " * b.m" .. n .. y
			end

			multiply_terms[i] = "temp[" .. (x * Y + y) .. "] = " .. term
			multiply_assign[i] = "o." .. fields[i] .. " = temp[" .. (x * Y + y) .. "]"
			column_body[y + 1] = "self:SetField(" .. y .. ", i, _" .. (y + 1) .. ")"
			row_body[x + 1] = "self:SetField(i, " .. x .. ", _" .. (x + 1) .. ")"
			i = i + 1
		end
	end

	local function args(n)
		local str = {}

		for j = 1, n do
			str[j] = "_" .. j
		end

		return table.concat(str, ", ")
	end

	local column_returns = {}
	local row_returns = {}

	for j = 0, Y - 1 do
		column_returns[j + 1] = "self:GetField(" .. j .. ", i)"
	end

	for j = 0, X - 1 do
		row_returns[j + 1] = "self:GetField(i, " .. j .. ")"
	end

	local env = {
		DIMS = X .. Y,
		NUMTYPE = structs.NumberType,
		X = X,
		Y = Y,
		XMINUS1 = X - 1,
		YMINUS1 = Y - 1,
		SIZE = X * Y,
		SIZE_MINUS_1 = X * Y - 1,
		IDENTITY = table.concat(identity, ", "),
		FIELDS = table.concat(fields, ", "),
		FIELDS_QUOTED = table.concat(quoted_fields, ", "),
		M_FIELDS = field_refs("m."),
		SELF_FIELDS = field_refs("self."),
		COLUMN_ARGS = args(Y),
		ROW_ARGS = args(X),
		GET_COLUMN = table.concat(column_returns, ", "),
		GET_ROW = table.concat(row_returns, ", "),
		IDENTITY_LINES = codegen.each(identity_lines, ""),
		COPYTO_LINES = codegen.each(copyto_lines, ""),
		TRANSPOSE_LINES = codegen.each(transpose_lines, ""),
		MULTIPLY_TERMS = codegen.each(multiply_terms, ""),
		MULTIPLY_ASSIGN = codegen.each(multiply_assign, ""),
		COLUMN_BODY = codegen.each(column_body, ""),
		ROW_BODY = codegen.each(row_body, ""),
	}
	local code = codegen.render(MATRIX_TEMPLATE, env)
	local chunk = assert(codegen.compile(code, "matrix " .. X .. "x" .. Y .. " builder"))
	return chunk(structs)
end

local out = {matrix_template = matrix_template}
-- Matrix44 and Matrix33 is handled separately
local variants = {
	{2, 2},
	{2, 3},
	{2, 4},
	{3, 2},
	{3, 4},
	{4, 2},
	{4, 3},
}

for _, xy in ipairs(variants) do
	local X, Y = xy[1], xy[2]
	local identity = {}
	local i = 1

	for x = 1, X do
		for y = 1, Y do
			identity[i] = i % (Y + 1) - 1 == 0 and 1 or 0
			i = i + 1
		end
	end

	local META = matrix_template(X, Y, identity)
	ffi.metatype(META.CType, META)
	out["Matrix" .. X .. Y] = META.CType
end

return out
