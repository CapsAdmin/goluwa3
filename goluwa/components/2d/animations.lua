local prototype = require("prototype")
local animations = require("animations")
local system = require("system")
local event = require("event")
local ecs = require("ecs")
local Vec2 = require("structs.vec2")
local transform_2d = require("components.2d.transform").Component
local META = prototype.CreateTemplate("animations_2d")
META.ComponentName = "animations_2d"
META.Require = {transform_2d}
local parent_layout = {
	Size = true,
	Position = true,
	Rotation = true,
}

local function call_on_ent_or_comps(ent, func_name, ...)
	if not ent or not ent:IsValid() then return end

	if type(ent[func_name]) == "function" then return ent[func_name](ent, ...) end

	for _, comp in pairs(ent.ComponentsHash) do
		if type(comp[func_name]) == "function" then return comp[func_name](comp, ...) end
	end
end

function META:Animate(config)
	local var = config.var
	config.id = var
	config.group = self.Entity

	if not config.get then
		config.get = function(ent)
			local getter = "Get" .. var

			if type(ent[getter]) == "function" then return ent[getter](ent) end

			for _, comp in pairs(ent.ComponentsHash) do
				if type(comp[getter]) == "function" then return comp[getter](comp) end
			end

			local val = ent[var]

			if val ~= nil then return val end

			for _, comp in pairs(ent.ComponentsHash) do
				if comp[var] ~= nil then return comp[var] end
			end
		end
	end

	if not config.base then
		if var == "DrawScaleOffset" and (config.operator == "*" or config.operator == "/") then
			config.base = Vec2(1, 1)
		end
	end

	if not config.set then
		config.set = function(ent, val)
			local done = false
			local setter = "Set" .. var

			if type(ent[setter]) == "function" then
				ent[setter](ent, val)
				done = true
			else
				for _, comp in pairs(ent.ComponentsHash) do
					if type(comp[setter]) == "function" then
						comp[setter](comp, val)
						done = true

						break
					end
				end
			end

			if not done then ent[var] = val end

			if parent_layout[var] then
				if ent:HasParent() and not ent:GetParent():IsWorld() then
					call_on_ent_or_comps(ent:GetParent(), "InvalidateLayout")
				else
					call_on_ent_or_comps(ent, "InvalidateLayout")
				end
			elseif var:sub(1, 4) ~= "Draw" then
				call_on_ent_or_comps(ent, "InvalidateLayout")
			end
		end
	end

	animations.Animate(config)
end

function META:StopAnimations()
	animations.StopAnimations(self.Entity)
end

function META:IsAnimating(var)
	return animations.IsAnimating(self.Entity, var)
end

local animations_comp = library()
animations_comp.Component = META:Register()

function animations_comp.Update()
	local dt = system.GetFrameTime()
	local instances = ecs.component_instances["animations_2d"]

	if not instances then return end

	for i = 1, #instances do
		local comp = instances[i]

		if comp.Entity and comp.Entity:IsValid() then
			animations.Update(dt, comp.Entity)
		end
	end
end

function animations_comp.StartSystem()
	event.AddListener("Update", "animations_2d_system", animations_comp.Update)
end

function animations_comp.StopSystem()
	event.RemoveListener("Update", "animations_2d_system")
end

return animations_comp
