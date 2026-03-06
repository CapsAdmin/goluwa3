local prototype = require("prototype")
local META = prototype.CreateTemplate("tui_mouse_input")
META:StartStorable()
META:GetSet("Hovered", false)
META:GetSet("IgnoreMouseInput", false)
META:GetSet("FocusOnClick", false)
META:EndStorable()
local pressed_entities = {}
local last_hovered = NULL

function META:IsHit(col, row)
	local tr = self.Owner.transform
	local x1, y1, x2, y2 = tr:GetWorldRectFast()
	return col >= math.floor(x1 + 0.5) and
		col < math.floor(x2 + 0.5)
		and
		row >= math.floor(y1 + 0.5)
		and
		row < math.floor(y2 + 0.5)
end

function META:SetHovered(b)
	if self.Hovered == b then return end

	self.Hovered = b
	self.Owner:CallLocalEvent("OnHover", b)
end

local function get_entity_at(entity, col, row)
	local el = entity.tui_element

	if el and not el:GetVisible() then return nil end

	local mi = entity.tui_mouse_input

	if mi and mi:GetIgnoreMouseInput() then return nil end

	local children = entity:GetChildren()

	for i = #children, 1, -1 do
		local found = get_entity_at(children[i], col, row)

		if found then return found end
	end

	if mi and mi:IsHit(col, row) then return entity end

	return nil
end

function META:OnFirstCreated()
	local function get_world()
		local tp = package.loaded["ecs.tui_panel"]
		return tp and tp.World
	end

	local function update_hover(world, col, row)
		local hovered = get_entity_at(world, col, row) or NULL

		if hovered == last_hovered then return end

		if last_hovered:IsValid() then
			local mi = last_hovered.tui_mouse_input

			if mi then mi:SetHovered(false) end

			last_hovered:CallLocalEvent("OnMouseLeave")
		end

		if hovered:IsValid() then
			local mi = hovered.tui_mouse_input

			if mi then mi:SetHovered(true) end

			hovered:CallLocalEvent("OnMouseEnter")
		end

		last_hovered = hovered
	end

	local event = require("event")
	require("tui")

	event.AddListener("TerminalMouseMoved", "tui_mouse_input", function(x, y)
		local world = get_world()

		if world then update_hover(world, x, y) end
	end)

	event.AddListener("TerminalMouseWheel", "tui_mouse_input", function(delta, x, y)
		local world = get_world()

		if world then update_hover(world, x, y) end

		local target = last_hovered

		if not target:IsValid() then return end

		local current = target

		while current:IsValid() do
			if current:CallLocalEvent("OnMouseWheel", delta) then return end

			current = current:GetParent()
		end
	end)

	event.AddListener("TerminalMouseInput", "tui_mouse_input", function(button, press, x, y)
		local world = get_world()

		if not world then return end

		if press then
			update_hover(world, x, y)
			local hovered = last_hovered

			if hovered:IsValid() then
				local mi = hovered.tui_mouse_input

				if mi then
					pressed_entities[button] = hovered

					if mi:GetFocusOnClick() then hovered:RequestFocus() end

					local current = hovered

					while current:IsValid() do
						if current:CallLocalEvent("OnMouseInput", button, true, x, y) then return end

						current = current:GetParent()
					end
				end
			else
				prototype.SetFocusedObject(NULL)
			end
		else
			local pressed = pressed_entities[button] or NULL

			if pressed:IsValid() then
				local current = pressed

				while current:IsValid() do
					if current:CallLocalEvent("OnMouseInput", button, false, x, y) then break end

					current = current:GetParent()
				end

				pressed_entities[button] = nil
			end
		end
	end)
end

function META:OnLastRemoved()
	local event = require("event")
	event.RemoveListener("TerminalMouseMoved", "tui_mouse_input")
	event.RemoveListener("TerminalMouseWheel", "tui_mouse_input")
	event.RemoveListener("TerminalMouseInput", "tui_mouse_input")
end

function META:Initialize()
	self.Owner:EnsureComponent("tui_element")
end

return META:Register()