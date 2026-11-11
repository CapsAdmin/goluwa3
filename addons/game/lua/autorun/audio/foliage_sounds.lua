local event = import("goluwa/event.lua")
local audio = AUDIO and import("goluwa/audio.lua")
local foliage_field = import("goluwa/foliage_field.lua")
local RigidBody = import("goluwa/physics/rigid_body.lua")
local sounds = import("lua/sounds.lua")
local sound_profiles = import("lua/sound_profiles.lua")
local TICK = 0.05
local RANGE_SQUARED = 40 ^ 2
local MIN_SPEED = 0.5
local LOUD_SPEED = 4
local SPACING = 1
local QUIET = 0.2
local MAX_PER_TICK = 3
local travelled = setmetatable({}, {__mode = "k"})
local elapsed = 0

event.AddListener("Update", "foliage_sounds", function(dt)
	if not audio or not CLIENT then return end

	elapsed = elapsed + dt

	if elapsed < TICK then return end

	local step = elapsed
	elapsed = 0
	local listener = audio.GetListenerPosition()
	local bodies = RigidBody.Instances
	local played = 0

	for i = 1, #bodies do
		local body = bodies[i]

		if body.MotionType == "dynamic" and body.Awake then
			local velocity = body.Velocity
			local speed = velocity:GetLength()

			if speed > MIN_SPEED then
				local position = body.Position
				local dx, dz = position.x - listener.x, position.z - listener.z

				if dx * dx + dz * dz < RANGE_SQUARED then
					local cover = foliage_field.Sample(position.x, position.y, position.z)

					if cover > 0 then
						local distance = (travelled[body] or 0) + speed * step

						if distance >= SPACING and played < MAX_PER_TICK then
							distance = distance - SPACING
							played = played + 1
							local set = sound_profiles.Get().GetFoliage()
							local index = math.random(#set)

							if index == set.last then index = index % #set + 1 end

							set.last = index
							sounds.Play(
								set[index],
								position,
								set.gain * cover * math.clamp(speed / LOUD_SPEED, QUIET, 1),
								math.randomf(0.9, 1.1)
							)
						end

						travelled[body] = distance
					else
						travelled[body] = nil
					end
				end
			end
		end
	end
end)
