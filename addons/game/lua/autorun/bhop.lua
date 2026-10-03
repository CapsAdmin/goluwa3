local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local WALL_NORMAL_MAX_Y = 0.7
local WALL_BOUNCE_SPEED = 1.1
local DOWN_LOOK_PITCH = math.rad(89)
local DOWN_LOOK_MIN = 0.3
local DOWN_LOOK_SPEED_GAIN = 0.3
local DOWN_LOOK_HORIZONTAL_KEEP = 0.5
local MAX_SPEED = 300
pvars.StartGroup("bhop", {store = true})
local multiplier = pvars.Setup2{
	key = "bhop_multiplier",
	default = 1.5,
	min = 0,
	friendly = "jump multiplier",
	help = "how much a jump from the ground multiplies the speed, 1 turns the extra movement off",
}
pvars.EndGroup()
local players = table.weak("k")

local function setup_player(entity)
	local movement = entity.player_movement
	movement:SetAirAcceleration(1000000)
	movement:SetStickToGround(false)
	movement:SetWalkMaxLinearSpeed(MAX_SPEED)

	if entity.player_input.Mode == "walk" then
		entity.rigid_body:SetMaxLinearSpeed(MAX_SPEED)
	end

	return {}
end

event.AddListener("PlayerMove", "bhop", function(entity, move)
	local player = players[entity]

	if not player then
		player = setup_player(entity)
		players[entity] = player
	end

	local velocity = move.velocity
	local jump_multiplier = multiplier:Get()

	if jump_multiplier ~= 1 and move.jump_pressed and move.grounded then
		velocity:Set(velocity.x * jump_multiplier, velocity.y * jump_multiplier, velocity.z * jump_multiplier)
		local look_down = math.clamp(-move.pitch / DOWN_LOOK_PITCH, 0, 1) ^ 3

		if look_down > DOWN_LOOK_MIN then
			move.grounded = false
			local speed = velocity:GetLength()
			local keep = DOWN_LOOK_HORIZONTAL_KEEP
			local jump_speed = entity.player_movement.JumpSpeed
			velocity:Set(
				math.lerp(look_down, velocity.x, velocity.x * keep),
				math.lerp(look_down, velocity.y, velocity.y + speed * DOWN_LOOK_SPEED_GAIN) + jump_speed,
				math.lerp(look_down, velocity.z, velocity.z * keep)
			)
		end
	end

	if
		(
			move.jump_pressed or
			move.jump_down
		)
		and
		not move.grounded and
		velocity.x ~= 0 and
		velocity.z ~= 0
	then
		local movement = entity.player_movement
		local radius = math.sqrt(movement.Radius ^ 2 + (movement.Height * 0.5) ^ 2)
		local hit = movement:SweepHull(velocity:GetNormalized(), radius * 2)

		if
			hit and
			math.abs(hit.normal.y) < WALL_NORMAL_MAX_Y and
			(
				not player.bounce_position or
				(
					player.bounce_position - move.position
				):GetLength() > radius
			)
		then
			local normal = hit.normal
			local into_wall = normal:Dot(velocity)
			velocity:Set(
				(velocity.x - 2 * into_wall * normal.x) * WALL_BOUNCE_SPEED,
				(velocity.y - 2 * into_wall * normal.y) * WALL_BOUNCE_SPEED,
				(velocity.z - 2 * into_wall * normal.z) * WALL_BOUNCE_SPEED
			)
			player.bounce_position = move.position:Copy()
		end
	end
end)
