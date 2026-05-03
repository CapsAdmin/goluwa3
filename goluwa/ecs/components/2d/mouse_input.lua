local prototype = import("goluwa/prototype.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local WALK_CONTINUE = 1
local WALK_DESCEND = 2
local WALK_SKIP_SUBTREE = 3
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
	self.Owner:CallLocalEvent("OnHover", b)
end

function META:GetMousePosition()
	local mouse_pos = system.GetWindow():GetMousePosition()
	local transform = self.Owner.transform

	if not transform then return Vec2() end

	return transform:GlobalToLocal(mouse_pos)
end

function META:GetGlobalMousePosition()
	return system.GetWindow():GetMousePosition()
end

function META:IsMouseButtonDown(button)
	self.button_states = self.button_states or {}
	local state = self.button_states[button]
	return state and state.press
end

local mouse_input = library()
mouse_input.pressed_entities = mouse_input.pressed_entities or {}
mouse_input.last_hovered = mouse_input.last_hovered or NULL
local reverse_query_cache_key = {}

local function build_reverse_query_traversal_recursive(owner, traversal)
	local enter_index = traversal.count + 1
	traversal.count = enter_index
	traversal.elements[enter_index] = owner
	traversal.exit[enter_index] = false
	local children = owner:GetChildren()

	for i = #children, 1, -1 do
		build_reverse_query_traversal_recursive(children[i], traversal)
	end

	local exit_index = traversal.count + 1
	traversal.count = exit_index
	traversal.elements[exit_index] = owner
	traversal.exit[exit_index] = true
	traversal.skip_to[enter_index] = exit_index + 1
end

local function build_reverse_query_traversal(owner)
	local traversal = {
		count = 0,
		elements = {},
		exit = {},
		skip_to = {},
	}
	build_reverse_query_traversal_recursive(owner, traversal)
	return traversal
end

local function query_children_reverse(entity, context, on_enter, on_visit)
	local traversal = entity:GetCachedChildrenTraversal(reverse_query_cache_key, build_reverse_query_traversal)
	local elements = traversal.elements
	local exit = traversal.exit
	local skip_to = traversal.skip_to
	local count = traversal.count
	local index = 1

	while index <= count do
		local owner = elements[index]

		if exit[index] then
			local a, b, c, d, e, f, g, h = on_visit(context, owner, index)

			if a ~= nil then return a, b, c, d, e, f, g, h end

			index = index + 1
		else
			local action = on_enter and on_enter(context, owner, index) or WALK_CONTINUE

			if action == WALK_CONTINUE or action == WALK_DESCEND then
				index = index + 1
			elseif action == WALK_SKIP_SUBTREE then
				index = skip_to[index]
			else
				error("unknown query action: " .. tostring(action), 2)
			end
		end
	end
end

local function hovered_entity_query_enter(mouse_pos, owner)
	local gui = owner.gui_element
	local internal_dock = owner.gmod_internal_dock

	if gui and not gui:GetVisible() then return WALK_SKIP_SUBTREE end

	local mouse_comp = owner.mouse_input

	if mouse_comp and mouse_comp:GetIgnoreMouseInput() and not internal_dock then
		return WALK_SKIP_SUBTREE
	end

	return WALK_CONTINUE
end

local function hovered_entity_query_visit(mouse_pos, owner)
	local gui = owner.gui_element
	local internal_dock = owner.gmod_internal_dock
	local mouse_comp = owner.mouse_input

	if
		gui and
		mouse_comp and
		not mouse_comp:GetIgnoreMouseInput()
		and
		gui:IsHovered(mouse_pos) and
		not internal_dock
	then
		return owner
	end
end

local function global_event_query_visit(context, owner)
	if owner.mouse_input then
		local res = owner:CallLocalEvent(
			context.event_name,
			context.a,
			context.b,
			context.c,
			context.d,
			context.e,
			context.f,
			context.g
		)

		if res ~= nil then return res, owner.mouse_input end
	end
end

local function get_hovered_entity(entity, mouse_pos)
	return query_children_reverse(entity, mouse_pos, hovered_entity_query_enter, hovered_entity_query_visit)
end

local function call_global_event(entity, event_name, a, b, c, d, e, f, g)
	return query_children_reverse(
		entity,
		{
			event_name = event_name,
			a = a,
			b = b,
			c = c,
			d = d,
			e = e,
			f = f,
			g = g,
		},
		nil,
		global_event_query_visit
	)
end

local Panel = import("goluwa/ecs/panel.lua")

function META.GetHoveredObject()
	return mouse_input.last_hovered
end

function META:IsHoveredExclusively(mouse_pos)
	if mouse_pos then
		if not Panel.World then return false end

		return get_hovered_entity(Panel.World, mouse_pos) == self.Owner
	end

	return mouse_input.last_hovered == self.Owner
end

function META:OnFirstCreated()
	function mouse_input.MouseInput(button, press)
		local world = Panel.World

		if not Panel.World then return end

		local pos = system.GetWindow():GetMousePosition()

		do
			local res, cmp = call_global_event(Panel.World, "OnGlobalMouseInput", button, press, pos)

			if res and press then return true end
		end

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
						local transform = current.transform

						if not transform then break end

						local local_pos = transform:GlobalToLocal(pos)

						if current:CallLocalEvent("OnMouseInput", button, press, local_pos) then
							break
						end

						current = current:GetParent()
					end

					return true
				end
			else
				prototype.SetFocusedObject(NULL)
			end
		else
			local pressed = mouse_input.pressed_entities[button] or NULL

			if pressed:IsValid() then
				local mouse_comp = pressed.mouse_input

				if mouse_comp then
					mouse_comp.button_states = mouse_comp.button_states or {}
					mouse_comp.button_states[button] = {press = press, pos = pos}
					local current = pressed

					while current:IsValid() do
						local transform = current.transform

						if not transform then break end

						local local_pos = transform:GlobalToLocal(pos)

						if current:CallLocalEvent("OnMouseInput", button, press, local_pos) then
							break
						end

						current = current:GetParent()
					end
				end

				mouse_input.pressed_entities[button] = nil
				return true
			end
		end
	end

	function mouse_input.Update()
		if not Panel.World then return end

		local pos = system.GetWindow():GetMousePosition()
		local hovered = get_hovered_entity(Panel.World, pos) or NULL

		if hovered ~= mouse_input.last_hovered then
			if mouse_input.last_hovered:IsValid() then
				local mouse = mouse_input.last_hovered.mouse_input

				if mouse then mouse:SetHovered(false) end

				mouse_input.last_hovered:CallLocalEvent("OnMouseLeave")
			end

			if hovered:IsValid() then
				local mouse = hovered.mouse_input

				if mouse then mouse:SetHovered(true) end

				hovered:CallLocalEvent("OnMouseEnter")
			end

			mouse_input.last_hovered = hovered
		end

		local cursor = "arrow"
		local global_handled_move = false

		do
			local res, cmp = call_global_event(Panel.World, "OnGlobalMouseMove", pos)

			if res then
				cursor = cmp:GetCursor()
				global_handled_move = true
			end
		end

		if not global_handled_move and hovered:IsValid() then
			local mouse = hovered.mouse_input

			if mouse then
				cursor = mouse:GetCursor()

				if hovered.transform then
					hovered:CallLocalEvent("OnMouseMove", hovered.transform:GlobalToLocal(pos))
				end

				if hovered.GreyedOut then cursor = "no" end
			end
		end

		local window = system.GetWindow()

		if window:GetCursor() ~= cursor then window:SetCursor(cursor) end
	end

	event.AddListener("MouseInput", "ecs_gui_system", mouse_input.MouseInput, {priority = 100})
	event.AddListener("Update", "ecs_gui_system", mouse_input.Update, {priority = 100})
end

function META:OnLastRemoved()
	event.RemoveListener("MouseInput", "ecs_gui_system")
	event.RemoveListener("Update", "ecs_gui_system")
end

return META:Register()
