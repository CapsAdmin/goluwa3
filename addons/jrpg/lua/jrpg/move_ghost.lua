local Color = import("goluwa/structs/color.lua")
local Material = import("goluwa/render3d/material.lua")
local movesets = import("lua/movesets.lua")
local move_stage = import("lua/jrpg/move_stage.lua")
local move_preview = import("lua/jrpg/move_preview.lua")
local move_ghost = {}
move_ghost.MaxCount = 12
local EARLY = Color(0.35, 0.65, 1, 0.3)
local LATE = Color(1, 0.6, 0.25, 0.3)
local TINT = Color()
local SETTLE_STEP = 0.025
local OVERRIDE_RETRY = 0.5
local OVERRIDE_TIME = 10

local function apply_material(ghost)
	for _, entity in ipairs{ghost.Attacker, ghost.Victim} do
		for _, child in ipairs(entity:GetChildrenList()) do
			if child.visual and child.visual.MaterialOverride ~= ghost.Material then
				child.visual:SetMaterialOverride(ghost.Material)
			end
		end

		if entity.visual and entity.visual.MaterialOverride ~= ghost.Material then
			entity.visual:SetMaterialOverride(ghost.Material)
		end
	end
end

local function remove(ghost)
	if ghost.Preview then ghost.Preview:Stop() end

	for _, entity in ipairs{ghost.Attacker, ghost.Victim} do
		if entity:IsValid() then entity:Remove() end
	end
end

local function start(session, ghost)
	local live = session.Preview
	ghost.Attacker.character_movement:TeleportTo(live.GrabberHome)
	ghost.Victim.character_movement:TeleportTo(live.VictimHome)
	ghost.Preview = move_preview.Start(ghost.Attacker, ghost.Victim, live.Move)
	ghost.Source = live
end

function move_ghost.Clear(session)
	for _, ghost in ipairs(session.Ghosts or {}) do
		remove(ghost)
	end

	session.Ghosts = {}
end

function move_ghost.Show(session, phases, now, stamp)
	local ghosts = session.Ghosts
	local live = session.Preview

	if session.GhostSet ~= session.SetName then
		move_ghost.Clear(session)
		ghosts = session.Ghosts
		session.GhostSet = session.SetName
	end

	while #ghosts > #phases do
		remove(table.remove(ghosts))
	end

	for i, phase in ipairs(phases) do
		local ghost = ghosts[i]

		if not ghost then
			local rotation = session.Grabber.transform:GetRotation()
			ghost = {
				Attacker = move_stage.SpawnAttacker(session.SetName, session.AttackerName, live.GrabberHome, rotation),
				Victim = move_stage.SpawnNpc(session.VictimName, live.VictimHome, rotation),
				Material = Material.New{Translucent = true},
				Born = now,
				Checked = -math.huge,
			}
			ghosts[i] = ghost
		end

		move_stage.Arm(ghost.Attacker, session.SetName)
		move_stage.Hold(ghost.Attacker)
		move_stage.Hold(ghost.Victim)

		if ghost.Source ~= live then
			if ghost.Preview then ghost.Preview:Stop() end

			start(session, ghost)
		end

		if ghost.Stamp ~= stamp then
			ghost.Stamp = stamp
			ghost.Preview.Move = live.Move
			ghost.Preview:SetPhase(0)
			ghost.Current = nil
		end

		if ghost.Phase ~= phase then
			ghost.Phase = phase
			local t = #phases > 1 and (i - 1) / (#phases - 1) or 0
			TINT:Set(
				EARLY.r + (LATE.r - EARLY.r) * t,
				EARLY.g + (LATE.g - EARLY.g) * t,
				EARLY.b + (LATE.b - EARLY.b) * t,
				EARLY.a
			)
			ghost.Material:SetColorMultiplier(TINT:Copy())
		end

		if ghost.Current ~= phase then
			local latch = movesets.GetEvent(live.Move, "latch")

			if not ghost.Current then
				ghost.Current = latch and phase > latch.At and latch.At or phase
			end

			ghost.Current = ghost.Current + math.clamp(phase - ghost.Current, -SETTLE_STEP, SETTLE_STEP)
			ghost.Preview:SetPhase(ghost.Current)
		end

		if now - ghost.Born < OVERRIDE_TIME and now - ghost.Checked > OVERRIDE_RETRY then
			ghost.Checked = now
			apply_material(ghost)
		end
	end
end

return move_ghost
