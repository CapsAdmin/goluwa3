local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local META = Panel:CreateTemplate("color_surface")
META.CMP.transform = {}
META.CMP.layout = {
	GrowWidth = 0,
	FitWidth = false,
	FitHeight = false,
}
META.CMP.visual = {Clipping = true}
META.CMP.mouse_input = {Cursor = "hand"}
META.CMP.clickable = {}
META.CMP.animation = {}
META:StartStorable()
META:GetSet("Mode", "vertical", {enums = {"vertical", "2d"}})
META:GetSet("InvertY", true)
META:GetSet("Texture", nil)
META:GetSet("Position", nil)
META:GetSet("MarkerColor", nil)
META:EndStorable()

function META.OnChange(normalized, surface) end

function META.PropDefaults(_, props)
	return {layout = {MinSize = props.Size, MaxSize = props.Size}}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self._dragging = false
end

function META:set_from_local(local_pos)
	local size = self.transform:GetSize()
	local y = math.clamp(local_pos.y / math.max(size.y, 1), 0, 1)

	if self.InvertY then y = 1 - y end

	if self.Mode == "2d" then
		self.OnChange(Vec2(math.clamp(local_pos.x / math.max(size.x, 1), 0, 1), y), self)
	else
		self.OnChange(y, self)
	end
end

function META:OnMouseInput(button, press, local_pos)
	if button ~= "button_1" then return end

	if press then
		self._dragging = true
		self:set_from_local(local_pos)
	end

	return true
end

function META:OnGlobalMouseMove(pos)
	if not self._dragging then return end

	self:set_from_local(self.transform:GlobalToLocal(pos))
	return true
end

function META:OnGlobalMouseInput(button, press)
	if button == "button_1" and not press and self._dragging then
		self._dragging = false
		return true
	end
end

function META:OnDraw()
	local size = self.transform:GetSize()
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetTexture(self.Texture)
	render2d.DrawRect(0, 0, size.x, size.y)
	render2d.SetTexture(nil)
	theme.active:DrawColorSurface(size, self.Mode, self.Position, self.MarkerColor)
end

return META:Register()
