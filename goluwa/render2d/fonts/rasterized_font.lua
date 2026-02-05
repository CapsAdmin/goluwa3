local ffi = require("ffi")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local render2d = require("render2d.render2d")
local Texture = require("render.texture")
local Framebuffer = require("render.framebuffer")
local Buffer = require("structs.buffer")
local system = require("system")
local render = require("render.render")
local prototype = require("prototype")
local utf8 = require("utf8")
local event = require("event")
local TextureAtlas = require("render.texture_atlas")
local EasyPipeline = require("render.easy_pipeline")
local Fence = require("render.vulkan.internal.fence")
local META = prototype.CreateTemplate("rasterized_font")
META.IsFont = true
META:GetSet("Fonts", {})
META:GetSet("Padding", 0, {callback = "ClearCache"})
META:GetSet("Curve", 0, {callback = "ClearCache"})
META:IsSet("Spacing", 0, {callback = "ClearCache"})
META:IsSet("Size", 12, {callback = "ClearCache"})
META:IsSet("Scale", Vec2(1, 1), {callback = "ClearCache"})
META:GetSet("Filtering", "linear", {callback = "ClearCache"})
META:GetSet("ShadingInfo", nil, {callback = "ClearCache"})
META:IsSet("Monospace", false, {callback = "ClearCache"})
META:IsSet("Ready", false)
META:IsSet("ReverseDraw", false)
local SUPER_SAMPLING_SCALE = 4

function META:ClearCache()
	self.text_size_cache = nil
	self.wrap_string_cache = nil
end

function META:OnRemove()
	if self.texture_atlas then self.texture_atlas:Remove() end
end

local function get_ascent_descent(self)
	if not self.ascent then
		self.ascent = self.Fonts[1]:GetAscent()
		self.descent = self.Fonts[1]:GetDescent()
	end

	return self.ascent, self.descent
end

META:GetSet("LoadSpeed", 10)
META:GetSet("TabWidthMultiplier", 4)
META:GetSet("Flags")
local atlas_format = "r8g8b8a8_unorm"

