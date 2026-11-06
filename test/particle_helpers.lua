local render3d = import("goluwa/render3d/render3d.lua")
local weather = import("goluwa/render3d/weather.lua")
local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local particle_helpers = {}
particle_helpers.STEP = 1 / 30

function particle_helpers.init()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/light_grid.lua").pass,
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/lighting.lua"),
			import("goluwa/render3d/passes/particles.lua"),
			import("goluwa/render3d/passes/translucent.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
end

function particle_helpers.restore()
	weather.SetSnow(0)
	weather.SetRain(0)
end

function particle_helpers.step(draw, count)
	for _ = 1, count do
		system.SetElapsedTime(system.GetElapsedTime() + particle_helpers.STEP)
		draw()
	end
end

function particle_helpers.step_with_update(draw, count)
	for _ = 1, count do
		system.SetElapsedTime(system.GetElapsedTime() + particle_helpers.STEP)
		event.Call("Update", particle_helpers.STEP)
		draw()
	end
end

function particle_helpers.add_emitter(component, position, direction)
	local entity = Entity.New{Name = "test_emitter"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(position)
	local dir = direction:GetNormalized()
	local axis = Vec3(0, 1, 0):GetCross(dir)
	entity.transform:SetRotation(Quat(axis.x, axis.y, axis.z, 1 + dir.y):Normalize())
	return entity:AddComponent(component), entity
end

return particle_helpers
