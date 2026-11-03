local Panel = import("goluwa/render2d/ui/panel.lua")
local Control = import("goluwa/render2d/ui/widgets/properties/control.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local curve = import("goluwa/math/curve.lua")
local META = Panel:CreateTemplate("property_curve")
META.Base = Control
META.CMP.transform = {}
META.CMP.layout = {GrowWidth = 1, FitWidth = false}
META.CMP.visual = {}
META.CMP.mouse_input = {Cursor = "hand"}
META:StartStorable()
META:GetSet("Value", nil)
META:GetSet("Kind", "scalar")
META:GetSet("Min", nil)
META:GetSet("Max", nil)
META:EndStorable()
local PADDING = 3
local SAMPLES = 48

function META:SetValue(value, notify)
	local old = self.Value
	self.Value = value

	if notify then self.OnChange(value, old, self) end

	return self
end

function META:GetValue()
	return self.Value
end

function META:OnMouseInput(button, press)
	if button == "button_1" and press then
		self.Editor:open_curve_editor_window(self)
		return true
	end

	return META.BaseClass.OnMouseInput(self, button, press)
end

local function draw_gradient(keys, x, y, width, height)
	local columns = math.floor(width / 3)

	for i = 0, columns - 1 do
		local from, to, fraction = curve.Segment(keys, (i + 0.5) / columns)
		local a, b = from[2], to[2]
		local alpha_a, alpha_b = a[4] or 1, b[4] or 1
		render2d.SetColor(
			a[1] + (b[1] - a[1]) * fraction,
			a[2] + (b[2] - a[2]) * fraction,
			a[3] + (b[3] - a[3]) * fraction,
			alpha_a + (alpha_b - alpha_a) * fraction
		)
		local x0 = math.floor(x + i * width / columns)
		render2d.DrawRect(x0, y, math.floor(x + (i + 1) * width / columns) - x0, height)
	end
end

function META:OnDraw()
	local active = theme.active
	local size = self.transform:GetSize()
	local surface, border = active:GetColor("surface_alt"), active:GetColor("border")
	local primary = active:GetColor("primary")
	local x, y = PADDING, PADDING
	local width, height = size.x - PADDING * 2, size.y - PADDING * 2
	local value = self.Value
	render2d.SetTexture(nil)
	render2d.SetColor(surface.r, surface.g, surface.b, 1)
	render2d.DrawRect(0, 0, size.x, size.y)

	if self.Kind == "color" then
		local checker = 6

		for row = 0, math.ceil(height / checker) - 1 do
			for column = 0, math.ceil(width / checker) - 1 do
				local shade = (row + column) % 2 == 0 and 0.28 or 0.4
				render2d.SetColor(shade, shade, shade, 1)
				render2d.DrawRect(
					x + column * checker,
					y + row * checker,
					math.min(checker, width - column * checker),
					math.min(checker, height - row * checker)
				)
			end
		end

		if value.MaxKeys then
			draw_gradient(value.Keys, x, y, width, height / 2)
			draw_gradient(value.MaxKeys, x, y + height / 2, width, height / 2)
		else
			draw_gradient(value.Keys, x, y, width, height)
		end
	else
		local low, high = 0, 0

		for _, keys in ipairs{value.Keys, value.MaxKeys or value.Keys} do
			for _, key in ipairs(keys) do
				low, high = math.min(low, key[2]), math.max(high, key[2])
			end
		end

		high = math.max(high, low + 1e-6)
		local px, py, pax, pay

		for i = 0, SAMPLES do
			local t = i / SAMPLES
			local low_value = curve.Evaluate(value.Keys, t)
			local high_value = curve.Evaluate(value.MaxKeys or value.Keys, t)
			local cx = x + t * width
			local cy = y + (1 - (low_value - low) / (high - low)) * height
			local top = y + (1 - (high_value - low) / (high - low)) * height

			if value.MaxKeys then
				render2d.SetColor(primary.r, primary.g, primary.b, 0.25)
				render2d.DrawRect(cx, math.min(cy, top), width / SAMPLES + 1, math.abs(cy - top))
			end

			if px then
				local length = math.sqrt((cx - px) ^ 2 + (cy - py) ^ 2)
				render2d.SetColor(primary.r, primary.g, primary.b, 1)
				render2d.DrawRect(px, py, length + 0.5, 2, math.atan2(cy - py, cx - px), 0, 1)
			end

			px, py = cx, cy
		end
	end

	render2d.SetColor(border.r, border.g, border.b, 1)
	render2d.DrawRect(0, 0, size.x, 1)
	render2d.DrawRect(0, size.y - 1, size.x, 1)
	render2d.DrawRect(0, 0, 1, size.y)
	render2d.DrawRect(size.x - 1, 0, 1, size.y)
end

return META:Register()
