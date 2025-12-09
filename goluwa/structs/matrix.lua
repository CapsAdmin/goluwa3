local structs = require("structs.structs")
local ffi = require("ffi")

local function matrix_template(X, Y, identity, number_type)
	number_type = number_type or "double"

	local function generate_generic(cb, no_newline)
		local str = ""
		local i = 0

		for x = 0, X - 1 do
			for y = 0, Y - 1 do
				str = str .. cb(x, y, i)
				i = i + 1
			end

			if not no_newline then str = str .. "\n" end
		end

		return str
	end

	local code = [==[
		local structs = ...

		local ffi = require("ffi")
		local META = structs.Template("matrix]==] .. X .. Y .. [==[")
		META.__index = META

		META.NumberType = "]==] .. number_type .. [==["

		META.Args = {{
			]==] .. generate_generic(function(x, y)
			return "\"m" .. x .. y .. "\", "
		end) .. [==[
		}}

		function META:GetI(i)
			return self[META.Args[1][i+1]]
		end		
	
		function META:SetI(i, val)
			self[META.Args[1][i+1]] = val

			return self
		end

		do
			local tr = {}

			for x = 0, ]==] .. X .. [==[-1 do
				tr[x] = tr[x] or {}
				for y = 0, ]==] .. Y .. [==[-1 do
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

		function META:SetColumn(i, ]==] .. (
			function()
				local str = {}

				for i = 1, Y do
					str[i] = "_" .. i
				end

				return table.concat(str, ", ")
			end
		)() .. [==[)
			]==] .. (
			function()
				local str = ""

				for i = 0, Y - 1 do
					str = str .. "self:SetField(" .. i .. ", i, _" .. i + 1 .. ")\n"
				end

				return str
			end
		)() .. [==[

			return self
		end

	function META:GetColumn(i)
		return
		]==] .. (
			function()
				local str = {}

				for i = 0, Y - 1 do
					str[i + 1] = "self:GetField(" .. i .. ", i)"
				end

				return table.concat(str, ",\n")
			end
		)() .. [==[
	end

	function META:GetRow(i)
		return
		]==] .. (
			function()
				local str = {}

				for i = 0, X - 1 do
					str[i + 1] = "self:GetField(i, " .. i .. ")"
				end

				return table.concat(str, ",\n")
			end
		)() .. [==[
	end		function META:SetRow(i, ]==] .. (
			function()
				local str = {}

				for i = 1, X do
					str[i] = "_" .. i
				end

				return table.concat(str, ", ")
			end
		)() .. [==[)
			]==] .. (
			function()
				local str = ""

				for i = 0, X - 1 do
					str = str .. "self:SetField(i, " .. i .. ", _" .. i + 1 .. ")\n"
				end

				return str
			end
		)() .. [==[

			return self
		end

		function META.Identity(m)
			]==] .. (
			function()
				local str = ""
				local i = 1

				for x = 0, X - 1 do
					for y = 0, Y - 1 do
						str = str .. "m.m" .. x .. y .. " = " .. identity[i] .. " "
						i = i + 1
					end

					str = str .. "\n"
				end

				return str
			end
		)() .. [==[
			return m
		end

		META.LoadIdentity = META.Identity

		structs.AddOperator(META, "==")

		META.CType = ffi.typeof("struct { $ ]==] .. generate_generic(function(x, y)
			return "m" .. x .. y .. ", "
		end, true):sub(0, -3) .. [==[; }", ffi.typeof(META.NumberType))

		local ctype = ffi.typeof("float[]==] .. X * Y .. [==[]")
		local o = ctype()

		function META.GetFloatPointer(m)
			]==] .. generate_generic(function(x, y, i)
			return "o[" .. i .. "] = m.m" .. x .. y .. " "
		end) .. [==[
			return o
		end

		function META.GetDoublePointer(m)
			return m
		end

		function META.GetFloatCopy(m)
			return ctype(
				]==] .. generate_generic(function(x, y)
			return "m.m" .. x .. y .. ", "
		end):sub(0, -4) .. [==[
			)
		end
		function META.Unpack(m)
			return
				]==] .. generate_generic(function(x, y)
			return "m.m" .. x .. y .. ", "
		end):sub(0, -4) .. [==[
		end

		function META.CopyTo(a, b)
			]==] .. generate_generic(function(x, y)
			return "b.m" .. x .. y .. " = a.m" .. x .. y .. " "
		end) .. [==[
			return a
		end

		function META.Copy(m)
			return META.CType(
				]==] .. generate_generic(function(x, y)
			return "m.m" .. x .. y .. ", "
		end):sub(0, -4) .. [==[
			)
		end

		META.__copy = META.Copy

		function META.__tostring(m)
			return string.format("matrix]==] .. X .. Y .. [==[[%p]:\n" .. (("%f "):rep(]==] .. X .. [==[) .. "\n"):rep(]==] .. Y .. [==[), m,
				]==] .. generate_generic(function(x, y)
			return "m.m" .. x .. y .. ", "
		end):sub(0, -4) .. [==[
			)
		end

		function META:Lerp(alpha, other)
			for i = 0, ]==] .. (
			X * Y
		) - 1 .. [==[ do
				self:SetI(i, math.lerp(alpha, self:GetI(i), other:GetI(i)))
			end
		end

		function META.GetMultiplied(a, b, o)
			o = o or META.CType(]==] .. table.concat(identity, ", ") .. [==[)

			]==] .. (
			function()
				local str = ""

				for x = 0, X - 1 do
					for y = 0, Y - 1 do
						str = str .. "o.m" .. x .. y .. " = b.m" .. x .. "0 * a.m0" .. y

						for n = 1, Y - 1 do
							str = str .. " + b.m" .. x .. n .. " * a.m" .. n .. y
						end

						str = str .. "\n"
					end
				end

				return str
			end
		)() .. [==[

			return o
		end

		function META:__mul(b)
			return self:GetMultiplied(b)
		end

		function META:Multiply(b, out)
			return self:GetMultiplied(b, out or self)
		end

		function META.GetTransposed(m, o)
			o = o or META.CType(]==] .. table.concat(identity, ", ") .. [==[)

			]==] .. (
			function()
				local str = ""

				for x = 0, X - 1 do
					for y = 0, Y - 1 do
						str = str .. "o.m" .. x .. y .. " = m.m" .. y .. x .. " "
					end

					str = str .. "\n"
				end

				return str
			end
		)() .. [==[

			return o
		end

		function META:__new(...)
			if ... then
				return ffi.new(self, ...)
			end
			
			return ffi.new(self, ]==] .. table.concat(identity, ", ") .. [==[)
		end
		return META
	]==]
	local name = "Matrix" .. X .. Y
	return name, assert(loadstring(code, name))(structs)
end

local out = {}

do -- 44
	local name, META = matrix_template(4, 4, {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}, "double")
	out[name] = META.CType

	-- Optimized GetInverse using local variables to help LuaJIT optimize
	-- This avoids aliasing issues and allows better register allocation
	function META.GetInverse(m, o)
		-- Cache input values in locals - helps LuaJIT avoid re-reading from memory
		local m00, m01, m02, m03 = m.m00, m.m01, m.m02, m.m03
		local m10, m11, m12, m13 = m.m10, m.m11, m.m12, m.m13
		local m20, m21, m22, m23 = m.m20, m.m21, m.m22, m.m23
		local m30, m31, m32, m33 = m.m30, m.m31, m.m32, m.m33
		-- Compute cofactors into locals
		local o00 = m11 * m22 * m33 - m11 * m32 * m23 - m12 * m21 * m33 + m12 * m31 * m23 + m13 * m21 * m32 - m13 * m31 * m22
		local o01 = -m01 * m22 * m33 + m01 * m32 * m23 + m02 * m21 * m33 - m02 * m31 * m23 - m03 * m21 * m32 + m03 * m31 * m22
		local o02 = m01 * m12 * m33 - m01 * m32 * m13 - m02 * m11 * m33 + m02 * m31 * m13 + m03 * m11 * m32 - m03 * m31 * m12
		local o03 = -m01 * m12 * m23 + m01 * m22 * m13 + m02 * m11 * m23 - m02 * m21 * m13 - m03 * m11 * m22 + m03 * m21 * m12
		local o10 = -m10 * m22 * m33 + m10 * m32 * m23 + m12 * m20 * m33 - m12 * m30 * m23 - m13 * m20 * m32 + m13 * m30 * m22
		local o11 = m00 * m22 * m33 - m00 * m32 * m23 - m02 * m20 * m33 + m02 * m30 * m23 + m03 * m20 * m32 - m03 * m30 * m22
		local o12 = -m00 * m12 * m33 + m00 * m32 * m13 + m02 * m10 * m33 - m02 * m30 * m13 - m03 * m10 * m32 + m03 * m30 * m12
		local o13 = m00 * m12 * m23 - m00 * m22 * m13 - m02 * m10 * m23 + m02 * m20 * m13 + m03 * m10 * m22 - m03 * m20 * m12
		local o20 = m10 * m21 * m33 - m10 * m31 * m23 - m11 * m20 * m33 + m11 * m30 * m23 + m13 * m20 * m31 - m13 * m30 * m21
		local o21 = -m00 * m21 * m33 + m00 * m31 * m23 + m01 * m20 * m33 - m01 * m30 * m23 - m03 * m20 * m31 + m03 * m30 * m21
		local o22 = m00 * m11 * m33 - m00 * m31 * m13 - m01 * m10 * m33 + m01 * m30 * m13 + m03 * m10 * m31 - m03 * m30 * m11
		local o23 = -m00 * m11 * m23 + m00 * m21 * m13 + m01 * m10 * m23 - m01 * m20 * m13 - m03 * m10 * m21 + m03 * m20 * m11
		local o30 = -m10 * m21 * m32 + m10 * m31 * m22 + m11 * m20 * m32 - m11 * m30 * m22 - m12 * m20 * m31 + m12 * m30 * m21
		local o31 = m00 * m21 * m32 - m00 * m31 * m22 - m01 * m20 * m32 + m01 * m30 * m22 + m02 * m20 * m31 - m02 * m30 * m21
		local o32 = -m00 * m11 * m32 + m00 * m31 * m12 + m01 * m10 * m32 - m01 * m30 * m12 - m02 * m10 * m31 + m02 * m30 * m11
		local o33 = m00 * m11 * m22 - m00 * m21 * m12 - m01 * m10 * m22 + m01 * m20 * m12 + m02 * m10 * m21 - m02 * m20 * m11
		-- Compute determinant from locals (no aliasing possible)
		local det = 1 / (m00 * o00 + m01 * o10 + m02 * o20 + m03 * o30)
		-- Create or reuse output matrix
		o = o or META.CType(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
		-- Write results with determinant scaling
		o.m00 = o00 * det
		o.m01 = o01 * det
		o.m02 = o02 * det
		o.m03 = o03 * det
		o.m10 = o10 * det
		o.m11 = o11 * det
		o.m12 = o12 * det
		o.m13 = o13 * det
		o.m20 = o20 * det
		o.m21 = o21 * det
		o.m22 = o22 * det
		o.m23 = o23 * det
		o.m30 = o30 * det
		o.m31 = o31 * det
		o.m32 = o32 * det
		o.m33 = o33 * det
		return o
	end

	-- Optimized GetMultiplied for Matrix44 using local variables
	-- Overrides the generated template version for better LuaJIT performance
	function META.GetMultiplied(a, b, o)
		-- Cache input values in locals for better register allocation
		local a00, a01, a02, a03 = a.m00, a.m01, a.m02, a.m03
		local a10, a11, a12, a13 = a.m10, a.m11, a.m12, a.m13
		local a20, a21, a22, a23 = a.m20, a.m21, a.m22, a.m23
		local a30, a31, a32, a33 = a.m30, a.m31, a.m32, a.m33
		local b00, b01, b02, b03 = b.m00, b.m01, b.m02, b.m03
		local b10, b11, b12, b13 = b.m10, b.m11, b.m12, b.m13
		local b20, b21, b22, b23 = b.m20, b.m21, b.m22, b.m23
		local b30, b31, b32, b33 = b.m30, b.m31, b.m32, b.m33
		-- Compute results into locals (helps with aliasing and register allocation)
		local o00 = b00 * a00 + b01 * a10 + b02 * a20 + b03 * a30
		local o01 = b00 * a01 + b01 * a11 + b02 * a21 + b03 * a31
		local o02 = b00 * a02 + b01 * a12 + b02 * a22 + b03 * a32
		local o03 = b00 * a03 + b01 * a13 + b02 * a23 + b03 * a33
		local o10 = b10 * a00 + b11 * a10 + b12 * a20 + b13 * a30
		local o11 = b10 * a01 + b11 * a11 + b12 * a21 + b13 * a31
		local o12 = b10 * a02 + b11 * a12 + b12 * a22 + b13 * a32
		local o13 = b10 * a03 + b11 * a13 + b12 * a23 + b13 * a33
		local o20 = b20 * a00 + b21 * a10 + b22 * a20 + b23 * a30
		local o21 = b20 * a01 + b21 * a11 + b22 * a21 + b23 * a31
		local o22 = b20 * a02 + b21 * a12 + b22 * a22 + b23 * a32
		local o23 = b20 * a03 + b21 * a13 + b22 * a23 + b23 * a33
		local o30 = b30 * a00 + b31 * a10 + b32 * a20 + b33 * a30
		local o31 = b30 * a01 + b31 * a11 + b32 * a21 + b33 * a31
		local o32 = b30 * a02 + b31 * a12 + b32 * a22 + b33 * a32
		local o33 = b30 * a03 + b31 * a13 + b32 * a23 + b33 * a33
		-- Create or reuse output matrix
		o = o or META.CType(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
		-- Write results
		o.m00, o.m01, o.m02, o.m03 = o00, o01, o02, o03
		o.m10, o.m11, o.m12, o.m13 = o10, o11, o12, o13
		o.m20, o.m21, o.m22, o.m23 = o20, o21, o22, o23
		o.m30, o.m31, o.m32, o.m33 = o30, o31, o32, o33
		return o
	end

	-- Optimized GetTransposed for Matrix44 using local variables
	function META.GetTransposed(m, o)
		-- Cache input values
		local m00, m01, m02, m03 = m.m00, m.m01, m.m02, m.m03
		local m10, m11, m12, m13 = m.m10, m.m11, m.m12, m.m13
		local m20, m21, m22, m23 = m.m20, m.m21, m.m22, m.m23
		local m30, m31, m32, m33 = m.m30, m.m31, m.m32, m.m33
		-- Create or reuse output matrix
		o = o or META.CType(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
		-- Write transposed values
		o.m00, o.m01, o.m02, o.m03 = m00, m10, m20, m30
		o.m10, o.m11, o.m12, o.m13 = m01, m11, m21, m31
		o.m20, o.m21, o.m22, o.m23 = m02, m12, m22, m32
		o.m30, o.m31, o.m32, o.m33 = m03, m13, m23, m33
		return o
	end

	function META:MultiplyVector(x, y, z, w, out)
		out = out or META.CType(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
		out.m00 = self.m00 * x + self.m10 * y + self.m20 * z + self.m30 * w
		out.m01 = self.m01 * x + self.m11 * y + self.m21 * z + self.m31 * w
		out.m02 = self.m02 * x + self.m12 * y + self.m22 * z + self.m32 * w
		out.m03 = self.m03 * x + self.m13 * y + self.m23 * z + self.m33 * w
		return out
	end

	function META:Skew(x, y)
		y = y or x
		x = math.rad(x)
		y = math.rad(y)
		local skew = META.CType(1, math.tan(x), 0, 0, math.tan(y), 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
		self:CopyTo(skew)
		return self
	end

	function META:GetTranslation()
		return self.m30, self.m31, self.m32
	end

	function META:GetClipCoordinates()
		return self.m30 / self.m33, self.m31 / self.m33, self.m32 / self.m33
	end

	function META:Translate(x, y, z)
		if x == 0 and y == 0 and z == 0 then return self end

		self.m30 = self.m00 * x + self.m10 * y + self.m20 * z + self.m30
		self.m31 = self.m01 * x + self.m11 * y + self.m21 * z + self.m31
		self.m32 = self.m02 * x + self.m12 * y + self.m22 * z + self.m32
		self.m33 = self.m03 * x + self.m13 * y + self.m23 * z + self.m33
		return self
	end

	function META:SetShear(x, y, z)
		self.m01 = x
		self.m10 = y
	-- z?
	end

	function META:SetTranslation(x, y, z)
		self.m30 = x
		self.m31 = y
		self.m32 = z
		return self
	end

	do
		local sin = math.sin
		local cos = math.cos
		local sqrt = math.sqrt

		function META:Rotate(a, x, y, z, out)
			if a == 0 then return self end

			out = out or META.CType(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
			local s = sin(a)
			local c = cos(a)

			if x == 0 and y == 0 then
				if z == 0 then
					-- rotate only around y axis
					out.m00 = c
					out.m22 = c

					if y < 0 then
						out.m20 = -s
						out.m02 = s
					else
						out.m20 = s
						out.m02 = -s
					end
				else
					-- rotate only around z axis
					out.m00 = c
					out.m11 = c

					if z < 0 then
						out.m10 = s
						out.m01 = -s
					else
						out.m10 = -s
						out.m01 = s
					end
				end
			elseif y == 0 and z == 0 then
				-- rotate only around x axis
				out.m11 = c
				out.m22 = c

				if x < 0 then
					out.m21 = s
					out.m12 = -s
				else
					out.m21 = -s
					out.m12 = s
				end
			else
				local mag = sqrt(x * x + y * y + z * z)

				if mag <= 1.0e-4 then return self end

				x = x / mag
				y = y / mag
				z = z / mag
				out.m00 = (1 - c * x * x) + c
				out.m10 = (1 - c * x * y) - z * s
				out.m20 = (1 - c * z * x) + y * s
				out.m01 = (1 - c * x * y) + z * s
				out.m11 = (1 - c * y * y) + c
				out.m21 = (1 - c * y * z) - x * s
				out.m02 = (1 - c * z * x) - y * s
				out.m12 = (1 - c * y * z) + x * s
				out.m22 = (1 - c * z * z) + c
			end

			self.GetMultiplied(self:Copy(), out, self)
			return self
		end
	end

	function META:Scale(x, y, z)
		if x == 1 and y == 1 and z == 1 then return self end

		self.m00 = self.m00 * x
		self.m10 = self.m10 * y
		self.m20 = self.m20 * z
		self.m01 = self.m01 * x
		self.m11 = self.m11 * y
		self.m21 = self.m21 * z
		self.m02 = self.m02 * x
		self.m12 = self.m12 * y
		self.m22 = self.m22 * z
		self.m03 = self.m03 * x
		self.m13 = self.m13 * y
		self.m23 = self.m23 * z
		return self
	end

	do -- projection
		local tan = math.tan

		function META:Perspective(fov, near, far, aspect)
			local yScale = 1.0 / tan(fov / 2)
			local xScale = yScale / aspect
			local nearmfar = far - near
			-- Row-major layout (will be transposed before sending to GPU)
			-- Vulkan uses [0, 1] depth range and flipped Y coordinate
			self.m00 = xScale
			self.m01 = 0
			self.m02 = 0
			self.m03 = 0
			self.m10 = 0
			self.m11 = -yScale -- Negative for Vulkan Y-flip
			self.m12 = 0
			self.m13 = 0
			self.m20 = 0
			self.m21 = 0
			self.m22 = -far / nearmfar -- Negative for Vulkan depth mapping
			self.m23 = -1
			self.m30 = 0
			self.m31 = 0
			self.m32 = -(far * near) / nearmfar -- Negative for Vulkan depth mapping
			self.m33 = 0
			return self
		end

		function META:Frustum(l, r, b, t, n, f)
			local temp = 2.0 * n
			local temp2 = r - l
			local temp3 = t - b
			local temp4 = f - n
			self.m00 = temp / temp2
			self.m01 = 0.0
			self.m02 = 0.0
			self.m03 = 0.0
			self.m10 = 0.0
			self.m11 = temp / temp3
			self.m12 = 0.0
			self.m13 = 0.0
			self.m20 = (r + l) / temp2
			self.m21 = (t + b) / temp3
			self.m22 = (-f - n) / temp4
			self.m23 = -1.0
			self.m30 = 0.0
			self.m31 = 0.0
			self.m32 = (-temp * f) / temp4
			self.m33 = 0.0
			return self
		end

		function META:Ortho(left, right, bottom, top, near, far)
			self.m00 = 2 / (right - left)
			--self.m10 = 0
			--self.m20 = 0
			self.m30 = -(right + left) / (right - left)
			--	self.m01 = 0
			self.m11 = 2 / (top - bottom)
			--	self.m21 = 0
			self.m31 = -(top + bottom) / (top - bottom)
			--	self.m02 = 0
			--	self.m12 = 0
			self.m22 = -2 / (far - near)
			self.m32 = -(far + near) / (far - near)
			--	self.m03 = 0
			--	self.m13 = 0
			--	self.m23 = 0
			--	self.m33 = 1
			return self
		end
	end

	-- Optimized TransformVector using local caching for better LuaJIT performance
	function META:TransformVector(x, y, z)
		-- Cache matrix values in locals for better register allocation
		local m00, m01, m02, m03 = self.m00, self.m01, self.m02, self.m03
		local m10, m11, m12, m13 = self.m10, self.m11, self.m12, self.m13
		local m20, m21, m22, m23 = self.m20, self.m21, self.m22, self.m23
		local m30, m31, m32, m33 = self.m30, self.m31, self.m32, self.m33
		local div = x * m03 + y * m13 + z * m23 + m33
		return (x * m00 + y * m10 + z * m20 + m30) / div,
		(x * m01 + y * m11 + z * m21 + m31) / div,
		(x * m02 + y * m12 + z * m22 + m32) / div
	end

	function META:TransformPoint(x, y, z)
		return self.m00 * x + self.m01 * y + self.m02 * z + self.m03,
		self.m10 * x + self.m11 * y + self.m12 * z + self.m13,
		self.m20 * x + self.m21 * y + self.m22 * z + self.m23
	end

	local Quat = require("structs.quat")

	function META:GetRotation(out)
		local w = math.sqrt(1 + self.m00 + self.m11 + self.m22) / 2
		local w2 = w * 4
		local x = (self.m21 - self.m12) / w2
		local y = (self.m02 - self.m20) / w2
		local z = (self.m10 - self.m01) / w2
		out = out or Quat()
		out:Set(x, y, z, w)
		return out
	end

	function META:SetRotation(q)
		local sqw = q.w * q.w
		local sqx = q.x * q.x
		local sqy = q.y * q.y
		local sqz = q.z * q.z
		-- invs (inverse square length) is only required if quaternion is not already normalised
		local invs = 1 / (sqx + sqy + sqz + sqw)
		self.m00 = (sqx - sqy - sqz + sqw) * invs -- since sqw + sqx + sqy + sqz =1/invs*invs
		self.m11 = (-sqx + sqy - sqz + sqw) * invs
		self.m22 = (-sqx - sqy + sqz + sqw) * invs
		local tmp1, tmp2
		tmp1 = q.x * q.y
		tmp2 = q.z * q.w
		self.m10 = 2.0 * (tmp1 + tmp2) * invs
		self.m01 = 2.0 * (tmp1 - tmp2) * invs
		tmp1 = q.x * q.z
		tmp2 = q.y * q.w
		self.m20 = 2.0 * (tmp1 - tmp2) * invs
		self.m02 = 2.0 * (tmp1 + tmp2) * invs
		tmp1 = q.y * q.z
		tmp2 = q.x * q.w
		self.m21 = 2.0 * (tmp1 + tmp2) * invs
		self.m12 = 2.0 * (tmp1 - tmp2) * invs
		return self
	end

	function META:RotateQuat(q)
		self:Multiply(Matrix44():SetRotation(q))
	end

	function META:SetAngles(ang)
		self:SetRotation(Quat():SetAngles(ang))
	end

	function META:GetAngles()
		return self:GetRotation():GetAngles()
	end

	ffi.metatype(META.CType, META)
end

-- other variants
for X = 2, 4 do
	for Y = 2, 4 do
		if not (X == 4 and Y == 4) then
			local identity = {}
			local i = 1

			for x = 1, X do
				for y = 1, Y do
					identity[i] = i % (Y + 1) - 1 == 0 and 1 or 0
					i = i + 1
				end
			end

			local name, META = matrix_template(X, Y, identity)
			ffi.metatype(META.CType, META)
			out[name] = META.CType
		end
	end
end

return out
