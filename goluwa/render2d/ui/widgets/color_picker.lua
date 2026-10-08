local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Texture = import("goluwa/render/texture.lua")
local Control = import("goluwa/render2d/ui/widgets/properties/control.lua")
local ColorSurface = import("goluwa/render2d/ui/widgets/color_surface.lua")
local StepNumberValue = import("goluwa/render2d/ui/widgets/step_number_value.lua")
local Column = import("goluwa/render2d/ui/elements/column.lua")
local Row = import("goluwa/render2d/ui/elements/row.lua")
local Text = import("goluwa/render2d/ui/elements/text.lua")
local TextEdit = import("goluwa/render2d/ui/elements/text_edit.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("color_picker")
META.Base = Control
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentX = "stretch",
	ChildGap = "XS",
}
META:StartStorable()
META:GetSet("Value", nil)
META:GetSet("SVSize", nil)
META:GetSet("SliderSize", nil)
META:GetSet("InputSize", nil)
META:GetSet("SVTextureResolution", 128)
META:GetSet("SliderTextureResolution", 256)
META:EndStorable()
local channels = {
	{label = "R", key = "r"},
	{label = "G", key = "g"},
	{label = "B", key = "b"},
	{label = "A", key = "a"},
}

local function clamp_unit(value)
	return math.clamp(tonumber(value) or 0, 0, 1)
end

local function clamp_byte(value)
	return math.clamp(math.floor((tonumber(value) or 0) + 0.5), 0, 255)
end

local function copy_color(color)
	return Color(color.r, color.g, color.b, color.a)
end

local function get_color_bytes(color)
	return {
		r = clamp_byte(color.r * 255),
		g = clamp_byte(color.g * 255),
		b = clamp_byte(color.b * 255),
		a = clamp_byte(color.a * 255),
	}
end

local function format_hex(color)
	local bytes = get_color_bytes(color)
	return string.format("#%02X%02X%02X%02X", bytes.r, bytes.g, bytes.b, bytes.a)
end

local function parse_hex(text)
	local normalized = tostring(text or ""):upper():gsub("%s+", "")

	if normalized == "" then return nil, false end

	if not normalized:find("^#") then normalized = "#" .. normalized end

	if not normalized:find("^#%x%x%x%x%x%x%x?%x?$") then return nil, false end

	if #normalized == 7 then return Color.FromHex(normalized .. "FF"), true end

	if #normalized == 9 then return Color.FromHex(normalized), true end

	return nil, false
end

