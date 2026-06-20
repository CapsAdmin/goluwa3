local prototype = import("goluwa/prototype.lua")
local system = import("goluwa/system.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local META = prototype.CreateTemplate("ui_debug_2d")
META.LayoutDebugEnabled = false
META.LayoutDebugFadeDuration = 0.5
META:StartStorable()
META:GetSet("LayoutDebug", false)
META:EndStorable()

function META:Initialize()
	META.LayoutDebugEnabled = self.LayoutDebug == true
end

function META:SetLayoutDebug(enabled)
	enabled = enabled == true
	self.LayoutDebug = enabled
	META.LayoutDebugEnabled = enabled
end

function META:IsLayoutDebugEnabled()
	return META.LayoutDebugEnabled == true
end

function META:GetLayoutDebugFadeDuration()
	return META.LayoutDebugFadeDuration
end

function META.OnDebugLayout(layout)
	if not META.LayoutDebugEnabled then return end

	layout.debug_layout_flash_time = system.GetElapsedTime and system.GetElapsedTime() or 0
end

local function draw_layout_debug_outline(owner)
	local layout = owner.layout

	if not layout then return end

	local flashed_at = layout.debug_layout_flash_time

	if not flashed_at then return end

	local fade_duration = META.LayoutDebugFadeDuration

	if fade_duration <= 0 then return end

	local elapsed_time = system.GetElapsedTime and system.GetElapsedTime() or 0
	local alpha = 1 - ((elapsed_time - flashed_at) / fade_duration)

	if alpha <= 0 then return end

	local transform = owner.transform

	if not transform then return end

	render2d.PushMatrix()
	render2d.SetWorldMatrix(transform:GetWorldMatrix())
	gfx.DrawOutlinedRect(0, 0, transform.Size.x, transform.Size.y, 1, 0, 0.2, 0.45, 1.0, alpha)
	render2d.PopMatrix()
end

local function draw_layout_debug_recursive(owner)
	local gui = owner.gui_element

	if gui and not gui:GetVisible() then return end

	draw_layout_debug_outline(owner)

	for _, child in ipairs(owner:GetChildren()) do
		draw_layout_debug_recursive(child)
	end
end

function META.OnDebugPostDraw(owner)
	if not META.LayoutDebugEnabled then return end

	draw_layout_debug_recursive(owner)
end

return META:Register()
