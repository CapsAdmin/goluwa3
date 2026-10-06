local network = import("goluwa/network/network.lua")
local relayed = 0
local relay_numbers = 0
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local signals = import("test/network_e2e/signals.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local SETTLE_DISTANCE = 0.15
local TIMEOUT = 40
local NetworkComponent = import("goluwa/entities/components/network.lua")

event.AddListener("RemotePlayerCommands", "e2e_observer", function(owner, commands)
	relayed = relayed + 1
	relay_numbers = math.max(relay_numbers, commands[#commands].number)
end)

network.Connect("127.0.0.1", os.getenv("GOLUWA_PORT"))
local first_x
local moved = false
local ball_fell = false
local checks = {}
local passed = false
local crate_lifted = false
local crate_max_y = 0

local function find(name)
	for id = 1, 16 do
		local component = NetworkComponent.GetByNetworkId(id)

		if component and component.Owner:GetName() == name then
			return component.Owner
		end
	end
end

event.AddListener("Update", "e2e_observer", function()
	if not network.IsConnected() then return end

	local ground = find("e2e_ground")
	checks.ground = ground ~= nil and
		ground.transform:GetScale().x == 200 and
		ground.model:GetModelPath() == "models/box.lua" and
		ground.rigid_body:GetMotionType() == "static" and
		ground.rigid_body:GetPhysicsShape():GetSize().x == 200
	local ball = find("e2e_ball")

	if ball then
		local y = ball.transform:GetPosition().y

		if y < 5 then ball_fell = true end

		checks.ball = ball.rigid_body:GetMotionType() == "kinematic" and
			ball_fell and
			math.abs(y - 0.5) < 0.1
	end

	local crate = find("e2e_crate")

	if crate then
		crate_max_y = math.max(crate_max_y, crate.transform:GetPosition().y)

		if crate.transform:GetPosition().y > 0.7 then crate_lifted = true end
	end

	local light = find("e2e_light")
	checks.light = light ~= nil and
		light.light_point:GetLumen() == 500 and
		light.light_point:GetRange() == 20 and
		light.light_point:GetColor().g == 0.5
	local prop = find("replicated_prop")

	if prop then
		first_x = first_x or prop.transform:GetPosition().x

		if math.abs(prop.transform:GetPosition().x - first_x) > 0.5 then moved = true end

		checks.prop = moved and
			prop.transform:GetSize() == 3 and
			prop.model:GetModelOptions().size.z == 3
	end

	local child = find("replicated_child")
	checks.child = child ~= nil and child:GetParent():GetName() == "replicated_prop"
	local all = true

	for _, key in ipairs{"ground", "ball", "light", "prop", "child"} do
		if not checks[key] then all = false end
	end

	passed = passed or all
end)

local started = system.GetTime()
local finished = false

local function find_avatar()
	for _, component in pairs(NetworkComponent.GetAllNetworked()) do
		if component.Owner.player_avatar then return component.Owner end
	end
end

local function finish(timed_out)
	finished = true
	local lines = {}

	for _, key in ipairs{"ground", "ball", "light", "prop", "child"} do
		lines[#lines + 1] = string.format("OBSERVER_CHECK %s %s", key, tostring(checks[key]))
	end

	local avatar = find_avatar()

	if avatar then
		local p = avatar.transform:GetPosition()
		lines[#lines + 1] = string.format("OBSERVER_AVATAR x=%.3f y=%.3f z=%.3f", p.x, p.y, p.z)
		local crate = find("e2e_crate")

		if crate then
			local distance = (crate.transform:GetPosition() - p):GetLength()
			lines[#lines + 1] = string.format(
				"OBSERVER_CRATE lifted=%s distance=%.3f max_y=%.3f holding=%s",
				tostring(crate_lifted),
				distance,
				crate_max_y,
				tostring(avatar.player_avatar:IsHolding())
			)
		end
	end

	lines[#lines + 1] = string.format("OBSERVER_RELAY batches=%d last=%d", relayed, relay_numbers)
	lines[#lines + 1] = "OBSERVER_RESULT passed=" .. tostring(passed and not timed_out)
	signals.Write("observer.result", table.concat(lines, "\n") .. "\n")
end

event.AddListener("Update", "e2e_observer_finish", function()
	if finished then return end

	if system.GetTime() - started > TIMEOUT then
		finish(true)
		return
	end

	local bot_result = signals.Read("bot.result")
	local avatar = find_avatar()

	if not (bot_result and avatar) then return end

	local x, y, z = bot_result:match("BOT_RESULT x=([%-%d%.]+) y=([%-%d%.]+) z=([%-%d%.]+)")
	local expected = Vec3(tonumber(x), tonumber(y), tonumber(z))

	if (avatar.transform:GetPosition() - expected):GetLength() < SETTLE_DISTANCE then
		finish(false)
	end
end)
