local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
local material_proxies = library()
local animated = setmetatable({}, {__mode = "k"})
local TEXTURE_PROPERTIES = {
	basetexture = "AlbedoTexture",
	basetexture2 = "Albedo2Texture",
	texture2 = "Albedo2Texture",
	bumpmap = "NormalTexture",
}
local TRANSFORM_TARGETS = {
	basetexturetransform = "BaseTexture",
	bumptransform = "Bump",
	texture2transform = "Texture2",
}

function material_proxies.BuildTransform(cx, cy, sx, sy, degrees, tx, ty)
	local angle = degrees * math.pi / 180
	local cos, sin = math.cos(angle), math.sin(angle)
	local a, b, c, d = cos * sx, -sin * sy, sin * sx, cos * sy
	return {a, b, cx - a * cx - b * cy + tx, c, d, cy - c * cx - d * cy + ty}
end

local function parse_transform(str)
	local cx, cy = str:match("center%s+(%S+)%s+(%S+)")
	local sx, sy = str:match("scale%s+(%S+)%s+(%S+)")
	local rotate = str:match("rotate%s+(%S+)")
	local tx, ty = str:match("translate%s+(%S+)%s+(%S+)")
	return material_proxies.BuildTransform(
		tonumber(cx) or 0.5,
		tonumber(cy) or 0.5,
		tonumber(sx) or 1,
		tonumber(sy) or 1,
		tonumber(rotate) or 0,
		tonumber(tx) or 0,
		tonumber(ty) or 0
	)
end

material_proxies.ParseTransform = parse_transform

