local prototype = import("goluwa/prototype.lua")
local WALK_CONTINUE = 1
local WALK_DESCEND = 2
local WALK_SKIP_SUBTREE = 3
local META = prototype.CreateTemplate("tui_element")
META:StartStorable()
META:GetSet("Visible", true)
META:GetSet("Clipping", false)
META:GetSet("ForegroundColor", nil)
META:GetSet("BackgroundColor", nil)
META:EndStorable()

function META:Initialize()
	self.Owner:EnsureComponent("transform")
end

function META:SetVisible(visible)
	self.Visible = visible
	self.Owner:CallLocalEvent("OnVisibilityChanged", visible)
end

local draw_recursive_cache_key = {}
local draw_recursive_context = {}
local draw_recursive_active = {}
local draw_recursive_payloads = {}
local draw_recursive_context = {}
local DRAW_RECURSIVE_FOREGROUND = 1
local DRAW_RECURSIVE_BACKGROUND = 2
local DRAW_RECURSIVE_CLIPPING = 4

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

local function walk_draw_recursive(owner, context, on_enter, on_exit)
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
				error("unknown tui draw action: " .. tostring(action), 2)
			end
		end
	end
end

local function draw_recursive_enter(context, owner)
	local current = owner.tui_element

	if not current then return WALK_DESCEND end

	if not current:GetVisible() then return WALK_SKIP_SUBTREE end

	local transform = owner.transform

	if not transform then return WALK_SKIP_SUBTREE end

	local x1, y1, x2, y2 = transform:GetWorldRectFast()
	local abs_x = math.floor(x1 + 0.5)
	local abs_y = math.floor(y1 + 0.5)
	local w = math.floor(x2 - x1 + 0.5)
	local h = math.floor(y2 - y1 + 0.5)
	local fg = current:GetForegroundColor()
	local bg = current:GetBackgroundColor()
	local term = context.term
	local exit_state = 0

	if fg then
		term:PushForegroundColor(fg[1], fg[2], fg[3])
		exit_state = exit_state + DRAW_RECURSIVE_FOREGROUND
	end

	if bg then
		term:PushBackgroundColor(bg[1], bg[2], bg[3])
		exit_state = exit_state + DRAW_RECURSIVE_BACKGROUND
	end

	local clipping = current:GetClipping()

	if clipping then
		if not term:PushViewport(abs_x, abs_y, w, h) then
			if exit_state >= DRAW_RECURSIVE_BACKGROUND then
				term:PopAttribute()
				exit_state = exit_state - DRAW_RECURSIVE_BACKGROUND
			end

			if exit_state >= DRAW_RECURSIVE_FOREGROUND then term:PopAttribute() end

			return WALK_SKIP_SUBTREE
		end

		exit_state = exit_state + DRAW_RECURSIVE_CLIPPING
	end

	owner:CallLocalEvent("OnDraw", term, abs_x, abs_y, w, h)
	return WALK_CONTINUE, exit_state
end

local function draw_recursive_leave(context, _, exit_state)
	local term = context.term

	if exit_state >= DRAW_RECURSIVE_CLIPPING then
		term:PopViewport()
		exit_state = exit_state - DRAW_RECURSIVE_CLIPPING
	end

	if exit_state >= DRAW_RECURSIVE_BACKGROUND then
		term:PopAttribute()
		exit_state = exit_state - DRAW_RECURSIVE_BACKGROUND
	end

	if exit_state >= DRAW_RECURSIVE_FOREGROUND then term:PopAttribute() end
end

function META:DrawRecursive(term)
	local old_term = draw_recursive_context.term
	draw_recursive_context.term = term
	walk_draw_recursive(self.Owner, draw_recursive_context, draw_recursive_enter, draw_recursive_leave)
	draw_recursive_context.term = old_term
end

return META:Register()
