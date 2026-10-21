local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local objects = import("goluwa/objects/objects.lua")
local autocomplete = import("goluwa/autocomplete.lua")
local Color = import("goluwa/structs/color.lua")
local white = Color(1, 1, 1, 1)
local full_anim = {glow_alpha = 1}
local META = Panel:CreateTemplate("autocomplete_list")
META.CMP.transform = {}
META.CMP.layout = {Floating = true}
META.CMP.visual = {Visible = false}
META.CMP.mouse_input = {}
META:StartStorable()
META:GetSet("Target", nil)
META:GetSet("MaxRows", 8)
META:GetSet("Transparent", false)
META:GetSet("FontSize", "M")
META:GetSet("TextColor", nil)
META:GetSet("Placement", "auto", {enums = {"auto", "below", "above"}})
META:EndStorable()

function META.PropDefaults()
	return {Parent = Panel.World}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._rows = {}
	self._first_row = 1
	self._version = -1
	self._hover_index = nil
	self:AddGlobalEvent("Update")
end

function META:get_metrics()
	local active = theme.active
	local font = active:GetFont("body", self.FontSize)
	local padding = active:GetPadding("XS")
	return font, padding, font:GetAscent() + padding
end

function META:rebuild_rows(session, width)
	local rows = self._rows
	local font, padding = self:get_metrics()
	table.clear(rows)
	local last_id
	local selected_row = 1
	local results = session:GetResults()

	for index, result in ipairs(results) do
		if not results.ungrouped and result.id ~= last_id then
			last_id = result.id
			local name = autocomplete.GetListName(result.id)

			if name then rows[#rows + 1] = {header = name} end
		end

		local row = {index = index, result = result}
		rows[#rows + 1] = row

		if result.detail then
			local value_width = result.val == "" and 0 or font:GetTextSize(result.val) + padding * 2
			local available = width - padding * 2 - value_width
			local detail = result.detail

			while #detail > 1 and font:GetTextSize(detail) > available do
				detail = detail:sub(1, math.max(1, math.floor(#detail * available / font:GetTextSize(detail)) - 1))
			end

			row.detail = detail
			row.detail_x = padding + value_width
		end

		if index == session:GetSelectedIndex() then selected_row = #rows end
	end

	local max_rows = self.MaxRows

	if selected_row < self._first_row then
		self._first_row = selected_row
	elseif selected_row > self._first_row + max_rows - 1 then
		self._first_row = selected_row - max_rows + 1
	end

	self._first_row = math.max(1, math.min(self._first_row, math.max(1, #rows - max_rows + 1)))
end

function META:get_row_at(y)
	local _, padding, row_height = self:get_metrics()
	local row = self._rows[self._first_row + math.floor((y - padding / 2) / row_height)]

	if row and row.index then return row.index end
end

function META:OnUpdate()
	local target = self.Target

	if not target:IsValid() then
		self:Remove()
		return
	end

	local session = target.Autocomplete
	local hovered = self.mouse_input.Hovered
	local visible = session ~= nil and
		session:HasResults() and
		(
			hovered or
			objects.GetFocusedObject() == target:GetTextPanel()
		)

	if self.visual.Visible ~= visible then self.visual:SetVisible(visible) end

	if not visible then return end

	local width = target.transform:GetWidth()

	if self._version ~= session.version or self._width ~= width then
		self._version = session.version
		self._width = width
		self:rebuild_rows(session, width)
	end

	local _, padding, row_height = self:get_metrics()
	local row_count = math.min(#self._rows, self.MaxRows)
	local height = row_count * row_height + padding
	local x, y = target.transform:GetWorldMatrix():GetTranslation()
	local target_height = target.transform:GetHeight()
	local below = y + target_height + 2
	local above = y - height - 2
	local placement = self.Placement

	if
		placement == "above" or
		(
			placement == "auto" and
			below + height > Panel.World.transform:GetHeight()
			and
			above >= 0
		)
	then
		y = above
	else
		y = below
	end

	self.transform:SetPosition(Vec2(x, y))
	self.transform:SetSize(Vec2(width, height))
	self._hover_index = hovered and self:get_row_at(self.mouse_input:GetMousePosition().y) or nil
end

function META:OnMouseInput(button, press)
	if button == "mwheel_up" or button == "mwheel_down" then
		self._first_row = math.max(
			1,
			math.min(
				self._first_row + (button == "mwheel_up" and -1 or 1),
				math.max(1, #self._rows - self.MaxRows + 1)
			)
		)
		return true
	end

	if button ~= "button_1" or not press then return end

	local index = self:get_row_at(self.mouse_input:GetMousePosition().y)

	if index then
		self.Target.Autocomplete:Select(index)
		self.Target:AcceptAutocomplete()
	end

	return true
end

do
	local function draw_string(font, str, x, y, color, alpha, shadow)
		if str == "" then return x end

		if shadow then
			render2d.PushColor(0, 0, 0, 1)
			render2d.PushAlphaMultiplier(alpha * 0.8)
			font:DrawText(str, x + 1, y + 1)
			render2d.PopAlphaMultiplier()
			render2d.PopColor()
		end

		render2d.PushColor(color.r, color.g, color.b, 1)
		render2d.PushAlphaMultiplier(alpha * color.a)
		font:DrawText(str, x, y)
		render2d.PopAlphaMultiplier()
		render2d.PopColor()
		return x + font:GetTextSize(str)
	end

	function META:OnDraw()
		if not self.Target:IsValid() then return end

		local session = self.Target.Autocomplete
		local size = self.transform:GetSize()
		local active = theme.active
		local transparent = self.Transparent
		local font, padding, row_height = self:get_metrics()

		if not transparent then active:DrawMenuContainer(size) end

		local match_color = active:GetColor("primary")
		local disabled_color = active:GetColor("text_disabled")
		local selected_index = session:GetSelectedIndex()
		local y = padding / 2
		local row_size = Vec2(size.x, row_height)
		render2d.SetTexture()

		for i = self._first_row, math.min(#self._rows, self._first_row + self.MaxRows - 1) do
			local row = self._rows[i]

			if row.header then
				draw_string(font, row.header, padding, y + padding / 2, disabled_color, 1, transparent)
			else
				local selected = row.index == selected_index and not row.result.hint
				local hovered = row.index == self._hover_index
				local text_color
				local row_match_color = match_color
				local alpha = 1

				if transparent then
					text_color = self.TextColor and active:GetColor(self.TextColor) or white
					row_match_color = text_color
					alpha = selected and 1 or 0.75

					if selected or hovered then
						render2d.PushColor(0, 0, 0, selected and 0.5 or 0.3)
						render2d.DrawRect(0, y, size.x, row_height)
						render2d.PopColor()
					end
				else
					local state = {mode = "menu", selected = selected, hovered = hovered, anim = full_anim}
					text_color = active:GetColor(self.TextColor or active:ResolveButtonStyleContext(state).foreground_token)
					render2d.PushMatrix(0, y)
					active:DrawMenuButton(row_size, state)
					render2d.PopMatrix()

					if selected then
						row_match_color = text_color
						alpha = 0.7
					end
				end

				local result = row.result
				local value = result.val
				local x = padding
				local text_y = y + padding / 2
				x = draw_string(font, value:sub(1, result.start - 1), x, text_y, text_color, alpha, transparent)
				x = draw_string(
					font,
					value:sub(result.start, result.stop),
					x,
					text_y,
					row_match_color,
					1,
					transparent
				)
				draw_string(font, value:sub(result.stop + 1), x, text_y, text_color, alpha, transparent)

				if row.detail then
					draw_string(
						font,
						row.detail,
						row.detail_x,
						text_y,
						result.hint and text_color or disabled_color,
						result.hint and 0.8 or 1,
						transparent
					)
				end
			end

			y = y + row_height
		end
	end
end

return META:Register()
