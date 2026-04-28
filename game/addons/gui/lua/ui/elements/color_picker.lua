local Vec2 = import("goluwa/structs/vec2.lua")
local Rect = import("goluwa/structs/rect.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/ecs/panel.lua")
local Texture = import("goluwa/render/texture.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Column = import("lua/ui/elements/column.lua")
local Row = import("lua/ui/elements/row.lua")
local Text = import("lua/ui/elements/text.lua")
local StepNumberValue = import("lua/ui/elements/step_number_value.lua")
local TextEdit = import("lua/ui/elements/text_edit.lua")
local theme = import("lua/ui/theme.lua")

local function clamp_unit(value)
	return math.clamp(tonumber(value) or 0, 0, 1)
end

local function clamp_byte(value)
	return math.clamp(math.floor((tonumber(value) or 0) + 0.5), 0, 255)
end

local function color_equals(a, b)
	return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a
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

local function set_text(panel, value)
	if panel and panel:IsValid() and panel.text then
		panel.text:SetText(value or "")
	end
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
			vec3 c = vec3(hue, 1.0, 1.0);
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
			vec3 rgb = mix(checker_color, vec3(1.0), alpha);
			return vec4(rgb, 1.0);
		]])
end

local function create_picker_surface(props)
	local state = {
		hovered = false,
		dragging = false,
	}
	local invert_y = props.InvertY ~= false
	local set_from_local

	local function set_from_global(owner, global_pos)
		set_from_local(owner, owner.transform:GlobalToLocal(global_pos))
	end

	set_from_local = function(owner, local_pos)
		local size = owner.transform:GetSize()
		local normalized_y = math.clamp(local_pos.y / math.max(size.y, 1), 0, 1)

		if invert_y then normalized_y = 1 - normalized_y end

		if props.Mode == "2d" then
			local normalized = Vec2(math.clamp(local_pos.x / math.max(size.x, 1), 0, 1), normalized_y)
			props.OnChange(normalized)
		else
			props.OnChange(normalized_y)
		end
	end
	return Panel.New{
		Name = props.Name,
		transform = {
			Size = props.Size,
		},
		layout = {
			GrowWidth = 0,
			FitWidth = false,
			FitHeight = false,
			MinSize = props.MinSize or props.Size,
			MaxSize = props.MaxSize or props.Size,
			props.layout,
		},
		gui_element = {
			Clipping = true,
			OnDraw = function(self)
				props.OnDraw(self.Owner, state)
			end,
		},
		mouse_input = {
			Cursor = "hand",
			OnMouseInput = function(self, button, press, local_pos)
				if button ~= "button_1" then return end

				if press then
					state.dragging = true
					set_from_local(self.Owner, local_pos)
				end

				return true
			end,
			OnGlobalMouseMove = function(self, pos)
				if not state.dragging then return end

				set_from_global(self.Owner, pos)
				return true
			end,
			OnGlobalMouseInput = function(self, button, press)
				if button == "button_1" and not press and state.dragging then
					state.dragging = false
					return true
				end
			end,
			OnHover = function(self, hovered)
				state.hovered = hovered
			end,
		},
		clickable = true,
		animation = true,
	}
end

