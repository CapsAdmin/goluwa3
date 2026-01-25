--[[HOTRELOAD
	package.loaded["gui.base_panel"] = nil
	require("goluwa.gui.base_panel")
]]
local system = require("system")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")
local Ang3 = require("structs.ang3")
local Color = require("structs.color")
local animations = require("animations")
local META = ...
-- these are useful for animations
META:GetSet("DrawSizeOffset", Vec2(0, 0), {callback = "InvalidateMatrices"})
META:GetSet("DrawScaleOffset", Vec2(1, 1), {callback = "InvalidateMatrices"})
META:GetSet("DrawPositionOffset", Vec2(0, 0), {callback = "InvalidateMatrices"})
META:GetSet("DrawAngleOffset", Ang3(0, 0, 0), {callback = "InvalidateMatrices"})
META:GetSet("DrawColor", Color(0, 0, 0, 0))
META:GetSet("DrawAlpha", 1)
local parent_layout = {
	Size = true,
	Position = true,
	Rotation = true,
}

function META:CalcAnimations()
	animations.Update(system.GetFrameTime(), self)
end

function META:StopAnimations()
	animations.StopAnimations(self)
end

function META:IsAnimating(var)
	return animations.IsAnimating(self, var)
end

function META:Animate(config)
	local var = config.var
	config.id = var
	config.group = config.group or self

	if not config.get then
		config.get = function(s)
			local val = type(s["Get" .. var]) == "function" and s["Get" .. var](s) or s[var]
			return val
		end
	end

	if not config.base then
		if var == "DrawScaleOffset" and (config.operator == "*" or config.operator == "/") then
			config.base = Vec2(1, 1)
		end
	end

	if not config.set then
		local set_func = self["Set" .. var]
		config.set = function(s, val)
			set_func(s, val)

			if parent_layout[var] then
				if s:HasParent() and not s.Parent:IsWorld() then
					s.Parent:CalcLayoutInternal(true)
				else
					s:CalcLayoutInternal(true)
				end
			elseif var:sub(1, 4) ~= "Draw" then
				s:CalcLayoutInternal(true)
			end
		end
	end

	animations.Animate(config)
end