function META:GetEffectPipeline(info)
	self.effect_pipelines = self.effect_pipelines or {}
	local cache_key = info.source .. (info.blend_mode or "none")

	if self.effect_pipelines[cache_key] then
		return self.effect_pipelines[cache_key]
	end

	local push_constant_block = {
		{
			"self_idx",
			"int",
			function(pipeline, block, key)
				block[key] = pipeline:GetTextureIndex(self.current_shade_tex)
			end,
		},
		{
			"copy_idx",
			"int",
			function(pipeline, block, key)
				block[key] = pipeline:GetTextureIndex(self.current_shade_glyph_copy)
			end,
		},
		{
			"size",
			"vec2",
			function(pipeline, block, key)
				block[key][0] = self.current_shade_size.x
				block[key][1] = self.current_shade_size.y
			end,
		},
	}
	local glsl_header = "#define self TEXTURE(pc.fragment.self_idx)\n"
	glsl_header = glsl_header .. "#define copy TEXTURE(pc.fragment.copy_idx)\n"
	glsl_header = glsl_header .. "#define size pc.fragment.size\n"

	if info.vars then
		for k, v in pairs(info.vars) do
			local tx = typex(v)
			local scale = SUPER_SAMPLING_SCALE -- Hardcoded scale since it's used for supersampling
			if tx == "number" then
				table.insert(
					push_constant_block,
					{
						k,
						"float",
						function(pipeline, block, key)
							block[key] = self.current_shade_info.vars[k]
						end,
					}
				)
				glsl_header = glsl_header .. "#define " .. k .. " pc.fragment." .. k .. "\n"
			elseif tx == "vec2" then
				table.insert(
					push_constant_block,
					{
						k,
						"vec2",
						function(pipeline, block, key)
							local val = self.current_shade_info.vars[k]
							block[key][0] = val.x * scale
							block[key][1] = val.y * scale
						end,
					}
				)
				glsl_header = glsl_header .. "#define " .. k .. " pc.fragment." .. k .. "\n"
			elseif tx == "vec3" then
				table.insert(
					push_constant_block,
					{
						k,
						"vec3",
						function(pipeline, block, key)
							local val = self.current_shade_info.vars[k]
							block[key][0] = val.x * scale
							block[key][1] = val.y * scale
							block[key][2] = val.z * scale
						end,
					}
				)
				glsl_header = glsl_header .. "#define " .. k .. " pc.fragment." .. k .. "\n"
			elseif tx == "vec4" or tx == "color" then
				table.insert(
					push_constant_block,
					{
						k,
						"vec4",
						function(pipeline, block, key)
							local val = self.current_shade_info.vars[k]
							block[key][0] = val.r or val.x
							block[key][1] = val.g or val.y
							block[key][2] = val.b or val.z
							block[key][3] = val.a or val.w
						end,
					}
				)
				glsl_header = glsl_header .. "#define " .. k .. " pc.fragment." .. k .. "\n"
			elseif tx == "render_texture" then
				table.insert(
					push_constant_block,
					{
						k .. "_idx",
						"int",
						function(pipeline, block, key)
							local tex = self.current_shade_info.vars[k]

							if k == "copy" then tex = self.current_shade_glyph_copy end

							block[key] = pipeline:GetTextureIndex(tex)
						end,
					}
				)
				glsl_header = glsl_header .. "#define " .. k .. " TEXTURE(pc.fragment." .. k .. "_idx)\n"
			end
		end
	end

	local color_blend = nil

	if info.blend_mode == "alpha" then
		color_blend = {
			attachments = {
				{
					blend = true,
					src_color_blend_factor = "src_alpha",
					dst_color_blend_factor = "one_minus_src_alpha",
					color_blend_op = "add",
					src_alpha_blend_factor = "one",
					dst_alpha_blend_factor = "zero",
					alpha_blend_op = "add",
					color_write_mask = {"r", "g", "b", "a"},
				},
			},
		}
	end

	local pipeline = EasyPipeline.New(
		{
			color_format = {{atlas_format, {"rgba", "rgba"}}},
			samples = "1",
			color_blend = color_blend,
			rasterizer = {
				cull_mode = "none",
			},
			vertex = {
				shader = [[
				vec2 positions[3] = vec2[](
					vec2(-1.0, -1.0),
					vec2( 3.0, -1.0),
					vec2(-1.0,  3.0)
				);
				layout(location = 0) out vec2 out_uv;
				void main() {
					vec2 pos = positions[gl_VertexIndex];
					gl_Position = vec4(pos, 0.0, 1.0);
					out_uv = pos * 0.5 + 0.5;
				}
			]],
			},
			fragment = {
				custom_declarations = [[
				layout(location = 0) in vec2 in_uv;
			]],
				shader = glsl_header .. [[
				vec4 shade(vec2 uv) {
					]] .. info.source .. [[
				}
				void main() {
					set_rgba(shade(in_uv));
				}
			]],
				push_constants = {
					{
						name = "fragment",
						block = push_constant_block,
					},
				},
			},
		}
	)
	self.effect_pipelines[cache_key] = pipeline
	return pipeline
end

function META:GetBlitPipeline()
	if self.blit_pipeline then return self.blit_pipeline end

	self.blit_pipeline = EasyPipeline.New(
		{
			color_format = {{atlas_format, {"rgba", "rgba"}}},
			samples = "1",
			vertex = {
				shader = [[
				vec2 positions[3] = vec2[](
					vec2(-1.0, -1.0),
					vec2( 3.0, -1.0),
					vec2(-1.0,  3.0)
				);
				layout(location = 0) out vec2 out_uv;
				void main() {
					vec2 pos = positions[gl_VertexIndex];
					gl_Position = vec4(pos, 0.0, 1.0);
					out_uv = pos * 0.5 + 0.5;
				}
			]],
			},
			rasterizer = {
				cull_mode = "none",
			},
			depth_stencil = {
				depth_test = false,
				depth_write = false,
			},
			fragment = {
				push_constants = {
					{
						name = "fragment",
						block = {
							{
								"tex_idx",
								"int",
								function(pipeline, block, key)
									block[key] = pipeline:GetTextureIndex(self.current_draw_tex)
								end,
							},
						},
					},
				},
				shader = [[
				layout(location = 0) in vec2 in_uv;
				void main() {
					vec4 col = texture(TEXTURE(pc.fragment.tex_idx), in_uv);
					if (col.a > 0.0001) col.rgb /= col.a;
					set_rgba(col);
				}
			]],
			},
		}
	)
	return self.blit_pipeline
end

