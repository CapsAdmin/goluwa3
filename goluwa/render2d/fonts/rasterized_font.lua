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
local META = prototype.CreateTemplate("rasterized_font")
META.IsFont = true
META:GetSet("Fonts", {})
META:GetSet("Padding", 0)
META:GetSet("Curve", 0)
META:IsSet("Spacing", 0)
META:IsSet("Size", 12)
META:IsSet("Scale", Vec2(1, 1))
META:GetSet("Filtering", "linear")
META:GetSet("ShadingInfo", nil)
META:IsSet("Monospace", false)
META:IsSet("Ready", false)
META:IsSet("ReverseDraw", false)

function META:OnRemove()
	if self.texture_atlas then self.texture_atlas:Remove() end
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
			local scale = 8 -- Hardcoded scale since it's used for supersampling
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
	return self.Fonts[1]:GetAscent()
end

function META:GetDescent()
	return self.Fonts[1]:GetDescent()
end

function META:Rebuild()
	self.texture_atlas:Build()
end

function META:RebuildFromScratch()
	if not self.texture_atlas then return end

	-- Clear all cached glyphs
	local codes_to_reload = {}

	for code in pairs(self.chars) do
		table.insert(codes_to_reload, code)
		self.chars[code] = nil
	end

	-- Reload all glyphs
	for _, code in ipairs(codes_to_reload) do
		self:LoadGlyph(code)
	end

	-- Rebuild the atlas
	self.texture_atlas:Build()
end

-- Override SetShadingInfo to trigger full rebuild and shading
function META:SetShadingInfo(info)
	self.ShadingInfo = info

	if self.Ready and info then self:RebuildFromScratch() end
end

function META:LoadGlyph(code)
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
			if not render.available or not render.target then return end

			local scale = 8
			local padding = self:GetPadding()
			local sw = (glyph.w + padding * 2) * scale
			local sh = (glyph.h + padding * 2) * scale
			local fb_ss = Framebuffer.New(
				{
					width = sw,
					height = sh,
					clear_color = {0, 0, 0, 0},
					format = atlas_format,
					mip_map_levels = "auto",
				}
			)

			do
				local old_cmd = render2d.cmd
				local old_w, old_h = render2d.GetSize()
				local cmd = fb_ss:Begin()
				render2d.cmd = cmd
				render2d.PushColorFormat(fb_ss.color_texture.format)
				render2d.PushSamples("1")
				render2d.PushMatrix()
				render2d.PushColor(render2d.GetColor())
				render2d.PushUV(render2d.GetUV())
				render2d.PushBlendMode(render2d.GetBlendMode())
				render2d.PushTexture(render2d.GetTexture())
				render2d.PushAlphaMultiplier(render2d.GetAlphaMultiplier())
				render2d.PushSwizzleMode(render2d.GetSwizzleMode())
				render2d.UpdateScreenSize({w = sw, h = sh})
				render2d.pipeline:Bind(render2d.cmd, render.GetCurrentFrame())
				render2d.SetColor(1, 1, 1, 1)
				render2d.SetUV()
				render2d.SetBlendMode("alpha", true)
				render2d.SetAlphaMultiplier(1)
				render2d.SetSwizzleMode(0)
				render2d.LoadIdentity()
				-- Flip coordinates so font (Y-down) renders right-side up in Y-up framebuffer
				render2d.Translate(padding * scale, (glyph.h + padding) * scale)
				render2d.Scale(scale, -scale)
				-- Shift glyph to be at (0, 0) in the padded area
				render2d.Translatef(-glyph.bitmap_left, -glyph.bitmap_top)
				glyph_source_font:DrawGlyph(glyph.glyph_data)
				render2d.PopSwizzleMode()
				render2d.PopAlphaMultiplier()
				render2d.PopTexture()
				render2d.PopBlendMode()
				render2d.PopUV()
				render2d.PopColor()
				render2d.PopMatrix()
				render2d.PopSamples()
				render2d.PopColorFormat()
				fb_ss:End()
				fb_ss.color_texture:GenerateMipmaps("shader_read_only_optimal")
				render2d.cmd = old_cmd
				render2d.UpdateScreenSize({w = old_w, h = old_h})
			end

			local current_tex = fb_ss.color_texture

			if not self.ShadingInfo then
				if code == string.byte("T") then current_tex:DumpToDisk("glyph") end
			end

			if self.ShadingInfo then
				local glyph_copy = current_tex

				for i, info in ipairs(self.ShadingInfo) do
					if info.copy then
						glyph_copy = current_tex
					else
						local fb_effect = Framebuffer.New(
							{
								width = sw,
								height = sh,
								clear_color = {0, 0, 0, 0},
								format = atlas_format,
								mip_map_levels = "auto",
							}
						)
						local pipeline = self:GetEffectPipeline(info)
						self.current_shade_tex = current_tex
						self.current_shade_info = info
						self.current_shade_glyph_copy = glyph_copy
						self.current_shade_size = Vec2(sw, sh)
						pipeline:Draw(fb_effect.cmd, fb_effect)
						current_tex = fb_effect.color_texture
						current_tex:GenerateMipmaps("shader_read_only_optimal")
					-- DEBUG: Save intermediate shading steps
					--		current_tex:DumpToDisk("debug_glyph_shade_" .. code .. "_" .. i .. "")
					end
				end
			end

			local fb_final = Framebuffer.New(
				{
					width = glyph.w + padding * 2,
					height = glyph.h + padding * 2,
					clear_color = {0, 0, 0, 0},
					format = atlas_format,
				}
			)

			do
				local pipeline = self:GetBlitPipeline()
				self.current_draw_tex = current_tex
				pipeline:Draw(fb_final.cmd, fb_final)
			-- DEBUG: Save the final downsampled glyph
			--fb_final.color_texture:DumpToDisk("debug_glyph_final_" .. code)
			end

			glyph.texture = fb_final.color_texture

			if not self.ShadingInfo then
				if code == string.byte("T") then
					glyph.texture:DumpToDisk("glyph_final")
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
		-- DEBUG: Build atlas immediately to see it
		self.texture_atlas:Build()
		self.chars[code] = glyph
	else
		self.chars[code] = false
	end
