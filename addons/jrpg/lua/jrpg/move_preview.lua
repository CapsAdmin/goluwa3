local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local actors = import("lua/actors.lua")
local grab = import("lua/grab.lua")
local movesets = import("lua/jrpg/movesets.lua")
local move_preview = {}
local META = {}
META.__index = META
local motion = Vec3()

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
			GrabberHome = grabber.transform:GetPosition():Copy(),
			VictimHome = victim.transform:GetPosition():Copy(),
		},
		META
	)
end

function META:SetPhase(f)
	local move = self.Move
	local victim = self.Victim
	self.Grabber.character_pose:ScrubAction(move.Action, move.Duration, f)
	movesets.SampleMotion(move, f, self.Frame, self.Frame.point, motion)
	self.Puppet.Position:Set(motion.x, self.Ground, motion.z)
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
					Bones = victim.source_pose.bones,
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

	grab.Unpuppet(self.Grabber)
	self.Grabber.character_movement:TeleportTo(self.GrabberHome)
	self.Grabber.character_pose:EndScrub()
end

return move_preview
