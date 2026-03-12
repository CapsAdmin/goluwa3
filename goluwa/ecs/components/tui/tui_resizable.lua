local prototype = import("goluwa/prototype.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local event = import("goluwa/event.lua")
local META = prototype.CreateTemplate("tui_resizable")
META:StartStorable()
META:GetSet("ResizeBorder", 1)
META:GetSet("MinimumSize", Vec2(4, 3))
META:EndStorable()
local active = nil -- the tui_resizable component being dragged
local drag_start_col = 0
local drag_start_row = 0
local drag_start_w = 0
local drag_start_h = 0
local drag_location = nil

local function floor(n)
	return math.floor(n + 0.5)
end

local function get_rect(comp)
	local x1, y1, x2, y2 = comp.Owner.transform:GetWorldRectFast()
	return floor(x1), floor(y1), floor(x2), floor(y2)
end

function META:GetResizeZone(col, row)
	local x1, y1, x2, y2 = get_rect(self)

	if col < x1 or col >= x2 or row < y1 or row >= y2 then return nil end

	local b = self:GetResizeBorder()
	local is_left = col < x1 + b
	local is_right = col >= x2 - b
	local is_top = row < y1 + b
	local is_bottom = row >= y2 - b

	if is_top and is_left then return "top_left" end

	if is_top and is_right then return "top_right" end

	if is_bottom and is_left then return "bottom_left" end

	if is_bottom and is_right then return "bottom_right" end

	if is_left then return "left" end

	if is_right then return "right" end

	if is_top then return "top" end

	if is_bottom then return "bottom" end

	return nil
end

local function apply_drag(col, row)
	if not active or not active.Owner:IsValid() then
		active = nil
		return
	end

	local dc = col - drag_start_col
	local dr = row - drag_start_row
	local loc = drag_location
	local min = active:GetMinimumSize()
	local new_w = drag_start_w
	local new_h = drag_start_h

	if loc == "right" or loc == "top_right" or loc == "bottom_right" then
		new_w = math.max(min.x, new_w + dc)
	elseif loc == "left" or loc == "top_left" or loc == "bottom_left" then
		new_w = math.max(min.x, new_w - dc)
	end

	if loc == "bottom" or loc == "bottom_left" or loc == "bottom_right" then
		new_h = math.max(min.y, new_h + dr)
	elseif loc == "top" or loc == "top_left" or loc == "top_right" then
		new_h = math.max(min.y, new_h - dr)
	end

	local owner = active.Owner
	local pin_w = loc:find("left") ~= nil or loc:find("right") ~= nil
	local pin_h = loc:find("top") ~= nil or loc:find("bottom") ~= nil

	if owner.layout then
		local mn = owner.layout:GetMinSize()
		local mx = owner.layout:GetMaxSize()

		if pin_w then
			owner.layout:SetMinSize(Vec2(new_w, mn.y))

			if mx.x > 0 then owner.layout:SetMaxSize(Vec2(new_w, mx.y)) end
		end

		if pin_h then
			mn = owner.layout:GetMinSize()
			mx = owner.layout:GetMaxSize()
			owner.layout:SetMinSize(Vec2(mn.x, new_h))

			if mx.y > 0 then owner.layout:SetMaxSize(Vec2(mx.x, new_h)) end
		end
	else
		owner.transform:SetSize(Vec2(new_w, new_h))
	end

	owner:CallLocalEvent("OnResize", new_w, new_h)
end

function META:OnFirstCreated()
	event.AddListener(
		"TerminalMouseInput",
		"tui_resizable",
		function(button, press, col, row)
			if button ~= "left" then return end

			if press then
				for _, inst in ipairs(META.Instances) do
					if inst.Owner:IsValid() then
						local zone = inst:GetResizeZone(col, row)

						if zone then
							local x1, y1, x2, y2 = get_rect(inst)
							active = inst
							drag_start_col = col
							drag_start_row = row
							drag_start_w = x2 - x1
							drag_start_h = y2 - y1
							drag_location = zone
							return true
						end
					end
				end
			else
				if active then
					active.Owner:CallLocalEvent("OnResizeEnd")
					active = nil
				end
			end
		end,
		{priority = 10}
	)

	event.AddListener("TerminalMouseMoved", "tui_resizable", function(col, row)
		if active then apply_drag(col, row) end
	end)
end

function META:OnLastRemoved()
	event.RemoveListener("TerminalMouseInput", "tui_resizable")
	event.RemoveListener("TerminalMouseMoved", "tui_resizable")
	active = nil
end

function META:Initialize()
	self.Owner:EnsureComponent("tui_element")
	self.Owner:EnsureComponent("transform")
end

return META:Register()