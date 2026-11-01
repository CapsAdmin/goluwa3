local Vec2 = import("goluwa/structs/vec2.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local system = import("goluwa/system.lua")
local SMOOTH_SPEED = 8
local TRAIL_DELAY = 0.6
local TRAIL_SPEED = 0.8
local Tracker = {}
Tracker.__index = Tracker

function Tracker:Update(value, dt, now)
	if not self.shown then
		self.shown = value
		self.ghost = value
	end

	self.shown = self.shown + (value - self.shown) * math.min(dt * SMOOTH_SPEED, 1)

	if self.last and value < self.last then self.hold = now + TRAIL_DELAY end

	self.last = value

	if now > self.hold then
		self.ghost = math.max(self.ghost - dt * TRAIL_SPEED, self.shown)
	end

	self.ghost = math.max(self.ghost, self.shown)
	return self.shown, self.ghost
end

local META = Panel:CreateTemplate("progress_bar")
META.CMP.transform = {}
META.CMP.layout = {}
META.CMP.visual = {}
META:StartStorable()
META:GetSet("Value", 0)
META:GetSet("Color", nil)
META:GetSet("Trail", false)
META:GetSet("GhostColor", nil)
META:GetSet("Segments", nil)
META:EndStorable()

function META:SetValue(val)
	self.Value = math.clamp(val, 0, 1)
	self:SetState("value", self.Value)
end

local function get_bar_size(active, width)
	return Vec2(width, active:GetSize("M"))
end

function META.PropDefaults()
	return {
		Size = theme.Dynamic(get_bar_size, 200),
		layout = {MinSize = theme.Dynamic(get_bar_size, 100)},
	}
end

function META:OnCreate()
	META.BaseClass.OnCreate(self)
	self:SetValue(self.Value)
	self:SetState("color", self.Color)
	self:SetState("ghost_color", self.GhostColor)
	self:SetState("segments", self.Segments)

	if self.Trail then self.tracker = setmetatable({hold = -math.huge}, Tracker) end
end

function META:OnDraw()
	if self.tracker then
		local shown, ghost = self.tracker:Update(self.Value, system.GetFrameTime(), system.GetElapsedTime())
		self:SetState("value", shown)
		self:SetState("ghost", ghost)
	end

	theme.active:Draw(self)
end

local progress_bar = META:Register()

function progress_bar.NewTracker()
	return setmetatable({hold = -math.huge}, Tracker)
end

return progress_bar
