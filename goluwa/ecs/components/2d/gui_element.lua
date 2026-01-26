local prototype = require("prototype")
local event = require("event")
local ecs = require("ecs.ecs")
local render2d = require("render2d.render2d")
local gfx = require("render2d.gfx")
local Color = require("structs.color")
local Vec2 = require("structs.vec2")
local transform = require("ecs.components.2d.transform")
local META = prototype.CreateTemplate("gui_element_2d")
META.ComponentName = "gui_element_2d"
META.Require = {transform}
META:StartStorable()
META:GetSet("Visible", true)
META:GetSet("Clipping", false)
META:GetSet("Shadows", false)
META:GetSet("ShadowSize", 16)
META:GetSet("ShadowColor", Color(0, 0, 0, 0.5))
META:GetSet("ShadowOffset", Vec2(0, 0))
META:GetSet("BorderRadius", 0)
META:EndStorable()

function META:Initialize() end

function META:DrawShadow()
	if not self:GetShadows() then return end

	local transform = self.Entity.transform_2d
	render2d.PushMatrix()
	render2d.SetWorldMatrix(transform:GetWorldMatrix())
	local s = transform.Size + transform.DrawSizeOffset
	render2d.SetBlendMode("alpha")
	render2d.SetColor(self:GetShadowColor():Unpack())
	gfx.DrawShadow(
		self:GetShadowOffset().x,
		self:GetShadowOffset().y,
		s.x,
		s.y,
		self:GetShadowSize(),
		self:GetBorderRadius()
	)
	render2d.PopMatrix()
end

function META:IsHovered(mouse_pos)
	local transform = self.Entity.transform_2d
	local local_pos = transform:GlobalToLocal(mouse_pos)
	return local_pos.x >= 0 and
		local_pos.y >= 0 and
		local_pos.x <= transform.Size.x and
		local_pos.y <= transform.Size.y
end

function META:DrawRecursive()
	if not self:GetVisible() then return end

	self:DrawShadow()
	local transform = self.Entity.transform_2d
	local clipping = self:GetClipping()

	if clipping then
		render2d.PushStencilMask()
		render2d.PushMatrix()
		render2d.SetWorldMatrix(transform:GetWorldMatrix())
		render2d.DrawRect(0, 0, transform.Size.x, transform.Size.y)
		render2d.PopMatrix()
		render2d.BeginStencilTest()
	end

	render2d.PushMatrix()
	render2d.SetWorldMatrix(transform:GetWorldMatrix())
	local comps = {}

	for _, component in pairs(self.Entity.ComponentsHash) do
		if component.OnDraw then table.insert(comps, component) end
	end

	table.sort(comps, function(a, b)
		local ao = a.DrawOrder or (a.ComponentName == "rect_2d" and 0 or 10)
		local bo = b.DrawOrder or (b.ComponentName == "rect_2d" and 0 or 10)
		return ao < bo
	end)

	for _, component in ipairs(comps) do
		component:OnDraw()
	end

	for _, child in ipairs(self.Entity:GetChildren()) do
		local gui_element = child:GetComponent("gui_element_2d")

		if gui_element then gui_element:DrawRecursive() end
	end

	if clipping then render2d.PopStencilMask() end

	for _, component in pairs(self.Entity.ComponentsHash) do
		if component.OnPostDraw then component:OnPostDraw() end
	end

	render2d.PopMatrix()
end

local gui_element_2d = {}

function gui_element_2d.StartSystem()
	event.AddListener("Draw2D", "ecs_gui_system", function()
		local world = ecs.Get2DWorld()

		if not world then return end

		for _, child in ipairs(world:GetChildren()) do
			local gui_element = child:GetComponent("gui_element_2d")

			if gui_element then gui_element:DrawRecursive() end
		end
	end)
end

function gui_element_2d.StopSystem()
	event.RemoveListener("Draw2D", "ecs_gui_system")
end

gui_element_2d.Component = META:Register()
return gui_element_2d