local function create_atlas(self)
	local atlas_size = 512

	if self.Size > 32 then atlas_size = 1024 end

	if self.Size > 64 then atlas_size = 2048 end

	if self.Size > 128 then atlas_size = 4096 end

	self.texture_atlas = TextureAtlas.New(atlas_size, atlas_size, self.Filtering, atlas_format)
	self.texture_atlas:SetMipMapLevels("auto")
	self.texture_atlas:SetPadding(0)

	for code in pairs(self.chars) do
		self.chars[code] = nil
		self:LoadGlyph(code)
	end

	self.texture_atlas:Build()
	self:SetReady(true)
end

function META.New(fonts, padding)
	if type(fonts) == "table" and fonts.IsFont then fonts = {fonts} end

	local self = META:CreateObject()
	self.tr = debug.traceback()
	self:SetFonts(fonts)
	self:SetPadding(padding or 0)
	self.chars = {}
	self.rebuild = false

	-- Get size from first font
	if fonts[1] and fonts[1].Size then self:SetSize(fonts[1].Size) end

	if render.target then
		create_atlas(self)
	else
		event.AddListener("RendererReady", self, function()
			create_atlas(self)
			return event.destroy_tag
		end)
	end

	return self
end

function META:GetAscent()
	local a, d = get_ascent_descent(self)
	return a
end

function META:GetDescent()
	local a, d = get_ascent_descent(self)
	return d
end

function META:Rebuild(cmd)
	self.texture_atlas:Build(cmd)
end

function META:RebuildFromScratch(cmd)
	if not self.texture_atlas then return end

	-- Clear all cached glyphs
	local codes_to_reload = {}

	for code in pairs(self.chars) do
		table.insert(codes_to_reload, code)
		self.chars[code] = nil
	end

	-- Reload all glyphs
	for _, code in ipairs(codes_to_reload) do
		self:LoadGlyph(code, cmd)
	end

	-- Rebuild the atlas
	self.texture_atlas:Build(cmd)
end

-- Override SetShadingInfo to trigger full rebuild and shading
function META:SetShadingInfo(info)
	self.ShadingInfo = info

	if self.Ready and info then self:RebuildFromScratch() end
end

local scratch_size = {w = 0, h = 0}
local fb_pool = {}
local fence_pool = {}

local function get_fence(device)
	local f = table.remove(fence_pool)

	if f then return f end

	return Fence.New(device)
end

local function release_fence(f)
	table.insert(fence_pool, f)
end

local function get_temp_fb(w, h, format, mip_maps)
	local key = string.format("%d_%d_%s_%s", w, h, format, tostring(mip_maps))
	fb_pool[key] = fb_pool[key] or {}
	local fb = table.remove(fb_pool[key])

	if not fb then
		fb = Framebuffer.New(
			{
				width = w,
				height = h,
				clear_color = {0, 0, 0, 0},
				format = format,
				mip_map_levels = mip_maps and "auto" or 1,
			}
		)
	end

	return fb
end

local function release_temp_fb(fb)
	local key = string.format(
		"%d_%d_%s_%s",
		fb.width,
		fb.height,
		fb.format,
		tostring(fb.mip_map_levels ~= 1)
	)
	fb_pool[key] = fb_pool[key] or {}
	table.insert(fb_pool[key], fb)
end

