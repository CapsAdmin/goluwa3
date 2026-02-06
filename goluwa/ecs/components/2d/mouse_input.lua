local prototype = require("prototype")
local window = require("window")
local event = require("event")
local Vec2 = require("structs.vec2")
local META = prototype.CreateTemplate("mouse_input")
META:StartStorable()
META:GetSet("Hovered", false)
META:GetSet("IgnoreMouseInput", false)
META:GetSet("FocusOnClick", false)
META:GetSet("BringToFrontOnClick", false)
META:GetSet("RedirectFocus", NULL)
META:GetSet("Cursor", "arrow")
META:EndStorable()

function META:SetHovered(b)
	if self.Hovered == b then return end

	self.Hovered = b
	local entity = self.Owner

	if entity and entity.OnHover then entity:OnHover(b) end
end

function META:GetMousePosition()
	local mouse_pos = window.GetMousePosition()
	return self.Owner.transform:GlobalToLocal(mouse_pos)
end

function META:GetGlobalMousePosition()
	return window.GetMousePosition()
end

function META:IsMouseButtonDown(button)
	self.button_states = self.button_states or {}
	local state = self.button_states[button]
	return state and state.press
end

function META:OnMouseInput(button, press, pos) end

local mouse_input = library()
mouse_input.pressed_entities = mouse_input.pressed_entities or {}
mouse_input.last_hovered = mouse_input.last_hovered or NULL

local function get_hovered_entity(entity, mouse_pos)
	local gui = entity.gui_element

	if gui and not gui:GetVisible() then return nil end

	local mouse_comp = entity.mouse_input

	if mouse_comp and mouse_comp:GetIgnoreMouseInput() then return nil end

	-- Check children first (top-most in draw order is usually last in child list)
	local children = entity:GetChildren()

	for i = #children, 1, -1 do
		local found = get_hovered_entity(children[i], mouse_pos)

		if found then return found end
	end

	if gui and gui:IsHovered(mouse_pos) then return entity end

	return nil
end

local Panel = require("ecs.panel")

function META:IsHoveredExclusively(mouse_pos)
	if mouse_pos then
		if not Panel.World then return false end

		return get_hovered_entity(Panel.World, mouse_pos) == self.Owner
	end

	return mouse_input.last_hovered == self.Owner
end

function META:OnFirstCreated()
	local mouse_input = mouse_input
	local get_hovered_entity = get_hovered_entity

	function mouse_input.MouseInput(button, press)
		local world = Panel.World

		if not Panel.World then return end

		local pos = window.GetMousePosition()
		local global_handled = false

		for _, cmp in ipairs(META.Instances) do
			local res1 = cmp.OnGlobalMouseInput and cmp:OnGlobalMouseInput(button, press, pos)
			local res2 = cmp.Owner:CallLocalListeners("OnGlobalMouseInput", button, press, pos)

			if res1 or res2 then
				global_handled = true

				if press then break end
			end
		end

		if global_handled and press then return true end

		if press then
			local hovered = get_hovered_entity(Panel.World, pos)

			if hovered then
				local mouse_comp = hovered.mouse_input

				if mouse_comp then
					mouse_input.pressed_entities[button] = hovered
					mouse_comp.button_states = mouse_comp.button_states or {}
					mouse_comp.button_states[button] = {press = press, pos = pos}

					if mouse_comp:GetFocusOnClick() then
						local target = hovered

						if mouse_comp:GetRedirectFocus():IsValid() then
							target = mouse_comp:GetRedirectFocus()
						end

						target:RequestFocus()
					end

					if mouse_comp:GetBringToFrontOnClick() then hovered:BringToFront() end

					local current = hovered

					while current:IsValid() do
						local local_pos = current.transform:GlobalToLocal(pos)
						local consumed = false

						if current.component_map then
							for _, comp in pairs(current.component_map) do
								if comp.OnMouseInput then
									if comp:OnMouseInput(button, press, local_pos) then
										consumed = true
									end
								end
							end
						end

						if current.OnMouseInput then
							if current:OnMouseInput(button, press, local_pos) then
								consumed = true
							end
						end

						if consumed then return true end

						current = current:GetParent()
					end

					return true
				end
			else
				prototype.SetFocusedObject(NULL)
			end
		else
			local pressed = mouse_input.pressed_entities[button]

			if pressed then
				if pressed:IsValid() then
					local mouse_comp = pressed.mouse_input

					if mouse_comp then
						mouse_comp.button_states = mouse_comp.button_states or {}
						mouse_comp.button_states[button] = {press = press, pos = pos}
						local current = pressed

						while current:IsValid() do
							local local_pos = current.transform:GlobalToLocal(pos)
							local consumed = false

							if current.component_map then
								for _, comp in pairs(current.component_map) do
									if comp.OnMouseInput then
										if comp:OnMouseInput(button, press, local_pos) then
											consumed = true
										end
									end
								end
							end

							if current.OnMouseInput then
								if current:OnMouseInput(button, press, local_pos) then
									consumed = true
								end
							end

							if consumed then break end

							current = current:GetParent()
						end
					end
				end

				mouse_input.pressed_entities[button] = nil
				return true
			end
		end
	end

	function mouse_input.Update()
		if not Panel.World then return end

		local pos = window.GetMousePosition()
		local hovered = get_hovered_entity(Panel.World, pos) or NULL

		if hovered ~= mouse_input.last_hovered then
			if mouse_input.last_hovered:IsValid() then
				local mouse = mouse_input.last_hovered.mouse_input

				if mouse then mouse:SetHovered(false) end

				if mouse_input.last_hovered.OnMouseLeave then
					mouse_input.last_hovered:OnMouseLeave()
				end

				mouse_input.last_hovered:CallLocalListeners("OnMouseLeave")
			end

			if hovered:IsValid() then
				local mouse = hovered.mouse_input

				if mouse then mouse:SetHovered(true) end

				if hovered.OnMouseEnter then hovered:OnMouseEnter() end

				hovered:CallLocalListeners("OnMouseEnter")
			end

			mouse_input.last_hovered = hovered
		end

		local cursor = "arrow"
		local global_handled_move = false

		for _, cmp in ipairs(META.Instances) do
			local res1 = cmp.OnGlobalMouseMove and cmp:OnGlobalMouseMove(pos)
			local res2 = cmp.Owner:CallLocalListeners("OnGlobalMouseMove", pos)

			if res1 or res2 then
				cursor = cmp:GetCursor()
				global_handled_move = true

				break
			end
		end

		if not global_handled_move and hovered:IsValid() then
			local mouse = hovered.mouse_input

			if mouse then
				cursor = mouse:GetCursor()
				local local_pos = hovered.transform:GlobalToLocal(pos)

				if hovered.component_map then
					for _, comp in pairs(hovered.component_map) do
						if comp.OnMouseMove then
							if comp:OnMouseMove(local_pos) then break end
						end
					end
				end

				if hovered.GreyedOut then cursor = "no" end
			end
		end

		if window.GetCursor() ~= cursor then window.SetCursor(cursor) end
	end

	event.AddListener("MouseInput", "ecs_gui_system", mouse_input.MouseInput, {priority = 100})
	event.AddListener("Update", "ecs_gui_system", mouse_input.Update, {priority = 100})
end

function META:OnLastRemoved()
	event.RemoveListener("MouseInput", "ecs_gui_system")
	event.RemoveListener("Update", "ecs_gui_system")
end

return META:Register()
