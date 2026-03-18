local prototype = import("goluwa/prototype.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local event = import("goluwa/event.lua")
local META = prototype.CreateTemplate("tui_draggable")
META:StartStorable()
META:GetSet("Draggable", true)
META:EndStorable()
local active = nil
local drag_start_col = 0
local drag_start_row = 0
local drag_start_pos = nil

local function floor(n)
	return math.floor(n + 0.5)
end

function META:GetTarget()
	return self.target or self.Owner
end

function META:SetTarget(entity)
	self.target = entity
end

function META:IsDragging()
	return active == self
end

function META:OnFirstCreated()
	event.AddListener(
		"TerminalMouseInput",
		"tui_draggable",
		function(button, press, col, row)
			if button ~= "left" then return end

			if press then
				for _, inst in ipairs(META.Instances) do
					if inst.Owner:IsValid() and inst:GetDraggable() then
						local el = inst.Owner.tui_element

						if el and not el:GetVisible() then goto continue end

						local mi = inst.Owner.tui_mouse_input
						local hit = false

						if mi then
							hit = mi:IsHit(col, row)
						else
							local x1, y1, x2, y2 = inst.Owner.transform:GetWorldRectFast()
							hit = col >= floor(x1) and
								col < floor(x2)
								and
								row >= floor(y1)
								and
								row < floor(y2)
						end

						if hit then
							local res = inst:GetTarget().tui_resizable

							if res and res:GetResizeZone(col, row) then goto continue end

							local target_tr = inst:GetTarget().transform
							active = inst
							drag_start_col = col
							drag_start_row = row
							drag_start_pos = target_tr:GetPosition():Copy()
							inst.Owner:CallLocalEvent("OnDragStarted")
							return true
						end

						::continue::
					end
				end
			else
				if active then
					active.Owner:CallLocalEvent("OnDragStopped")
					active = nil
				end
			end
		end,
		{priority = 5}
	)

	event.AddListener("TerminalMouseMoved", "tui_draggable", function(col, row)
		if not active then return end

		if not active.Owner:IsValid() then
			active = nil
			return
		end

		local dc = col - drag_start_col
		local dr = row - drag_start_row

		if active.Owner:CallLocalEvent("OnDrag", dc, dr) then return end

		local target_tr = active:GetTarget().transform
		local new_pos = Vec2(drag_start_pos.x + dc, drag_start_pos.y + dr)
		target_tr:SetPosition(new_pos)
	end)
end

function META:OnLastRemoved()
	event.RemoveListener("TerminalMouseInput", "tui_draggable")
	event.RemoveListener("TerminalMouseMoved", "tui_draggable")
	active = nil
end

function META:Initialize()
	self.Owner:EnsureComponent("tui_element")
	self.Owner:EnsureComponent("transform")
end

return META:Register()
