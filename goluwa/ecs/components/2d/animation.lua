local prototype = import("goluwa/prototype.lua")
local animations = import("goluwa/animations.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local META = prototype.CreateTemplate("animation")

local function call_on_ent_or_comps(ent, func_name, ...)
	if not ent or not ent:IsValid() then return end

	if type(ent[func_name]) == "function" then return ent[func_name](ent, ...) end

	if ent.component_map then
		for _, comp in pairs(ent.component_map) do
			if type(comp[func_name]) == "function" then return comp[func_name](comp, ...) end
		end
	end
end

function META:Animate(config)
	assert(config.id, "must have an .id field")
	config.group = self.Owner
	animations.Animate(config)
end

function META:CalcAnimations()
	animations.Update(system.GetFrameTime(), self.Owner)
end

function META:StopAnimations()
	animations.StopAnimations(self.Owner)
end

function META:IsAnimating(var)
	return animations.IsAnimating(self.Owner, var)
end

function META:OnFirstCreated()
	event.AddListener(
		"Update",
		"animations_2d_system",
		function()
			for _, anim in ipairs(META.Instances) do
				anim:CalcAnimations()
			end
		end,
		{priority = 102}
	)
end

function META:OnLastRemoved()
	event.RemoveListener("Update", "animations_2d_system")
end

return META:Register()