local function parse_blocks(text)
	local pos, len = 1, #text

	local function token()
		while true do
			local _, stop = text:find("^%s+", pos)

			if stop then pos = stop + 1 end

			if text:sub(pos, pos + 1) == "//" then
				pos = (text:find("\n", pos, true) or len) + 1
			else
				break
			end
		end

		if pos > len then return nil end

		local c = text:sub(pos, pos)

		if c == "{" or c == "}" then
			pos = pos + 1
			return c, false
		end

		if c == "\"" then
			local stop = text:find("\"", pos + 1, true) or len + 1
			local str = text:sub(pos + 1, stop - 1)
			pos = stop + 1
			return str, true
		end

		local stop = text:find("[%s{}\"]", pos) or len + 1
		local str = text:sub(pos, stop - 1)
		pos = stop
		return str, true
	end

	local function peek()
		local save = pos
		local t, is_text = token()
		pos = save
		return t, is_text
	end

	local function block()
		local entries = {}

		while true do
			local key, key_is_text = token()

			if key == nil or (key == "}" and not key_is_text) then return entries end

			local nxt, nxt_is_text = peek()

			if nxt == "{" and not nxt_is_text then
				token()
				entries[#entries + 1] = {key = key:lower(), children = block()}
			else
				local value = token()
				entries[#entries + 1] = {key = key:lower(), value = value}
			end
		end
	end

	return block()
end

local function find_child(entries, key)
	for _, entry in ipairs(entries) do
		if entry.key == key and entry.children then return entry.children end
	end
end

local function parse_variable(name, value)
	if name:find("transform$") and value:find("center") then
		return parse_transform(value)
	end

	local vector = value:match("^%[(.-)%]$")

	if vector then
		local out = {}

		for number in vector:gmatch("%S+") do
			out[#out + 1] = tonumber(number) or 0
		end

		return out
	end

	local color = value:match("^{(.-)}$")

	if color then
		local out = {}

		for number in color:gmatch("%S+") do
			out[#out + 1] = (tonumber(number) or 0) / 255
		end

		return out
	end

	return tonumber(value) or value
end

local function reference(str)
	local name, index = str:match("^%$([%w_]+)%[(%d+)%]$")

	if name then return name, tonumber(index) + 1 end

	name = str:match("^%$([%w_]+)$")
	return name
end

local function scalar(str, default)
	if str == nil then return tostring(default) end

	local name, index = reference(str)

	if name then return string.format("n(v[%q], %d)", name, index or 1) end

	return tostring(tonumber(str) or default)
end

local function raw(str, default)
	if str == nil then return default end

	local name = reference(str)

	if name then return string.format("v[%q]", name) end

	return tostring(tonumber(str) or 0)
end

local function store(str, expression)
	local name, index = reference(str)
	return string.format("set(v, %q, %s, %s)", name, tostring(index), expression)
end

local generators = {
	equals = function(p)
		return store(p.resultvar, "copy(" .. raw(p.srcvar1, "0") .. ")")
	end,
	add = function(p)
		return store(
			p.resultvar,
			string.format("map2(add, %s, %s)", raw(p.srcvar1, "0"), raw(p.srcvar2, "0"))
		)
	end,
	subtract = function(p)
		return store(
			p.resultvar,
			string.format("map2(sub, %s, %s)", raw(p.srcvar1, "0"), raw(p.srcvar2, "0"))
		)
	end,
	multiply = function(p)
		return store(
			p.resultvar,
			string.format("map2(mul, %s, %s)", raw(p.srcvar1, "0"), raw(p.srcvar2, "0"))
		)
	end,
	divide = function(p)
		return store(
			p.resultvar,
			string.format("map2(div, %s, %s)", raw(p.srcvar1, "0"), raw(p.srcvar2, "1"))
		)
	end,
	abs = function(p)
		return store(p.resultvar, string.format("map2(absolute, %s, 0)", raw(p.srcvar1, "0")))
	end,
	frac = function(p)
		return store(p.resultvar, string.format("map2(fraction, %s, 0)", raw(p.srcvar1, "0")))
	end,
	clamp = function(p)
		return store(
			p.resultvar,
			string.format(
				"math.min(math.max(%s, %s), %s)",
				scalar(p.srcvar1, 0),
				scalar(p.min, 0),
				scalar(p.max, 1)
			)
		)
	end,
	exponential = function(p)
		local expression = string.format(
			"%s * math.exp(%s) + %s",
			scalar(p.scale, 1),
			scalar(p.srcvar1, 0),
			scalar(p.offset, 0)
		)

		if p.minval or p.maxval then
			expression = string.format(
				"math.min(math.max(%s, %s), %s)",
				expression,
				scalar(p.minval, "-math.huge"),
				scalar(p.maxval, "math.huge")
			)
		end

		return store(p.resultvar, expression)
	end,
	linearramp = function(p)
		return store(
			p.resultvar,
			string.format("%s + %s * time", scalar(p.initialvalue, 0), scalar(p.rate, 1))
		)
	end,
	sine = function(p)
		return store(
			p.resultvar,
			string.format(
				"sine(time, %s, %s, %s, %s)",
				scalar(p.sineperiod, 1),
				scalar(p.sinemin, 0),
				scalar(p.sinemax, 1),
				scalar(p.timeoffset, 0)
			)
		)
	end,
	wrapminmax = function(p)
		return store(
			p.resultvar,
			string.format(
				"wrap(%s, %s, %s)",
				scalar(p.srcvar1, 0),
				scalar(p.minval, 0),
				scalar(p.maxval, 1)
			)
		)
	end,
	gaussiannoise = function(p)
		local expression = string.format("%s + %s * gauss()", scalar(p.mean, 0), scalar(p.halfwidth, 1))

		if p.minval or p.maxval then
			expression = string.format(
				"math.min(math.max(%s, %s), %s)",
				expression,
				scalar(p.minval, "-math.huge"),
				scalar(p.maxval, "math.huge")
			)
		end

		return store(p.resultvar, expression)
	end,
	uniformnoise = function(p)
		return store(
			p.resultvar,
			string.format(
				"%s + (%s - %s) * math.random()",
				scalar(p.minval, 0),
				scalar(p.maxval, 1),
				scalar(p.minval, 0)
			)
		)
	end,
	currenttime = function(p)
		return store(p.resultvar, "time")
	end,
	texturetransform = function(p)
		return store(
			p.resultvar,
			string.format(
				"transform(%s, %s, %s, %s)",
				raw(p.centervar, "{0.5, 0.5}"),
				raw(p.scalevar, "{1, 1}"),
				scalar(p.rotatevar, 0),
				raw(p.translatevar, "{0, 0}")
			)
		)
	end,
	texturescroll = function(p)
		return store(
			p.texturescrollvar,
			string.format(
				"scroll(time, %s, %s, %s)",
				scalar(p.texturescrollrate, 1),
				scalar(p.texturescrollangle, 0),
				scalar(p.texturescale, 1)
			)
		)
	end,
	animatedtexture = function(p)
		return store(
			p.animatedtextureframenumvar,
			string.format(
				"(time * %s) %% (v.frame_count_%s or 1)",
				scalar(p.animatedtextureframerate, 1),
				reference(p.animatedtexturevar)
			)
		)
	end,
}
local PRELUDE = [[
local v, time = ...
local pi = math.pi
local function n(x, i)
	if type(x) == "table" then return x[i or 1] or 0 end
	return tonumber(x) or 0
end
local function copy(x)
	if type(x) ~= "table" then return x end
	local out = {}
	for i = 1, #x do out[i] = x[i] end
	return out
end
local function set(vars, name, index, value)
	if not index then vars[name] = value return end
	local t = vars[name]
	if type(t) ~= "table" then t = {0, 0, 0, 0} vars[name] = t end
	t[index] = value
end
local function map2(f, a, b)
	if type(a) == "table" or type(b) == "table" then
		local out = {}
		for i = 1, math.max(type(a) == "table" and #a or 1, type(b) == "table" and #b or 1) do
			out[i] = f(n(a, i), n(b, i))
		end
		return out
	end
	return f(n(a), n(b))
end
local function add(a, b) return a + b end
local function sub(a, b) return a - b end
local function mul(a, b) return a * b end
local function div(a, b) return b ~= 0 and a / b or 0 end
local function absolute(a) return math.abs(a) end
local function fraction(a) return a - math.floor(a) end
local function sine(t, period, min, max, offset)
	return (math.sin(2 * pi * (t - offset) / period) + 1) / 2 * (max - min) + min
end
local function wrap(x, min, max)
	if max <= min then return min end
	return min + (x - min) % (max - min)
end
local function gauss()
	return math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * pi * math.random())
end
local function transform(center, scale, rotate, translate)
	return build_transform(n(center, 1), n(center, 2), n(scale, 1), n(scale, 2), rotate, n(translate, 1), n(translate, 2))
end
local function scroll(t, rate, angle, scale)
	local a = angle * pi / 180
	local s, o = t * rate * math.cos(a), t * rate * math.sin(a)
	return {scale, 0, s - math.floor(s), 0, scale, o - math.floor(o)}
end
]]

function material_proxies.Compile(source_text)
	local root = parse_blocks(source_text)
	local shader = root[1] and root[1].children

	if not shader then return nil end

	local proxies = find_child(shader, "proxies")

	if not proxies then return nil end

	local lines = {}
	local animations = {}

	for _, proxy in ipairs(proxies) do
		local generator = generators[proxy.key]

		if generator and proxy.children then
			local params = {}

			for _, entry in ipairs(proxy.children) do
				if entry.value then params[entry.key] = entry.value end
			end

			local ok, line = pcall(generator, params)

			if ok then
				lines[#lines + 1] = line

				if proxy.key == "animatedtexture" then
					animations[#animations + 1] = {
						texture = reference(params.animatedtexturevar),
						frame = reference(params.animatedtextureframenumvar),
					}
				end
			end
		end
	end

	if #lines == 0 then return nil end

	local variables = {one = 1, zero = 0}

	for _, entry in ipairs(shader) do
		if entry.value and entry.key:sub(1, 1) == "$" then
			variables[entry.key:sub(2)] = parse_variable(entry.key:sub(2), entry.value)
		end
	end

	local code = PRELUDE .. table.concat(lines, "\n") .. "\n"
	local fn = assert(loadstring(code, "vmt proxies"))
	setfenv(
		fn,
		{
			math = math,
			type = type,
			tonumber = tonumber,
			build_transform = material_proxies.BuildTransform,
		}
	)
	return fn, variables, animations
end

local function own_copies(material)
	material:SetColorMultiplier(material:GetColorMultiplier():Copy())

	for _, target in pairs(TRANSFORM_TARGETS) do
		local u, v = material["Get" .. target .. "TransformU"](material),
		material["Get" .. target .. "TransformV"](material)
		material["Set" .. target .. "TransformU"](material, Vec4(u.x, u.y, u.z, u.w))
		material["Set" .. target .. "TransformV"](material, Vec4(v.x, v.y, v.z, v.w))
	end
end

local function detach(material)
	animated[material] = nil
end

function material_proxies.Attach(material, source_text)
	local fn, variables, animations = material_proxies.Compile(source_text)

	if not fn then return false end

	local originals = {}

	for _, animation in ipairs(animations) do
		originals[animation] = material[TEXTURE_PROPERTIES[animation.texture]]
	end

	local color = material:GetColorMultiplier()

	if variables.color == nil then variables.color = {color.r, color.g, color.b} end

	if variables.alpha == nil then variables.alpha = color.a end

	own_copies(material)
	material.has_uv_transform = true
	animated[material] = {fn = fn, variables = variables, animations = animations, originals = originals}
	material:CallOnRemove(detach)
	return true
end

local function apply(material, variables)
	for name, target in pairs(TRANSFORM_TARGETS) do
		local m = variables[name]

		if type(m) == "table" then
			local u, v = material["Get" .. target .. "TransformU"](material),
			material["Get" .. target .. "TransformV"](material)
			u.x, u.y, u.z = m[1], m[2], m[3]
			v.x, v.y, v.z = m[4], m[5], m[6]
		end
	end

	local color = material:GetColorMultiplier()
	local tint = variables.color

	if type(tint) == "table" then
		color.r, color.g, color.b = tint[1] or 1, tint[2] or tint[1] or 1, tint[3] or tint[1] or 1
	end

	if type(variables.alpha) == "number" then color.a = variables.alpha end

	material.proxy_frame = variables.frame
end

function material_proxies.Update(time)
	for material, state in pairs(animated) do
		local variables = state.variables

		for _, animation in ipairs(state.animations) do
			local texture = state.originals[animation]

			if texture then
				variables["frame_count_" .. animation.texture] = texture:GetFrameCount()
			end
		end

		state.fn(variables, time)
		apply(material, variables)

		for _, animation in ipairs(state.animations) do
			local texture = state.originals[animation]
			local frame = variables[animation.frame]

			if texture and type(frame) == "number" then
				material[TEXTURE_PROPERTIES[animation.texture]] = texture:GetFrameTexture(math.floor(frame) % texture:GetFrameCount())
			end
		end
	end
end

event.AddListener("Update", "material_proxies", function()
	material_proxies.Update(system.GetElapsedTime())
end)

return material_proxies
