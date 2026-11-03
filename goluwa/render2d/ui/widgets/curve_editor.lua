local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local curve = import("goluwa/math/curve.lua")
local CANVAS = Panel:CreateTemplate("curve_canvas")
CANVAS.CMP.transform = {}
CANVAS.CMP.layout = {GrowWidth = 1, GrowHeight = 1, MinSize = Vec2(200, 160)}
CANVAS.CMP.visual = {}
CANVAS.CMP.mouse_input = {Cursor = "arrow"}
CANVAS:StartStorable()
CANVAS:GetSet("Editor", nil)
CANVAS:EndStorable()
local PAD_LEFT, PAD_TOP, PAD_RIGHT, PAD_BOTTOM = 42, 10, 14, 22
local KEY_RADIUS = 5
local PICK_RADIUS = 9
local DOUBLE_CLICK = 0.3
local SAMPLES = 96
local MODES = {"linear", "smooth", "step"}
local PRESETS = {
	{"flat", {{0, 1}, {1, 1}}},
	{"fade in", {{0, 0}, {1, 1}}},
	{"fade out", {{0, 1}, {1, 0}}},
	{"fade in and out", {{0, 0}, {0.5, 1}, {1, 0}}},
	{"hold and fade", {{0, 1}, {0.6, 1}, {1, 0}}},
}

local function get_alpha(color)
	return color[4] or 1
end

local function evaluate_color(keys, t)
	local from, to, fraction = curve.Segment(keys, t)
	local a, b = from[2], to[2]
	return a[1] + (b[1] - a[1]) * fraction,
	a[2] + (b[2] - a[2]) * fraction,
	a[3] + (b[3] - a[3]) * fraction,
	get_alpha(a) + (get_alpha(b) - get_alpha(a)) * fraction
end

local function format_number(value)
	return string.format("%g", math.floor(value * 1e4 + 0.5) / 1e4)
end

function CANVAS:get_plot()
	local size = self.transform:GetSize()
	return PAD_LEFT,
	PAD_TOP,
	size.x - PAD_LEFT - PAD_RIGHT,
	size.y - PAD_TOP - PAD_BOTTOM
end

function CANVAS:to_screen(t, value)
	local editor = self.Editor
	local left, top, width, height = self:get_plot()
	local y = top + height / 2

	if not editor:IsColor() then
		y = top + (1 - (value - editor._min) / (editor._max - editor._min)) * height
	end

	return left + t * width, y
end

function CANVAS:from_screen(x, y)
	local editor = self.Editor
	local left, top, width, height = self:get_plot()
	local value = 0

	if not editor:IsColor() then
		value = editor._min + (1 - (y - top) / height) * (editor._max - editor._min)
	end

	return math.clamp((x - left) / width, 0, 1), value
end

function CANVAS:key_at(local_pos)
	local editor = self.Editor
	local best, best_distance

	for index, key in ipairs(editor:GetKeys()) do
		local x, y = self:to_screen(key[1], editor:IsColor() and 0 or key[2])
		local distance = math.sqrt((x - local_pos.x) ^ 2 + (y - local_pos.y) ^ 2)

		if distance <= PICK_RADIUS and (not best_distance or distance < best_distance) then
			best, best_distance = index, distance
		end
	end

	return best
end

function CANVAS:OnMouseInput(button, press, local_pos)
	local editor = self.Editor

	if button == "button_2" and press then
		local index = self:key_at(local_pos)

		if index then
			editor:Select(index)
			editor:OpenKeyMenu(index)
		end

		return true
	end

	if button ~= "button_1" then return end

	if not press then
		self:end_drag()
		return true
	end

	local index = self:key_at(local_pos)
	local now = os.clock()
	local double = now - (self._last_press or 0) < DOUBLE_CLICK
	self._last_press = now

	if index then
		editor:Select(index)
		self._drag = {index = index, moved = false}
	elseif double then
		local t, value = self:from_screen(local_pos.x, local_pos.y)
		self._drag = {index = editor:AddKey(t, value), moved = true}
	else
		editor:Select(nil)
	end

	return true
end

function CANVAS:end_drag()
	local drag = self._drag
	self._drag = nil

	if drag and drag.moved then
		self.Editor:Fit()
		self.Editor:Refresh()
	end
end

function CANVAS:OnGlobalMouseInput(button, press)
	if self._drag and not press and button == "button_1" then self:end_drag() end
end

