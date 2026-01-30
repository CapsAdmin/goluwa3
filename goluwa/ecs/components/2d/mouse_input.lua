local prototype = require("prototype")
local window = require("window")
local event = require("event")
local ecs = require("ecs.ecs")
local transform = require("ecs.components.2d.transform")
local Vec2 = require("structs.vec2")
local META = prototype.CreateTemplate("mouse_input_2d")
META.ComponentName = "mouse_input_2d"
META.Require = {transform}
META:StartStorable()
META:GetSet("Hovered", false)
META:GetSet("IgnoreMouseInput", false)
META:GetSet("FocusOnClick", false)
META:GetSet("BringToFrontOnClick", false)
META:GetSet("RedirectFocus", NULL)
META:GetSet("Cursor", "arrow")
META:GetSet("DragEnabled", false)
META:EndStorable()

function META:SetHovered(b)
	if self.Hovered == b then return end

	self.Hovered = b
	local entity = self.Entity

	if entity and entity.OnHover then entity:OnHover(b) end
end

function META:GetMousePosition()
	local mouse_pos = window.GetMousePosition()
	return self.Entity.transform_2d:GlobalToLocal(mouse_pos)
end

function META:GetGlobalMousePosition()
	return window.GetMousePosition()
end

function META:IsMouseButtonDown(button)
	self.button_states = self.button_states or {}
	local state = self.button_states[button]
	return state and state.press
end

function META:OnMouseInput(button, press, pos)
	local transform = self.Entity.transform_2d

	if transform:GetScrollEnabled() then
		if button == "mwheel_up" then
			local s = transform:GetScroll() + Vec2(0, -20)
			s.y = math.max(s.y, 0)
			transform:SetScroll(s)
			return true
		elseif button == "mwheel_down" then
			local s = transform:GetScroll() + Vec2(0, 20)
			transform:SetScroll(s)
			return true
		end
	end
end

local mouse_input = library()
mouse_input.pressed_entities = mouse_input.pressed_entities or {}
mouse_input.Component = META:Register()
mouse_input.last_hovered = mouse_input.last_hovered or NULL

local function get_hovered_entity(entity, mouse_pos)
	local gui = entity:GetComponent("gui_element_2d")

	if gui and not gui:GetVisible() then return nil end

	local mouse_comp = entity:GetComponent("mouse_input_2d")

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

function mouse_input.GetHoveredEntity()
	return mouse_input.last_hovered
end

function META:IsHoveredExclusively(mouse_pos)
	if mouse_pos then
		local world = ecs.Get2DWorld()

		if not world then return false end

		return get_hovered_entity(world, mouse_pos) == self.Entity
	end

	return mouse_input.last_hovered == self.Entity
end

