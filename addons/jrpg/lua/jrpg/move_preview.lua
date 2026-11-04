local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local actors = import("lua/actors.lua")
local grab = import("lua/grab.lua")
local movesets = import("lua/movesets.lua")
local move_preview = {}
local META = {}
META.__index = META
local motion = Vec3()
local before, after = Vec3(), Vec3()
local velocity = Vec3()
local SPAN = 0.01

function move_preview.Start(grabber, victim, move)
	local frame = {}
	movesets.NewFrame(grabber, move, frame)
	frame.target = victim
	movesets.Anchor(frame, actors.GetCenter(victim):Copy())
	local direction = frame.point - frame.start
	local puppet = grab.Puppet(grabber)
	puppet.Rotation:Identity():RotateYaw(math.atan2(-direction.x, -direction.z))
	grabber.character_pose:SetFocusOn(nil, frame.point)
	return setmetatable(
		{
			Grabber = grabber,
			Victim = victim,
			Move = move,
			Frame = frame,
			Puppet = puppet,
			Ground = grabber.transform:GetPosition().y,
			Distance = 0,
			GrabberHome = grabber.transform:GetPosition():Copy(),
			VictimHome = victim.transform:GetPosition():Copy(),
		},
		META
	)
end

function META:SetPhase(f, dt)
	local move = self.Move
	local victim = self.Victim
	self.Grabber.character_pose:ScrubAction(move.Action, move.Duration, f)
	local _, height = movesets.SampleMotion(move, f, self.Frame, self.Frame.point, motion)
	self.Puppet.Position:Set(motion.x, self.Ground + (move.Vertical and math.max(height, 0) or 0), motion.z)
	local pose = self.Grabber.character_pose
	velocity:Set(0, 0, 0)

	if dt then
		local from, to = math.max(f - SPAN, 0), math.min(f + SPAN, 1)
		local _, from_height = movesets.SampleMotion(move, from, self.Frame, self.Frame.point, before)
		local _, to_height = movesets.SampleMotion(move, to, self.Frame, self.Frame.point, after)
		local seconds = (to - from) * move.Duration

		if seconds > 0 then
			velocity:Set(
				(after.x - before.x) / seconds,
				move.Vertical and (to_height - from_height) / seconds or 0,
				(after.z - before.z) / seconds
			)
		end

		self.Distance = self.Distance + math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z) * dt
	end

	pose:SetPreviewMotion(velocity, self.Distance)
	local latch = movesets.GetEvent(move, "latch")

	if not latch then return end

	local latched = grab.IsHeld(victim)

	if f >= latch.At then
		if not latched then
			grab.Latch(
				self.Grabber,
				victim,
				{
					Def = move,
					Bones = grab.GetCarryBones(victim, move.CarryBones),
					Weapon = self.Grabber.weapon_holder:GetWeapon("right"),
					PhaseLimit = movesets.GetEvent(move, "release").At,
				}
			)
		end
	elseif latched then
		grab.Detach(victim)
		victim.character_movement:TeleportTo(self.VictimHome)
	end
end

function META:Stop()
	local victim = self.Victim

	if grab.IsHeld(victim) then
		grab.Detach(victim)
		victim.character_movement:TeleportTo(self.VictimHome)
	end

			if grab.IsAwaitingBones(victim, move.CarryBones) then return end

	grab.Unpuppet(self.Grabber)
	self.Grabber.character_movement:TeleportTo(self.GrabberHome)
	self.Grabber.character_pose:EndScrub()
end

return move_preview
