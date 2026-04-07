local line = import("goluwa/love/line.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local window = import("goluwa/window.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local shared = import("goluwa/love/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or _G.love
local ENV = shared.Get(love).ENV
local Shader = line.TypeTemplate("Shader", love)
local warned_missing_custom_shader_backend = false
local warned_unsupported_love_vertex_shader = false
local shader_pipeline_cache = setmetatable({}, {__mode = "k"})

local function warn_unsupported_love_vertex_shader()
	if warned_unsupported_love_vertex_shader then return end

	warned_unsupported_love_vertex_shader = true
	wlog(
		"love.graphics.newShader: vertex/pixel shader pairs are not supported by the minimal Love shader backend yet"
	)
end

local function warn_missing_custom_shader_backend()
	if warned_missing_custom_shader_backend then return end

	warned_missing_custom_shader_backend = true
	wlog(
		"love.graphics.newShader: custom shader backend unavailable, using compatibility fallback"
	)
end

local function store_shader_uniform(self, name, value)
	self.uniforms = self.uniforms or {}
	self.uniforms[name] = value
end

local function register_shader_uniform(self, name)
	self.uniform_names = self.uniform_names or {}
	self.uniform_names[name] = true
end

local function clone_uniform_value(value)
	if type(value) ~= "table" then return value end

	local out = {}

	for i = 1, #value do
		out[i] = value[i]
	end

	return out
end

local function parse_default_uniform_value(kind, source)
	if not source or source == "" then return nil end

	source = source:match("^%s*(.-)%s*$")

	if kind == "number" or kind == "float" then return tonumber(source) end

	if kind == "boolean" or kind == "bool" then
		if source == "true" then return true end

		if source == "false" then return false end

		return nil
	end

	if kind == "vec2" or kind == "vec3" or kind == "vec4" then
		local out = {}

		for num in source:gmatch("[-+]?%d*%.?%d+[fF]?") do
			out[#out + 1] = tonumber(num)
		end

		return #out > 0 and out or nil
	end

	return nil
end

local shader_precision_qualifiers = {
	highp = true,
	mediump = true,
	lowp = true,
	MY_HIGHP_OR_MEDIUMP = true,
}

local function parse_love_shader_uniform_declaration(declaration)
	if not declaration then return nil end

	local default_expr = declaration:match("=%s*(.+)$")
	local head = declaration:match("^(.-)%s*=") or declaration
	local tokens = {}

	for token in head:gmatch("[%a_][%w_]*") do
		tokens[#tokens + 1] = token
	end

	if #tokens < 2 then return nil end

	local name = tokens[#tokens]
	local kind_index = #tokens - 1
	local kind = tokens[kind_index]

	while kind_index > 1 and shader_precision_qualifiers[kind] do
		kind_index = kind_index - 1
		kind = tokens[kind_index]
	end

	if not kind or kind == "extern" then return nil end

	return {
		kind = kind,
		name = name,
		default = parse_default_uniform_value(kind, default_expr),
	}
end

local function extract_fragment_source(source)
	if not source then return nil, false end

	local pixel = source:match("#ifdef%s+PIXEL(.-)#endif")
	local has_vertex = source:find("#ifdef%s+VERTEX") ~= nil

	if pixel then return pixel, has_vertex end

	if has_vertex then source = source:gsub("#ifdef%s+VERTEX.-#endif%s*", "") end

	return source, has_vertex
end

local function extract_vertex_source(source)
	if not source then return nil, false end

	local vertex = source:match("#ifdef%s+VERTEX(.-)#endif")
	local has_pixel = source:find("#ifdef%s+PIXEL") ~= nil

	if vertex then return vertex, has_pixel end

	return nil, has_pixel
end

local function parse_love_shader_uniforms(source)
	local uniforms = {}
	local stripped = source:gsub("extern%s+([^;]+);", function(declaration)
		local uniform = parse_love_shader_uniform_declaration(declaration)

		if not uniform then return "extern " .. declaration .. ";" end

		uniforms[#uniforms + 1] = uniform
		return ""
	end)
	return stripped, uniforms
end

local function parse_love_shader_varyings(source)
	local varyings = {}
	local stripped = source:gsub("varying%s+([%a_][%w_]*)%s+([%a_][%w_]*)%s*;", function(kind, name)
		varyings[#varyings + 1] = {kind = kind, name = name}
		return ""
	end)
	return stripped, varyings
end

local function parse_love_shader_attributes(source)
	local attributes = {}
	local stripped = source:gsub("attribute%s+([%a_][%w_]*)%s+([%a_][%w_]*)%s*;", function(kind, name)
		attributes[#attributes + 1] = {kind = kind, name = name}
		return ""
	end)
	return stripped, attributes
end

local function rewrite_shader_identifier(source, name, replacement)
	return source:gsub("(%f[%a_])" .. name .. "(%f[^%w_])", "%1" .. replacement .. "%2")
end

local function rewrite_shader_identifiers(source, items, prefix)
	for _, item in ipairs(items) do
		source = rewrite_shader_identifier(source, item.name, prefix .. item.name)
	end

	return source
end

local function glsl_type_to_vertex_format(glsl_type)
	if glsl_type == "vec4" then return "r32g32b32a32_sfloat" end

	if glsl_type == "vec3" then return "r32g32b32_sfloat" end

	if glsl_type == "vec2" then return "r32g32_sfloat" end

	return "r32_sfloat"
end

local function build_shader_vertex_bindings(attributes)
	local bindings = {
		{
			binding = 0,
			input_rate = "vertex",
			attributes = {
				{"pos", "vec3", "r32g32b32_sfloat"},
				{"uv", "vec2", "r32g32_sfloat"},
				{"color", "vec4", "r32g32b32a32_sfloat"},
			},
		},
	}

	if #attributes > 0 then
		local instance_attributes = {}

		for _, attribute in ipairs(attributes) do
			instance_attributes[#instance_attributes + 1] = {
				attribute.name,
				attribute.kind,
				glsl_type_to_vertex_format(attribute.kind),
			}
		end

		bindings[#bindings + 1] = {
			binding = 1,
			input_rate = "instance",
			attributes = instance_attributes,
		}
	end

	return bindings
end

local function rewrite_love_shader_identifiers(source, uniforms)
	source = source:gsub("(%f[%a_]love_ScreenSize%f[^%w_])", "love_user.love_ScreenSize")

	for _, uniform in ipairs(uniforms) do
		source = source:gsub(
			"(%f[%a_])" .. uniform.name .. "(%f[^%w_])",
			"%1love_user." .. uniform.name .. "%2"
		)
	end

	return source
end

local function rewrite_volume_texture_fetches(source, uniforms)
	for _, uniform in ipairs(uniforms) do
		if uniform.kind == "VolumeImage" then
			source = source:gsub(
				"texelFetch%s*%(%s*" .. uniform.name .. "%s*,",
				"love_volume_texelFetch_" .. uniform.name .. "("
			)
		end
	end

	return source
end

local function collect_image_identifiers(source, uniforms)
	local names = {}
	local seen = {}

	for _, uniform in ipairs(uniforms) do
		if uniform.kind == "Image" then
			seen[uniform.name] = true
			names[#names + 1] = uniform.name
		end
	end

	for name in source:gmatch("Image%s+([%a_][%w_]*)") do
		if not seen[name] then
			seen[name] = true
			names[#names + 1] = name
		end
	end

	return names
end

local function rewrite_image_texture_fetches(source, image_names)
	for _, name in ipairs(image_names) do
		source = source:gsub("texelFetch%s*%(%s*" .. name .. "%s*,", "love_image_texelFetch(" .. name .. ",")
	end

	return source
end

local function build_volume_uniform_declarations(uniforms)
	local lines = {}

	for _, uniform in ipairs(uniforms) do
		if uniform.kind == "VolumeImage" then
			if #lines == 0 then
				lines[#lines + 1] = [[
						vec4 love_volume_texel_fetch(int tex, ivec3 coords, int lod, ivec4 info) {
							if (tex < 0) return vec4(0.0);
							if (coords.z < 0 || coords.z >= info.z) return vec4(0.0);
							return texelFetch(TEXTURE(tex), ivec2(coords.x, coords.y + coords.z * info.y), lod);
						}
					]]
			end

			lines[#lines + 1] = string.format(
				"#define love_volume_texelFetch_%s(coords, lod) love_volume_texel_fetch(love_user.%s, (coords), (lod), love_user.%s_volume_info)",
				uniform.name,
				uniform.name,
				uniform.name
			)
		end
	end

	if #lines == 0 then return "" end

	return table.concat(lines, "\n") .. "\n"
end

local function get_volume_uniform_info(value)
	if type(value) ~= "table" then return 0, 0, 0 end

	local width = value.layer_width or value.width or 0
	local height = value.layer_height or value.height or 0
	local depth = value.depth or value.layers or 0
	return tonumber(width) or 0, tonumber(height) or 0, tonumber(depth) or 0
end

local function get_shader_screen_size()
	if ENV.graphics_current_canvas then
		local tex_w, tex_h = ENV.graphics_current_canvas.fb:GetColorTexture():GetSize():Unpack()
		return tex_w, tex_h
	end

	local size = window.GetSize()
	return size.x or 0, size.y or 0
end

local function build_shader_uniform_block(obj, uniforms)
	local block = {
		{
			"love_ScreenSize",
			"vec2",
			function(_, data, key)
				local w, h = get_shader_screen_size()
				data[key][0] = w
				data[key][1] = h
			end,
		},
	}

	for _, uniform in ipairs(uniforms) do
		local uniform_info = uniform
		local glsl_type = uniform_info.kind

		if glsl_type == "number" then glsl_type = "float" end

		if glsl_type == "Image" then glsl_type = "int" end

		if glsl_type == "VolumeImage" then glsl_type = "int" end

		if glsl_type == "boolean" then glsl_type = "int" end

		block[#block + 1] = {
			uniform_info.name,
			glsl_type,
			function(self, data, key)
				local value = obj.uniforms and obj.uniforms[key]

				if value == nil then
					for _, info in ipairs(uniforms) do
						if info.name == key then
							value = clone_uniform_value(info.default)

							break
						end
					end
				end

				if uniform_info.kind == "Image" or uniform_info.kind == "VolumeImage" then
					local texture = value and (ENV.textures[value] or value)
					data[key] = texture and self:GetTextureIndex(texture) or -1
					return
				end

				if uniform_info.kind == "boolean" or uniform_info.kind == "bool" then
					data[key] = value and 1 or 0
					return
				end

				if type(value) == "table" then
					for i = 1, #value do
						data[key][i - 1] = value[i] or 0
					end

					return
				end

				data[key] = value or 0
			end,
		}

		if uniform_info.kind == "VolumeImage" then
			block[#block + 1] = {
				uniform_info.name .. "_volume_info",
				"ivec4",
				function(_, data, key)
					local value = obj.uniforms and obj.uniforms[uniform_info.name]
					local width, height, depth = get_volume_uniform_info(value)
					data[key][0] = width
					data[key][1] = height
					data[key][2] = depth
					data[key][3] = 0
				end,
			}
		end
	end

	return block
end

local function copy_love_shader_matrix(ptr, matrix)
	matrix:CopyToFloatPointer(ptr)
end

local function copy_love_shader_projection_matrix(ptr)
	copy_love_shader_matrix(ptr, render2d.GetMatrix())
end

local function copy_love_shader_projection_view_matrix(ptr)
	copy_love_shader_matrix(ptr, render2d.GetProjectionViewMatrix())
end

local function copy_love_shader_world_matrix(ptr)
	copy_love_shader_matrix(ptr, render2d.GetWorldMatrix())
end

local function load_shader_source_if_path(source)
	if type(source) ~= "string" then return source end

	if source:find("\n", 1, true) then return source end

	if love.filesystem.getInfo(source, "file") then
		local content = love.filesystem.read(source)

		if content and content ~= "" then return content end
	end

	return source
end

local function is_balatro_shader_source(source, path_hint)
	local identity = love and
		love.filesystem and
		love.filesystem.getIdentity and
		love.filesystem.getIdentity() or
		nil

	if tostring(identity or ""):lower() == "balatro" then return true end

	path_hint = tostring(path_hint or "")
	path_hint = path_hint:gsub("\\", "/"):lower()
	return path_hint:find("balatro/resources/shaders/", 1, true) ~= nil
end

local function patch_balatro_hover_shader_source(source, path_hint)
	if type(source) ~= "string" or source == "" then return source end

	if not is_balatro_shader_source(source, path_hint) then return source end

	if not source:find("mouse_screen_pos", 1, true) then return source end

	if not source:find("screen_scale", 1, true) then return source end

	if not source:find("love_ScreenSize", 1, true) then return source end

	if not source:find("vec4 position", 1, true) then return source end

	local patched = source
	patched = patched:gsub(
		"vertex_position%.xy%s*%-%s*0%.5%s*%*%s*love_ScreenSize%.xy",
		"((U.world_matrix * vertex_position).xy - 0.5*love_ScreenSize.xy)"
	)
	patched = patched:gsub(
		"vertex_position%.xy%s*%-%s*mouse_screen_pos%.xy",
		"((U.world_matrix * vertex_position).xy - mouse_screen_pos.xy)"
	)
	return patched
end

local function append_generated_stage(user_source, generated_source)
	user_source = user_source or ""

	if user_source ~= "" and not user_source:match("\n%s*$") then
		user_source = user_source .. "\n"
	end

	return user_source .. generated_source
end

local function has_love_effect_function(source)
	if not source or source == "" then return false end

	return source:find("[%a_][%w_]*%s+effect%s*%(") ~= nil
end

local function build_fragment_pipeline(obj, source)
	local pixel_source, has_vertex_stage = extract_fragment_source(source)

	if has_vertex_stage then
		obj.warning_message = "minimal Love shader backend does not support #ifdef VERTEX shaders yet"
		warn_unsupported_love_vertex_shader()
		return nil
	end

	local stripped_source, uniforms = parse_love_shader_uniforms(pixel_source)
	local image_names = collect_image_identifiers(stripped_source, uniforms)
	stripped_source = rewrite_volume_texture_fetches(stripped_source, uniforms)
	stripped_source = rewrite_image_texture_fetches(stripped_source, image_names)
	stripped_source = rewrite_love_shader_identifiers(stripped_source, uniforms)
	local volume_uniform_declarations = build_volume_uniform_declarations(uniforms)
	register_shader_uniform(obj, "love_ScreenSize")
	local block = build_shader_uniform_block(obj, uniforms)
	local defines = {
		"#define number float",
		"#define Image int",
		"#define extern",
		"#define Texel(tex, coords) love_texel((tex), (coords))",
	}

	for _, uniform in ipairs(uniforms) do
		register_shader_uniform(obj, uniform.name)

		if uniform.default ~= nil then
			obj.uniforms[uniform.name] = clone_uniform_value(uniform.default)
		end
	end

	local config = {
		name = "love_shader_fragment",
		dont_create_framebuffers = true,
		RasterizationSamples = function()
			return render.target:GetSamples()
		end,
		ColorFormat = render.target:GetColorFormat(),
		vertex = {
			uniform_buffers = {
				{
					block = {
						{
							"projection_view_world",
							"mat4",
							function(self, data, key)
								copy_love_shader_projection_matrix(data[key])
							end,
						},
						{
							"world_matrix",
							"mat4",
							function(self, data, key)
								copy_love_shader_world_matrix(data[key])
							end,
						},
						{
							"apply_love_depth",
							"int",
							function(_, data, key)
								local compare_mode = render2d.GetDepthMode()
								data[key] = compare_mode ~= "none" and 1 or 0
							end,
						},
					},
				},
			},
			attributes = {
				{"pos", "vec3", "r32g32b32_sfloat"},
				{"uv", "vec2", "r32g32_sfloat"},
				{"color", "vec4", "r32g32b32a32_sfloat"},
			},
			shader = [[
					void main() {
						vec4 love_vertex_position = U.world_matrix * vec4(in_pos, 1.0);
						gl_Position = U.projection_view_world * vec4(in_pos, 1.0);
						if (U.apply_love_depth != 0) {
							gl_Position.z = clamp(1.0 - love_vertex_position.z, 0.0, 1.0) * gl_Position.w;
						}
						out_uv = in_uv;
						out_color = in_color;
					}
				]],
		},
		fragment = {
			uniform_buffers = {
				{
					block = {
						{
							"global_color",
							"vec4",
							function(_, data, key)
								local r, g, b, a = render2d.GetColor()
								data[key][0] = r or 1
								data[key][1] = g or 1
								data[key][2] = b or 1
								data[key][3] = a or 1
							end,
						},
						{
							"alpha_multiplier",
							"float",
							function(_, data, key)
								data[key] = render2d.GetAlphaMultiplier()
							end,
						},
						{
							"texture_index",
							"int",
							function(self, data, key)
								local texture = render2d.GetTexture()
								data[key] = texture and self:GetTextureIndex(texture) or -1
							end,
						},
						{
							"discard_zero_alpha",
							"int",
							function(_, data, key)
								local compare_mode = render2d.GetDepthMode()
								data[key] = compare_mode ~= "none" and 1 or 0
							end,
						},
						{
							"uv_offset",
							"vec2",
							function(_, data, key)
								local x, y = render2d.GetUVTransform()
								data[key][0] = x or 0
								data[key][1] = y or 0
							end,
						},
						{
							"uv_scale",
							"vec2",
							function(_, data, key)
								local _, _, w, h = render2d.GetUVTransform()
								data[key][0] = w or 1
								data[key][1] = h or 1
							end,
						},
					},
				},
				{
					name = "love_user",
					block = block,
				},
			},
			custom_declarations = table.concat(defines, "\n") .. [[

					vec4 love_texel(int tex, vec2 coords) {
						if (tex < 0) return vec4(0.0);
						return texture(TEXTURE(tex), coords);
					}

					vec4 love_image_texelFetch(int tex, ivec2 coords, int lod) {
						if (tex < 0) return vec4(0.0);
						return texelFetch(TEXTURE(tex), coords, lod);
					}
				]] .. (
					#volume_uniform_declarations > 0 and
					(
						"\n" .. volume_uniform_declarations
					)
					or
					""
				),
			shader = append_generated_stage(
				stripped_source,
				[[
					void main() {
						vec4 love_color = in_color * U.global_color;
						vec2 love_texture_coords = in_uv * U.uv_scale + U.uv_offset;
						out_color = effect(love_color, U.texture_index, love_texture_coords, gl_FragCoord.xy);
						out_color.a *= U.alpha_multiplier;
						if (U.discard_zero_alpha != 0 && out_color.a <= 0.0) discard;
					}
				]]
			),
		},
		CullMode = "none",
		Blend = true,
		SrcColorBlendFactor = "src_alpha",
		DstColorBlendFactor = "one_minus_src_alpha",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "zero",
		AlphaBlendOp = "add",
		ColorWriteMask = {"r", "g", "b", "a"},
		DepthTest = false,
		DepthWrite = true,
		StencilTest = false,
		FrontStencilFailOp = "keep",
		FrontStencilPassOp = "keep",
		FrontStencilDepthFailOp = "keep",
		FrontStencilCompareOp = "always",
		BackStencilFailOp = "keep",
		BackStencilPassOp = "keep",
		BackStencilDepthFailOp = "keep",
		BackStencilCompareOp = "always",
	}
	return EasyPipeline.New(config)
end

local function build_vertex_fragment_pipeline(obj, source)
	local stripped_source, varyings = parse_love_shader_varyings(source)
	stripped_source, uniforms = parse_love_shader_uniforms(stripped_source)
	local vertex_section = extract_vertex_source(stripped_source)
	local fragment_section = extract_fragment_source(stripped_source)

	if not vertex_section or not fragment_section then
		obj.warning_message = "Love shader is missing a #ifdef VERTEX or #ifdef PIXEL section"
		warn_unsupported_love_vertex_shader()
		return nil
	end

	local cleaned_vertex, attributes = parse_love_shader_attributes(vertex_section)
	local cleaned_fragment = fragment_section
	local has_fragment_effect = has_love_effect_function(cleaned_fragment)
	local image_names = collect_image_identifiers(stripped_source, uniforms)
	cleaned_vertex = rewrite_volume_texture_fetches(cleaned_vertex, uniforms)
	cleaned_fragment = rewrite_volume_texture_fetches(cleaned_fragment, uniforms)
	cleaned_vertex = rewrite_image_texture_fetches(cleaned_vertex, image_names)
	cleaned_fragment = rewrite_image_texture_fetches(cleaned_fragment, image_names)
	cleaned_vertex = rewrite_shader_identifiers(cleaned_vertex, varyings, "out_")
	cleaned_fragment = rewrite_shader_identifiers(cleaned_fragment, varyings, "in_")
	cleaned_vertex = rewrite_shader_identifiers(cleaned_vertex, attributes, "in_")
	cleaned_vertex = rewrite_love_shader_identifiers(cleaned_vertex, uniforms)
	cleaned_fragment = rewrite_love_shader_identifiers(cleaned_fragment, uniforms)
	local volume_uniform_declarations = build_volume_uniform_declarations(uniforms)
	register_shader_uniform(obj, "love_ScreenSize")
	local user_block = build_shader_uniform_block(obj, uniforms)
	local outputs = {
		{"uv", "vec2"},
		{"color", "vec4"},
	}

	for _, varying in ipairs(varyings) do
		outputs[#outputs + 1] = {varying.name, varying.kind}
	end

	for _, uniform in ipairs(uniforms) do
		register_shader_uniform(obj, uniform.name)

		if uniform.default ~= nil then
			obj.uniforms[uniform.name] = clone_uniform_value(uniform.default)
		end
	end

	obj.instance_attributes = attributes
	obj.instance_binding = #attributes > 0 and 1 or nil
	return EasyPipeline.New{
		name = "love_shader_vertex_fragment",
		dont_create_framebuffers = true,
		RasterizationSamples = function()
			return render.target:GetSamples()
		end,
		ColorFormat = render.target:GetColorFormat(),
		vertex = {
			uniform_buffers = {
				{
					block = {
						{
							"projection_view_world",
							"mat4",
							function(self, data, key)
								copy_love_shader_projection_matrix(data[key])
							end,
						},
						{
							"world_matrix",
							"mat4",
							function(self, data, key)
								copy_love_shader_world_matrix(data[key])
							end,
						},
						{
							"apply_love_depth",
							"int",
							function(_, data, key)
								local compare_mode = render2d.GetDepthMode()
								data[key] = compare_mode ~= "none" and 1 or 0
							end,
						},
					},
				},
				{
					name = "love_user",
					block = user_block,
				},
			},
			bindings = build_shader_vertex_bindings(attributes),
			outputs = outputs,
			shader = append_generated_stage(
				cleaned_vertex,
				[[
					void main() {
						out_uv = in_uv;
						out_color = in_color;
						vec4 love_local_vertex_position = vec4(in_pos, 1.0);
						vec4 love_depth_position = position(U.world_matrix, love_local_vertex_position);
						gl_Position = position(U.projection_view_world, love_local_vertex_position);
						if (U.apply_love_depth != 0) {
							gl_Position.z = clamp(1.0 - love_depth_position.z, 0.0, 1.0) * gl_Position.w;
						}
					}
				]]
			),
		},
		fragment = {
			uniform_buffers = {
				{
					block = {
						{
							"global_color",
							"vec4",
							function(_, data, key)
								local r, g, b, a = render2d.GetColor()
								data[key][0] = r or 1
								data[key][1] = g or 1
								data[key][2] = b or 1
								data[key][3] = a or 1
							end,
						},
						{
							"alpha_multiplier",
							"float",
							function(_, data, key)
								data[key] = render2d.GetAlphaMultiplier()
							end,
						},
						{
							"texture_index",
							"int",
							function(self, data, key)
								local texture = render2d.GetTexture()
								data[key] = texture and self:GetTextureIndex(texture) or -1
							end,
						},
						{
							"discard_zero_alpha",
							"int",
							function(_, data, key)
								local compare_mode = render2d.GetDepthMode()
								data[key] = compare_mode ~= "none" and 1 or 0
							end,
						},
						{
							"uv_offset",
							"vec2",
							function(_, data, key)
								local x, y = render2d.GetUVTransform()
								data[key][0] = x or 0
								data[key][1] = y or 0
							end,
						},
						{
							"uv_scale",
							"vec2",
							function(_, data, key)
								local _, _, w, h = render2d.GetUVTransform()
								data[key][0] = w or 1
								data[key][1] = h or 1
							end,
						},
					},
				},
				{
					name = "love_user",
					block = user_block,
				},
			},
			custom_declarations = [[
					#define number float
					#define Image int
					#define extern

					vec4 love_texel(int tex, vec2 coords) {
						if (tex < 0) return vec4(0.0);
						return texture(TEXTURE(tex), coords);
					}

					vec4 love_image_texelFetch(int tex, ivec2 coords, int lod) {
						if (tex < 0) return vec4(0.0);
						return texelFetch(TEXTURE(tex), coords, lod);
					}

					#define Texel(tex, coords) love_texel((tex), (coords))
				]] .. (
					#volume_uniform_declarations > 0 and
					(
						"\n" .. volume_uniform_declarations
					)
					or
					""
				),
			shader = append_generated_stage(
				cleaned_fragment,
				[[
					void main() {
						vec4 love_color = in_color * U.global_color;
						vec2 love_texture_coords = in_uv * U.uv_scale + U.uv_offset;
						]] .. (
						has_fragment_effect and
						"out_color = effect(love_color, U.texture_index, love_texture_coords, gl_FragCoord.xy);" or
						"out_color = love_texel(U.texture_index, love_texture_coords) * love_color;"
					) .. [[
						out_color.a *= U.alpha_multiplier;
						if (U.discard_zero_alpha != 0 && out_color.a <= 0.0) discard;
					}
				]]
			),
		},
		CullMode = "none",
		Blend = true,
		SrcColorBlendFactor = "src_alpha",
		DstColorBlendFactor = "one_minus_src_alpha",
		ColorBlendOp = "add",
		SrcAlphaBlendFactor = "one",
		DstAlphaBlendFactor = "zero",
		AlphaBlendOp = "add",
		ColorWriteMask = {"r", "g", "b", "a"},
		DepthTest = false,
		DepthWrite = true,
		StencilTest = false,
		FrontStencilFailOp = "keep",
		FrontStencilPassOp = "keep",
		FrontStencilDepthFailOp = "keep",
		FrontStencilCompareOp = "always",
		BackStencilFailOp = "keep",
		BackStencilPassOp = "keep",
		BackStencilDepthFailOp = "keep",
		BackStencilCompareOp = "always",
	}
end

function Shader:getWarnings()
	return self.warning_message or ""
end

function Shader:hasUniform(name)
	if self.uniform_names and self.uniform_names[name] ~= nil then
		return self.uniform_names[name]
	end

	if self.shader and self.shader.program and self.shader.program.GetUniformLocation then
		local ok, loc = pcall(self.shader.program.GetUniformLocation, self.shader.program, name)

		if ok then return loc ~= nil and loc ~= -1 end
	end

	return false
end

function Shader:sendColor(name, tbl, ...)
	if ... then warning("uh oh") end

	store_shader_uniform(self, name, {tbl[1], tbl[2], tbl[3], tbl[4]})

	if not (self.shader and self.shader.program) then return end

	local loc = self.shader.program:GetUniformLocation(name)
	self.shader.program:UploadColor(loc, ColorBytes(unpack(tbl)))
end

function Shader:send(name, var, ...)
	if ... then warning("uh oh") end

	store_shader_uniform(self, name, var)

	if not (self.shader and self.shader.program) then return end

	local loc = self.shader.program:GetUniformLocation(name)
	local t = type(var)

	if t == "number" then
		self.shader.program:UploadNumber(loc, var)
	elseif t == "boolean" then
		self.shader.program:UploadBoolean(loc, var)
	elseif ENV.textures[var] then
		self.shader.program:UploadTexture(loc, ENV.textures[var], 0, 0)
	elseif t == "table" then
		if type(var[1]) == "number" then
			if #var == 2 then
				self.shader.program:UploadVec2(loc, Vec2(unpack(var)))
			elseif #var == 3 then
				self.shader.program:UploadVec3(loc, Vec3(unpack(var)))
			elseif #var == 16 then
				self.shader.program:UploadMatrix44(loc, Vec2(unpack(var)))
			end
		else
			if #var == 4 then
				self.shader.program:UploadMatrix44(
					loc,
					Matrix44(
						var[1][1],
						var[1][2],
						var[1][3],
						var[1][4],
						var[2][1],
						var[2][2],
						var[2][3],
						var[2][4],
						var[3][1],
						var[3][2],
						var[3][3],
						var[3][4],
						var[4][1],
						var[4][2],
						var[4][3],
						var[4][4]
					)
				)
			elseif #var == 3 then
				warning("uh oh")
			end
		end
	end
end

function love.graphics.newShader(frag, vert)
	local frag_path = type(frag) == "string" and frag or nil
	local vert_path = type(vert) == "string" and vert or nil
	frag = load_shader_source_if_path(frag)
	vert = load_shader_source_if_path(vert)
	frag = patch_balatro_hover_shader_source(frag, frag_path)
	vert = patch_balatro_hover_shader_source(vert, vert_path)
	local obj = line.CreateObject("Shader", love)
	obj.uniforms = {}
	obj.uniform_names = {}
	obj.source = {fragment = frag, vertex = vert}
	obj.warning_message = nil

	if render.CreateShader then
		obj.shader = render.CreateShader{
			fragment = {
				mesh_layout = {
					{uv = "vec2"},
				},
				variables = {
					love_ScreenSize = {
						vec2 = function()
							if ENV.graphics_current_canvas then
								local tex_w, tex_h = ENV.graphics_current_canvas.fb:GetColorTexture():GetSize():Unpack()
								return Vec2(tex_w, tex_h)
							end

							return window.GetSize()
						end,
					},
					current_texture = {
						texture = function()
							return render2d.shader and render2d.shader.tex or nil
						end,
					},
					current_color = {
						color = function()
							return render2d.shader and render2d.shader.global_color or nil
						end,
					},
				},
				include_directories = {
					"shaders/include/",
				},
				source = [[
						#version 430 core

						#define number float
						#define Image sampler2D
						#define Texel texture2D
						#define extern uniform
						#define PIXEL 1

						]] .. frag .. [[

						out vec4 out_color;

						void main()
						{
							out_color = effect(current_color, current_texture, uv, gl_FragCoord.xy);
						}
					]],
			},
		}
	else
		if frag and frag:find("#ifdef%s+VERTEX") then
			obj.shader = build_vertex_fragment_pipeline(obj, frag)
		else
			obj.shader = build_fragment_pipeline(obj, frag)
		end

		if not obj.shader then warn_missing_custom_shader_backend() end
	end

	obj.pipeline = obj.shader
	return obj
end

line.RegisterType(Shader, love)
love.graphics.newPixelEffect = love.graphics.newShader

function love.graphics.setShader(obj)
	ENV.current_shader = obj
	render2d.shader_override = obj and obj.pipeline or nil

	if render2d.cmd then render2d.BindPipeline(render2d.cmd) end
end

function love.graphics.getShader()
	return ENV.current_shader
end

love.graphics.setPixelEffect = love.graphics.setShader
return love.graphics