function META:LoadGlyph(code, parent_cmd, temp_fbs)
	-- Convert string to character code if needed
	if type(code) == "string" then code = utf8.uint32(code) end

	if self.chars[code] ~= nil then return end

	local glyph
	local glyph_source_font

	for i = 1, #self.Fonts do
		local font = self.Fonts[i]
		glyph = font:GetGlyph(code)

		if glyph then
			glyph_source_font = font

			break
		end
	end

	if glyph then
		if not glyph.buffer and glyph.glyph_data and glyph.w > 0 and glyph.h > 0 then
			if not render.available or not render.target then
				-- Renderer not ready, don't cache yet so we can try again later
				return
			end

			local scale = SUPER_SAMPLING_SCALE
			local padding = self:GetPadding()
			local sw = (glyph.w + padding * 2) * scale
			local sh = (glyph.h + padding * 2) * scale
			local used_temp_fbs = {}
			local fb_ss = get_temp_fb(sw, sh, atlas_format, true)
			table.insert(used_temp_fbs, fb_ss)
			local own_cmd = false
			local cmd = parent_cmd

			if not cmd then
				cmd = render.GetCommandPool():AllocateCommandBuffer()
				cmd:Begin()
				own_cmd = true
			end

			do
				render2d.ResetState()
				local old_cmd = render2d.cmd
				local old_w, old_h = render2d.GetSize()
				fb_ss:Begin(cmd)
				render2d.cmd = cmd
				render2d.PushColorFormat(fb_ss.color_texture.format)
				render2d.PushSamples("1")
				local old_color = {render2d.GetColor()}
				render2d.SetColor(1, 1, 1, 1)
				local old_blend_mode = render2d.GetBlendMode()
				render2d.SetBlendMode("alpha", true)
				render2d.PushSwizzleMode(render2d.GetSwizzleMode())
				scratch_size.w = sw
				scratch_size.h = sh
				render2d.UpdateScreenSize(scratch_size)
				render2d.pipeline:Bind(render2d.cmd, render.GetCurrentFrame())
				render2d.SetSwizzleMode(0)
				render2d.PushMatrix()
				render2d.LoadIdentity()
				-- Flip coordinates so font (Y-down) renders right-side up in Y-up framebuffer
				render2d.Translate(padding * scale, (glyph.h + padding) * scale)
				render2d.Scale(scale, -scale)
				-- Shift glyph to be at (0, 0) in the padded area
				render2d.Translatef(-glyph.bitmap_left, -glyph.bitmap_top)
				glyph_source_font:DrawGlyph(glyph.glyph_data)
				render2d.PopMatrix()
				render2d.PopSwizzleMode()
				render2d.SetBlendMode(old_blend_mode, true)
				render2d.SetColor(unpack(old_color))
				render2d.PopSamples()
				render2d.PopColorFormat()
				fb_ss:End(cmd)
				fb_ss.color_texture:GenerateMipmaps("shader_read_only_optimal", cmd)
				render2d.cmd = old_cmd
				scratch_size.w = old_w
				scratch_size.h = old_h
				render2d.UpdateScreenSize(scratch_size)
			end

			local current_tex = fb_ss.color_texture

			if self.ShadingInfo then
				local glyph_copy = current_tex

				for i, info in ipairs(self.ShadingInfo) do
					if info.copy then
						glyph_copy = current_tex
					else
						local fb_effect = get_temp_fb(sw, sh, atlas_format, true)
						table.insert(used_temp_fbs, fb_effect)
						local pipeline = self:GetEffectPipeline(info)
						self.current_shade_tex = current_tex
						self.current_shade_info = info
						self.current_shade_glyph_copy = glyph_copy
						self.current_shade_size = Vec2(sw, sh)
						pipeline:Draw(cmd, fb_effect)
						current_tex = fb_effect.color_texture
						current_tex:GenerateMipmaps("shader_read_only_optimal", cmd)
					end
				end
			end

			local fb_final = get_temp_fb(glyph.w + padding * 2, glyph.h + padding * 2, atlas_format, false)
			table.insert(used_temp_fbs, fb_final)

			do
				local pipeline = self:GetBlitPipeline()
				self.current_draw_tex = current_tex
				pipeline:Draw(cmd, fb_final)
			end

			glyph.texture = fb_final.color_texture

			if own_cmd then
				cmd:End()
				local fence = get_fence(render.GetDevice())
				render.GetQueue():SubmitAndWait(render.GetDevice(), cmd, fence)
				release_fence(fence)

				for _, fb in ipairs(used_temp_fbs) do
					release_temp_fb(fb)
				end
			elseif temp_fbs then
				for _, fb in ipairs(used_temp_fbs) do
					table.insert(temp_fbs, fb)
				end
			end
		end

		self.texture_atlas:Insert(
			code,
			{
				w = glyph.w + self:GetPadding() * 2,
				h = glyph.h + self:GetPadding() * 2,
				texture = glyph.texture,
				flip_y = glyph.flip_y,
			}
		)
		self.chars[code] = glyph
	else
		self.chars[code] = false
	end
end

function META:GetChar(char)
	local data = self.chars[char]

	if data ~= nil then
		if char == 10 then
			if data then
				if data.h <= 1 then data.h = self.Size end
			else
				data = {h = self.Size}
				self.chars[10] = data
			end
		end

		return data
	end

	self.rebuild = true
	self:LoadGlyph(char)
	data = self.chars[char]

	if char == 10 then
		if data then
			if data.h <= 1 then data.h = self.Size end
		else
			data = {h = self.Size}
			self.chars[10] = data
		end
	end

	return data
