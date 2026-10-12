local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = {}
local surface_features = import("goluwa/render3d/surface_features.lua")
-- the guaranteed minimum of vulkan's maxColorAttachments
local MAX_TARGETS = 8
gbuffer_layout.DEPTH_FORMAT = "d32_sfloat"
-- fields are what the gbuffer stores per pixel. features declare theirs (features/*.lua), no layout
-- needs editing, and they are packed into as few targets as fit.
-- kind: unorm8 (one 8 bit channel) or octa (a unit vector in two 16 bit channels)
-- default: the value written when a pass doesn't write the field, before encode
-- encode, decode: GLSL on v, the field's value and what is stored. encode becomes
--   gbuffer_encode_<name>, decode is what gbuffer_<accessor> returns
-- readers: the passes that read it. fields with the same readers sit next to each other, so a
--   pass binds fewer textures. no readers means all of them
gbuffer_layout.fields = surface_features.GetFields()

-- fixed targets: their formats are chosen for what they hold
local ALBEDO_TARGET = {
	texture = "albedo",
	format = "r8g8b8a8_srgb",
	channels = {{"albedo", "rgb"}, {"alpha", "a"}},
}
local EMISSIVE_TARGET = {
	texture = "emissive",
	format = "b10g11r11_ufloat_pack32",
	channels = {{"emissive", "rgb"}},
}
local VELOCITY_TARGET = {
	texture = "velocity",
	format = "r16g16b16a16_sfloat",
	channels = {{"velocity", "rg"}, {"prev_view_depth", "b"}},
}
local KIND_WIDTH = {unorm8 = 1, octa = 2}

-- a field is stored in the first free channels of its kind, in the order of its readers, so
-- the fields one pass reads end up next to each other, and share as few textures as possible
local function pack_fields(fields)
	local keyed = {}

	for i, field in ipairs(fields) do
		local readers = ""

		if field.readers then
			local sorted = table.copy(field.readers)
			table.sort(sorted)
			readers = table.concat(sorted, ",")
		end

		keyed[i] = {field = field, readers = readers, index = i}
	end

	table.sort(keyed, function(a, b)
		if a.readers ~= b.readers then return a.readers < b.readers end

		return a.index < b.index
	end)

	local buckets = {}
	local bucket_order = {}

	for _, entry in ipairs(keyed) do
		local field = entry.field
		local bucket = buckets[field.kind]

		if not bucket then
			bucket = {kind = field.kind, fields = {}}
			buckets[field.kind] = bucket
			table.insert(bucket_order, bucket)
		end

		table.insert(bucket.fields, field)
	end

	local targets = {}

	for _, bucket in ipairs(bucket_order) do
		local target

		for _, field in ipairs(bucket.fields) do
			local width = KIND_WIDTH[bucket.kind]

			if not target or target.used + width > 4 then
				target = {used = 0, kind = bucket.kind, channels = {}, fields = {}}
				table.insert(targets, target)
			end

			local swizzle = ("rgba"):sub(target.used + 1, target.used + width)
			target.used = target.used + width
			table.insert(target.channels, {field.name, swizzle})
			table.insert(target.fields, field)
			field.swizzle = swizzle
			field.target = target
		end
	end

	for i, target in ipairs(targets) do
		target.texture = "packed" .. (i - 1)

		if target.kind == "octa" then
			target.format = target.used > 2 and "r16g16b16a16_unorm" or "r16g16_unorm"
		else
			target.format = "r8g8b8a8_unorm"
		end
	end

	return targets
end

do
	local packed = pack_fields(gbuffer_layout.fields)

	if #packed + 3 > MAX_TARGETS then
		error("the gbuffer needs " .. (#packed + 3) .. " targets, the limit is " .. MAX_TARGETS, 2)
	end

	gbuffer_layout.targets = {ALBEDO_TARGET}

	for _, target in ipairs(packed) do
		table.insert(gbuffer_layout.targets, target)
	end

	table.insert(gbuffer_layout.targets, EMISSIVE_TARGET)
	table.insert(gbuffer_layout.targets, VELOCITY_TARGET)
end

gbuffer_layout.color_format = {}
gbuffer_layout.block = {{"depth_tex", "int"}}
gbuffer_layout.attachment_index = {}

for i, target in ipairs(gbuffer_layout.targets) do
	gbuffer_layout.color_format[i] = {target.format, unpack(target.channels)}
	gbuffer_layout.block[i + 1] = {target.texture .. "_tex", "int"}
	gbuffer_layout.attachment_index[target.texture] = i
end

function gbuffer_layout.GetTexture(name)
	return render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(gbuffer_layout.attachment_index[name])
end

function gbuffer_layout.GetDepthTexture()
	return render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture()
end

function gbuffer_layout.WriteBlock(self, block)
	local framebuffer = render3d.pipelines.gbuffer:GetFramebuffer()
	block.depth_tex = self:GetTextureIndex(framebuffer:GetDepthTexture())

	for i, target in ipairs(gbuffer_layout.targets) do
		block[target.texture .. "_tex"] = self:GetTextureIndex(framebuffer:GetAttachment(i))
	end

	if not render3d.velocity_enabled:Get() then block.velocity_tex = -1 end

	return block
end

do
	local lines = {}
	local handwritten = [[
		vec2 gbuffer_encode_normal(vec3 N) {
			N /= abs(N.x) + abs(N.y) + abs(N.z);
			vec2 e = N.z >= 0.0 ? N.xy : (1.0 - abs(N.yx)) * vec2(N.x >= 0.0 ? 1.0 : -1.0, N.y >= 0.0 ? 1.0 : -1.0);
			return e * 0.5 + 0.5;
		}

		// cd/m2 in. b10g11r11 stops at 64512, a frosted bulb is ~1e5 and a clear
		// filament ~1e7; scaled down it reaches 1.7e7 (render3d.EMISSIVE_MAX_LUMINANCE)
		// and keeps full precision down to 0.016
		vec3 gbuffer_encode_emissive(vec3 luminance) {
			return luminance * (1.0 / 256.0);
		}
]]
	local defaults = {"void gbuffer_set_defaults() {"}
	for _, field in ipairs(gbuffer_layout.fields) do
		if field.encode then
			table.insert(
				lines,
				string.format("float gbuffer_encode_%s(float v) { return %s; }", field.name, field.encode)
			)
		end
	end

	for _, field in ipairs(gbuffer_layout.fields) do
		if field.kind == "octa" then
			table.insert(defaults, string.format("\tset_%s(vec2(0.5));", field.name))
		else
			local value = field.encode and
				string.format("gbuffer_encode_%s(%s)", field.name, field.default) or
				field.default
			table.insert(defaults, string.format("\tset_%s(%s);", field.name, value))
		end
	end

	table.insert(defaults, "}")
	table.insert(lines, handwritten)
	table.insert(lines, surface_features.GetEncodersGLSL())
	table.insert(lines, table.concat(defaults, "\n"))
	-- every pass that writes the gbuffer calls gbuffer_set_defaults first, so a field
	-- it doesn't know about reads as its default instead of garbage
	function gbuffer_layout.GetEncodeGLSL()
		return table.concat(lines, "\n") .. surface_features.GetSurfaceGLSL() .. surface_features.GetDefaultFunctionGLSL() .. surface_features.GetWeatherFunctionGLSL() .. surface_features.GetWriteFunctionGLSL()
	end
end

do
	local decoders = {
		[[
		vec3 gbuffer_albedo(COORD c) { return gbuffer_fetch(GBUFFER.albedo_tex, c).rgb; }
		float gbuffer_alpha(COORD c) { return gbuffer_fetch(GBUFFER.albedo_tex, c).a; }
		float gbuffer_depth(COORD c) { return gbuffer_fetch(GBUFFER.depth_tex, c).r; }
		vec3 gbuffer_emissive(COORD c) { return gbuffer_fetch(GBUFFER.emissive_tex, c).rgb * 256.0; }
		]],
	}

	for _, field in ipairs(gbuffer_layout.fields) do
		local accessor = "gbuffer_" .. (field.accessor or field.name)
		local fetch = string.format("GBUFFER.%s_tex", field.target.texture)

		if field.kind == "octa" then
			-- never filtered, texels on either side of the octahedral fold don't blend
			table.insert(
				decoders,
				string.format(
					[[
		vec3 %s(COORD c) {
			vec2 e = gbuffer_fetch_nearest(%s, c).%s * 2.0 - 1.0;
			vec3 N = vec3(e, 1.0 - abs(e.x) - abs(e.y));
			float t = max(-N.z, 0.0);
			N.xy += vec2(N.x >= 0.0 ? -t : t, N.y >= 0.0 ? -t : t);
			return normalize(N);
		}
		]],
					accessor,
					fetch,
					field.swizzle
				)
			)
		else
			table.insert(
				decoders,
				string.format(
					"float %s(COORD c) { float v = gbuffer_fetch(%s, c).%s; return %s; }",
					accessor,
					fetch,
					field.swizzle,
					field.decode or "v"
				)
			)
		end
	end

	table.insert(decoders, surface_features.GetDecodersGLSL())
	table.insert(
		decoders,
		"bool gbuffer_is_thin(COORD c) { return " .. surface_features.GetThinExpressionGLSL() .. "; }"
	)
	decoders = table.concat(decoders, "\n")
	local code = [[
		vec4 gbuffer_fetch(int tex, vec2 uv) {
			return texture(TEXTURE(tex), uv);
		}

		vec4 gbuffer_fetch(int tex, ivec2 pixel) {
			return texelFetch(TEXTURE(tex), pixel, 0);
		}

		vec4 gbuffer_fetch_nearest(int tex, vec2 uv) {
			ivec2 size = textureSize(TEXTURE(tex), 0);
			return texelFetch(TEXTURE(tex), clamp(ivec2(uv * vec2(size)), ivec2(0), size - 1), 0);
		}

		vec4 gbuffer_fetch_nearest(int tex, ivec2 pixel) {
			return texelFetch(TEXTURE(tex), pixel, 0);
		}
	]] .. decoders:gsub("COORD", "vec2") .. decoders:gsub("COORD", "ivec2")

	function gbuffer_layout.GetDecodeGLSL(block_name)
		return (code:gsub("GBUFFER%.", block_name .. "."))
	end
end

return gbuffer_layout