function CANVAS:OnGlobalMouseMove(pos)
	local drag = self._drag

	if not drag then return end

	local local_pos = self.transform:GlobalToLocal(pos)
	local t, value = self:from_screen(local_pos.x, local_pos.y)
	drag.moved = true
	self.Editor:MoveKey(drag.index, t, value)
	return true
end

function CANVAS:draw_curve(keys, color, alpha, thickness)
	local editor = self.Editor
	local px, py

	for i = 0, SAMPLES do
		local t = i / SAMPLES
		local x, y = self:to_screen(t, curve.Evaluate(keys, t))

		if px then
			local length = math.sqrt((x - px) ^ 2 + (y - py) ^ 2)

			if length > 0 then
				render2d.SetColor(color.r, color.g, color.b, alpha)
				render2d.DrawRect(px, py, length + 0.5, thickness, math.atan2(y - py, x - px), 0, thickness / 2)
			end
		end

		px, py = x, y
	end
end

function CANVAS:draw_gradient(keys, y, height)
	local left, _, width = self:get_plot()
	local columns = math.floor(width / 3)

	for i = 0, columns - 1 do
		local r, g, b, a = evaluate_color(keys, (i + 0.5) / columns)
		local x0 = math.floor(left + i * width / columns)
		render2d.SetColor(r, g, b, a)
		render2d.DrawRect(x0, y, math.floor(left + (i + 1) * width / columns) - x0, height)
	end
end

function CANVAS:OnDraw()
	local editor = self.Editor
	local active = theme.active
	local size = self.transform:GetSize()
	local font = active:GetFont("body", "XS")
	local surface, border = active:GetColor("surface"), active:GetColor("border")
	local text, disabled = active:GetColor("text"), active:GetColor("text_disabled")
	local primary = active:GetColor("primary")
	local left, top, width, height = self:get_plot()
	render2d.SetTexture(nil)
	render2d.SetColor(surface.r, surface.g, surface.b, 1)
	render2d.DrawRect(0, 0, size.x, size.y)
	local color = editor:IsColor()

	if color then
		local checker = 8

		for row = 0, math.ceil(height / checker) - 1 do
			for column = 0, math.ceil(width / checker) - 1 do
				local shade = (row + column) % 2 == 0 and 0.28 or 0.4
				render2d.SetColor(shade, shade, shade, 1)
				render2d.DrawRect(
					left + column * checker,
					top + row * checker,
					math.min(checker, width - column * checker),
					math.min(checker, height - row * checker)
				)
			end
		end

		if editor:HasMax() then
			self:draw_gradient(editor._value.Keys, top, height / 2)
			self:draw_gradient(editor._value.MaxKeys, top + height / 2, height / 2)
		else
			self:draw_gradient(editor._value.Keys, top, height)
		end
	else
		for i = 0, 4 do
			local value = editor._min + (editor._max - editor._min) * i / 4
			local _, y = self:to_screen(0, value)
			render2d.SetColor(border.r, border.g, border.b, 0.6)
			render2d.DrawRect(left, y, width, 1)
			render2d.SetColor(disabled.r, disabled.g, disabled.b, 1)
			font:DrawText(format_number(value), 4, y - 6)
		end
	end

	for i = 0, 4 do
		local x = left + width * i / 4
		render2d.SetColor(border.r, border.g, border.b, color and 0.3 or 0.6)
		render2d.DrawRect(x, top, 1, height)
		render2d.SetColor(disabled.r, disabled.g, disabled.b, 1)
		font:DrawText(format_number(i / 4), x - 4, top + height + 4)
	end

	render2d.SetColor(border.r, border.g, border.b, 1)
	render2d.DrawRect(left, top + height, width, 1)
	render2d.DrawRect(left, top, 1, height)
	local current = editor:GetKeys()
	local other = editor._band == "Keys" and editor._value.MaxKeys or editor._value.Keys

	if not color then
		if editor:HasMax() then
			local steps = 64

			for i = 0, steps - 1 do
				local t = (i + 0.5) / steps
				local _, low = self:to_screen(t, curve.Evaluate(editor._value.Keys, t))
				local _, high = self:to_screen(t, curve.Evaluate(editor._value.MaxKeys, t))
				render2d.SetColor(primary.r, primary.g, primary.b, 0.18)
				render2d.DrawRect(
					left + width * i / steps,
					math.min(low, high),
					width / steps + 1,
					math.abs(high - low)
				)
			end

			self:draw_curve(other, text, 0.35, 1)
		end

		self:draw_curve(current, primary, 1, 2)
	end

	for index, key in ipairs(current) do
		local x, y = self:to_screen(key[1], color and 0 or key[2])

		if color then y = top + height end

		local selected = index == editor._selected

		if selected then
			render2d.SetColor(text.r, text.g, text.b, 1)
			render2d.DrawFilledCircle(x, y, KEY_RADIUS + 2)
		end

		if color then
			render2d.SetColor(text.r, text.g, text.b, 0.9)
			render2d.DrawFilledCircle(x, y, KEY_RADIUS + 1)
			render2d.SetColor(key[2][1], key[2][2], key[2][3], 1)
		else
			render2d.SetColor(primary.r, primary.g, primary.b, 1)
		end

		render2d.DrawFilledCircle(x, y, KEY_RADIUS)
	end

	if editor._hint and #current <= 2 then
		render2d.SetColor(disabled.r, disabled.g, disabled.b, 1)
		font:DrawText(editor._hint, left + 6, top + 4)
	end
