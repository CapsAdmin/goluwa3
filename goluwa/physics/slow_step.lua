local system = import("goluwa/system.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local slow_step = {}
slow_step.IslandTimes = {}
slow_step.Islands = nil
local WARNING_INTERVAL = 2
local TIMING_TICKS = 30
local MIN_CULPRIT_SHARE = 0.25
local MAX_CULPRITS = 3
local culprit_notes = {}

local function get_state(physics)
	local state = physics.SlowStep

	if not state then
		state = {warned_at = -math.huge, suppressed = 0, dropped = 0, timing_ticks = 0}
		physics.SlowStep = state
	end

	return state
end

function slow_step.Drop(physics, seconds)
	local state = get_state(physics)
	state.dropped = state.dropped + seconds
end

function slow_step.Relax(physics)
	local state = get_state(physics)
	state.timing_ticks = state.timing_ticks - 1

	if state.timing_ticks <= 0 then
		physics.TimeIslands = false
		slow_step.Islands = nil
	end
end

function slow_step.Report(physics, listener_time, step_time)
	local state = get_state(physics)
	local times = slow_step.IslandTimes
	local simulation_islands = slow_step.Islands
	local total_time = 0
	local slept_bodies = 0
	local note_count = 0

	if simulation_islands then
		for i = 1, #simulation_islands do
			total_time = total_time + (times[i] or 0)
		end

		for _ = 1, MAX_CULPRITS do
			local best_index
			local best_time = 0

			for i = 1, #simulation_islands do
				local island_time = times[i]

				if island_time and island_time > best_time then
					best_index = i
					best_time = island_time
				end
			end

			if not best_index or best_time < total_time * MIN_CULPRIT_SHARE then break end

			times[best_index] = nil
			local island = simulation_islands[best_index]
			local bodies = island.dynamic_bodies
			local awake_count = 0
			local sleepable = true
			local first_awake

			for i = 1, #bodies do
				local body = bodies[i]

				if body.Awake then
					awake_count = awake_count + 1
					first_awake = first_awake or body

					if not body.CanSleep or body:IsKinematic() or body:HasKinematicController() then
						sleepable = false
					end
				end
			end

			if first_awake then
				if sleepable then
					for i = 1, #bodies do
						if bodies[i].Awake then bodies[i]:Sleep() end
					end

					slept_bodies = slept_bodies + awake_count
				end

				note_count = note_count + 1
				culprit_notes[note_count] = string.format(
					"island of %d awake bodies took %.1f ms near %s (%s), %s",
					awake_count,
					best_time * 1000,
					tostring(first_awake.Position),
					tostring(first_awake.Owner),
					sleepable and
						"put to sleep" or
						"not put to sleep: it holds a body that cannot sleep"
				)
			end
		end
	end

	physics.TimeIslands = true
	state.timing_ticks = TIMING_TICKS
	local now = system.GetTime()

	if now - state.warned_at < WARNING_INTERVAL then
		state.suppressed = state.suppressed + 1

		if slept_bodies == 0 then
			for i = 1, note_count do
				culprit_notes[i] = nil
			end

			return
		end
	end

	local awake_bodies = 0
	local dynamic_bodies = 0
	local bodies = RigidBody.Instances

	for i = 1, #bodies do
		local body = bodies[i]

		if body:IsDynamic() then
			dynamic_bodies = dynamic_bodies + 1

			if body.Awake then awake_bodies = awake_bodies + 1 end
		end
	end

	wlog(
		"[physics] slow tick %.1f ms (listeners %.1f ms, step %.1f ms), %d of %d dynamic bodies awake%s%s%s%s",
		(listener_time + step_time) * 1000,
		listener_time * 1000,
		step_time * 1000,
		awake_bodies,
		dynamic_bodies,
		state.suppressed > 0 and
			string.format(", %d more slow ticks since the last warning", state.suppressed) or
			"",
		state.dropped > 0 and
			string.format(", dropped %.0f ms of simulation", state.dropped * 1000) or
			"",
		note_count > 0 and ": " or "",
		table.concat(culprit_notes, "; ", 1, note_count)
	)
	state.warned_at = now
	state.suppressed = 0
	state.dropped = 0

	for i = 1, note_count do
		culprit_notes[i] = nil
	end
end

return slow_step