end

local function batch_load_glyphs(self, str)
	local i = 1
	local len = #str
	local any_new = false

	while i <= len do
		local char_code = utf8.uint32(str, i)

		if self.chars[char_code] == nil then
			any_new = true

			break
		end

		i = i + utf8.byte_length(str, i)
	end

	if not any_new then return end

	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	i = 1
	local temp_fbs = {}

	while i <= len do
		local char_code = utf8.uint32(str, i)
		self:LoadGlyph(char_code, cmd, temp_fbs)
		i = i + utf8.byte_length(str, i)
	end

	self:Rebuild(cmd)
	cmd:End()
	local fence = get_fence(render.GetDevice())
	render.GetQueue():SubmitAndWait(render.GetDevice(), cmd, fence)
	release_fence(fence)
	self.rebuild = false

	for _, fb in ipairs(temp_fbs) do
		release_temp_fb(fb)
	end
end

function META:GetLineHeight()
	local a, d = get_ascent_descent(self)
	return (a + d)
end

function META:GetTextSizeNotCached(str)
	if not self:IsReady() then return 0, 0 end

	str = tostring(str)
	batch_load_glyphs(self, str)
	local X, Y = 0, self:GetLineHeight()
	local max_x = 0
	local spacing = self.Spacing
	local line_height = self:GetLineHeight()
	local i = 1
	local len = #str

	while i <= len do
		local char_code = utf8.uint32(str, i)

		if char_code == 10 then -- \n
			Y = Y + line_height + spacing
			max_x = math.max(max_x, X)
			X = 0
		elseif char_code == 32 then -- space
			X = X + self.Size / 2
		elseif char_code == 9 then -- \t
			local data = self:GetChar(32)

			if data then
				if self.Monospace then
					X = X + spacing * self.TabWidthMultiplier
				else
					X = X + (data.x_advance + spacing) * self.TabWidthMultiplier
				end
			else
				X = X + self.Size * self.TabWidthMultiplier
			end
		else
			local data = self.chars[char_code]

			if data then
				if self.Monospace then
					X = X + spacing
				else
					X = X + data.x_advance + spacing
				end
			end
		end

		i = i + utf8.byte_length(str, i)
	end

	if max_x ~= 0 then X = math.max(max_x, X) end

	return X * self.Scale.x, Y * self.Scale.y
end

function META:DrawString(str, x, y, spacing)
	if not self:IsReady() then return end

	str = tostring(str)
	batch_load_glyphs(self, str)
	spacing = spacing or self.Spacing
	local X, Y = 0, 0
	local i = 1
	local len = #str
	local last_texture
	local padding = self:GetPadding()
	local scale_x, scale_y = self.Scale.x, self.Scale.y
	local line_height = self:GetLineHeight()
	render2d.PushUV()

	while i <= len do
		local char_code = utf8.uint32(str, i)

		if char_code == 10 then -- \n
			X = 0
			Y = Y + line_height + spacing
		elseif char_code == 32 then -- space
			X = X + self.Size / 2
		elseif char_code == 9 then -- \t
			local data = self:GetChar(32)

			if data then
				if self.Monospace then
					X = X + spacing * self.TabWidthMultiplier
				else
					X = X + (data.x_advance + spacing) * self.TabWidthMultiplier
				end
			else
				X = X + self.Size * self.TabWidthMultiplier
			end
		else
			local data = self.chars[char_code]

			if data then
				local texture = self.texture_atlas:GetPageTexture(char_code)

				if texture then
					if texture ~= last_texture then
						render2d.SetTexture(texture)
						last_texture = texture
					end

					local uv, aw, ah = self.texture_atlas:GetNormalizedUV(char_code)
					render2d.SetUV2(uv[1], uv[2], uv[3], uv[4])
					render2d.DrawRect(
						x + (X + data.bitmap_left - padding) * scale_x,
						y + (Y + data.bitmap_top - padding) * scale_y,
						aw * scale_x,
						ah * scale_y
					)
				end

				if self.Monospace then
					X = X + spacing
				else
					X = X + data.x_advance + spacing
				end
			end
		end

		i = i + utf8.byte_length(str, i)
	end

	render2d.PopUV()
end