function mouse_input.MouseInput(button, press)
	local world = ecs.Get2DWorld()

	if not world then return end

	local pos = window.GetMousePosition()

	if press then
		local hovered = get_hovered_entity(world, pos)

		if hovered then
			local mouse_comp = hovered:GetComponent("mouse_input_2d")

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

				if button == "button_1" then
					local resizable_comp = hovered:GetComponent("resizable_2d")

					if resizable_comp and resizable_comp:GetResizable() then
						local local_pos = hovered.transform_2d:GlobalToLocal(pos)

						if resizable_comp:StartResizing(local_pos, button) then
							mouse_input.ResizingObject = resizable_comp
						end
					end

					if not mouse_input.ResizingObject and mouse_comp:GetDragEnabled() then
						mouse_input.DraggingObject = hovered
						mouse_input.DragMouseStart = pos:Copy()
						mouse_input.DragObjectStart = hovered.transform_2d:GetPosition():Copy()
					end
				end

				local local_pos = hovered.transform_2d:GlobalToLocal(pos)

				for _, comp in pairs(hovered.ComponentsHash) do
					if comp.OnMouseInput then
						comp:OnMouseInput(button, press, local_pos)
					end
				end

				if hovered.OnMouseInput then
					hovered:OnMouseInput(button, press, local_pos)
				end

				return true
			end
		else
			ecs.SetFocusedEntity(NULL)
		end
	else
		if button == "button_1" then
			mouse_input.DraggingObject = nil

			if mouse_input.ResizingObject and mouse_input.ResizingObject.resize_button == button then
				mouse_input.ResizingObject:StopResizing()
				mouse_input.ResizingObject = nil
			end
		end

		local pressed = mouse_input.pressed_entities[button]

		if pressed then
			if pressed:IsValid() then
				local mouse_comp = pressed:GetComponent("mouse_input_2d")

				if mouse_comp then
					mouse_comp.button_states = mouse_comp.button_states or {}
					mouse_comp.button_states[button] = {press = press, pos = pos}
					local local_pos = pressed.transform_2d:GlobalToLocal(pos)

					for _, comp in pairs(pressed.ComponentsHash) do
						if comp.OnMouseInput then
							comp:OnMouseInput(button, press, local_pos)
						end
					end

					if pressed.OnMouseInput then
						pressed:OnMouseInput(button, press, local_pos)
					end
				end
			end

			mouse_input.pressed_entities[button] = nil
			return true
		end
	end
end

function mouse_input.Update()
	local world = ecs.Get2DWorld()

	if not world then return end

	local pos = window.GetMousePosition()

	if mouse_input.ResizingObject and mouse_input.ResizingObject:IsValid() then
		mouse_input.ResizingObject:UpdateResizing(pos)
	elseif mouse_input.DraggingObject and mouse_input.DraggingObject:IsValid() then
		local delta = pos - mouse_input.DragMouseStart
		local new_pos = mouse_input.DragObjectStart + delta

		if mouse_input.DraggingObject.transform_2d then
			mouse_input.DraggingObject.transform_2d:SetPosition(new_pos)
		elseif mouse_input.DraggingObject.SetPosition then
			mouse_input.DraggingObject:SetPosition(new_pos)
		end
	end

	local hovered = get_hovered_entity(world, pos)

	if hovered ~= mouse_input.last_hovered then
		if mouse_input.last_hovered:IsValid() then
			local mouse = mouse_input.last_hovered:GetComponent("mouse_input_2d")

			if mouse then mouse:SetHovered(false) end

			mouse_input.last_hovered:CallLocalListeners("OnMouseLeave")
		end

		if hovered then
			local mouse = hovered:GetComponent("mouse_input_2d")

			if mouse then mouse:SetHovered(true) end

			hovered:CallLocalListeners("OnMouseEnter")
		end

		mouse_input.last_hovered = hovered or NULL
	end

	if hovered and hovered:IsValid() then
		local mouse = hovered:GetComponent("mouse_input_2d")

		if mouse then
			local cursor = mouse:GetCursor()
			local resizable_comp = hovered:GetComponent("resizable_2d")

			if resizable_comp and resizable_comp:GetResizable() then
				local res_cursor = resizable_comp:GetResizeCursor(hovered.transform_2d:GlobalToLocal(pos))

				if res_cursor then cursor = res_cursor end
			end

			if hovered.GreyedOut then cursor = "no" end

			if mouse_input.active_cursor ~= cursor then
				window.SetCursor(cursor)
				mouse_input.active_cursor = cursor
			end
		end
	else
		if mouse_input.active_cursor ~= "arrow" then
			window.SetCursor("arrow")
			mouse_input.active_cursor = "arrow"
		end
	end
end

function mouse_input.StartSystem()
	event.AddListener("MouseInput", "ecs_gui_system", mouse_input.MouseInput, {priority = 100})
	event.AddListener("Update", "ecs_gui_system", mouse_input.Update, {priority = 100})
end

function mouse_input.StopSystem()
	event.RemoveListener("MouseInput", "ecs_gui_system")
	event.RemoveListener("Update", "ecs_gui_system")
end

return mouse_input