end

local Canvas = CANVAS:Register()
local META = Panel:CreateTemplate("curve_editor")
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	GrowHeight = 1,
	AlignmentX = "stretch",
	ChildGap = "XS",
}
META:StartStorable()
META:GetSet("Value", nil)
META:GetSet("Kind", "scalar")
META:GetSet("Min", nil)
META:GetSet("Max", nil)
META:EndStorable()

function META.OnChange(value, editor) end

function META:IsColor()
	return self.Kind == "color"
end

function META:HasMax()
	return self._value.MaxKeys ~= nil
end

function META:GetKeys()
	return self._value[self._band]
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._value = table.copy(self.Value)
	self._band = "Keys"
	self._selected = nil
	self._hint = "double click to add a key, right click a key for more"
	self:Fit()
	self.canvas = Canvas{Parent = self, IsInternal = true, Editor = self}
	local PropertyEditor = import("goluwa/render2d/ui/widgets/property_editor.lua")
	self.inspector = PropertyEditor{
		Parent = self,
		IsInternal = true,
		Items = self:BuildItems(),
		layout = {GrowWidth = 1, GrowHeight = 1, FitWidth = false},
	}
end

function META:Fit()
	if self:IsColor() then
		self._min, self._max = 0, 1
		return
	end

	local low, high = 0, 0

	for _, name in ipairs{"Keys", "MaxKeys"} do
		for _, key in ipairs(self._value[name] or {}) do
			low = math.min(low, key[2])
			high = math.max(high, key[2])
		end
	end

	high = math.max(high * 1.25, low + 0.01)
	local magnitude = 10 ^ math.floor(math.log10(high - low))

	for _, factor in ipairs{1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10} do
		if magnitude * factor >= high - low then
			high = low + magnitude * factor

			break
		end
	end

	self._min, self._max = low, high
end

function META:Changed()
	self.OnChange(table.copy(self._value), self)
end

function META:Refresh()
	self.inspector:SetItems(self:BuildItems())
end

function META:Select(index)
	self._selected = index
	self:Refresh()
end

function META:AddKey(t, value)
	local keys = self:GetKeys()
	local position = #keys + 1

	for i, key in ipairs(keys) do
		if key[1] > t then
			position = i

			break
		end
	end

	local new

	if self:IsColor() then
		new = {t, {evaluate_color(keys, t)}}
	else
		new = {t, math.clamp(value, self.Min or -math.huge, self.Max or math.huge)}
	end

	table.insert(keys, position, new)
	self._selected = position
	self:Changed()
	self:Refresh()
	return position
end

function META:RemoveKey(index)
	local keys = self:GetKeys()

	if #keys <= 1 then return end

	table.remove(keys, index)
	self._selected = nil
	self:Fit()
	self:Changed()
	self:Refresh()
end

function META:MoveKey(index, t, value)
	local keys = self:GetKeys()
	local key = keys[index]
	key[1] = math.clamp(
		t,
		keys[index - 1] and keys[index - 1][1] or 0,
		keys[index + 1] and keys[index + 1][1] or 1
	)

	if not self:IsColor() then
		key[2] = math.clamp(value, self.Min or -math.huge, self.Max or math.huge)
	end

	self:Changed()
end

