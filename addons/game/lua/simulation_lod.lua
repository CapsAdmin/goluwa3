local physics = import("goluwa/physics.lua")
local render3d = RENDER_3D and import("goluwa/render3d/render3d.lua")
local PlayerController = import("lua/components/player_controller.lua")
local simulation_lod = {}
simulation_lod.MaxSimulated = 12
local PHYSICS_HYSTERESIS = 8
local RANK_INTERVAL = 4
local observers, observer_count, observer_step = {}, 0, nil
local ranked = {}

local function refresh_observers()
	observer_count = 0

	if render3d then
		local position = render3d.GetCamera():GetPosition()
		observers[1], observers[2], observers[3] = position.x, position.y, position.z
		observer_count = 3
	end

	for _, controller in ipairs(PlayerController.Instances or {}) do
		local position = controller.Owner.transform:GetPosition()
		observers[observer_count + 1], observers[observer_count + 2], observers[observer_count + 3] = position.x, position.y, position.z
		observer_count = observer_count + 3
	end
end

local function sort_by_distance(a, b)
	return a.observer_distance < b.observer_distance
end

function simulation_lod.Update(controllers)
	local step = physics.instance.StepIndex

	if observer_step and step >= observer_step and step - observer_step < RANK_INTERVAL then
		return
	end

	observer_step = step
	refresh_observers()
	local count = 0

	for _, controller in ipairs(controllers) do
		if controller.Owner.character_movement then
			local position = controller.Owner.transform:GetPosition()
			local nearest = math.huge

			for i = 1, observer_count, 3 do
				local dx, dy, dz = observers[i] - position.x,
				observers[i + 1] - position.y,
				observers[i + 2] - position.z
				nearest = math.min(nearest, dx * dx + dy * dy + dz * dz)
			end

			controller.observer_distance = math.sqrt(nearest)
			count = count + 1
			ranked[count] = controller
		end
	end

	for i = #ranked, count + 1, -1 do
		ranked[i] = nil
	end

	table.sort(ranked, sort_by_distance)

	for rank, controller in ipairs(ranked) do
		controller.far = observer_count > 0 and
			(
				rank > simulation_lod.MaxSimulated or
				controller.observer_distance > controller.PhysicsDistance + (
					controller.far and
					0 or
					PHYSICS_HYSTERESIS
				)
			)
	end
end

return simulation_lod
