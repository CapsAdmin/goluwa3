local network = import("goluwa/network/network.lua")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local signals = import("test/network_e2e/signals.lua")
local QuatDeg3 = QuatDeg3
local RUN_TIME = 4
local BUTTON = usercmd.BUTTON
local ent = Entity.New{
	Name = "e2e_bot",
	ComponentSet = {"transform", "player_controller", "player_movement"},
	transform = {Position = Vec3(0, 3, 0)},
	player_controller = {Source = "local", Networked = true},
}
local controller = ent.player_controller
local start_time

event.AddListener("CreateMove", "e2e_bot", function(owner, cmd)
	if owner ~= ent or not controller.synced then return end

	if not start_time then
		start_time = system.GetTime()
		signals.Write("bot.synced")
	end

	local elapsed = system.GetTime() - start_time
	cmd.mode = "walk"
	cmd.buttons = BUTTON.ACTIVE

	if elapsed > 0.8 then cmd.buttons = cmd.buttons + BUTTON.ATTACK1 end

	cmd.view = QuatDeg3(-15, math.floor(elapsed / 1.5) * 90, 0)

	if elapsed > 1.2 and elapsed < 3.2 then
		cmd.forward = 1
		cmd.side = math.floor(elapsed) % 2 == 0 and 1 or 0

		if math.floor(elapsed * 2) % 5 == 0 then
			cmd.buttons = bit.bor(cmd.buttons, BUTTON.JUMP)
		end
	end
end)

local own_relays = 0

event.AddListener("RemotePlayerCommands", "e2e_bot", function()
	own_relays = own_relays + 1
end)

network.Connect("127.0.0.1", os.getenv("GOLUWA_PORT"))
local max_error = 0
local reconcile = controller.Reconcile
local calls = 0

if os.getenv("E2E_TRACE") then
	event.AddListener("PlayerCommand", "e2e_trace", function(owner, cmd)
		if cmd.number >= 296 and cmd.number <= 330 then
			local b = ent.rigid_body
			print(
				string.format(
					"TRACE n=%d pos=(%.3f %.3f %.3f) vel=(%.2f %.2f %.2f)",
					cmd.number,
					b:GetPosition().x,
					b:GetPosition().y,
					b:GetPosition().z,
					b:GetVelocity().x,
					b:GetVelocity().y,
					b:GetVelocity().z
				)
			)
		end
	end)
end

if os.getenv("E2E_DEBUG") then
	function controller:Reconcile(number, position, velocity)
		local entry = self:GetHistory(number)
		calls = calls + 1

		if not entry then print("RECONCILE_NO_ENTRY", number, self.number) end

		local before = entry and position - entry.position
		local before_vel = entry and velocity - entry.velocity
		local magnitude = reconcile(self, number, position, velocity)

		if magnitude > 0 then
			print(
				string.format(
					"reconcile n=%d cur=%d err=(%.3f %.3f %.3f) verr=(%.2f %.2f %.2f) srv=(%.3f %.3f %.3f)",
					number,
					self.number,
					before.x,
					before.y,
					before.z,
					before_vel.x,
					before_vel.y,
					before_vel.z,
					position.x,
					position.y,
					position.z
				)
			)
		end

		return magnitude
	end
end

local finished = false

event.AddListener("Update", "e2e_bot_report", function()
	if controller.last_correction and controller.last_correction > max_error then
		max_error = controller.last_correction
	end

	if finished or not start_time or system.GetTime() - start_time < RUN_TIME then
		return
	end

	finished = true
	local p = ent.transform:GetPosition()
	signals.Write(
		"bot.result",
		string.format(
			"BOT_RESULT x=%.3f y=%.3f z=%.3f corrections=%d max_error=%.4f cmds=%d\nBOT_RELAYS_RECEIVED %d\nBOT_RECONCILE_CALLS %d\n",
			p.x,
			p.y,
			p.z,
			controller.corrections,
			max_error,
			controller.number,
			own_relays,
			calls
		)
	)
end)

if os.getenv("E2E_DESYNC") then
	event.AddListener("Update", "e2e_bot_desync", function()
		if not start_time or system.GetTime() - start_time < 2.2 then return end

		event.RemoveListener("Update", "e2e_bot_desync")
		ent.player_movement:MoveBodyBy(ent.rigid_body, Vec3(2, 0, 0))
	end)
end