return function(props)
	props = props or {}
	local external_ref = props.Ref

	if external_ref then
		props = table.shallow_copy(props)
		props.Ref = nil
	end

	local sv_size = props.SVSize or Vec2(220, 220)
	local slider_size = props.SliderSize or Vec2(24, sv_size.y)
	local input_size = props.InputSize or Vec2(84, 34)
	local current_color = copy_color(props.Value or Color(1, 0, 0, 1))
	local hue = 0
	local saturation = 0
	local value = 0
	local alpha = clamp_unit(current_color.a)
	local suppress_updates = false
	local last_sv_hue = false
	local input_refs = {}
	local hex_input
	local sv_texture = create_texture(props.SVTextureResolution or 128, props.SVTextureResolution or 128)
	local hue_texture = create_texture(16, props.SliderTextureResolution or 256)
	local alpha_texture = create_texture(16, props.SliderTextureResolution or 256)
	local apply_color
	shade_hue_texture(hue_texture)
	shade_alpha_texture(alpha_texture)

	local function update_hex_text()
		if hex_input and hex_input:IsValid() then
			hex_input:SetText(format_hex(current_color))
		end
	end

	local function apply_hex_text(text)
		if suppress_updates then return end

		local color, ok = parse_hex(text)

		if ok then apply_color(color, true, true) end
	end

	local function update_input_values()
		local bytes = get_color_bytes(current_color)
		local ordered = {bytes.r, bytes.g, bytes.b, bytes.a}

		for index, input in ipairs(input_refs) do
			if input and input:IsValid() then input:SetValue(ordered[index], false) end
		end
	end

	local function update_sv_texture()
		if last_sv_hue == hue then return end

		last_sv_hue = hue
		shade_sv_texture(sv_texture, hue)
	end

	local function notify_change(old_color)
		if props.OnChange then props.OnChange(copy_color(current_color), old_color) end
	end

	apply_color = function(next_color, notify, preserve_hue)
		next_color = copy_color(next_color)
		next_color.a = clamp_unit(next_color.a)
		local old_color = copy_color(current_color)
		current_color = next_color
		local next_hue, next_saturation, next_value = current_color:GetHSV()

		if preserve_hue and (next_saturation == 0 or next_value == 0) then
			next_hue = hue
		end

		hue = clamp_unit(next_hue or hue)
		saturation = clamp_unit(next_saturation)
		value = clamp_unit(next_value)
		alpha = clamp_unit(current_color.a)
		suppress_updates = true
		update_sv_texture()
		update_input_values()
		update_hex_text()
		suppress_updates = false

		if notify and not color_equals(old_color, current_color) then
			notify_change(old_color)
		end
	end

	local function apply_hsva(next_hue, next_saturation, next_value, next_alpha, notify)
		local next_color = Color.FromHSV(clamp_unit(next_hue), clamp_unit(next_saturation), clamp_unit(next_value))
		next_color.a = clamp_unit(next_alpha)
		apply_color(next_color, notify, false)
	end

	local function apply_bytes(r, g, b, a, notify)
		apply_color(
			Color.FromBytes(clamp_byte(r), clamp_byte(g), clamp_byte(b), clamp_byte(a)),
			notify,
			true
		)
	end

	local function get_marker_color()
		local brightness = current_color.r * 0.299 + current_color.g * 0.587 + current_color.b * 0.114

		if brightness > 0.55 then return Color(0, 0, 0, 1) end

		return Color(1, 1, 1, 1)
	end

	local function draw_frame(size)
		render2d.SetTexture(nil)
		render2d.SetColor(theme.GetColor("border"):Unpack())
		render2d.DrawRect(0, 0, size.x, 1)
		render2d.DrawRect(0, size.y - 1, size.x, 1)
		render2d.DrawRect(0, 0, 1, size.y)
		render2d.DrawRect(size.x - 1, 0, 1, size.y)
	end

	local function draw_sv_picker(owner)
		local size = owner.transform:GetSize()
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetTexture(sv_texture)
		render2d.DrawRect(0, 0, size.x, size.y)
		draw_frame(size)
		local marker_x = math.clamp(math.floor(saturation * (size.x - 1) + 0.5), 0, math.max(size.x - 1, 0))
		local marker_y = math.clamp(math.floor((1 - value) * (size.y - 1) + 0.5), 0, math.max(size.y - 1, 0))
		local marker_color = get_marker_color()
		render2d.SetTexture(nil)
		render2d.SetColor(marker_color:Unpack())
		render2d.DrawRect(marker_x - 6, marker_y, 13, 1)
		render2d.DrawRect(marker_x, marker_y - 6, 1, 13)
		render2d.SetColor(1 - marker_color.r, 1 - marker_color.g, 1 - marker_color.b, 1)
		render2d.DrawRect(marker_x - 7, marker_y - 7, 15, 1)
		render2d.DrawRect(marker_x - 7, marker_y + 7, 15, 1)
		render2d.DrawRect(marker_x - 7, marker_y - 7, 1, 15)
		render2d.DrawRect(marker_x + 7, marker_y - 7, 1, 15)
	end

	local function draw_vertical_picker(owner, texture, normalized)
		local size = owner.transform:GetSize()
		render2d.SetColor(1, 1, 1, 1)
		render2d.SetTexture(texture)
		render2d.DrawRect(0, 0, size.x, size.y)
		draw_frame(size)
		local y = math.clamp(math.floor((1 - normalized) * (size.y - 1) + 0.5), 0, math.max(size.y - 1, 0))
		render2d.SetTexture(nil)
		render2d.SetColor(theme.GetColor("actual_black"):Unpack())
		render2d.DrawRect(0, y - 1, size.x, 3)
		render2d.SetColor(1, 1, 1, 1)
		render2d.DrawRect(1, y, size.x - 2, 1)
	end

	local channel_children = {}
	local channels = {
		{label = "R", key = "r"},
		{label = "G", key = "g"},
		{label = "B", key = "b"},
		{label = "A", key = "a"},
	}

	for index, info in ipairs(channels) do
		channel_children[#channel_children + 1] = Column{
			layout = {
				FitHeight = true,
				ChildGap = 4,
			},
		}{
			Text{
				Text = info.label,
				FontSize = "XS",
				Color = "text_disabled",
				AlignX = "center",
			},
			StepNumberValue{
				Ref = function(self)
					input_refs[index] = self
				end,
				Value = get_color_bytes(current_color)[info.key],
				Min = 0,
				Max = 255,
				Step = 1,
				Precision = 0,
				Size = input_size,
				MinSize = input_size,
				MaxSize = input_size,
				OnChange = function(channel_value)
					if suppress_updates then return end

					local bytes = get_color_bytes(current_color)
					bytes[info.key] = clamp_byte(channel_value)
					apply_bytes(bytes.r, bytes.g, bytes.b, bytes.a, true)
				end,
			},
		}
	end

	local control = Column{
		Name = props.Name or "color_picker",
		Padding = Rect(),
		layout = {
			Direction = "y",
			GrowWidth = 1,
			FitHeight = true,
			ChildGap = 10,
			AlignmentX = "stretch",
			props.layout,
		},
	}{
		Row{
			layout = {
				ChildGap = 10,
				FitHeight = true,
				AlignmentY = "start",
			},
		}{
			Column{
				layout = {
					FitHeight = true,
					ChildGap = 4,
				},
			}{
				Text{
					Text = "SATURATION / VALUE",
					FontSize = "XS",
					Color = "text_disabled",
				},
				create_picker_surface{
					Name = "color_picker_sv",
					Mode = "2d",
					InvertY = true,
					Size = sv_size,
					OnChange = function(next_value)
						if suppress_updates then return end

						apply_hsva(hue, next_value.x, next_value.y, alpha, true)
					end,
					OnDraw = function(owner)
						draw_sv_picker(owner)
					end,
				},
			},
			Column{
				layout = {
					FitHeight = true,
					ChildGap = 4,
				},
			}{
				Text{
					Text = "HUE",
					FontSize = "XS",
					Color = "text_disabled",
				},
				create_picker_surface{
					Name = "color_picker_hue",
					Mode = "vertical",
					Size = slider_size,
					OnChange = function(next_hue)
						if suppress_updates then return end

						apply_hsva(next_hue, saturation, value, alpha, true)
					end,
					OnDraw = function(owner)
						draw_vertical_picker(owner, hue_texture, hue)
					end,
				},
			},
			Column{
				layout = {
					FitHeight = true,
					ChildGap = 4,
				},
			}{
				Text{
					Text = "ALPHA",
					FontSize = "XS",
					Color = "text_disabled",
				},
				create_picker_surface{
					Name = "color_picker_alpha",
					Mode = "vertical",
					Size = slider_size,
					OnChange = function(next_alpha)
						if suppress_updates then return end

						apply_hsva(hue, saturation, value, next_alpha, true)
					end,
					OnDraw = function(owner)
						draw_vertical_picker(owner, alpha_texture, alpha)
					end,
				},
			},
		},
		Row{
			layout = {
				ChildGap = 8,
				FitHeight = true,
				AlignmentY = "start",
			},
		}(channel_children),
		Column{
			layout = {
				FitHeight = true,
				ChildGap = 4,
			},
		}{
			Text{
				Text = "HEX",
				FontSize = "XS",
				Color = "text_disabled",
			},
			TextEdit{
				Ref = function(self)
					hex_input = self
					update_hex_text()
				end,
				Text = format_hex(current_color),
				OnTextChanged = function(text)
					apply_hex_text(text)
				end,
				FontName = "body_strong",
				FontSize = "S",
				Size = Vec2(sv_size.x + slider_size.x * 2 + 20, 34),
				MinSize = Vec2(sv_size.x + slider_size.x * 2 + 20, 34),
				MaxSize = Vec2(sv_size.x + slider_size.x * 2 + 20, 34),
				layout = {
					FitWidth = false,
				},
			},
		},
	}

	function control:SetValue(next_color, notify)
		apply_color(next_color or current_color, notify == true, true)
		return self
	end

	function control:GetValue()
		return copy_color(current_color)
	end

	local initial_hue, initial_saturation, initial_value = current_color:GetHSV()
	hue = clamp_unit(initial_hue)
	saturation = clamp_unit(initial_saturation)
	value = clamp_unit(initial_value)
	alpha = clamp_unit(current_color.a)
	update_sv_texture()
	update_input_values()
	update_hex_text()

	if external_ref then external_ref(control) end

	return control
end
