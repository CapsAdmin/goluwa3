local players = import("lua/players.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Rect = import("goluwa/structs/rect.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local theme = import("goluwa/render2d/ui/theme.lua")
local objects = import("goluwa/objects/objects.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local View = import("goluwa/render3d/view.lua")
local Quat = import("goluwa/structs/quat.lua")
local view_camera = import("lua/view_camera.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local keyframes = import("lua/keyframes.lua")
local actors = import("lua/actors.lua")
local npcs = import("lua/npcs.lua")
local movesets = import("lua/movesets.lua")
local move_edit = import("lua/jrpg/move_edit.lua")
local move_preview = import("lua/jrpg/move_preview.lua")
local move_ghost = import("lua/jrpg/move_ghost.lua")
local move_stage = import("lua/jrpg/move_stage.lua")
local data_history = import("lua/data_history.lua")
local camera_shots = import("lua/camera_shots.lua")
local faces = import("lua/faces.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local input = import("goluwa/input.lua")
local physics = import("goluwa/physics.lua")
local system = import("goluwa/system.lua")
local move_editor = {}
local NPC_OFFSET = 3
local STAGE_DISTANCE = 6
local STAGE_GAP = 2.6
local STAGE_RAISE = 3
local LEFT_WIDTH = 400
local BOTTOM_HEIGHT = 320
local MOVES_HEIGHT = 210
local STRIP_HEIGHT = 16
local MOVE_COLUMNS = {
	{Key = "Text", Text = "Move", Grow = true, MinWidth = 100},
	{Key = "Time", Text = "Time", Width = 52},
	{
		Key = "Ticks",
		Text = "Keys",
		Width = 118,
		Draw = |node, x, y, width, height|->move_editor.DrawTicks(node.Ticks, x, y, width, height),
	},
}
local TIMELINE_RULER = 22
local TIMELINE_ROW = 22
local TIMELINE_CHROME = 34 + 6 * 2
local CAMERAS = {"three", "side", "front"}
local GHOST_MODES = {"off", "whole move", "around playhead", "selection"}
local GHOST_SOURCES = {"evenly spaced", "one per key"}
local GHOST_COUNTS = {3, 6, 9, 12}
local SPEEDS = {"1", "0.5", "0.25", "0.1"}
local DEG = 180 / math.pi
move_editor.LastSet = "sword"
local MOVE_FIELDS = {
	{"Duration", "duration"},
	{"Stamina", "stamina"},
	{"Reach", "reach"},
	{"Approach", "approach"},
	{"Retreat", "retreat"},
	{"Cancel", "cancel"},
	{"Follow", "follow"},
}

function move_editor.GetSetNames()
	local names = {}

	for name in pairs(movesets.Registered) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end

local function get_move_names(data)
	local names = {}

	for name in pairs(data.Moves) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end

local function get_pose_names(data)
	local names = {}

	for name in pairs(keyframes.Poses) do
		if name ~= "rest" then names[#names + 1] = name end
	end

	for name in pairs(data.Poses or {}) do
		if not keyframes.Poses[name] then names[#names + 1] = name end
	end

	table.sort(names)
	return names
end

local function find_selection(rows, selected)
	local found = {}

	for _, selection in ipairs(selected) do
		for i, row in ipairs(rows) do
			for j, key in ipairs(row.Keys) do
				if
					selection.Entry and
					key.Entry == selection.Entry or
					selection.Event and
					key.Event == selection.Event or
					selection.Frame and
					key.Frame == selection.Frame and
					key.Track == selection.Track
				then
					found[#found + 1] = {i, j}
				end
			end
		end
	end

	return found
end

do
	local CAMERA_OFFSETS = {
		three = {3.2, 1.8, 4.8},
		side = {1.4, 1.8, 7.5},
		front = {6, 1.8, 0.8},
	}

	function move_editor.SetCameraPreset(session, name)
		local grabber = session.Grabber
		local anchor = grabber.transform:GetPosition():Copy()
		local forward = actors.GetForward(grabber)
		local right = Vec3(forward.z, 0, -forward.x)
		local offset = CAMERA_OFFSETS[name]
		local eye = anchor + forward * offset[1] + Vec3(0, offset[2], 0) + right * offset[3]

		if name == "side" then
			eye = anchor + right * offset[3] + Vec3(0, offset[2], 0) + forward * offset[1]
		end

		local direction = (anchor + forward * 1.4 + Vec3(0, 0.5, 0) - eye):GetNormalized()
		local focal = Panel.World.transform:GetHeight() / 2 / math.tan(render3d.GetMainCamera():GetFOV() / 2)
		local yaw = math.deg(math.atan2(-direction.x, -direction.z) + math.atan(LEFT_WIDTH / 2 / focal))
		local pitch = math.deg(math.asin(direction.y) - math.atan(BOTTOM_HEIGHT / 2 / focal))
		view_camera.Set(session.Fly, eye, pitch, yaw)
		session.Camera = name
	end
end

function move_editor.CreateSession()
	local player = assert(players.GetLocal(), "the move editor needs the local player")
	local session = {
		Player = player,
		Grabber = player,
		PreviewOn = "stage",
		AttackerName = "player",
		VictimName = "citizen",
		Procedural = true,
		Stage = {},
		Camera = "three",
		Phase = 0,
		Playing = false,
		Loop = true,
		Speed = 1,
		Status = "",
		SelectId = 0,
		Selected = {},
		Ghosts = {},
		GhostMode = "off",
		GhostSource = "evenly spaced",
		GhostCount = 6,
		GhostWindow = 0.15,
	}
	session.View = View.New{
		Priority = 1000,
		ExposureLock = 16,
		HidePlayer = false,
		HideHud = true,
	}
	session.View:Activate()
	session.BaseFOV = session.View:GetFOV()
	session.Fly = view_camera.Start(session.View, 6)
	move_editor.SetCameraPreset(session, session.Camera)
	move_editor.Current = session
	return session
end

function move_editor.DestroySession(session)
	move_editor.Current = nil

	if session.Preview then session.Preview:Stop() end

	move_ghost.Clear(session)
	move_editor.RemoveActors(session)

	if session.PlayerVictim and session.PlayerVictim:IsValid() then
		session.PlayerVictim:Remove()
	end

	session.View:Remove()
	view_camera.Stop(session.Fly)
end

function move_editor.SelectMany(session, selected)
	session.Selected = selected
	session.Selection = #selected == 1 and selected[1] or nil
	session.SelectId = session.SelectId + 1
end

function move_editor.Select(session, selection)
	move_editor.SelectMany(session, selection and {selection} or {})
end

function move_editor.Commit(session, force)
	session.History:Commit(session.Data, system.GetElapsedTime(), force or session.ForceCommit)
	session.ForceCommit = false
end

function move_editor.StepHistory(session, redo)
	local data = redo and session.History:DoRedo() or session.History:DoUndo()

	if not data then return end

	session.Data = data
	move_editor.Select(session, nil)
	move_editor.Apply(session)
end

function move_editor.SelectAll(session, rows)
	local selected = {}

	for _, row in ipairs(rows) do
		for _, key in ipairs(row.Keys) do
			selected[#selected + 1] = move_edit.GetKeyIdentity(key)
		end
	end

	move_editor.SelectMany(session, selected)
end

function move_editor.UnlinkSelected(session)
	local move = move_editor.GetMove(session)
	local unlinked = false

	for i, key in ipairs(session.Selected) do
		if move_edit.IsLinked(key) then
			session.Selected[i] = move_edit.Unlink(move, key)
			unlinked = true
		end
	end

	move_editor.SelectMany(session, session.Selected)
	return unlinked
end

function move_editor.LinkSelected(session)
	if not move_edit.CanLink(session.Selected) then return false end

	move_editor.SelectMany(session, move_edit.Link(move_editor.GetMove(session), session.Selected))
	return true
end

function move_editor.DeleteSelected(session)
	if not session.Selected[1] then return false end

	move_edit.RemoveKeys(move_editor.GetMove(session), session.Selected)
	move_editor.Select(session, nil)
	return true
end

local function get_skeleton(session)
	local animator = session.Grabber.animator
	return animator and animator.skeleton
end

do
	local SAMPLES = 160
	local POSITION_WEIGHT = 2

	function move_editor.GetWave(session, name)
		local animator = session.Grabber.animator
		local skeleton = get_skeleton(session)
		local clip = skeleton and skeleton.ClipsByName[name]

		if not clip then return end

		local wave = session.Waves[name]

		if wave then return wave end

		local pose, previous = skeleton:NewPose(), skeleton:NewPose()
		local values, peak = {}, 1e-6
		pose:Sample(clip, 0, animator.pose_parameters)

		for i = 1, SAMPLES do
			previous:Copy(pose)
			pose:Sample(clip, (i - 1) / (SAMPLES - 1), animator.pose_parameters)
			local sum = 0

			for k = 0, skeleton.BoneCount * 7 - 1 do
				local weight = k % 7 < 3 and POSITION_WEIGHT or 1
				sum = sum + math.abs(pose.data[k] - previous.data[k]) * weight
			end

			values[i] = sum
			peak = math.max(peak, sum)
		end

		for i = 1, SAMPLES do
			values[i] = math.sqrt(values[i] / peak)
		end

		wave = {Values = values, Duration = clip.Duration}
		session.Waves[name] = wave
		return wave
	end
end

function move_editor.RemoveActors(session)
	for _, entity in ipairs(session.Stage) do
		if entity:IsValid() then entity:Remove() end
	end

	session.Stage = {}

	if session.Given then
		if session.Given:IsValid() then session.Given:Remove() end

		session.Given = nil
		local holder = session.Player.weapon_holder

		if not holder:GetWeapon("right") then holder:EquipFirst() end
	end

	if session.Npc and session.Npc:IsValid() then session.Npc:Remove() end

	session.Npc = nil
end

function move_editor.UseAttacker(session, set_name)
	session.Waves = {}

	if session.Preview then
		session.Preview:Stop()
		session.Preview = nil
	end

	move_ghost.Clear(session)
	move_editor.RemoveActors(session)
	local player = session.Player
	local npc_name = set_name:match("^npc_(.+)$")

	if session.PreviewOn == "stage" then
		local forward = actors.GetForward(player)
		local origin = player.transform:GetPosition() + forward * STAGE_DISTANCE
		local from = origin + Vec3(0, STAGE_RAISE, 0)
		local ground = physics.RayCast(from, Vec3(0, -1, 0), STAGE_RAISE * 4, player)

		if ground then origin.y = from.y - ground.distance end

		local rotation = player.transform:GetRotation()
		local attacker = move_stage.SpawnAttacker(set_name, session.AttackerName, origin, rotation)
		local victim = move_stage.SpawnNpc(
			session.VictimName,
			origin + actors.GetForward(attacker) * STAGE_GAP,
			rotation
		)
		session.Stage = {attacker, victim}
		session.Grabber = attacker
		session.Victim = victim
	else
		local holder = player.weapon_holder

		if not npc_name and not holder:FindWeapon("weapon_" .. set_name) then
			session.Given = holder:Give("weapon_" .. set_name)
		end

		if not (session.PlayerVictim and session.PlayerVictim:IsValid()) then
			session.PlayerVictim = npcs.Spawn(
				session.VictimName,
				player.transform:GetPosition() + actors.GetForward(player) * STAGE_GAP,
				0
			)
			session.PlayerVictim.ai_controller.Wander = false
		end

		session.Victim = session.PlayerVictim

		if npc_name then
			local forward = actors.GetForward(player)
			local position = player.transform:GetPosition() + Vec3(forward.z, 0, -forward.x) * NPC_OFFSET
			local npc = npcs.Spawn(npc_name, position, 0)
			npc.ai_controller.Wander = false
			session.Npc = npc
			session.Grabber = npc
			session.Victim.character_movement:TeleportTo(position + actors.GetForward(npc) * STAGE_GAP)
		else
			session.Grabber = player
			session.Victim.character_movement:TeleportTo(
				player.transform:GetPosition() + actors.GetForward(player) * STAGE_GAP
			)
		end
	end

	move_editor.SetCameraPreset(session, session.Camera)
end

function move_editor.LoadSet(session, set_name, move_name)
	move_editor.UseAttacker(session, set_name)
	session.SetName = set_name
	session.Data = table.copy(movesets.Source[set_name])
	session.Baseline = movesets.ReadFile(set_name)
	session.TickCache = {}

	for _, data in ipairs{session.Data, session.Baseline} do
		for _, move in pairs(data.Moves) do
			if move.Clips then move.Keys = move.Keys or {} end
		end
	end

	session.History = data_history.New(session.Data)
	session.MoveName = move_name or get_move_names(session.Data)[1]
	move_editor.Select(session, nil)
	move_editor.Restart(session)
end

function move_editor.GetMove(session)
	return session.Data.Moves[session.MoveName]
end

function move_editor.GetTicks(session, move_name)
	local cache = session.TickCache
	local ticks = cache[move_name]

	if ticks then return ticks end

	local rows = {}

	for _, row in ipairs(move_edit.Rows(session.Data.Moves[move_name])) do
		if row.Keys[1] then rows[#rows + 1] = row end
	end

	ticks = {}

	for lane, row in ipairs(rows) do
		for _, key in ipairs(row.Keys) do
			ticks[#ticks + 1] = {lane = lane, lanes = #rows, from = key.Time, to = key.Until or key.Time, color = row.Color}
		end
	end

	cache[move_name] = ticks
	return ticks
end

function move_editor.DrawTicks(ticks, x, y, width, height)
	local active = theme.active
	local strip_x, strip_y = x + 4, y + math.floor((height - STRIP_HEIGHT) / 2)
	local strip_width = width - 8

	for _, tick in ipairs(ticks) do
		local lane_height = math.max(1, math.floor(STRIP_HEIGHT / tick.lanes))
		local color = active:GetColor(tick.color or "primary")
		render2d.SetColor(color.r, color.g, color.b, 0.9)
		render2d.DrawRect(
			strip_x + math.floor(tick.from * (strip_width - 2)),
			strip_y + (tick.lane - 1) * lane_height,
			math.max(2, math.floor((tick.to - tick.from) * (strip_width - 2)) + 2),
			lane_height
		)
	end
end

function move_editor.GetMoveNodes(session)
	local nodes = {}

	for _, name in ipairs(get_move_names(session.Data)) do
		nodes[#nodes + 1] = {
			Key = name,
			Text = name,
			Icon = move_editor.IsDirty(session, name) and "save" or "file",
			Time = string.format("%.2fs", session.Data.Moves[name].Duration),
			Ticks = move_editor.GetTicks(session, name),
		}
	end

	return nodes
end

function move_editor.IsDirty(session, move_name)
	return not table.equal(session.Data.Moves[move_name], session.Baseline.Moves[move_name])
end

function move_editor.GetDirtyNames(session)
	local names = {}

	for _, name in ipairs(get_move_names(session.Data)) do
		if move_editor.IsDirty(session, name) then names[#names + 1] = name end
	end

	return names
end

function move_editor.SwitchMove(session, move_name)
	session.MoveName = move_name
	move_editor.Select(session, nil)
	move_editor.Restart(session)
end

function move_editor.StepMove(session, offset)
	local names = get_move_names(session.Data)

	for i, name in ipairs(names) do
		if name == session.MoveName then
			move_editor.SwitchMove(session, names[(i - 1 + offset) % #names + 1])

			return
		end
	end
end

function move_editor.RevertMove(session, move_name)
	session.Data.Moves[move_name] = table.copy(session.Baseline.Moves[move_name])
	move_editor.Select(session, nil)
	move_editor.Apply(session)
	move_editor.Commit(session, true)
end

function move_editor.Restart(session)
	if session.Preview then
		session.Preview:Stop()
		session.Preview = nil
	end

	session.Phase = 0
end

function move_editor.Apply(session)
	session.TickCache = {}
	for _, move in pairs(session.Data.Moves) do
		movesets.ResolveClipLinks(move)
	end

	local ok, err = pcall(movesets.Update, session.SetName, session.Data)
	session.Status = ok and "" or tostring(err):gsub("^.-:%d+: ", "")

	if ok and session.Preview then
		session.Preview.Move = movesets.Get(session.SetName).Moves[session.MoveName]
	end

	return ok
end

function move_editor.UpdateCamera(session, dt)
	local shots = movesets.Get(session.SetName).Moves[session.MoveName].Shots
	local index, name = 0, nil

	if session.PreviewShots and shots then
		index, name = camera_shots.Sample(shots, session.Phase)
	end

	if not name or name == camera_shots.Battle then
		if session.ShotIndex then
			session.ShotIndex = nil
			session.View:SetFOV(session.BaseFOV)
			render3d.CutCamera()
		end

		view_camera.Update(session.Fly, dt)
		return
	end

	local attacker = session.Grabber
	local to_victim = actors.GetCenter(session.Victim) - actors.GetCenter(attacker)
	to_victim.y = 0
	local forward = to_victim:GetLength() > 1e-3 and to_victim:GetNormalized() or actors.GetForward(attacker)
	local def = camera_shots.Shots[name]
	local origin, look = camera_shots.Place(def, attacker, forward, Vec3(-forward.z, 0, forward.x))
	session.View:SetPosition(origin)
	session.View:SetRotation(Quat():SetLookDirection((look - origin):GetNormalized()))
	session.View:SetFOV(math.rad(def.Fov))

	if session.ShotIndex ~= index then render3d.CutCamera() end

	session.ShotIndex = index
end

function move_editor.TogglePlaying(session)
	session.Playing = not session.Playing

	if session.Playing and session.Phase >= 1 then session.Phase = 0 end
end

function move_editor.GetGhostPhases(session)
	local mode = session.GhostMode
	local from, to = 0, 1
	local rows

	if mode == "around playhead" then
		from = math.max(session.Phase - session.GhostWindow, 0)
		to = math.min(session.Phase + session.GhostWindow, 1)
	elseif mode == "selection" then
		rows = move_edit.Rows(move_editor.GetMove(session))
		local found = find_selection(rows, session.Selected)

		if not found[1] then return {} end

		from, to = math.huge, -math.huge

		for _, item in ipairs(found) do
			local key = rows[item[1]].Keys[item[2]]
			from = math.min(from, key.Time)
			to = math.max(to, key.Until or key.Time)
		end
	end

	local phases = {}
	local limit = move_ghost.MaxCount

	if session.GhostSource == "one per key" then
		rows = rows or move_edit.Rows(move_editor.GetMove(session))
		local times = {}

		for _, row in ipairs(rows) do
			for _, key in ipairs(row.Keys) do
				for _, time in ipairs{key.Time, key.Until} do
					if time >= from - 1e-4 and time <= to + 1e-4 then times[#times + 1] = time end
				end
			end
		end

		table.sort(times)

		for _, time in ipairs(times) do
			if not phases[1] or time - phases[#phases] > 1e-3 then phases[#phases + 1] = time end
		end

		if #phases > limit then
			local thinned = {}

			for i = 1, limit do
				thinned[i] = phases[math.floor((i - 1) * (#phases - 1) / (limit - 1) + 1.5)]
			end

			phases = thinned
		end
	else
		local count = session.GhostCount

		for i = 1, count do
			phases[i] = count > 1 and from + (to - from) * (i - 1) / (count - 1) or (from + to) / 2
		end
	end

	if mode == "around playhead" then
		local kept = {}

		for _, phase in ipairs(phases) do
			if math.abs(phase - session.Phase) > 0.005 then kept[#kept + 1] = phase end
		end

		phases = kept
	end

	return phases
end

function move_editor.UpdateGhost(session)
	if session.GhostMode == "off" then
		if session.Ghosts[1] then move_ghost.Clear(session) end

		return
	end

	local mode = session.GhostMode
	local signature = table.concat(
		{
			mode,
			session.GhostSource,
			session.GhostCount,
			session.GhostWindow,
			session.MoveName,
			tostring(session.TickCache),
			tostring(session.Preview),
			mode == "around playhead" and session.Phase or "",
			mode == "selection" and session.SelectId or "",
		},
		"|"
	)

	local stamp = session.MoveName .. tostring(session.TickCache) .. tostring(session.Preview)

	if signature ~= session.GhostSignature then
		session.GhostSignature = signature
		session.GhostPhases = move_editor.GetGhostPhases(session)
	end

	move_ghost.Show(session, session.GhostPhases, system.GetElapsedTime(), stamp)
end

function move_editor.Step(session, dt)
	local registered = movesets.Get(session.SetName).Moves[session.MoveName]
	move_stage.Arm(session.Grabber, session.SetName)

	if not session.Preview then
		if not session.Victim:IsValid() then return end

		session.Preview = move_preview.Start(session.Grabber, session.Victim, registered)
	end

	session.Preview.Move = registered
	local moved

	if session.Playing then
		moved = dt * session.Speed
		session.Phase = session.Phase + dt * session.Speed / registered.Duration

		if session.Phase >= 1 then
			session.Phase = session.Loop and 0 or 1
			session.Playing = session.Loop
		end
	end

	if session.PreviewOn == "stage" then
		move_stage.Hold(session.Grabber)
		move_stage.Hold(session.Victim)
	end

	session.Preview:SetPhase(session.Phase, session.Procedural and moved or nil)
	move_editor.UpdateGhost(session)
end

local function number_node(key, text, value, on_change, precision)
	return {
		Key = key,
		Text = text,
		Type = "number",
		Value = value,
		Precision = precision or 3,
		ShowStepper = true,
		OnChange = |_, new|-> do
			on_change(new)
		end,
	}
end

local VECTORS = {vec2 = Vec2, vec3 = Vec3, ang3 = Ang3}
local COMPONENTS = {"x", "y", "z"}

local function vector_node(key, text, kind, values, on_change, precision)
	return {
		Key = key,
		Text = text,
		Type = kind,
		Value = VECTORS[kind](unpack(values)),
		Precision = precision or 3,
		OnChange = |_, value|-> do
			local out = {}

			for i = 1, #values do
				out[i] = value[COMPONENTS[i]]
			end

			on_change(out)
		end,
	}
end

function move_editor.BuildItems(session, changed)
	local move = move_editor.GetMove(session)
	local selection = session.Selection
	local move_children = {}

	for _, field in ipairs(MOVE_FIELDS) do
		local name = field[1]
		move_children[#move_children + 1] = number_node(
			"move/" .. name,
			field[2],
			move[name] or 0,
			|value|-> do
				move[name] = value
				changed()
			end
		)
	end

	move_children[#move_children + 1] = {
		Key = "move/Rewind",
		Text = "rewind on block",
		Type = "boolean",
		Value = move.Rewind ~= false,
		OnChange = |_, value|-> do
			move.Rewind = (not value) and false or nil
			changed()
		end,
	}
	move_children[#move_children + 1] = number_node(
		"move/FaceOut",
		"face out",
		move.FaceOut or keyframes.FaceOut,
		|value|-> do
			move.FaceOut = value
			changed()
		end
	)
	local items = {
		{
			Key = "move",
			Text = session.SetName .. " / " .. session.MoveName,
			Expanded = true,
			Children = move_children,
		},
	}

	if not selection then return items end

	if selection.List == "Clips" then
		local entry = selection.Entry
		local skeleton = get_skeleton(session)
		local options = {}

		for i, clip in ipairs(skeleton and skeleton.Clips or {}) do
			options[i] = {Text = string.format("%s (%.2fs)", clip.Name, clip.Duration), Value = clip.Name}
		end

		local function number_field(key, text, name, minimum)
			return number_node(
				key,
				text,
				entry[name] or 0,
				|value|-> do
					entry[name] = value > minimum and value or nil
					changed()
				end
			)
		end

		items[#items + 1] = {
			Key = "key",
			Text = "clip",
			Expanded = true,
			Children = {
				{
					Key = "key/clip",
					Text = "clip",
					Type = "enum",
					Value = entry[3],
					Options = options,
					OnChange = |_, value|-> do
						entry[3] = value
						entry.In, entry.Out = nil, nil
						changed(true)
					end,
				},
				number_node(
					"key/time",
					"from",
					entry[1],
					|value|-> do
						entry[1] = value
						move_edit.Sort(move.Clips)
						changed()
					end
				),
				number_node(
					"key/to",
					"to",
					entry[2],
					|value|-> do
						entry[2] = value
						changed()
					end
				),
				number_field("key/in", "in", "In", -1),
				number_field("key/out", "out", "Out", 0),
				number_field("key/speed", "speed", "Speed", 0),
				number_field("key/blend", "blend", "Blend", 0),
			},
		}
		return items
	end

	if selection.List == "Locks" then
		local entry = selection.Entry
		items[#items + 1] = {
			Key = "key",
			Text = "victim lock",
			Expanded = true,
			Children = {
				number_node(
					"key/time",
					"from",
					entry[1],
					|value|-> do
						entry[1] = value
						move_edit.Sort(move.Locks)
						changed()
					end
				),
				number_node(
					"key/to",
					"to",
					entry[2],
					|value|-> do
						entry[2] = value
						changed()
					end
				),
			},
		}
		return items
	end

	if selection.Entry then
		local entry, list = selection.Entry, selection.List
		local shot = list == "Shots"
		local children = {
			number_node(
				"key/time",
				"time",
				entry[1],
				|value|-> do
					entry[1] = value
					move_edit.Sort(move[list])
					changed()
				end
			),
		}
		local names = {}

		for name in pairs(shot and camera_shots.Shots or faces.Presets) do
			names[#names + 1] = name
		end

		table.sort(names)
		table.insert(names, 1, shot and camera_shots.Battle or "none")
		local options = {}

		for i, name in ipairs(names) do
			options[i] = {Text = name, Value = name}
		end

		children[#children + 1] = {
			Key = "key/value",
			Text = shot and "shot" or "face",
			Type = "enum",
			Value = entry[2] or "none",
			Options = options,
			OnChange = |_, value|-> do
				entry[2] = value ~= "none" and value or nil
				changed()
			end,
		}

		if not shot then
			children[#children + 1] = {
				Key = "key/victim",
				Text = "victim",
				Type = "enum",
				Value = entry.victim or "none",
				Options = options,
				OnChange = |_, value|-> do
					entry.victim = value ~= "none" and value or nil
					changed()
				end,
			}
		end

		items[#items + 1] = {Key = "key", Text = shot and "shot" or "face", Expanded = true, Children = children}
		return items
	end

	if selection.Event then
		local event = selection.Event
		local children = {
			number_node(
				"key/time",
				"at",
				event.At,
				|value|-> do
					event.At = value
					move_edit.SortEvents(move)
					changed()
				end
			),
		}

		for _, field in ipairs(move_edit.GetEventFields(event.Type)) do
			local values = move_edit.GetEventValues(event, field) or {}
			local key = "key/" .. field.Name
			local text = field.Name:lower()

			if field.String then
				local options = {}

				for i, name in ipairs(damage_types.Names) do
					options[i] = {Text = name, Value = name}
				end

				children[#children + 1] = {
					Key = key,
					Text = text,
					Type = "enum",
					Value = event[field.Name] or damage_types.Names[1],
					Options = options,
					OnChange = |_, value|-> do
						event[field.Name] = value
						changed()
					end,
				}
			elseif field.Count == 1 then
				children[#children + 1] = number_node(
					key,
					text,
					values[1] or 0,
					|value|-> do
						move_edit.SetEventValue(event, field, 1, value)
						changed()
					end
				)
			else
				for i = 1, field.Count do
					values[i] = values[i] or 0
				end

				children[#children + 1] = vector_node(
					key,
					text,
					field.Count == 2 and "vec2" or "vec3",
					values,
					|out|-> do
						for i = 1, field.Count do
							move_edit.SetEventValue(event, field, i, out[i])
						end

						changed()
					end
				)
			end
		end

		items[#items + 1] = {Key = "key", Text = event.Type .. " event", Expanded = true, Children = children}
		return items
	end

	local frame = selection.Frame
	local ease = frame.ease
	ease = type(ease) == "table" and ease[selection.Track] or ease or "smooth"
	local ease_options = {}

	for i, name in ipairs(move_edit.Eases) do
		ease_options[i] = {Text = name, Value = name}
	end

	local pose_options = {{Text = "none", Value = "none"}}

	for _, name in ipairs(get_pose_names(session.Data)) do
		pose_options[#pose_options + 1] = {Text = name, Value = name}
	end

	items[#items + 1] = {
		Key = "key",
		Text = "key",
		Expanded = true,
		Children = {
			number_node(
				"key/time",
				"time",
				frame[1],
				|value|-> do
					move_edit.MoveFrame(move, frame, value)
					changed()
				end
			),
			number_node(
				"key/hold",
				"hold",
				frame.hold or 0,
				|value|-> do
					frame.hold = value > 0 and value or nil
					changed()
				end
			),
			{
				Key = "key/ease",
				Text = "ease",
				Type = "enum",
				Value = ease,
				Options = ease_options,
				OnChange = |_, value|-> do
					if type(frame.ease) == "table" then
						frame.ease[selection.Track] = value ~= "smooth" and value or nil
					else
						move_edit.SetEase(frame, value)
					end

					changed()
				end,
			},
			{
				Key = "key/pose",
				Text = "pose",
				Type = "enum",
				Value = type(frame[2]) == "string" and frame[2] or "none",
				Options = pose_options,
				OnChange = |_, value|-> do
					frame[2] = value ~= "none" and value or nil
					changed()
				end,
			},
		},
	}
	local names = move_edit.GetTracks(frame)

	for _, track_name in ipairs(names) do
		local track = move_edit.TrackByName[track_name]
		local values = move_edit.GetValues(frame, track_name)
		local children = {}

		for _, group in ipairs(move_edit.GetGroups(track_name)) do
			local scale = group.Radians and DEG or 1
			local group_values = {}

			for i, index in ipairs(group.Indices) do
				group_values[i] = values[index] * scale
			end

			local key = track_name .. "/" .. group.Label

			local function apply(out)
				for i, index in ipairs(group.Indices) do
					move_edit.SetTrackValue(frame, track_name, index, out[i] / scale)
				end

				changed()
			end

			if group.Type == "number" then
				children[#children + 1] = number_node(
					key,
					group.Label,
					group_values[1],
					|value|->apply({value}),
					group.Radians and 1 or 3
				)
			else
				children[#children + 1] = vector_node(
					key,
					group.Label,
					group.Type,
					group_values,
					apply,
					group.Radians and 1 or 3
				)
			end
		end

		items[#items + 1] = {Key = track_name, Text = track_name, Expanded = true, Children = children}
	end

	return items
end

function move_editor.BuildMenu(session, h)
	return {
		{
			Text = "FILE",
			Items = ||-> do
				local function build_load_items()
					local load_items = {}

					for _, set_name in ipairs(move_editor.GetSetNames()) do
						load_items[#load_items + 1] = MenuItem{
							Text = set_name,
							Icon = "folder",
							Items = ||-> do
								local moves = {}

								for _, move_name in ipairs(get_move_names(movesets.Source[set_name])) do
									moves[#moves + 1] = MenuItem{
										Text = move_name,
										Icon = "file",
										OnClick = ||-> do
											move_editor.LoadSet(session, set_name, move_name)
											h.refresh()
										end,
									}
								end

								return moves
							end,
						}
					end

					return load_items
				end

				return {
					MenuItem{
						Text = "save",
						Icon = "save",
						OnClick = ||-> do
							if move_editor.Apply(session) then
								local ok, result = pcall(movesets.Save, session.SetName)
								session.Status = ok and "saved " .. result or tostring(result):gsub("^.-:%d+: ", "")

								if ok then
									session.Baseline = table.copy(session.Data)
									session.TickCache = {}
								end
							end

							h.refresh()
						end,
					},
					MenuItem{Text = "load", Icon = "folder_open", Items = build_load_items},
					MenuItem{
						Text = "revert to file",
						Icon = "file",
						OnClick = ||-> do
							local ok, err = pcall(movesets.Reload, session.SetName)

							if ok then
								move_editor.LoadSet(session, session.SetName, session.MoveName)
							else
								session.Status = tostring(err):gsub("^.-:%d+: ", "")
							end

							h.refresh()
						end,
					},
					MenuItem{Text = "close", Icon = "close", OnClick = ||->h.close()},
				}
			end,
		},
		{
			Text = "EDIT",
			Items = ||-> {
				MenuItem{
					Text = "undo",
					Icon = "undo",
					Tooltip = "ctrl+z",
					OnClick = ||-> do
						move_editor.StepHistory(session, false)
						h.refresh()
					end,
				},
				MenuItem{
					Text = "redo",
					Icon = "redo",
					Tooltip = "ctrl+y",
					OnClick = ||-> do
						move_editor.StepHistory(session, true)
						h.refresh()
					end,
				},
				MenuItem{
					Text = "delete selected keys",
					Icon = "trash",
					Tooltip = "delete",
					OnClick = ||->h.delete(),
				},
			},
		},
		{
			Text = "VIEW",
			Items = ||-> {
				MenuItem{
					Text = "camera",
					Items = ||-> do
						local items = {}

						for _, name in ipairs(CAMERAS) do
							items[#items + 1] = MenuItem{
								Text = name,
								Icon = name == session.Camera and "check" or nil,
								OnClick = ||-> do
									move_editor.SetCameraPreset(session, name)
									h.refresh()
								end,
							}
						end

						return items
					end,
				},
				MenuItem{
					Text = "preview on",
					Items = ||-> {
						MenuItem{
							Text = "stage",
							Icon = session.PreviewOn == "stage" and "check" or nil,
							OnClick = ||-> do
								session.PreviewOn = "stage"
								move_editor.UseAttacker(session, session.SetName)
								h.refresh()
							end,
						},
						MenuItem{
							Text = "player and npc",
							Icon = session.PreviewOn == "player" and "check" or nil,
							OnClick = ||-> do
								session.PreviewOn = "player"
								move_editor.UseAttacker(session, session.SetName)
								h.refresh()
							end,
						},
					},
				},
				MenuItem{
					Text = "attacker",
					Items = ||-> do
						local items = {}

						for _, name in ipairs{"player", table.unpack(npcs.GetNames())} do
							items[#items + 1] = MenuItem{
								Text = name,
								Icon = name == session.AttackerName and "check" or nil,
								OnClick = ||-> do
									session.AttackerName = name
									move_editor.UseAttacker(session, session.SetName)
									h.refresh()
								end,
							}
						end

						return items
					end,
				},
				MenuItem{
					Text = "victim",
					Items = ||-> do
						local items = {}

						for _, name in ipairs(npcs.GetNames()) do
							items[#items + 1] = MenuItem{
								Text = name,
								Icon = name == session.VictimName and "check" or nil,
								OnClick = ||-> do
									session.VictimName = name
									move_editor.UseAttacker(session, session.SetName)
									h.refresh()
								end,
							}
						end

						return items
					end,
				},
				MenuItem{
					Text = "procedural animation",
					Icon = session.Procedural and "check" or nil,
					OnClick = ||-> do
						session.Procedural = not session.Procedural
						h.refresh()
					end,
				},
				MenuItem{
					Text = "ghost",
					Items = ||-> do
						local items = {}

						for _, mode in ipairs(GHOST_MODES) do
							items[#items + 1] = MenuItem{
								Text = mode,
								Icon = mode == session.GhostMode and "check" or nil,
								OnClick = ||-> do
									session.GhostMode = mode
									h.refresh()
								end,
							}
						end

						items[#items + 1] = MenuItem{
							Text = "poses",
							Items = ||-> do
								local sources = {}

								for _, source in ipairs(GHOST_SOURCES) do
									sources[#sources + 1] = MenuItem{
										Text = source,
										Icon = source == session.GhostSource and "check" or nil,
										OnClick = ||-> do
											session.GhostSource = source
											h.refresh()
										end,
									}
								end

								for _, count in ipairs(GHOST_COUNTS) do
									sources[#sources + 1] = MenuItem{
										Text = count .. " ghosts",
										Icon = count == session.GhostCount and "check" or nil,
										OnClick = ||-> do
											session.GhostCount = count
											h.refresh()
										end,
									}
								end

								return sources
							end,
						}

						return items
					end,
				},
				MenuItem{
					Text = "preview shots",
					Icon = session.PreviewShots and "check" or nil,
					OnClick = ||-> do
						session.PreviewShots = not session.PreviewShots
						h.refresh()
					end,
				},
			},
		},
	}
end

local MoveEditor = react.Component(
	|props|-> do
		local version, set_version = react.UseState(0)
		local session = react.UseResource(
			||-> do
				local session = move_editor.CreateSession()
				move_editor.LoadSet(session, move_editor.LastSet, move_editor.LastMove)
				return session
			end,
			move_editor.DestroySession,
			{}
		)
		local properties = react.UseRef()
		local h = react.UseMemo(
			||-> do
				local h = {}

				function h.refresh()
					set_version(|value|->value + 1)
				end

				function h.changed(force)
					move_editor.Apply(session)
					move_editor.Commit(session, force)
					set_version(|value|->value + 1)
				end

				function h.delete()
					if move_editor.DeleteSelected(session) then h.changed(true) end
				end

				function h.close()
					props.OnClose()
				end

				return h
			end,
			{}
		)
		local menu = react.UseMemo(||->move_editor.BuildMenu(session, h), {})
		react.UseEvent(
			"Update",
			|dt|-> do
				move_editor.Step(session, math.min(dt, 0.1))
				move_editor.UpdateCamera(session, dt)

				if session.Playing or session.ShownPhase ~= session.Phase then
					session.ShownPhase = session.Phase
					set_version(|value|->value + 1)
				end
			end
		)
		react.UseEvent(
			"KeyInput",
			|key, press|-> do
				local focused = objects:GetFocusedObject()

				if focused and focused:IsValid() and tostring(focused.Type):find("text") then return end

				if key == "space" then
					if press then
						move_editor.TogglePlaying(session)
						h.refresh()
					end

					return true
				end

				if not press then return end

				if input.IsControlDown() and (key == "z" or key == "y") then
					move_editor.StepHistory(session, key == "y" or input.IsShiftDown())
					h.refresh()
					return true
				end

				if input.IsControlDown() and key == "a" then
					move_editor.SelectAll(session, move_edit.Rows(move_editor.GetMove(session)))
					h.refresh()
					return true
				end

				if input.IsAltDown() and (key == "up" or key == "down") then
					move_editor.StepMove(session, key == "up" and -1 or 1)
					h.refresh()
					return true
				end

				if key == "delete" then
					h.delete()
					return true
				end
			end
		)
		local items = react.UseMemo(
			||->move_editor.BuildItems(session, h.changed),
			{
				session.SelectId,
				session.SetName,
				session.MoveName,
				session.Grabber.animator ~= nil and session.Grabber.animator.skeleton ~= nil,
			}
		)
		local move = move_editor.GetMove(session)
		local rows = move_edit.Rows(move, |name|->move_editor.GetWave(session, name))
		local addable = move_edit.AddableTracks(move)

		if addable[1] then rows[#rows + 1] = {Name = "+ add track", Button = true, Keys = {}} end

		local timeline_height = TIMELINE_CHROME + TIMELINE_RULER + #rows * TIMELINE_ROW

		local move_nodes = react.UseMemo(||->move_editor.GetMoveNodes(session), {session.TickCache})

		local screen = Panel.World.transform:GetSize()
		local registered = movesets.Get(session.SetName).Moves[session.MoveName]

		local function add_track_key(name, time)
			local frame = move_edit.AddTrackKey(move, name, time, move_edit.Sample(registered, name, time))
			move_editor.Select(session, {Frame = frame, Track = name})
			h.changed()
		end

		return ui.Window{
			Title = move_editor.GetDirtyNames(session)[1] and "MOVE EDITOR *" or "MOVE EDITOR",
			Name = "move editor",
			RequestMouse = true,
			Size = Vec2(LEFT_WIDTH, screen.y),
			Position = Vec2(0, 0),
			Padding = Rect(),
			Minimizable = false,
			Maximizable = false,
			layout = {FitHeight = false, FitWidth = false},
			OnClose = props.OnClose,
		}{
			ui.MenuBar{MenuKey = "MoveEditorMenuBarContextMenu", Items = menu, layout = {GrowWidth = 1}},
			ui.TreeTable{
				Mode = "list",
				AlternateRows = false,
				Items = move_nodes,
				Columns = MOVE_COLUMNS,
				SelectedKey = session.MoveName,
				OnSelect = |node|-> do
					if node and node.Key ~= session.MoveName then
						move_editor.SwitchMove(session, node.Key)
						h.refresh()
					end
				end,
				OnContextMenu = |node|-> do
					Panel.OpenContextMenu(
						{},
						{
							MenuItem{
								Text = "revert",
								Icon = "undo",
								Disabled = not move_editor.IsDirty(session, node.Key),
								OnClick = ||-> do
									move_editor.RevertMove(session, node.Key)
									h.refresh()
								end,
							},
						}
					)
				end,
				layout = {GrowWidth = 1, GrowHeight = 0, MinSize = Vec2(0, MOVES_HEIGHT), MaxSize = Vec2(0, MOVES_HEIGHT)},
			},
			ui.ScrollablePanel{ScrollX = false, ScrollY = true, Padding = "none", layout = {GrowWidth = 1, GrowHeight = 1}}{
				ui.Panel{
					Name = "PropertyEditorFrame",
					transform = true,
					layout = {
						GrowWidth = 1,
						FitHeight = true,
						FitWidth = false,
						MinSize = Vec2(LEFT_WIDTH - 24, 0),
						Padding = Rect(2, 2, 2, 2),
					},
				}{
					ui.PropertyEditor{
						Ref = properties,
						Items = items,
						layout = {GrowWidth = 1, GrowHeight = 1, FitWidth = false, MinSize = Vec2(LEFT_WIDTH - 28, 0)},
					},
				},
			},
			react.Portal{Target = Panel.World}{
				ui.Window{
					Key = "MoveEditorTimeline",
					Name = "move editor timeline",
					RequestMouse = true,
					Headerless = true,
					Size = Vec2(screen.x - LEFT_WIDTH, timeline_height),
					Position = Vec2(LEFT_WIDTH, screen.y - timeline_height),
					Padding = Rect(),
					layout = {FitHeight = false, FitWidth = false},
				}{
					ui.Column{
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
							FitHeight = false,
							AlignmentX = "stretch",
						},
					}{
						ui.Timeline{
							Rows = rows,
							Time = session.Phase,
							Selection = find_selection(rows, session.Selected),
							OnScrub = |time|-> do
								session.Playing = false
								session.Phase = time
								h.refresh()
							end,
							OnSelect = |row, index|-> do
								local key = row and rows[row].Keys[index]
								session.ForceCommit = true
								move_editor.Select(session, key and move_edit.GetKeyIdentity(key) or nil)
								h.refresh()
							end,
							OnSelectKeys = |list|-> do
								local selected = {}

								for i, item in ipairs(list) do
									local key = rows[item[1]].Keys[item[2]]
									selected[i] = move_edit.GetKeyIdentity(key)
								end

								move_editor.SelectMany(session, selected)
								h.refresh()
							end,
							OnKeysTransform = |anchor, scale, offset, first, timeline|-> do
								if first then session.Grabbed = move_edit.Grab(session.Selected) end

								move_edit.Transform(move, session.Grabbed, anchor, scale, offset, timeline:GetSnap())
								h.changed(first)
							end,
							OnKeysDrop = ||-> do
								session.Grabbed = nil
							end,
							OnRowAction = ||-> do
								local items = {}

								for _, name in ipairs(addable) do
									items[#items + 1] = MenuItem{
										Text = name,
										OnClick = ||->add_track_key(name, session.Phase),
									}
								end

								Panel.OpenContextMenu({}, items)
							end,
							OnKeyTrim = |row, index, edge, time|-> do
								local entry = rows[row].Keys[index].Entry
								local skeleton = get_skeleton(session)

								if not skeleton then return end

								local clip = skeleton.ClipsByName[entry[3]]
								local from, out = entry.In or 0, entry.Out or clip.Duration
								local rate = entry.Speed or (out - from) / ((entry[2] - entry[1]) * move.Duration)

								if input.IsControlDown() then
									entry[edge == "left" and 1 or 2] = time
								elseif edge == "left" then
									time = math.max(time, entry[1] - from / (rate * move.Duration))
									entry.In = math.floor((from + (time - entry[1]) * move.Duration * rate) * 1e4 + 0.5) / 1e4
									entry.In = entry.In > 0 and entry.In or nil
									entry[1] = time
								elseif entry.Speed then
									entry[2] = time
								else
									time = math.min(time, entry[2] + (clip.Duration - out) / (rate * move.Duration))
									entry.Out = math.floor((out - (entry[2] - time) * move.Duration * rate) * 1e4 + 0.5) / 1e4
									entry.Out = entry.Out < clip.Duration and entry.Out or nil
									entry[2] = time
								end

								h.changed()

								if properties.current then
									properties.current:UpdateValueForKey("key/time", entry[1])
									properties.current:UpdateValueForKey("key/to", entry[2])
									properties.current:UpdateValueForKey("key/in", entry.In or 0)
									properties.current:UpdateValueForKey("key/out", entry.Out or 0)
								end
							end,
							OnKeyResize = |row, index, time|-> do
								local key = rows[row].Keys[index]

								if key.Entry then
									key.Entry[2] = time
								else
									key.Frame.hold = time - key.Frame[1]
								end

								h.changed()

								if properties.current then
									properties.current:UpdateValueForKey(key.Entry and "key/to" or "key/hold", key.Entry and time or key.Frame.hold)
								end
							end,
							OnKeySlip = |row, index, delta, first|-> do
								local entry = rows[row].Keys[index].Entry
								local skeleton = get_skeleton(session)

								if not skeleton then return end

								local clip = skeleton.ClipsByName[entry[3]]

								if first then
									session.Slip = {In = entry.In or 0, Out = entry.Out or clip.Duration}
								end

								local origin = session.Slip
								local span = origin.Out - origin.In
								local rate = entry.Speed or span / ((entry[2] - entry[1]) * move.Duration)
								local from = math.clamp(origin.In - delta * move.Duration * rate, 0, clip.Duration - span)
								from = math.floor(from * 1e4 + 0.5) / 1e4
								local out = math.floor((from + span) * 1e4 + 0.5) / 1e4
								entry.In = from > 0 and from or nil
								entry.Out = out < clip.Duration - 1e-3 and out or nil
								h.changed(first)

								if properties.current then
									properties.current:UpdateValueForKey("key/in", entry.In or 0)
									properties.current:UpdateValueForKey("key/out", entry.Out or 0)
								end
							end,
							OnKeyMenu = |row, index, time|-> do
								local count = #session.Selected
								local linked = false
								local key = rows[row].Keys[index]
								local skeleton = get_skeleton(session)
								local items = {}

								for _, selected in ipairs(session.Selected) do
									linked = linked or move_edit.IsLinked(selected)
								end

								if key.List == "Clips" then
									items[#items + 1] = MenuItem{
										Text = "split",
										Disabled = not skeleton or time <= key.Time + 0.005 or time >= key.Until - 0.005,
										OnClick = ||-> do
											move_edit.SplitClip(move, key.Entry, time, skeleton.ClipsByName[key.Entry[3]].Duration)
											h.changed(true)
										end,
									}
								end

								if key.Event then
									items[#items + 1] = MenuItem{
										Text = "link to clip",
										Disabled = key.Event.Clip ~= nil,
										OnClick = ||-> do
											local linked_ok = move_edit.LinkEvent(
												move,
												key.Event,
												|name|->skeleton and skeleton.ClipsByName[name] and skeleton.ClipsByName[name].Duration
											)
											session.Status = linked_ok and "" or "no clip under this event to link to"
											h.changed(true)
										end,
									}
									items[#items + 1] = MenuItem{
										Text = "unlink from clip",
										Disabled = key.Event.Clip == nil,
										OnClick = ||-> do
											move_edit.UnlinkEvent(key.Event)
											h.changed(true)
										end,
									}
								end

								local base = {
									MenuItem{
											Text = "link",
											Disabled = not move_edit.CanLink(session.Selected),
											OnClick = ||-> do
												if move_editor.LinkSelected(session) then h.changed(true) end
											end,
										},
										MenuItem{
											Text = "unlink",
											Disabled = not linked,
											OnClick = ||-> do
												if move_editor.UnlinkSelected(session) then h.changed(true) end
											end,
										},
										MenuItem{
											Text = count > 1 and "remove " .. count .. " keys" or "remove",
											Icon = "trash",
											Tooltip = "delete",
											OnClick = ||->h.delete(),
										},
}

								for _, item in ipairs(base) do
									items[#items + 1] = item
								end

								Panel.OpenContextMenu({}, items)
							end,
							OnKeyMove = |row, index, time|-> do
								local key = rows[row].Keys[index]

								if key.List == "Clips" or key.List == "Locks" then
									move_edit.PlaceBlock(move[key.List], key.Entry, time, key.List == "Clips")
								elseif key.Entry then
									key.Entry[1] = time
									move_edit.Sort(move[key.List])
								elseif key.Event then
									move_edit.SetEventTime(move, key.Event, time)
									move_edit.SortEvents(move)
								else
									move_edit.MoveFrame(move, key.Frame, time)
								end

								h.changed()

								if properties.current then
									properties.current:UpdateValueForKey("key/time", time)
								end
							end,
							OnKeyAdd = |row, time|-> do
								local name = rows[row].Name

								if name == "pose" then
									move_editor.Select(session, {Frame = move_edit.AddPoseKey(move, time, get_pose_names(session.Data)[1])})
									h.changed()
								elseif move_edit.TrackByName[name] then
									add_track_key(name, time)
								elseif name == "shots" then
									move_editor.Select(session, {Entry = move_edit.AddEntry(move, "Shots", time, {camera_shots.Battle}), List = "Shots"})
									h.changed(true)
								elseif name == "clips" then
									local skeleton = get_skeleton(session)
									local last = move.Clips and move.Clips[#move.Clips]
									local clip_name = last and last[3] or skeleton and skeleton.Clips[1].Name
									local following

									for _, clip in ipairs(move.Clips or {}) do
										if clip[1] >= time and (not following or clip[1] < following) then
											following = clip[1]
										end
									end

									local to = math.min(time + 0.2, following or 1)

									if not clip_name then
										session.Status = "this character has no animation clips to add"
										h.refresh()
									elseif to > time then
										move_editor.Select(session, {Entry = move_edit.AddEntry(move, "Clips", time, {to, clip_name}), List = "Clips"})
										h.changed(true)
									end
								elseif name == "locks" then
									move_editor.Select(session, {Entry = move_edit.AddEntry(move, "Locks", time, {math.min(time + 0.1, 1)}), List = "Locks"})
									h.changed(true)
								elseif name == "faces" then
									move_editor.Select(session, {Entry = move_edit.AddEntry(move, "Faces", time, {"neutral"}), List = "Faces"})
									h.changed(true)
								else
									move_editor.Select(session, {Event = move_edit.AddEvent(move, name, time)})
									h.changed()
								end
							end,
							layout = {GrowWidth = 1, GrowHeight = 1},
						},
						ui.Row{layout = {GrowWidth = 1, ChildGap = 8, AlignmentY = "center", Padding = Rect() + 6}}{
							ui.Button{
								Text = session.Playing and "Pause" or "Play",
								Mode = "outline",
								Tooltip = "space",
								OnClick = ||-> do
									move_editor.TogglePlaying(session)
									h.refresh()
								end,
							},
							ui.Button{
								Text = "Stop",
								Mode = "outline",
								OnClick = ||-> do
									session.Playing = false
									session.Phase = 0
									h.refresh()
								end,
							},
							ui.Checkbox{
								Text = "Loop",
								Value = session.Loop,
								OnChange = |value|-> do
									session.Loop = value
								end,
							},
							ui.Text{Text = "Speed", Color = "text_disabled", layout = {FitWidth = true}},
							ui.Dropdown{
								Key = "speed",
								Options = SPEEDS,
								Value = tostring(session.Speed),
								Padding = "XS",
								OnSelect = |value|-> do
									session.Speed = tonumber(value)
								end,
								layout = {MinSize = Vec2(70, 0), MaxSize = Vec2(70, 0), GrowWidth = 0},
							},
							ui.Text{
								Text = string.format("%s / %s   %.3f   %.2fs", session.SetName, session.MoveName, session.Phase, session.Phase * registered.Duration),
								Color = "text_disabled",
								IgnoreMouseInput = true,
								layout = {FitWidth = true},
							},
							ui.Text{
								Text = session.Status,
								Color = "negative",
								Font = "body XS",
								IgnoreMouseInput = true,
								layout = {GrowWidth = 1},
							},
						},
					},
				},
			},
		}
	end
)

function move_editor.Create()
	local root

	root = react.Mount(MoveEditor{OnClose = ||->root:Unmount()}, Panel.World)
	return root:GetEntity()
end

return move_editor
