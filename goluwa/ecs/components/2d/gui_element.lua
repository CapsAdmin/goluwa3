local prototype = import("goluwa/prototype.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local META = prototype.CreateTemplate("gui_element")
META:StartStorable()
META:GetSet("Visible", true)
META:GetSet("Clipping", false)
META:GetSet("BorderRadius", 0)
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("DrawColor", Color(0, 0, 0, 0))
META:GetSet("DrawAlpha", 1)
META:EndStorable()

function META:Initialize()
	self.Owner:EnsureComponent("transform")
end

function META:SetColor(c)
	if type(c) == "string" then
		self.Color = Color.FromHex(c)
	else
		self.Color = c
	end
end

function META:SetVisible(visible)
	self.Visible = visible
	self.Owner:CallLocalEvent("OnVisibilityChanged", visible)
end

function META:IsHovered(mouse_pos)
	local transform = self.Owner.transform
	if not transform then return false end
	local local_pos = transform:GlobalToLocal(mouse_pos)
	local clip_x1, clip_y1, clip_x2, clip_y2 = transform:GetVisibleLocalRect(0, 0, transform.Size.x, transform.Size.y)

	if not clip_x1 then return false end

	return local_pos.x >= clip_x1 and
		local_pos.y >= clip_y1 and
		local_pos.x <= clip_x2 and
		local_pos.y <= clip_y2
end

function META:DrawRecursive()
	if not self:GetVisible() then return end

	local transform = self.Owner.transform
	if not transform then return end

	if not transform:GetVisibleLocalRect(0, 0, transform.Size.x, transform.Size.y) then
		return
	end

	local c = self.Color + self.DrawColor

	if c.a <= 0 then return end

	local clipping = self:GetClipping()

	if clipping then
		render2d.PushStencilMask()
		render2d.PushMatrix()
		render2d.SetWorldMatrix(transform:GetWorldMatrix())

		if self:GetBorderRadius() > 0 then
			gfx.DrawRoundedRect(0, 0, transform.Size.x, transform.Size.y, self:GetBorderRadius())
		else
			render2d.DrawRect(0, 0, transform.Size.x, transform.Size.y)
		end

		render2d.PopMatrix()
		render2d.BeginStencilTest()
	end

	render2d.PushMatrix()
	render2d.SetWorldMatrix(transform:GetWorldMatrix())
	render2d.SetColor(c.r, c.g, c.b, c.a * self.DrawAlpha)
	self.Owner:CallLocalEvent("OnDraw")

	for _, child in ipairs(self.Owner:GetChildren()) do
		if child.gui_element then child.gui_element:DrawRecursive() end
	end

	if clipping then
		render2d.SetStencilMode("mask_decrement", render2d.stencil_level)
		render2d.PushMatrix()
		render2d.SetWorldMatrix(transform:GetWorldMatrix())

		if self:GetBorderRadius() > 0 then
			gfx.DrawRoundedRect(0, 0, transform.Size.x, transform.Size.y, self:GetBorderRadius())
		else
			render2d.DrawRect(0, 0, transform.Size.x, transform.Size.y)
		end

		render2d.PopMatrix()
		render2d.PopStencilMask()
	end

	self.Owner:CallLocalEvent("OnPostDraw")
	render2d.PopMatrix()
end

function META:OnFirstCreated()
	event.AddListener("Draw2D", "ecs_gui_system", function()
		self.Owner:GetRoot().gui_element:DrawRecursive()
	end)
end

function META:OnLastRemoved()
	event.RemoveListener("Draw2D", "ecs_gui_system")
end

return META:Register()