function META:OpenKeyMenu(index)
	local keys = self:GetKeys()
	local items = {
		MenuItem{
			Text = "Remove key",
			Icon = "trash",
			Disabled = #keys <= 1,
			OnClick = function()
				self:RemoveKey(index)
			end,
		},
	}

	for _, mode in ipairs(MODES) do
		items[#items + 1] = MenuItem{
			Text = mode,
			Icon = (keys[index][3] or "linear") == mode and "check" or nil,
			OnClick = function()
				keys[index][3] = mode ~= "linear" and mode or nil
				self:Changed()
				self:Refresh()
			end,
		}
	end

	Panel.OpenContextMenu({}, items)
end

function META:ApplyPreset(shape)
	local keys = self:GetKeys()
	local color = self:IsColor()
	local base = 0

	if color then
		base = keys[1][2]
	else
		for _, key in ipairs(keys) do
			base = math.max(base, math.abs(key[2]))
		end

		if base == 0 then base = self.Max or 1 end
	end

	local shaped = {}

	for i, point in ipairs(shape) do
		if color then
			shaped[i] = {point[1], {base[1], base[2], base[3], get_alpha(base) * point[2]}}
		else
			shaped[i] = {
				point[1],
				math.clamp(base * point[2], self.Min or -math.huge, self.Max or math.huge),
			}
		end
	end

	self._value[self._band] = shaped
	self._selected = nil
	self:Fit()
	self:Changed()
	self:Refresh()
end

function META:BuildItems()
	local items = {}
	local has_max = self:HasMax()
	items[#items + 1] = {
		Key = "/curve/random",
		Text = "Random",
		Type = "boolean",
		Description = "every particle picks its own point between a minimum and a maximum curve",
		Value = has_max,
		OnChange = function(_, value)
			if value then
				self._value.MaxKeys = table.copy(self._value.Keys)
			else
				self._value.MaxKeys = nil
				self._band = "Keys"
			end

			self._selected = nil
			self:Fit()
			self:Changed()
			self:Refresh()
		end,
	}

	if has_max then
		items[#items + 1] = {
			Key = "/curve/band",
			Text = "Editing",
			Type = "enum",
			Options = {{Text = "minimum", Value = "Keys"}, {Text = "maximum", Value = "MaxKeys"}},
			Value = self._band,
			OnChange = function(_, value)
				self._band = value
				self._selected = nil
				self:Refresh()
			end,
		}
	end

	local presets = {}

	for _, preset in ipairs(PRESETS) do
		presets[#presets + 1] = {
			Key = "/curve/preset/" .. preset[1],
			Text = preset[1],
			Type = "action",
			ButtonText = "apply",
			OnAction = function()
				self:ApplyPreset(preset[2])
			end,
		}
	end

	items[#items + 1] = {
		Key = "/curve/presets",
		Text = "presets",
		IsGroup = true,
		Children = presets,
		Collapsed = true,
	}
	local keys = self:GetKeys()
	local key = keys[self._selected]

	if key then
		local children = {
			{
				Key = "/curve/key/time",
				Text = "Time",
				Type = "number",
				Value = key[1],
				Min = 0,
				Max = 1,
				Precision = 3,
				ShowSlider = true,
				OnChange = function(_, value)
					self:MoveKey(self._selected, value, key[2])
				end,
			},
			{
				Key = "/curve/key/mode",
				Text = "Interpolation",
				Type = "enum",
				Options = {
					{Text = "linear", Value = "linear"},
					{Text = "smooth", Value = "smooth"},
					{Text = "step", Value = "step"},
				},
				Value = key[3] or "linear",
				OnChange = function(_, value)
					key[3] = value ~= "linear" and value or nil
					self:Changed()
				end,
			},
		}

		if self:IsColor() then
			table.insert(
				children,
				2,
				{
					Key = "/curve/key/color",
					Text = "Color",
					Type = "color",
					Value = Color(key[2][1], key[2][2], key[2][3], get_alpha(key[2])),
					OnChange = function(_, value)
						key[2] = {value.r, value.g, value.b, value.a}
						self:Changed()
					end,
				}
			)
		else
			table.insert(
				children,
				2,
				{
					Key = "/curve/key/value",
					Text = "Value",
					Type = "number",
					Value = key[2],
					Min = self.Min,
					Max = self.Max,
					Precision = 4,
					OnChange = function(_, value)
						key[2] = value
						self:Fit()
						self:Changed()
					end,
				}
			)
		end

		items[#items + 1] = {
			Key = "/curve/key",
			Text = "key " .. self._selected,
			IsGroup = true,
			Children = children,
		}
	end

	return {{Key = "/curve", Text = "curve", Expanded = true, Children = items}}
end

return META:Register()
