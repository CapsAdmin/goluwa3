local render3d = import("goluwa/render3d/render3d.lua")
local render = import("goluwa/render/render.lua")
local gbuffer_layout = {}
local surface_features = import("goluwa/render3d/surface_features.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local pvars = import("goluwa/cli/pvars.lua")
pvars.StartGroup("Rendering", "Visibility buffer", {store = false})
local visibility_enabled = pvars.Setup2{
	key = "r_visibility_buffer",
	default = true,
	help = "plain opaque scene geometry and scatter only rasterize triangle ids, and a compute pass shades each visible pixel once from them, set before starting (GOLUWA_PVARS)",
}
pvars.EndGroup()
-- test processes import render3d before the device exists
gbuffer_layout.visibility = visibility_enabled:Get() and
	(
		not render.IsInitialized() or
		render.GetDevice().visibility_buffer_supported
	)

if visibility_enabled:Get() and not gbuffer_layout.visibility then
	logn(
		"r_visibility_buffer is on but the device lacks fragment shader barycentrics, compute shader derivatives or 64 bit buffer atomics, drawing classic"
	)
end

-- the guaranteed minimum of vulkan's maxColorAttachments
local MAX_TARGETS = 8
gbuffer_layout.DEPTH_FORMAT = "d32_sfloat"
gbuffer_layout.fields = surface_features.GetFields()
local ALBEDO_TARGET = {
	texture = "albedo",
	format = "r8g8b8a8_unorm",
	channels = {{"albedo_srgb", "rgb"}, {"alpha", "a"}},
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
local CHANNEL_BITS = 16
local KINDS = {
	unorm4 = {bits = 4},
	unorm8 = {bits = 8},
	unorm16 = {width = 1},
	octa = {width = 2},
	velocity_alpha = {fixed = true},
}

function gbuffer_layout.Pack(fields)
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

	local targets = {}
	local target

	local function open_channels(width)
		if not target or target.used + width > 4 then
			target = {used = 0, channels = {}, fields = {}}
			table.insert(targets, target)
		end

		local swizzle = ("rgba"):sub(target.used + 1, target.used + width)
		target.used = target.used + width
		return swizzle
	end

	for _, entry in ipairs(keyed) do
		local field = entry.field
		local kind = KINDS[field.kind]
		assert(kind, "unknown gbuffer field kind " .. tostring(field.kind))

		if kind.fixed then
			field.target = VELOCITY_TARGET
			field.swizzle = "a"
		elseif kind.width then
			field.swizzle = open_channels(kind.width)
			field.target = target
			field.shift = nil
			field.bits = nil
			table.insert(target.fields, field)
			table.insert(target.channels, {field.name, field.swizzle})
		else
			local channel

			if target then
				for _, candidate in ipairs(target.channels) do
					if candidate.packed and candidate.bits + kind.bits <= CHANNEL_BITS then
						channel = candidate

						break
					end
				end
			end

			if not channel then
				channel = {false, open_channels(1), packed = true, bits = 0, fields = {}}
				table.insert(target.channels, channel)
			end

			field.target = target
			field.swizzle = channel[2]
			field.shift = channel.bits
			field.bits = kind.bits
			channel.bits = channel.bits + kind.bits
			table.insert(channel.fields, field)
			table.insert(target.fields, field)
		end
	end

	for i, target in ipairs(targets) do
		target.texture = "packed" .. (i - 1)
		target.format = target.used > 2 and "r16g16b16a16_unorm" or "r16g16_unorm"

		for _, channel in ipairs(target.channels) do
			if channel.packed then channel[1] = target.texture .. "_" .. channel[2] end
		end
	end

	return targets
end

do
	local packed = gbuffer_layout.Pack(gbuffer_layout.fields)

	if #packed + 3 > MAX_TARGETS then
		error(
			"the gbuffer needs " .. (#packed + 3) .. " targets, the limit is " .. MAX_TARGETS,
			2
		)
	end

	local alpha_fields = {}

	for _, field in ipairs(gbuffer_layout.fields) do
		if field.kind == "velocity_alpha" then table.insert(alpha_fields, field) end
	end

	assert(#alpha_fields <= 1, "the spare channel of the velocity target holds one field")

	for _, field in ipairs(alpha_fields) do
		table.insert(VELOCITY_TARGET.channels, {field.name, "a"})
	end

	gbuffer_layout.targets = {ALBEDO_TARGET}

	for _, target in ipairs(packed) do
		table.insert(gbuffer_layout.targets, target)
	end

	table.insert(gbuffer_layout.targets, EMISSIVE_TARGET)
	table.insert(gbuffer_layout.targets, VELOCITY_TARGET)

	if gbuffer_layout.visibility and #gbuffer_layout.targets + 1 > MAX_TARGETS then
		error(
			"the visibility buffer needs a target, the gbuffer already has " .. #gbuffer_layout.targets,
			2
		)
	end
end

gbuffer_layout.color_format = {}
gbuffer_layout.block = {{"depth_tex", "int"}}
gbuffer_layout.attachment_index = {}

for i, target in ipairs(gbuffer_layout.targets) do
	gbuffer_layout.color_format[i] = {target.format, unpack(target.channels)}
	gbuffer_layout.block[i + 1] = {target.texture .. "_tex", "int"}
	gbuffer_layout.attachment_index[target.texture] = i
end

for _, field in ipairs(gbuffer_layout.fields) do
	if field.kind == "velocity_alpha" then
		table.insert(gbuffer_layout.block, {field.name .. "_tex", "int"})
	end
end

if gbuffer_layout.visibility then
	gbuffer_layout.VISIBILITY_FORMAT = "r32g32b32a32_uint"
	table.insert(gbuffer_layout.color_format, {gbuffer_layout.VISIBILITY_FORMAT, {"visibility", "rgba"}})
	gbuffer_layout.attachment_index.visibility = #gbuffer_layout.color_format
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

	for _, field in ipairs(gbuffer_layout.fields) do
		if field.kind == "velocity_alpha" then
			block[field.name .. "_tex"] = self:GetTextureIndex(framebuffer:GetAttachment(gbuffer_layout.attachment_index.velocity))
		end
	end

	if not render3d.velocity_enabled:Get() then block.velocity_tex = -1 end

	return block
end

do
	local lines = {}
	local handwritten = [[
		vec2 gbuffer_encode_normal(vec3 N) {
			return oct_encode(N) * 0.5 + 0.5;
		}

		void set_albedo(vec3 c) {
			set_albedo_srgb(linear_to_srgb(c));
		}

		vec3 gbuffer_encode_emissive(vec3 luminance) {
			return luminance * (1.0 / 256.0);
		}
]]
	local defaults = {"void gbuffer_set_defaults() {"}
	local flush = {"void gbuffer_flush_packed() {"}

	for _, field in ipairs(gbuffer_layout.fields) do
		if field.encode then
			table.insert(
				lines,
				string.format("float gbuffer_encode_%s(float v) { return %s; }", field.name, field.encode)
			)
		end
	end

	for _, target in ipairs(gbuffer_layout.targets) do
		for _, channel in ipairs(target.channels) do
			if channel.packed then
				local terms = {}

				for _, field in ipairs(channel.fields) do
					local variable = "gbuffer_packed_" .. field.name
					table.insert(lines, string.format("float %s = 0.0;", variable))
					table.insert(
						lines,
						string.format("void set_%s(float v) { %s = v; }", field.name, variable)
					)
					table.insert(
						terms,
						string.format(
							"(uint(clamp(%s, 0.0, 1.0) * %d.0 + 0.5) << %du)",
							variable,
							2 ^ field.bits - 1,
							field.shift
						)
					)
				end

				table.insert(
					flush,
					string.format(
						"\tset_%s(float(%s) / %d.0);",
						channel[1],
						table.concat(terms, " | "),
						2 ^ CHANNEL_BITS - 1
					)
				)
			end
		end
	end

	table.insert(flush, "}")
	table.insert(lines, table.concat(flush, "\n"))

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

	if gbuffer_layout.visibility then
		table.insert(defaults, "\tset_visibility(uvec4(0u));")
	end

	table.insert(defaults, "\tgbuffer_flush_packed();")
	table.insert(defaults, "}")
	table.insert(lines, glsl_common.GetOctahedralGLSL())
	table.insert(lines, glsl_common.GetSRGBGLSL())
	table.insert(lines, handwritten)
	table.insert(lines, surface_features.GetEncodersGLSL())
	table.insert(lines, table.concat(defaults, "\n"))

	function gbuffer_layout.GetEncodeGLSL()
		return table.concat(lines, "\n") .. surface_features.GetSurfaceGLSL() .. surface_features.GetDefaultFunctionGLSL() .. surface_features.GetPrepareWeatherFunctionGLSL() .. surface_features.GetWeatherFunctionGLSL() .. surface_features.GetFaceFunctionGLSL() .. surface_features.GetWriteFunctionGLSL()
	end
end

do
	local decoders = {
		[[
		vec3 gbuffer_albedo(COORD c) { return srgb_to_linear(gbuffer_fetch(GBUFFER.albedo_tex, c).rgb); }
		float gbuffer_alpha(COORD c) { return gbuffer_fetch(GBUFFER.albedo_tex, c).a; }
		float gbuffer_depth(COORD c) { return gbuffer_fetch(GBUFFER.depth_tex, c).r; }
		vec3 gbuffer_emissive(COORD c) { return gbuffer_fetch(GBUFFER.emissive_tex, c).rgb * 256.0; }
		]],
	}

	for _, field in ipairs(gbuffer_layout.fields) do
		local accessor = "gbuffer_" .. (field.accessor or field.name)
		local fetch = string.format(
			"GBUFFER.%s_tex",
			field.kind == "velocity_alpha" and field.name or field.target.texture
		)

		if field.kind == "velocity_alpha" then
			table.insert(
				decoders,
				string.format(
					"float %s(COORD c) { float v = gbuffer_fetch_nearest(%s, c).a; return %s; }",
					accessor,
					fetch,
					field.decode or "v"
				)
			)
		elseif field.kind == "octa" then
			table.insert(
				decoders,
				string.format(
					[[
		vec3 %s(COORD c) {
			return oct_decode(gbuffer_fetch_nearest(%s, c).%s * 2.0 - 1.0);
		}
		]],
					accessor,
					fetch,
					field.swizzle
				)
			)
		elseif field.bits then
			table.insert(
				decoders,
				string.format(
					"float %s(COORD c) { uint raw = uint(gbuffer_fetch_nearest(%s, c).%s * %d.0 + 0.5); float v = float(bitfieldExtract(raw, %d, %d)) / %d.0; return %s; }",
					accessor,
					fetch,
					field.swizzle,
					2 ^ CHANNEL_BITS - 1,
					field.shift,
					field.bits,
					2 ^ field.bits - 1,
					field.decode or "v"
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
	table.insert(
		decoders,
		"bool gbuffer_is_lit_from_behind(COORD c) { return " .. surface_features.GetGBufferLitFromBehindExpressionGLSL() .. "; }"
	)
	decoders = table.concat(decoders, "\n")
	local code = glsl_common.GetOctahedralGLSL() .. glsl_common.GetSRGBGLSL() .. [[
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

do
	local FORMAT_BYTES = {
		r8g8b8a8_srgb = 4,
		r8g8b8a8_unorm = 4,
		b10g11r11_ufloat_pack32 = 4,
		r16g16_unorm = 4,
		r16g16b16a16_unorm = 8,
		r16g16b16a16_sfloat = 8,
	}
	gbuffer_layout.FORMAT_BYTES = FORMAT_BYTES

	function gbuffer_layout.Describe()
		local lines = {}
		local total = 0
		local free = 0
		local free_bits = 0
		local by_channel = {}

		for _, field in ipairs(gbuffer_layout.fields) do
			by_channel[field.target.texture .. "." .. field.swizzle] = by_channel[field.target.texture .. "." .. field.swizzle] or {}
			table.insert(by_channel[field.target.texture .. "." .. field.swizzle], field)
		end

		for i, target in ipairs(gbuffer_layout.targets) do
			local bytes = FORMAT_BYTES[target.format]
			total = total + bytes
			table.insert(
				lines,
				string.format("%d %s %s, %d bytes per pixel", i, target.texture, target.format, bytes)
			)

			for _, channel in ipairs(target.channels) do
				local fields = by_channel[target.texture .. "." .. channel[2]]
				local text

				if fields then
					local names = {}

					for _, field in ipairs(fields) do
						table.insert(
							names,
							string.format(
								"%s (%s%s)",
								field.name,
								field.kind,
								field.readers and ", read by " .. table.concat(field.readers, " ") or ""
							)
						)
					end

					text = table.concat(names, " + ")
				else
					text = "fixed"
				end

				if channel.packed and channel.bits < CHANNEL_BITS then
					free_bits = free_bits + CHANNEL_BITS - channel.bits
					text = text .. string.format(", %d of %d bits free", CHANNEL_BITS - channel.bits, CHANNEL_BITS)
				end

				table.insert(lines, string.format("    %-4s %s: %s", channel[2], channel[1], text))
			end

			if target.used and target.used < 4 then
				free = free + 4 - target.used
				table.insert(lines, string.format("    %d of 4 channels free", 4 - target.used))
			end
		end

		table.insert(
			lines,
			string.format(
				"%d targets of %d, %d bytes per pixel plus depth %s, %d free channels and %d free bits in packed targets",
				#gbuffer_layout.targets,
				MAX_TARGETS,
				total,
				gbuffer_layout.DEPTH_FORMAT,
				free,
				free_bits
			)
		)
		return table.concat(lines, "\n")
	end
end

return gbuffer_layout
