local T = import("test/environment.lua")
local animations = import("lua/animations.lua")
local pose_editor = import("lua/jrpg/pose_editor.lua")
import("addons/jrpg/lua/autorun/weapons.lua")

local function new_session()
	local session = {SelectId = 0}
	animations.Register(
		"pose_editor_hold",
		{Kind = "state", Enter = 0.05, Exit = 0.05, PoseWeapon = true}
	)
	pose_editor.LoadSources(session)
	return session
end

T.Test("the pose editor lists the shared poses and the ones local to a moveset and counts their uses", function()
	local session = new_session()
	local sources = pose_editor.GetSources(session)
	T(sources[1])["=="]("shared")
	T(session.Data.Poses.shared.crouch_low ~= nil)["=="](true)
	T(pose_editor.CountUses(session, "crouch_low") > 0)["=="](true)
	T(pose_editor.CountUses(session, "nobody_uses_this"))["=="](0)
	T(pose_editor.IsDirty(session, "shared"))["=="](false)
end)

T.Test("selecting a pose compiles it into the held state and edits follow", function()
	local session = new_session()
	pose_editor.Select(session, "shared", "crouch_low")
	local def = animations.Get("pose_editor_hold")
	T(def.TorsoKeys[1][2])["=="](session.Data.Poses.shared.crouch_low.torso)
	session.Data.Poses.shared.crouch_low.torso = 0.5
	pose_editor.Apply(session)
	T(def.TorsoKeys[1][2])["=="](0.5)
	T(pose_editor.IsDirty(session, "shared"))["=="](true)
end)

T.Test("a pose is duplicated with a free name and only deleted when nothing uses it", function()
	local session = new_session()
	pose_editor.Select(session, "shared", "crouch_low")
	T(pose_editor.Delete(session))["=="](false)
	T(pose_editor.Duplicate(session))["=="](true)
	T(session.PoseName)["=="]("crouch_low_copy")
	T(
		table.equal(session.Data.Poses.shared.crouch_low_copy, session.Data.Poses.shared.crouch_low)
	)["=="](true)
	T(pose_editor.Delete(session))["=="](true)
	T(session.Data.Poses.shared.crouch_low_copy)["=="](nil)
end)

T.Test("undo restores the poses from before an edit", function()
	local session = new_session()
	pose_editor.Select(session, "shared", "crouch_low")
	local before = session.Data.Poses.shared.crouch_low.torso
	session.Data.Poses.shared.crouch_low.torso = 0.9
	pose_editor.Commit(session, true)
	pose_editor.StepHistory(session, false)
	T(session.Data.Poses.shared.crouch_low.torso)["=="](before)
end)

T.Test("dragging the hand handle moves the hand values along the aim frame", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Quat = import("goluwa/structs/quat.lua")
	local session = new_session()
	pose_editor.Select(session, "shared", "cut_left")
	session.Attacker = {transform = {GetRotation = ||->Quat():Identity()}}
	local pose = session.Data.Poses.shared.cut_left
	pose.aim = {0, 0}
	local before = table.copy(pose.hand)
	pose_editor.MoveHand(session, Vec3(0.1, 0, 0))
	T(pose.hand[1] > before[1])["=="](true)
	T(pose.hand[2])["=="](before[2])
	pose_editor.MoveHand(session, Vec3(0, 0, 0.1))
	T(pose.hand[3] > before[3])["=="](true)
	pose_editor.MoveHand(session, Vec3(100, 0, 0))
	T(pose.hand[1] <= 1.5)["=="](true)
end)

T.Test("a new pose starts at rest for every track, with a free valid name", function()
	local session = new_session()
	pose_editor.Select(session, "shared", "crouch_low")
	T(pose_editor.IsNameFree(session, "crouch_low"))["=="](false)
	T(pose_editor.IsNameFree(session, ""))["=="](false)
	T(pose_editor.IsNameFree(session, "two words"))["=="](false)
	T(pose_editor.IsNameFree(session, "9lives"))["=="](false)
	T(pose_editor.IsNameFree(session, "my_new_pose"))["=="](true)
	T(pose_editor.AddPose(session, "crouch_low"))["=="](false)
	T(pose_editor.AddPose(session, "my_new_pose"))["=="](true)
	T(session.PoseName)["=="]("my_new_pose")
	local pose = session.Data.Poses.shared.my_new_pose
	T(pose.torso)["=="](0)
	T(pose.aim[1] == 0 and pose.aim[2] == 0)["=="](true)
	T(pose.head[1])["=="](1)
	T(#pose.hand)["=="](6)
	T(pose_editor.IsDirty(session, "shared"))["=="](true)
	T(animations.Get("pose_editor_hold").AimKeys)["=="](nil)
end)

T.Test("reloading from file drops every edit and keeps the selection when the pose still exists", function()
	local session = new_session()
	pose_editor.Select(session, "shared", "crouch_low")
	session.Data.Poses.shared.crouch_low.torso = 0.9
	pose_editor.AddPose(session, "scratch_pose")
	T(pose_editor.IsDirty(session, "shared"))["=="](true)
	pose_editor.Select(session, "shared", "crouch_low")
	pose_editor.Reload(session)
	T(pose_editor.IsDirty(session, "shared"))["=="](false)
	T(session.PoseName)["=="]("crouch_low")
	T(session.Data.Poses.shared.scratch_pose)["=="](nil)
	pose_editor.Select(session, "shared", "crouch_low")
	T(session.Data.Poses.shared.crouch_low.torso ~= 0.9)["=="](true)
end)