local function create_texture(width, height)
	return Texture.New{
		width = width,
		height = height,
		format = "r8g8b8a8_unorm",
		mip_map_levels = 1,
		sampler = {
			min_filter = "linear",
			mag_filter = "linear",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
end

local function shade_sv_texture(texture, hue)
	local hue_color = Color.FromHSV(hue, 1, 1)
	texture:Shade(
		[[
			vec3 hue_color = vec3(]] .. hue_color.r .. ", " .. hue_color.g .. ", " .. hue_color.b .. [[);
			vec3 saturated = mix(vec3(1.0), hue_color, clamp(uv.x, 0.0, 1.0));
			float value = clamp(uv.y, 0.0, 1.0);
			return vec4(saturated * value, 1.0);
		]]
	)
end

local function shade_hue_texture(texture)
	texture:Shade([[
			float hue = clamp(1.0 - uv.y, 0.0, 1.0);
			vec3 c = vec3(-hue + 1, 1.0, 1.0);
			vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
			vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
			vec3 rgb = c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
			return vec4(rgb, 1.0);
		]])
end

local function shade_alpha_texture(texture)
	texture:Shade([[
			float alpha = clamp(1.0 - uv.y, 0.0, 1.0);
			float checker = mod(floor(uv.x * 8.0) + floor(uv.y * 32.0), 2.0);
			vec3 checker_color = mix(vec3(1.0), vec3(0.82), checker);
			vec3 rgb = mix(checker_color, vec3(1.0), -alpha+1);
			return vec4(rgb, 1.0);
		]])
end

local function on_sv_change(normalized, surface)
	local picker = surface.Picker

	if picker._suppress_updates then return end

	picker:apply_hsva(picker._hue, normalized.x, normalized.y, picker._alpha, true)
end

local function on_hue_change(normalized, surface)
	local picker = surface.Picker

	if picker._suppress_updates then return end

	picker:apply_hsva(normalized, picker._saturation, picker._value, picker._alpha, true)
end

local function on_alpha_change(normalized, surface)
	local picker = surface.Picker

	if picker._suppress_updates then return end

	picker:apply_hsva(picker._hue, picker._saturation, picker._value, normalized, true)
end

local function on_channel_change(value, old_value, input)
	local picker = input.Picker

	if picker._suppress_updates then return end

	local bytes = get_color_bytes(picker._color)
	bytes[input.ChannelKey] = clamp_byte(value)
	picker:apply_color(Color.FromBytes(bytes.r, bytes.g, bytes.b, bytes.a), true, true)
end

local function on_hex_change(text_edit, text)
	local picker = text_edit.Picker

	if picker._suppress_updates then return end

	local color, ok = parse_hex(text)

	if ok then picker:apply_color(color, true, true) end
end

local function labeled(label, child)
	return Column{
		layout = {
			FitHeight = true,
			ChildGap = "XXS",
		},
	}{
		Text{
			Text = label,
			FontSize = "XS",
			Color = "text_disabled",
		},
		child,
	}
end

function META:OnCreate(props)
	META.BaseClass.OnCreate(self, props)
	local sv_size = self.SVSize or Vec2(220, 220)
	local slider_size = self.SliderSize or Vec2(theme.active:GetSize("L"), sv_size.y)
	local input_size = self.InputSize or Vec2(84, theme.active:GetInputHeight("M"))
	local row_gap = theme.active:GetSize("XS")
	self._color = copy_color(self.Value or Color(1, 0, 0, 1))
	self._hue = 0
	self._saturation = 0
	self._value = 0
	self._alpha = clamp_unit(self._color.a)
	self._suppress_updates = false
	self._last_sv_hue = false
	self._inputs = {}
	self._sv_texture = create_texture(self.SVTextureResolution, self.SVTextureResolution)
	self._hue_texture = create_texture(16, self.SliderTextureResolution)
	self._alpha_texture = create_texture(16, self.SliderTextureResolution)
	shade_hue_texture(self._hue_texture)
	shade_alpha_texture(self._alpha_texture)
	self._sv_surface = ColorSurface{
		Name = "color_picker_sv",
		Picker = self,
		Mode = "2d",
		Texture = self._sv_texture,
		Size = sv_size,
		OnChange = on_sv_change,
	}
	self._hue_surface = ColorSurface{
		Name = "color_picker_hue",
		Picker = self,
		Texture = self._hue_texture,
		Size = slider_size,
		OnChange = on_hue_change,
	}
	self._alpha_surface = ColorSurface{
		Name = "color_picker_alpha",
		Picker = self,
		Texture = self._alpha_texture,
		Size = slider_size,
		OnChange = on_alpha_change,
	}
	local channel_columns = {}

	for index, info in ipairs(channels) do
		self._inputs[index] = StepNumberValue{
			Picker = self,
			ChannelKey = info.key,
			Value = get_color_bytes(self._color)[info.key],
			Min = 0,
			Max = 255,
			Step = 1,
			Precision = 0,
			Size = input_size,
			MinSize = input_size,
			MaxSize = input_size,
			OnChange = on_channel_change,
		}
		channel_columns[index] = Column{
			layout = {
				FitHeight = true,
				ChildGap = "XXS",
			},
		}{
			Text{
				Text = info.label,
				FontSize = "XS",
				Color = "text_disabled",
				AlignX = 0.5,
			},
			self._inputs[index],
		}
	end

	local hex_size = Vec2(sv_size.x + slider_size.x * 2 + row_gap * 2, theme.active:GetInputHeight("S"))
	self._hex_input = TextEdit{
		Picker = self,
		Text = format_hex(self._color),
		Font = "body_strong",
		FontSize = "S",
		Size = hex_size,
		MinSize = hex_size,
		MaxSize = hex_size,
		layout = {FitWidth = false},
		OnTextChanged = on_hex_change,
	}
	self:AddChild(
		Row{
			layout = {
				ChildGap = row_gap,
				FitHeight = true,
				AlignmentY = "start",
			},
		}{
			labeled("SATURATION / VALUE", self._sv_surface),
			labeled("HUE", self._hue_surface),
			labeled("ALPHA", self._alpha_surface),
		}
	)
	self:AddChild(
		Row{
			layout = {
				ChildGap = row_gap,
				FitHeight = true,
				AlignmentY = "start",
			},
		}(channel_columns)
	)
	self:AddChild(labeled("HEX", self._hex_input))
	local hue, saturation, value = self._color:GetHSV()
	self._hue = clamp_unit(hue)
	self._saturation = clamp_unit(saturation)
	self._value = clamp_unit(value)
	self:sync_widgets()
end

function META:SetValue(color, notify)
	if not self._color then
		self.Value = color
		return self
	end

	self:apply_color(color or self._color, notify == true, true)
	return self
end

function META:GetValue()
	return copy_color(self._color)
end

function META:EncodeValue()
	return format_hex(self._color)
end

function META:EncodeAny(color)
	return format_hex(color)
end

function META:DecodeValue(text)
	return parse_hex(text)
end

function META:sync_widgets()
	self._suppress_updates = true

	if self._last_sv_hue ~= self._hue then
		self._last_sv_hue = self._hue
		shade_sv_texture(self._sv_texture, self._hue)
	end

	local bytes = get_color_bytes(self._color)
	local ordered = {bytes.r, bytes.g, bytes.b, bytes.a}

	for index, input in ipairs(self._inputs) do
		input:SetValue(ordered[index], false)
	end

	self._hex_input:SetText(format_hex(self._color))
	local color = self._color
	local brightness = color.r * 0.299 + color.g * 0.587 + color.b * 0.114
	self._sv_surface:SetMarkerColor(brightness > 0.55 and Color(0, 0, 0, 1) or Color(1, 1, 1, 1))
	self._sv_surface:SetPosition(Vec2(self._saturation, self._value))
	self._hue_surface:SetPosition(self._hue)
	self._alpha_surface:SetPosition(self._alpha)
	self._suppress_updates = false
end

function META:apply_color(next_color, notify, preserve_hue)
	next_color = copy_color(next_color)
	next_color.a = clamp_unit(next_color.a)
	local old_color = copy_color(self._color)
	self._color = next_color
	local next_hue, next_saturation, next_value = next_color:GetHSV()

	if preserve_hue and (next_saturation == 0 or next_value == 0) then
		next_hue = self._hue
	end

	self._hue = clamp_unit(next_hue or self._hue)
	self._saturation = clamp_unit(next_saturation)
	self._value = clamp_unit(next_value)
	self._alpha = clamp_unit(next_color.a)
	self:sync_widgets()

	if
		notify and
		not (
			old_color.r == next_color.r and
			old_color.g == next_color.g and
			old_color.b == next_color.b and
			old_color.a == next_color.a
		)
	then
		self.OnChange(copy_color(next_color), old_color, self)
	end
end

function META:apply_hsva(hue, saturation, value, alpha, notify)
	local color = Color.FromHSV(clamp_unit(hue), clamp_unit(saturation), clamp_unit(value))
	color.a = clamp_unit(alpha)
	self:apply_color(color, notify, false)
end

return META:Register()
