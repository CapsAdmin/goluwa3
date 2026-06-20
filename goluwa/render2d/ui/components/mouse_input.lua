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
META:GetSet("RequestMouse", false)
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

function META:IsRequestMouseActive()
	if not self:GetRequestMouse() then return false end

	local gui = self.Owner.gui_element

	if gui and not gui:GetVisible() then return false end

	return true
end

function META:UpdateMouseRequest()
	local window = system.GetWindow()

	if not (window and window.PushMouseTrapRequest and window.PopMouseTrapRequest) then
		self.mouse_request_active = false
		return false
	end

	local active = self:IsRequestMouseActive()

	if active then
		window:PushMouseTrapRequest(self, false)
	else
		window:PopMouseTrapRequest(self)
	end

	self.mouse_request_active = active
	return active
end

function META:SetRequestMouse(b)
	b = not not b

	if self.RequestMouse == b then return end

	self.RequestMouse = b
	self:UpdateMouseRequest()
end

local mouse_input = library()
mouse_input.pressed_entities = mouse_input.pressed_entities or {}
mouse_input.last_hovered = mouse_input.last_hovered or NULL
mouse_input.active_hover_query = mouse_input.active_hover_query or nil
mouse_input.cursor_override = mouse_input.cursor_override or nil
mouse_input.cursor_override_owner = mouse_input.cursor_override_owner or NULL
local reverse_query_cache_key = {}
local reverse_global_event_cache_key = {}

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

