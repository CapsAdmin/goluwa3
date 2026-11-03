local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local UIDebug = import("goluwa/render2d/ui/components/ui_debug.lua")
local WALK_CONTINUE = 1
local WALK_DESCEND = 2
local WALK_SKIP_SUBTREE = 3
local META = objects.CreateTemplate("visual_2d")
META.Is2D = true
META:StartStorable()
META:GetSet("Visible", true)
META:GetSet("Clipping", false)
META:GetSet("DrawAlpha", 1)
META:EndStorable()
META:GetSet("Ghosted", false)

function META:Initialize()
	self.Owner:EnsureComponent("transform")
end

function META:SetVisible(visible)
	local changed = visible ~= self.Visible
	self.Visible = visible

	if changed then
		self.Owner:CallLocalEvent("OnVisibilityChanged", visible)

		for _, child in ipairs(self.Owner:GetChildrenList()) do
			child:CallLocalEvent("OnParentVisibilityChanged", visible)
		end
	end
end

function META:IsHovered(mouse_pos)
	local transform = self.Owner.transform

	if not transform then return false end

	local wx1, wy1, wx2, wy2 = transform:GetCachedWorldBounds()

	if mouse_pos.x < wx1 or mouse_pos.x > wx2 or mouse_pos.y < wy1 or mouse_pos.y > wy2 then
		return false
	end

	local local_pos = transform:GlobalToLocal(mouse_pos)
	local clip_x1, clip_y1, clip_x2, clip_y2 = transform:GetVisibleLocalRect(0, 0, transform.Size.x, transform.Size.y)

	if not clip_x1 then return false end

	return local_pos.x >= clip_x1 and
		local_pos.y >= clip_y1 and
		local_pos.x <= clip_x2 and
		local_pos.y <= clip_y2
end

local draw_recursive_cache_key = {}
local main_active = {}
local main_payloads = {}
local ghost_translation = Matrix44(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
local ghost_world = Matrix44()
local drawing_ghost = false

local function build_draw_recursive_traversal_recursive(owner, traversal)
	local enter_index = traversal.count + 1
	traversal.count = enter_index
	traversal.elements[enter_index] = owner
	traversal.exit[enter_index] = false
	local children = owner:GetChildren()

	for i = 1, #children do
		build_draw_recursive_traversal_recursive(children[i], traversal)
	end

	local exit_index = traversal.count + 1
	traversal.count = exit_index
	traversal.elements[exit_index] = owner
	traversal.exit[exit_index] = true
	traversal.skip_to[enter_index] = exit_index + 1
end

local function build_draw_recursive_traversal(owner)
	local traversal = {
		count = 0,
		elements = {},
		exit = {},
		skip_to = {},
	}
	build_draw_recursive_traversal_recursive(owner, traversal)
	return traversal
end

local function walk_draw_recursive(owner, context, on_enter, on_exit, draw_recursive_active, draw_recursive_payloads)
	local traversal = owner:GetCachedChildrenTraversal(draw_recursive_cache_key, build_draw_recursive_traversal)
	local elements = traversal.elements
	local exit = traversal.exit
	local skip_to = traversal.skip_to
	local count = traversal.count
	local index = 1

	while index <= count do
		local owner = elements[index]

		if exit[index] then
			local active = draw_recursive_active[index]
			local payload = draw_recursive_payloads[index]
			draw_recursive_active[index] = nil
			draw_recursive_payloads[index] = nil

			if active then on_exit(context, owner, payload, index) end

			index = index + 1
		else
			local action, payload = on_enter(context, owner, index)

			if action == WALK_CONTINUE then
				local exit_index = skip_to[index] - 1
				draw_recursive_active[exit_index] = true
				draw_recursive_payloads[exit_index] = payload
				index = index + 1
			elseif action == WALK_DESCEND then
				index = index + 1
			elseif action == WALK_SKIP_SUBTREE then
				index = skip_to[index]
			else
				error("unknown gui draw action: " .. tostring(action), 2)
			end
		end
	end
end

local function draw_recursive_enter(_, owner)
	local current = owner.visual

	if not current then return WALK_DESCEND end

	if not current:GetVisible() then return WALK_SKIP_SUBTREE end

	if current.Ghosted and not drawing_ghost then return WALK_SKIP_SUBTREE end

	local transform = owner.transform

	if not transform then return WALK_SKIP_SUBTREE end

	if
		not (
			drawing_ghost or
			(
				owner.text and
				owner.text:GetDisableViewportCulling()
			)
			or
			transform:IntersectsScrollViewport()
		)
	then
		return WALK_SKIP_SUBTREE
	end

	if current.DrawAlpha <= 0 then return WALK_SKIP_SUBTREE end

	local clipping = current:GetClipping()
	render2d.PushMatrix()

	if drawing_ghost then
		render2d.SetWorldMatrix(transform:GetWorldMatrix():GetMultiplied(ghost_translation, ghost_world))
	else
		render2d.SetWorldMatrix(transform:GetWorldMatrix())
	end

	if clipping then
		render2d.PushClipRect(0, 0, transform.Size.x, transform.Size.y)
	end

	render2d.SetColor(1, 1, 1, current.DrawAlpha)
	owner:CallLocalEvent("OnPreDraw")
	owner:CallLocalEvent("OnDraw")
	return WALK_CONTINUE, {clipping = clipping}
end

local function draw_recursive_leave(_, owner, state)
	if state.clipping then render2d.PopClip() end

	UIDebug.OnDebugPostDraw(owner)
	owner:CallLocalEvent("OnPostDraw")
	render2d.PopMatrix()
end

function META:DrawRecursive()
	walk_draw_recursive(
		self.Owner,
		nil,
		draw_recursive_enter,
		draw_recursive_leave,
		main_active,
		main_payloads
	)
end

function META:DrawGhost(offset_x, offset_y, alpha)
	ghost_translation.m30 = offset_x
	ghost_translation.m31 = offset_y
	drawing_ghost = true
	render2d.PushAlphaMultiplier(alpha)
	walk_draw_recursive(self.Owner, nil, draw_recursive_enter, draw_recursive_leave, {}, {})
	render2d.PopAlphaMultiplier()
	drawing_ghost = false
end

function META:OnFirstCreated()
	event.AddListener("Draw2D", "ecs_gui_system", function()
		self.Owner:GetRoot().visual:DrawRecursive()
	end)
end

function META:OnLastRemoved()
	event.RemoveListener("Draw2D", "ecs_gui_system")
end

return META:Register()
