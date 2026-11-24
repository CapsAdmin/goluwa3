local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local curve = import("goluwa/math/curve.lua")
local TabBar = import("goluwa/render2d/ui/widgets/tab_bar.lua")
local Button = import("goluwa/render2d/ui/widgets/button.lua")
local CANVAS = Panel:CreateTemplate("tone_curve_canvas")
CANVAS.CMP.transform = {}
CANVAS.CMP.layout = {GrowWidth = 1, MinSize = Vec2(200, 260), MaxSize = Vec2(0, 260)}
CANVAS.CMP.visual = {}
CANVAS.CMP.mouse_input = {Cursor = "crosshair"}
CANVAS:StartStorable()
CANVAS:GetSet("Editor", nil)
CANVAS:EndStorable()
local PAD = 8
local POINT_RADIUS = 4
local PICK_RADIUS = 8
local MIN_GAP = 0.01
local SEGMENT_PIXELS = 4
local DEFAULT_POINTS = {{0, 0}, {1, 1}}

function CANVAS:get_plot()
	local size = self.transform:GetSize()
	return PAD, PAD, size.x - PAD * 2, size.y - PAD * 2
end

function CANVAS:to_screen(x, y)
	local left, top, width, height = self:get_plot()
	local range = self.Editor.Range
	return left + x / range * width, top + (1 - y / range) * height
end

function CANVAS:from_screen(sx, sy)
	local left, top, width, height = self:get_plot()
	local range = self.Editor.Range
	return math.clamp((sx - left) / width, 0, 1) * range,
	math.clamp(1 - (sy - top) / height, 0, 1) * range
end

function CANVAS:point_at(local_pos)
	local best, best_distance

	for index, point in ipairs(self.Editor:GetPoints()) do
		local x, y = self:to_screen(point[1], point[2])
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
		local index = self:point_at(local_pos)

		if index then editor:RemovePoint(index) end

		return true
	end

	if button ~= "button_1" then return end

	if not press then
		self._drag = nil
		return true
	end

	local index = self:point_at(local_pos)

	if not index then
		local x, y = self:from_screen(local_pos.x, local_pos.y)
		index = editor:AddPoint(x, y)
	end

	editor._selected = index
	self._drag = index
	return true
end

function CANVAS:OnGlobalMouseInput(button, press)
	if self._drag and not press and button == "button_1" then self._drag = nil end
end

function CANVAS:OnGlobalMouseMove(pos)
	if not self._drag then return end

	local local_pos = self.transform:GlobalToLocal(pos)
	self._drag = self.Editor:MovePoint(self._drag, self:from_screen(local_pos.x, local_pos.y))
	return true
end

function CANVAS:OnMouseMove(local_pos)
	self._hover = local_pos
end

function CANVAS:draw_curve(points, color, alpha, thickness)
	local tangents = curve.MonotoneTangents(points)
	local range = self.Editor.Range
	local _, _, width = self:get_plot()
	local samples = math.max(math.ceil(width / SEGMENT_PIXELS), 1)
	local background = theme.active:GetColor("surface_alt")
	local px, py
	-- overlapping round caps double a translucent colour at every joint, so the fade is mixed in and drawn opaque
	render2d.SetColor(
		math.lerp(alpha, background.r, color.r),
		math.lerp(alpha, background.g, color.g),
		math.lerp(alpha, background.b, color.b),
		1
	)
	render2d.PushBorderRadius(thickness / 2)

	for i = 0, samples do
		local x = i / samples * range
		local sx, sy = self:to_screen(x, math.clamp(curve.EvaluateMonotone(points, tangents, x, 1), 0, range))

		if px then
			render2d.DrawRect(
				px,
				py,
				math.sqrt((sx - px) ^ 2 + (sy - py) ^ 2) + thickness,
				thickness,
				math.atan2(sy - py, sx - px),
				thickness / 2,
				thickness / 2
			)
		end

		px, py = sx, sy
	end

	render2d.PopBorderRadius()
end

