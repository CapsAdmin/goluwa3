local prototype = require("prototype")
local animations = require("animations")
local system = require("system")
local event = require("event")
local Vec2 = require("structs.vec2")
local Vec3 = require("structs.vec3")
local META = prototype.CreateTemplate("tui_animation")

function META:Animate(config)
	assert(config.id, "tui_animation: config must have an .id field")
	config.group = self.Owner
	animations.Animate(config)
end

function META:Stop(id)
	animations.StopAnimations(self.Owner, id)
end

function META:StopAll()
	animations.StopAnimations(self.Owner)
end

function META:IsAnimating(id)
	return animations.IsAnimating(self.Owner, id)
end

function META:CalcAnimations()
	animations.Update(system.GetFrameTime(), self.Owner)
end

function META:AnimateForeground(id, to_color, duration, interp)
	local el = self.Owner.tui_element
	assert(el, "tui_animation:AnimateForeground – owner needs tui_element")
	local target = Vec3(to_color[1], to_color[2], to_color[3])
	self:Animate{
		id = id,
		get = function()
			local c = el:GetForegroundColor() or {0, 0, 0}
			return Vec3(c[1], c[2], c[3])
		end,
		set = function(v)
			el:SetForegroundColor{v.x, v.y, v.z}
		end,
		to = {target},
		time = duration or 0.15,
		interpolation = interp or "linear",
	}
end

function META:AnimateBackground(id, to_color, duration, interp)
	local el = self.Owner.tui_element
	assert(el, "tui_animation:AnimateBackground – owner needs tui_element")
	local target = Vec3(to_color[1], to_color[2], to_color[3])
	self:Animate{
		id = id,
		get = function()
			local c = el:GetBackgroundColor() or {0, 0, 0}
			return Vec3(c[1], c[2], c[3])
		end,
		set = function(v)
			el:SetBackgroundColor{v.x, v.y, v.z}
		end,
		to = {target},
		time = duration or 0.15,
		interpolation = interp or "linear",
	}
end

function META:AnimateMinSize(id, to_size, duration, interp)
	local layout = self.Owner.layout
	assert(layout, "tui_animation:AnimateMinSize – owner needs layout")
	self:Animate{
		id = id,
		get = function()
			return layout:GetMinSize():Copy()
		end,
		set = function(v)
			layout:SetMinSize(Vec2(math.max(0, v.x), math.max(0, v.y)))
		end,
		to = {to_size},
		time = duration or 0.25,
		interpolation = interp or "linear",
	}
end

function META:AnimatePosition(id, to_pos, duration, interp)
	local tr = self.Owner.transform
	assert(tr, "tui_animation:AnimatePosition – owner needs transform")
	self:Animate{
		id = id,
		get = function()
			return tr:GetPosition():Copy()
		end,
		set = function(v)
			tr:SetPosition(v)
		end,
		to = {to_pos},
		time = duration or 0.3,
		interpolation = interp or "linear",
	}
end

function META:OnFirstCreated()
	event.AddListener(
		"Update",
		"tui_animation_system",
		function()
			local any = false

			for _, anim in ipairs(META.Instances) do
				if anim.Owner:IsValid() then
					anim:CalcAnimations()

					if animations.IsAnimating(anim.Owner) then any = true end
				end
			end

			if any then event.Call("TuiAnimating") end
		end,
		{priority = 102} -- same as 2D animation, runs early in the frame
	)
end

function META:OnLastRemoved()
	event.RemoveListener("Update", "tui_animation_system")
end

function META:Initialize()
	self.Owner:EnsureComponent("tui_element")
end

return META:Register()