end

function META:GetChar(char)
	local data = self.chars[char]

	if data == nil then
		self:LoadGlyph(char)
		self.rebuild = true
		return self.chars[char]
	end

	if char == "\n" then
		if data then
			if data.h <= 1 then data.h = self.Size end
		else
			data = {h = self.Size}
		end
	end

	return data
end

function META:GetTextSizeNotCached(str)
	if not self.Ready then return 0, 0 end

	str = tostring(str)
	local X, Y = 0, self:GetAscent()
	local max_x = 0
	local spacing = self.Spacing

	for i, char in ipairs(utf8.to_list(str)) do
		local char_code = utf8.uint32(char)
		local data = self:GetChar(char_code)

		if char == "\n" then
			Y = Y + self:GetChar(utf8.uint32("\n")).h + spacing
			max_x = math.max(max_x, X)
			X = 0
		elseif char == "\t" then
			data = self:GetChar(utf8.uint32(" "))

			if data then
				if self.Monospace then
					X = X + spacing * self.TabWidthMultiplier
				else
					X = X + (data.x_advance + spacing) * self.TabWidthMultiplier
				end
			else
				X = X + self.Size * self.TabWidthMultiplier
			end
		elseif data then
			if self.Monospace then
				X = X + spacing
			else
				X = X + data.x_advance + spacing
			end
		elseif char == " " then
			X = X + self.Size / 2
		end
	end

	if max_x ~= 0 then X = max_x end

	return X * self.Scale.x, Y * self.Scale.y
end

function META:DrawString(str, x, y, spacing)
	if not self.Ready then return end

	-- Rebuild atlas if new glyphs were loaded
	if self.rebuild then
		self:Rebuild()
		self.rebuild = false
	end

	str = tostring(str)
	spacing = spacing or self.Spacing
	local X, Y = 0, 0

	for i, char in ipairs(utf8.to_list(str)) do
		local char_code = utf8.uint32(char)
		local data = self:GetChar(char_code)

		if char == "\n" then
			X = 0
			Y = Y + self:GetChar(utf8.uint32("\n")).h + spacing
		elseif char == "\t" then
			data = self:GetChar(utf8.uint32(" "))

			if data then
				if self.Monospace then
					X = X + spacing * self.TabWidthMultiplier
				else
					X = X + (data.x_advance + spacing) * self.TabWidthMultiplier
				end
			else
				X = X + self.Size * self.TabWidthMultiplier
			end
		elseif data then
			local texture = self.texture_atlas:GetPageTexture(char_code)

			if texture then
				render2d.SetTexture(texture)
				local u1, v1, w, h, sx, sy = self.texture_atlas:GetUV(char_code)
				local padding = self:GetPadding()
				render2d.PushMatrix()
				render2d.Translate(
					x + (X + data.bitmap_left - padding) * self.Scale.x,
					y + (Y + data.bitmap_top - padding) * self.Scale.y
				)
				render2d.PushUV()
				render2d.SetUV2(u1 / sx, v1 / sy, (u1 + w) / sx, (v1 + h) / sy)
				render2d.DrawRect(0, 0, w * self.Scale.x, h * self.Scale.y)
				render2d.PopUV()
				render2d.PopMatrix()
			end

			if self.Monospace then
				X = X + spacing
			else
				X = X + data.x_advance + spacing
			end
		elseif char == " " then
			X = X + self.Size / 2
		end
	end
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
		local cache = {} or table.weak()

		function META:GetTextSize(str)
			str = str or "|"

			if cache[self] and cache[self][str] then
				return cache[self][str][1], cache[self][str][2]
			end

			local x, y = self:GetTextSizeNotCached(str)
			cache[self] = cache[self] or table.weak()
			cache[self][str] = cache[self][str] or table.weak()
			cache[self][str][1] = x
			cache[self][str][2] = y
			return x, y
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

		local cache = table.weak()

		function META:WrapString(str, max_width)
			if cache[str] and cache[str][max_width] and cache[str][max_width][self] then
				return cache[str][max_width][self]
			end

			local size = self:GetTextSize(str)

			--print(size, max_width)
			--if max_width < size then return list.concat(str:split(""), "\n") end
			if max_width > size then return str end

			local res = wrap_2(self, str, max_width)
			cache[str] = cache[str] or {}
			cache[str][max_width] = cache[str][max_width] or {}
			cache[str][max_width][self] = res
			return res
		end
	end
end

return META:Register()