function CANVAS:OnDraw()
	local editor = self.Editor
	local active = theme.active
	local size = self.transform:GetSize()
	local font = active:GetFont("body", "XS")
	local surface, border = active:GetColor("surface_alt"), active:GetColor("border")
	local text, disabled = active:GetColor("text"), active:GetColor("text_disabled")
	local left, top, width, height = self:get_plot()
	local range = editor.Range
	render2d.SetTexture(nil)
	render2d.SetColor(surface.r, surface.g, surface.b, 1)
	render2d.DrawRect(0, 0, size.x, size.y)
	local histogram = editor.OnGetHistogram()

	if histogram then
		local values = histogram[editor.Curves[editor.Channel].Histogram]
		local count = #values
		local peak = 0

		for i = 2, count - 1 do
			peak = math.max(peak, values[i])
		end

		if peak > 0 then
			local color = editor.Curves[editor.Channel].Color
			local bin_width = width * histogram.range / range / count
			render2d.SetColor(
				math.lerp(0.18, surface.r, color.r),
				math.lerp(0.18, surface.g, color.g),
				math.lerp(0.18, surface.b, color.b),
				1
			)

			for i = 1, count do
				local bar = math.min(values[i] / peak, 1) * height

				if bar > 0 then
					render2d.DrawRect(left + (i - 1) * bin_width, top + height - bar, bin_width + 0.5, bar)
				end
			end
		end
	end

	if range > 1 then
		local white_x, white_y = self:to_screen(1, 1)
		render2d.SetColor(text.r, text.g, text.b, 0.05)
		render2d.DrawRect(white_x, top, left + width - white_x, height)
		render2d.DrawRect(left, top, white_x - left, white_y - top)
	end

	for i = 1, 3 do
		local x, y = self:to_screen(i / 4, i / 4)
		render2d.SetColor(border.r, border.g, border.b, 0.5)
		render2d.DrawRect(x, top, 1, height)
		render2d.DrawRect(left, y, width, 1)
	end

	if range > 1 then
		local white_x, white_y = self:to_screen(1, 1)
		render2d.SetColor(text.r, text.g, text.b, 0.5)
		render2d.DrawRect(white_x, top, 1, height)
		render2d.DrawRect(left, white_y, width, 1)
		render2d.SetColor(disabled.r, disabled.g, disabled.b, 1)
		font:DrawText("paper white", white_x + 4, top + 2)
	end

	local x0, y0 = self:to_screen(0, 0)
	local x1, y1 = self:to_screen(range, range)
	render2d.SetColor(border.r, border.g, border.b, 0.8)
	render2d.DrawRect(x0, y0, math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2), 1, math.atan2(y1 - y0, x1 - x0))

	for index, channel in ipairs(editor.Curves) do
		if index ~= editor.Channel and channel.Points then
			self:draw_curve(channel.Points, channel.Color, 0.35, 1)
		end
	end

	local channel = editor.Curves[editor.Channel]
	local points = editor:GetPoints()
	self:draw_curve(points, channel.Color, 1, 2)
	local hovered = self._hover and self:point_at(self._hover)

	for index, point in ipairs(points) do
		local x, y = self:to_screen(point[1], point[2])

		if index == editor._selected or index == hovered then
			render2d.SetColor(text.r, text.g, text.b, 1)
			render2d.DrawFilledCircle(x, y, POINT_RADIUS + 2)
		end

		render2d.SetColor(channel.Color.r, channel.Color.g, channel.Color.b, 1)
		render2d.DrawFilledCircle(x, y, POINT_RADIUS)
	end

	local point = points[self._drag or hovered or editor._selected or 0]
	render2d.SetColor(disabled.r, disabled.g, disabled.b, 1)

	if point then
		font:DrawText(string.format("%.3f -> %.3f", point[1], point[2]), left + 4, top + height - 14)
	elseif not channel.Points then
		font:DrawText(
			"click to add a point, drag to move, right click to remove",
			left + 4,
			top + height - 14
		)
	end

	render2d.SetColor(border.r, border.g, border.b, 1)
	render2d.DrawRect(left, top, width, 1)
	render2d.DrawRect(left, top + height, width, 1)
	render2d.DrawRect(left, top, 1, height)
	render2d.DrawRect(left + width, top, 1, height + 1)
end

local Canvas = CANVAS:Register()
local META = Panel:CreateTemplate("tone_curve")
META.CMP.transform = {}
META.CMP.layout = {
	Direction = "y",
	GrowWidth = 1,
	FitHeight = true,
	AlignmentX = "stretch",
	ChildGap = "XS",
}
META:StartStorable()
META:GetSet("Curves", nil)
META:GetSet("Range", 1)
META:GetSet("Channel", 1)
META:EndStorable()

function META.OnChange(index, points, tone_curve) end

function META.OnGetHistogram() end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	local names = {}

	for i, channel in ipairs(self.Curves) do
		names[i] = channel.Text
	end

	local header = Panel.New{
		Parent = self,
		IsInternal = true,
		Name = "tone_curve_header",
		transform = true,
		layout = {Direction = "x", GrowWidth = 1, FitHeight = true, AlignmentY = "center"},
	}
	self._tabs = TabBar{
		Parent = header,
		Tabs = names,
		Value = names[self.Channel],
		OnChange = function(name)
			for i, channel_name in ipairs(names) do
				if channel_name == name then self.Channel = i end
			end

			self._selected = nil
		end,
	}
	Button{
		Parent = header,
		Text = "reset",
		Mode = "outline",
		OnClick = function()
			self._selected = nil
			self.Curves[self.Channel].Points = nil
			self.OnChange(self.Channel, nil, self)
		end,
	}
	self._canvas = Canvas{Parent = self, IsInternal = true, Editor = self}
end

function META:GetPoints()
	return self.Curves[self.Channel].Points or DEFAULT_POINTS
end

function META:SetPoints(index, points)
	self.Curves[index].Points = points

	if index == self.Channel then self._selected = nil end
end

function META:changed()
	local points = self.Curves[self.Channel].Points

	if
		#points == 2 and
		points[1][1] == 0 and
		points[1][2] == 0 and
		points[2][1] == 1 and
		points[2][2] == 1
	then
		points = nil
		self.Curves[self.Channel].Points = nil
	end

	self.OnChange(self.Channel, points, self)
end

function META:editable_points()
	local channel = self.Curves[self.Channel]

	if not channel.Points then channel.Points = table.copy(DEFAULT_POINTS) end

	return channel.Points
end

function META:AddPoint(x, y)
	local points = self:editable_points()
	local position = #points + 1

	for i, point in ipairs(points) do
		if math.abs(point[1] - x) < MIN_GAP then return i end

		if point[1] > x then
			position = i

			break
		end
	end

	table.insert(points, position, {x, y})
	self:changed()
	return position
end

function META:MovePoint(index, x, y)
	local points = self:editable_points()
	local low = points[index - 1] and points[index - 1][1] + MIN_GAP or 0
	local high = points[index + 1] and points[index + 1][1] - MIN_GAP or self.Range
	points[index] = {math.clamp(x, low, math.max(high, low)), y}
	self:changed()
	return index
end

function META:RemovePoint(index)
	local points = self:editable_points()

	if #points <= 1 then return end

	table.remove(points, index)
	self._selected = nil
	self:changed()
end

return META:Register()