local function build_reverse_global_event_list_recursive(owner, elements)
	local children = owner:GetChildren()

	for i = #children, 1, -1 do
		build_reverse_global_event_list_recursive(children[i], elements)
	end

	elements[#elements + 1] = owner
end

local function build_reverse_global_event_list(owner)
	local elements = {}
	build_reverse_global_event_list_recursive(owner, elements)
	return elements
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
	if owner.gui_element and not owner.gui_element:GetVisible() then
		return WALK_SKIP_SUBTREE
	end

	if
		owner.mouse_input and
		owner.mouse_input:GetIgnoreMouseInput() and
		not owner.gmod_internal_dock
	then
		return WALK_SKIP_SUBTREE
	end

	return WALK_CONTINUE
end

local function hovered_entity_query_visit(context, owner)
	if not owner.gui_element or not owner.mouse_input then return end

	if owner.gmod_internal_dock then return end

	local mouse_pos = context.mouse_pos or context
	local hit_test = context.hit_test
	local is_hovered

	if hit_test then
		is_hovered = hit_test(owner, mouse_pos)
	else
		is_hovered = owner.gui_element:IsHovered(mouse_pos)
	end

	if not owner.mouse_input:GetIgnoreMouseInput() and is_hovered then
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

		if res then return res, owner.mouse_input end
	end
end

local function get_hovered_entity(entity, mouse_pos)
	return query_children_reverse(
		entity,
		{mouse_pos = mouse_pos},
		hovered_entity_query_enter,
		hovered_entity_query_visit
	)
end

local function get_hovered_entity_with_hit_test(entity, mouse_pos, hit_test)
	return query_children_reverse(
		entity,
		{mouse_pos = mouse_pos, hit_test = hit_test},
		hovered_entity_query_enter,
		hovered_entity_query_visit
	)
end

local function is_owner_or_descendant(target, owner)
	local current = target

	while current and current:IsValid() do
		if current == owner then return true end

		current = current:GetParent()
	end

	return false
end

local function get_active_hovered_entity(entity, mouse_pos)
	local cache = mouse_input.active_hover_query

	if cache and cache.entity == entity and cache.pos == mouse_pos then
		if not cache.resolved then
			cache.hovered = get_hovered_entity(entity, mouse_pos) or NULL
			cache.resolved = true
		end

		return cache.hovered
	end

	return get_hovered_entity(entity, mouse_pos)
end

local function call_global_event(entity, event_name, a, b, c, d, e, f, g)
	local context = {
		event_name = event_name,
		a = a,
		b = b,
		c = c,
		d = d,
		e = e,
		f = f,
		g = g,
	}
	local elements = entity:GetCachedChildrenTraversal(reverse_global_event_cache_key, build_reverse_global_event_list)

	for i = 1, #elements do
		local owner = elements[i]
		local res_a, res_b, res_c, res_d, res_e, res_f, res_g, res_h = global_event_query_visit(context, owner)

		if res_a ~= nil then
			return res_a, res_b, res_c, res_d, res_e, res_f, res_g, res_h
		end
	end
end

local Panel = import("goluwa/render2d/ui/panel.lua")

function META.GetHoveredObject()
	return mouse_input.last_hovered
end

function META:IsHoveredExclusively(mouse_pos)
	if mouse_pos then
		if not Panel.World then return false end

		return get_active_hovered_entity(Panel.World, mouse_pos) == self.Owner
	end

	return mouse_input.last_hovered == self.Owner
end

function META:IsExclusiveHit(mouse_pos, hit_test)
	if not Panel.World then return false end

	return get_hovered_entity_with_hit_test(Panel.World, mouse_pos, hit_test) == self.Owner
end

function META:IsExclusiveHitOrDescendant(mouse_pos, hit_test)
	if not Panel.World then return false end

	local hovered = get_hovered_entity_with_hit_test(Panel.World, mouse_pos, hit_test)
	return is_owner_or_descendant(hovered, self.Owner)
end

function META:SetCursorOverride(cursor)
	mouse_input.cursor_override = cursor
	mouse_input.cursor_override_owner = self.Owner
	local window = system.GetWindow()

	if window and window.GetCursor and window.SetCursor and window:GetCursor() ~= cursor then
		window:SetCursor(cursor)
	end
end

function META:ClearCursorOverride()
	if mouse_input.cursor_override_owner == self.Owner then
		mouse_input.cursor_override = nil
		mouse_input.cursor_override_owner = NULL
	end
end

function META:OnFirstCreated()
	function mouse_input.MouseInput(button, press)
		local world = Panel.World

		if not Panel.World then return end

		local pos = system.GetWindow():GetMousePosition()
		local result
		mouse_input.active_hover_query = {
			entity = world,
			pos = pos,
			resolved = false,
			hovered = NULL,
		}

		repeat
			local res, cmp = call_global_event(world, "OnGlobalMouseInput", button, press, pos)

			if res and press then
				result = true

				break
			end

			if press then
				local hovered = get_active_hovered_entity(world, pos)

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

						result = true

						break
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
					result = true

					break
				end
			end		
		until true

		mouse_input.active_hover_query = nil
		return result
	end

	function mouse_input.Update()
		if not Panel.World then return end

		local pos = system.GetWindow():GetMousePosition()
		local delta = system.GetWindow():GetMouseDelta()
		local has_relative_motion = delta and (delta.x ~= 0 or delta.y ~= 0)

		if
			mouse_input.last_mouse_pos and
			mouse_input.last_mouse_pos == pos and
			not has_relative_motion
		then
			return
		end

		mouse_input.last_mouse_pos = pos
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

		if
			mouse_input.cursor_override_owner and
			mouse_input.cursor_override_owner:IsValid() and
			mouse_input.cursor_override
		then
			cursor = mouse_input.cursor_override
			global_handled_move = true
		else
			mouse_input.cursor_override = nil
			mouse_input.cursor_override_owner = NULL
		end

		if not global_handled_move then
			do
				local res, cmp = call_global_event(Panel.World, "OnGlobalMouseMove", pos)

				if res then
					cursor = cmp:GetCursor()
					global_handled_move = true
				end
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

function META:Initialize()
	self.Owner:EnsureComponent("gui_element")

	self.Owner:AddLocalListener("OnVisibilityChanged", function()
		self:UpdateMouseRequest()
	end, self)

	self:UpdateMouseRequest()
end

function META:OnRemove()
	local window = system.GetWindow()

	if window and window.PopMouseTrapRequest then
		window:PopMouseTrapRequest(self)
	end

	self.mouse_request_active = false
end

function META:OnLastRemoved()
	event.RemoveListener("MouseInput", "ecs_gui_system")
	event.RemoveListener("Update", "ecs_gui_system")
end

return META:Register()