do
	-- Drawing functions
	function META:DrawText(str, x, y, spacing, align_x, align_y)
		if align_x or align_y then
			local w, h = self:GetTextSize(str)

			if type(align_x) == "number" then
				x = x - (w * align_x)
			elseif align_x == "center" then
				x = x - (w / 2)
			elseif align_x == "right" then
				x = x - w
			end

			if type(align_y) == "number" then
				y = y - (h * align_y)
			elseif align_y == "baseline" then
				y = y - self:GetAscent()
			elseif align_y == "center" then
				y = y - (h / 2)
			elseif align_y == "bottom" then
				y = y - h
			end
		end

		self:DrawString(str, x, y, spacing)
	end

	do
		function META:GetTextSize(str)
			if type(str) ~= "string" then str = tostring(str or "|") end

			self.text_size_cache = self.text_size_cache or {}

			if self.text_size_cache[str] then
				return self.text_size_cache[str][1], self.text_size_cache[str][2]
			end

			local w, h = self:GetTextSizeNotCached(str)

			if self:IsReady() then
				self.text_size_cache[str] = {w, h}
				self.text_size_cache_count = (self.text_size_cache_count or 0) + 1

				if self.text_size_cache_count > 1000 then
					self.text_size_cache = {}
					self.text_size_cache_count = 0
				end
			end

			return w, h
		end
	end

	do -- text wrap
		local function wrap_1(str, max_width)
			local lines = {}
			local i = 1
			local last_pos = 0
			local line_width = 0
			local space_pos
			local tbl = str:utf8_to_list()

			--local pos = 1
			--for _ = 1, 10000 do
			--	local char = tbl[pos]
			--	if not char then break end
			for pos, char in ipairs(tbl) do
				local w = fonts.GetTextSize(font, char)

				if char:find("%s") then space_pos = pos end

				if line_width + w >= max_width then
					if space_pos then
						lines[i] = str:utf8_sub(last_pos + 1, space_pos)
						last_pos = space_pos
					else
						lines[i] = str:utf8_sub(last_pos + 1, pos)
						last_pos = pos
					end

					i = i + 1
					line_width = 0
					space_pos = nil
				end

				line_width = line_width + w
			--pos = pos + 1
			end

			if lines[1] then
				lines[i] = str:utf8_sub(last_pos + 1)
				return list.concat(lines, "\n")
			end

			return str
		end

		local function wrap_2(self, str, max_width)
			local tbl = str:utf8_to_list()
			local lines = {}
			local chars = {}
			local i = 1
			local width = 0
			local width_before_last_space = 0
			local width_of_trailing_space = 0
			local last_space_index = -1
			local prev_char

			while i < #tbl do
				local c = tbl[i]
				local char_width = self:GetTextSize(c)
				local new_width = width + char_width

				if c == "\n" then
					list.insert(lines, list.concat(chars))
					list.clear(chars)
					width = 0
					width_before_last_space = 0
					width_of_trailing_space = 0
					prev_char = nil
					last_space_index = -1
					i = i + 1
				elseif char ~= " " and width >= max_width then
					if #chars == 0 then
						i = i + 1
					elseif last_space_index ~= -1 then
						for i = #chars, 1, -1 do
							if chars[i] == " " then break end

							list.remove(chars, i)
						end

						width = width_before_last_space
						i = last_space_index
						i = i + 1
					end

					list.insert(lines, list.concat(chars))
					list.clear(chars)
					prev_char = nil
					width = char_width
					width_before_last_space = 0
					width_of_trailing_space = 0
					last_space_index = -1
				else
					if prev_char ~= " " and c == " " then
						width_before_last_space = width
					end

					width = new_width
					prev_char = c
					list.insert(chars, c)

					if c == " " then
						last_space_index = i
					elseif c ~= "\n" then
						width_of_trailing_space = 0
					end

					i = i + 1
				end
			end

			if #chars ~= 0 then list.insert(lines, list.concat(chars)) end

			return list.concat(lines, "\n")
		end

		function META:WrapString(str, max_width)
			str = tostring(str or "")
			self.wrap_string_cache = self.wrap_string_cache or {}
			local cache = self.wrap_string_cache

			if cache[str] and cache[str][max_width] then
				return cache[str][max_width]
			end

			local size = self:GetTextSize(str)

			--print(size, max_width)
			--if max_width < size then return list.concat(str:split(""), "\n") end
			if max_width > size then return str end

			local res = wrap_2(self, str, max_width)
			cache[str] = cache[str] or {}
			cache[str][max_width] = res
			return res
		end
	end
end

return META:Register()
