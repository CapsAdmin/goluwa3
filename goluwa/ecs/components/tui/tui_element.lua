local prototype = import("goluwa/prototype.lua")
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

function META:DrawRecursive(term)
	if not self:GetVisible() then return end

	local transform = self.Owner.transform
	local x1, y1, x2, y2 = transform:GetWorldRectFast()
	local abs_x = math.floor(x1 + 0.5)
	local abs_y = math.floor(y1 + 0.5)
	local w = math.floor(x2 - x1 + 0.5)
	local h = math.floor(y2 - y1 + 0.5)
	local fg = self:GetForegroundColor()
	local bg = self:GetBackgroundColor()

	if fg then term:PushForegroundColor(fg[1], fg[2], fg[3]) end

	if bg then term:PushBackgroundColor(bg[1], bg[2], bg[3]) end

	local clipping = self:GetClipping()

	if clipping then
		if not term:PushViewport(abs_x, abs_y, w, h) then
			-- Clip rect is empty - nothing to show. Skip this node and children.
			if bg then term:PopAttribute() end

			if fg then term:PopAttribute() end

			return
		end
	end

	self.Owner:CallLocalEvent("OnDraw", term, abs_x, abs_y, w, h)

	local function draw_children(entity)
		for _, child in ipairs(entity:GetChildren()) do
			if child.tui_element then
				child.tui_element:DrawRecursive(term)
			else
				draw_children(child)
			end
		end
	end

	draw_children(self.Owner)

	if clipping then term:PopViewport() end

	if bg then term:PopAttribute() end

	if fg then term:PopAttribute() end
end

return META:Register()