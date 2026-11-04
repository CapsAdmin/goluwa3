local players = import("lua/players.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Rect = import("goluwa/structs/rect.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local View = import("goluwa/render3d/view.lua")
local vfs = import("goluwa/vfs.lua")
local input = import("goluwa/input.lua")
local system = import("goluwa/system.lua")
local objects = import("goluwa/objects/objects.lua")
local view_camera = import("lua/view_camera.lua")
local actors = import("lua/actors.lua")
local keyframes = import("lua/keyframes.lua")
local animations = import("lua/animations.lua")
local movesets = import("lua/movesets.lua")
local move_edit = import("lua/jrpg/move_edit.lua")
local move_editor = import("lua/jrpg/move_editor.lua")
local move_stage = import("lua/jrpg/move_stage.lua")
local data_history = import("lua/data_history.lua")
local gizmo = import("lua/gizmo.lua")
local Entity = import("goluwa/entities/entity.lua")
local Quat = import("goluwa/structs/quat.lua")
local pose_editor = {}
local LEFT_WIDTH = 400
local LIST_HEIGHT = 230
local HOLD = "pose_editor_hold"
local SHARED_PATH = "lua/jrpg/movesets/poses.lua"
local CAMERAS = {three = {2.2, 1.5, 3.2}, side = {1, 1.5, 5}, front = {4, 1.5, 0.6}}
local CAMERA_NAMES = {"three", "side", "front"}
local PRIORITY = {"base", "aim", "hand", "torso", "head", "pelvis"}
local ZERO = Vec3()
local HAND_GAIN = {1.15, 1.15, 3}
local HAND_LIMIT = 1.5
pose_editor.LastWeapon = "sword"
pose_editor.LastStageHeight = 0

local function get_set_names()
	local names = {}

	for name in pairs(movesets.Registered) do
		if not name:find("^npc_") then names[#names + 1] = name end
	end

	table.sort(names)
	return names
end

function pose_editor.GetSources(session)
	local names = {"shared"}

	for _, set_name in ipairs(get_set_names()) do
		if session.Data.Poses[set_name] then names[#names + 1] = set_name end
	end

	return names
end

function pose_editor.GetPoseNames(session, source)
	local names = {}

	for name in pairs(session.Data.Poses[source]) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end

function pose_editor.CountUses(session, name)
	local count = 0

	for set_name, set in pairs(movesets.Source) do
		local poses = session.Data.Poses[set_name]

		if not (poses and poses[name]) then
			for _, move in pairs(set.Moves) do
				for _, overlay in ipairs(move.Overlays or {}) do
					if overlay[3] == name then count = count + 1 end
				end
			end

			for _, gesture in pairs(set.Gestures or {}) do
				for _, key in ipairs(gesture.Keys) do
					if key[2] == name then count = count + 1 end
				end
			end

			if set.Guard == name then count = count + 1 end
		end
	end

	return count
end

function pose_editor.GetPose(session)
	local source, name = session.Source, session.PoseName
	return source and name and session.Data.Poses[source][name]
end

function pose_editor.IsDirty(session, source)
	return not table.equal(session.Data.Poses[source], session.Baseline[source])
end

function pose_editor.LoadSources(session)
	local data = {Poses = {}}
	data.Poses.shared = assert(loadfile(vfs.GetAbsolutePath(SHARED_PATH)))()

	for _, set_name in ipairs(get_set_names()) do
		local poses = movesets.ReadFile(set_name).Poses

		if poses then data.Poses[set_name] = poses end
	end

	session.Data = data
	session.Baseline = table.copy(data.Poses)
	session.History = data_history.New(data)
end

function pose_editor.GetAttackerPosition(session)
	return session.Player.transform:GetPosition() + Vec3(0, session.StageHeight, 0)
end

function pose_editor.GetSkeleton(session)
	for _, child in ipairs(session.Attacker.player_avatar.outfit:GetChildrenList()) do
		if child.animator and child.animator.skeleton then return child.animator.skeleton end
	end
end

function pose_editor.GetBaseNames(session)
	local names = {}
	local skeleton = pose_editor.GetSkeleton(session)

	for _, clip in ipairs(skeleton and skeleton.Clips or {}) do
		if clip.Name:find("^c?idle") then names[#names + 1] = clip.Name end
	end

	table.sort(names)
	return names, skeleton and skeleton.ClipsByName.reference ~= nil
end

function pose_editor.SetCameraPreset(session, name)
	local grabber = session.Attacker
	local anchor = grabber.transform:GetPosition():Copy()
	local forward = actors.GetForward(grabber)
	local right = Vec3(forward.z, 0, -forward.x)
	local offset = CAMERAS[name]
	local eye = anchor + forward * offset[1] + Vec3(0, offset[2], 0) + right * offset[3]

	if name == "side" then
		eye = anchor + right * offset[3] + Vec3(0, offset[2], 0) + forward * offset[1]
	end

	local direction = (anchor + forward * 1.4 + Vec3(0, 0.5, 0) - eye):GetNormalized()
	local focal = Panel.World.transform:GetHeight() / 2 / math.tan(render3d.GetMainCamera():GetFOV() / 2)
	local yaw = math.deg(math.atan2(-direction.x, -direction.z) + math.atan(LEFT_WIDTH / 2 / focal))
	local pitch = math.deg(math.asin(direction.y))
	view_camera.Set(session.Fly, eye, pitch, yaw)
	session.Camera = name
end

function pose_editor.SpawnAttacker(session)
	if session.Attacker and session.Attacker:IsValid() then session.Attacker:Remove() end

	local player = session.Player
	local rotation = player.transform:GetRotation()
	local attacker = move_stage.SpawnAttacker(session.Weapon, "player", pose_editor.GetAttackerPosition(session), rotation)
	attacker.character_pose:SetState(HOLD, "1")
	session.Attacker = attacker
	pose_editor.SetCameraPreset(session, session.Camera)
end

function pose_editor.Apply(session)
	local source, name = session.Source, session.PoseName

	if not (source and name and session.Data.Poses[source][name]) then return end

	local compiled = keyframes.Compile(
		{Duration = 1, Overlays = {{0, 1, name, FadeIn = 0, FadeOut = 0}}},
		session.Data.Poses[source]
	)
	local def = animations.Get(HOLD)

	for _, track in ipairs(keyframes.Tracks) do
		def[track.Key] = compiled[track.Key]
	end
end

function pose_editor.Commit(session, force)
	session.History:Commit(session.Data, system.GetElapsedTime(), force or session.ForceCommit)
	session.ForceCommit = false
end

function pose_editor.StepHistory(session, redo)
	local data = redo and session.History:DoRedo() or session.History:DoUndo()

	if not data then return end

	session.Data = data

	if not (session.Source and session.Data.Poses[session.Source] and session.Data.Poses[session.Source][session.PoseName]) then
		session.PoseName = nil
	end

	session.SelectId = session.SelectId + 1
	pose_editor.Apply(session)
end

function pose_editor.Select(session, source, name)
	session.Source, session.PoseName = source, name
	session.SelectId = session.SelectId + 1
	pose_editor.Apply(session)
end

function pose_editor.NewName(session, source, base)
	local poses = session.Data.Poses[source]
	local name, n = base .. "_copy", 1

	while poses[name] or keyframes.Poses[name] do
		n = n + 1
		name = base .. "_copy" .. n
	end

	return name
end

function pose_editor.Duplicate(session)
	local pose = pose_editor.GetPose(session)

	if not pose then return false end

	local name = pose_editor.NewName(session, session.Source, session.PoseName)
	session.Data.Poses[session.Source][name] = table.copy(pose)
	pose_editor.Select(session, session.Source, name)
	return true
end

function pose_editor.Delete(session)
	local pose = pose_editor.GetPose(session)

	if not pose or pose_editor.CountUses(session, session.PoseName) > 0 then return false end

	session.Data.Poses[session.Source][session.PoseName] = nil
	session.PoseName = nil
	session.SelectId = session.SelectId + 1
	return true
end

function pose_editor.Reload(session)
	local source, name = session.Source, session.PoseName
	pose_editor.LoadSources(session)

	if not (source and session.Data.Poses[source] and session.Data.Poses[source][name]) then
		source = "shared"
		name = pose_editor.GetPoseNames(session, source)[1]
	end

	session.NameDraft = nil
	pose_editor.Select(session, source, name)
end

function pose_editor.IsNameFree(session, name)
	if not name:find("^[%a_][%w_]*$") or keyframes.Poses[name] then return false end

	for _, poses in pairs(session.Data.Poses) do
		if poses[name] then return false end
	end

	for _, set in pairs(movesets.Source) do
		if set.Gestures and set.Gestures[name] then return false end
	end

	return true
end

function pose_editor.AddPose(session, name)
	if not pose_editor.IsNameFree(session, name) then return false end

	local pose = {}

	for _, track in ipairs(keyframes.OverlayTracks) do
		pose[track.Name] = #track.Rest == 1 and track.Rest[1] or table.copy(track.Rest)
	end

	local source = session.Source or "shared"
	session.Data.Poses[source][name] = pose
	session.NameDraft = nil
	pose_editor.Select(session, source, name)
	return true
end

function pose_editor.Save(session)
	for _, source in ipairs(pose_editor.GetSources(session)) do
		if pose_editor.IsDirty(session, source) then
			local poses = session.Data.Poses[source]

			if source == "shared" then
				local file = assert(io.open(vfs.GetAbsolutePath(SHARED_PATH), "wb"))
				file:write(table.to_source(poses, PRIORITY))
				file:close()
				keyframes.AddPoses(poses)
			else
				local data = table.copy(movesets.Source[source])
				data.Poses = table.copy(poses)
				movesets.Update(source, data)
				movesets.Save(source)
			end

			session.Baseline[source] = table.copy(poses)
		end
	end

	for set_name, set in pairs(movesets.Source) do
		movesets.Update(set_name, table.copy(set))
	end
end

function pose_editor.GetGripPosition(session)
	local weapon = session.Attacker.weapon_holder:GetWeapon("right")
	local matrix = weapon.prefab:GetNode("blade_base").transform:GetWorldMatrix()
	return Vec3(matrix.m30, matrix.m31, matrix.m32)
end

function pose_editor.GetAimFrame(session, pose)
	local base = session.Attacker.transform:GetRotation()
	local aim = pose.aim or {0, 0}
	return Quat():Identity():RotateYaw(aim[1]) * base:Copy():RotatePitch(aim[2])
end

function pose_editor.MoveHand(session, delta)
	local pose = pose_editor.GetPose(session)
	local base = pose.base and keyframes.ResolvePose(pose.base, session.Data.Poses[session.Source])

	if not pose.hand then
		pose.hand = move_edit.GetValues({hand = base and base.hand or keyframes.Poses.rest.hand}, "hand")
	end

	local frame = pose_editor.GetAimFrame(session, pose)
	local components = {delta:Dot(frame:GetRight()), delta:Dot(frame:GetUp()), delta:Dot(frame:GetForward() * -1)}

	for i = 1, 3 do
		pose.hand[i] = math.clamp((pose.hand[i] or 0) + components[i] * HAND_GAIN[i], -HAND_LIMIT, HAND_LIMIT)
	end
end

function pose_editor.UpdateHandles(session)
	local handle = session.Handle

	if not handle then return end

	local dragging = gizmo.GetStatus().active_drag ~= nil

	if dragging and pose_editor.GetPose(session) then
		local position = handle.transform:GetPosition()

		if not session.HandleLast then session.HandleLast = position:Copy() end

		local delta = position - session.HandleLast
		session.HandleLast:CopyFrom(position)

		if delta:GetLength() > 1e-6 then
			pose_editor.MoveHand(session, delta)
			session.SelectId = session.SelectId + 1
			session.Changed(false)
		end
	elseif not dragging then
		session.HandleLast = nil
		handle.transform:SetPosition(pose_editor.GetGripPosition(session))
	end
end

function pose_editor.SetHandles(session, enabled)
	session.HandlesOn = enabled

	if enabled and not session.Handle then
		session.Handle = Entity.New{Name = "pose handle", transform = {Position = pose_editor.GetGripPosition(session)}}
		gizmo.SetMode("move")
		gizmo.SetSpace("world")
		gizmo.EnableGizmo(session.Handle)
	elseif not enabled and session.Handle then
		gizmo.DisableGizmo()
		session.Handle:Remove()
		session.Handle = nil
	end
end

function pose_editor.CreateSession()
	local player = assert(players.GetLocal(), "the pose editor needs the local player")
	local session = {
		Player = player,
		Weapon = pose_editor.LastWeapon,
		Camera = "three",
		StageHeight = pose_editor.LastStageHeight,
		Base = "game",
		SelectId = 0,
		Status = "",
	}
	session.PlayerMode = player.player_input.Mode
	player.player_input:SetMode("fly")
	animations.Register(
		HOLD,
		{
			Kind = "state",
			Enter = 0.05,
			Exit = 0.05,
			PoseWeapon = true,
			Sequence = |inst, suffix, clips|->session.Base ~= "game" and clips[session.Base] and session.Base or nil,
		}
	)
	session.View = View.New{
		Priority = 1000,
		ExposureLock = 16,
		HidePlayer = true,
		HideHud = true,
	}
	session.View:Activate()
	session.Fly = view_camera.Start(session.View, 6)
	session.Changed = ||->nil
	pose_editor.LoadSources(session)
	pose_editor.SpawnAttacker(session)
	pose_editor.Current = session
	return session
end

function pose_editor.DestroySession(session)
	pose_editor.Current = nil
	pose_editor.SetHandles(session, false)
	session.Player.player_input:SetMode(session.PlayerMode)

	if session.Attacker and session.Attacker:IsValid() then session.Attacker:Remove() end

	session.View:Remove()
	view_camera.Stop(session.Fly)
end

function pose_editor.Step(session, dt)
	view_camera.Update(session.Fly, dt)
	local attacker = session.Attacker
	move_stage.Arm(attacker, session.Weapon)
	move_stage.Hold(attacker)
	attacker.character_pose:SetPreviewMotion(ZERO, 0)

	if session.HandlesOn then pose_editor.UpdateHandles(session) end
end

function pose_editor.BuildItems(session, changed)
	local pose = pose_editor.GetPose(session)

	if not pose then return {} end

	local items = {}
	local base = pose.base and keyframes.ResolvePose(pose.base, session.Data.Poses[session.Source])
	move_editor.AddTrackItems(
		items,
		pose,
		|track|->move_edit.GetValues({[track.Name] = base and base[track.Name] or track.Rest}, track.Name),
		changed,
		""
	)
	return items
end

function pose_editor.BuildMenu(session, h)
	return {
		{
			Text = "FILE",
			Items = ||-> {
				MenuItem{
					Text = "new pose",
					Icon = "file",
					OnClick = ||-> do
						session.NameDraft = ""
						h.refresh()
					end,
				},
				MenuItem{
					Text = "reload from file",
					Icon = "folder_open",
					OnClick = ||-> do
						pose_editor.Reload(session)
						session.Status = "reloaded from file"
						h.refresh()
					end,
				},
				MenuItem{
					Text = "save",
					Icon = "save",
					OnClick = ||-> do
						local ok, err = pcall(pose_editor.Save, session)
						session.Status = ok and "saved" or tostring(err):gsub("^.-:%d+: ", "")
						h.refresh()
					end,
				},
				MenuItem{Text = "close", Icon = "close", OnClick = ||->h.close()},
			},
		},
		{
			Text = "EDIT",
			Items = ||-> {
				MenuItem{
					Text = "undo",
					Icon = "undo",
					Tooltip = "ctrl+z",
					OnClick = ||-> do
						pose_editor.StepHistory(session, false)
						h.refresh()
					end,
				},
				MenuItem{
					Text = "redo",
					Icon = "redo",
					Tooltip = "ctrl+y",
					OnClick = ||-> do
						pose_editor.StepHistory(session, true)
						h.refresh()
					end,
				},
				MenuItem{
					Text = "duplicate pose",
					Icon = "copy",
					OnClick = ||-> do
						if pose_editor.Duplicate(session) then h.changed(true) end
					end,
				},
				MenuItem{
					Text = "delete pose",
					Icon = "trash",
					Disabled = not pose_editor.GetPose(session) or
						pose_editor.CountUses(session, session.PoseName or "") > 0,
					OnClick = ||-> do
						if pose_editor.Delete(session) then h.changed(true) end
					end,
				},
			},
		},
		{
			Text = "VIEW",
			Items = ||-> do
				local items = {}

				for _, name in ipairs(CAMERA_NAMES) do
					items[#items + 1] = MenuItem{
						Text = name,
						Icon = name == session.Camera and "check" or nil,
						OnClick = ||-> do
							pose_editor.SetCameraPreset(session, name)
							h.refresh()
						end,
					}
				end

				for _, step in ipairs{0.05, -0.05} do
					items[#items + 1] = MenuItem{
						Text = string.format("%s stage %d cm", step > 0 and "raise" or "lower", math.abs(step) * 100),
						OnClick = ||-> do
							session.StageHeight = session.StageHeight + step
							pose_editor.LastStageHeight = session.StageHeight
							pose_editor.SpawnAttacker(session)
							h.refresh()
						end,
					}
				end

				items[#items + 1] = MenuItem{
					Text = "base animation",
					Items = ||-> do
						local bases = {
							MenuItem{
								Text = "game default",
								Icon = session.Base == "game" and "check" or nil,
								OnClick = ||-> do
									session.Base = "game"
									h.refresh()
								end,
							},
						}
						local names, has_reference = pose_editor.GetBaseNames(session)

						if has_reference then
							bases[#bases + 1] = MenuItem{
								Text = "reference pose",
								Icon = session.Base == "reference" and "check" or nil,
								OnClick = ||-> do
									session.Base = "reference"
									h.refresh()
								end,
							}
						end

						for _, name in ipairs(names) do
							bases[#bases + 1] = MenuItem{
								Text = name,
								Icon = session.Base == name and "check" or nil,
								OnClick = ||-> do
									session.Base = name
									h.refresh()
								end,
							}
						end

						return bases
					end,
				}
				items[#items + 1] = MenuItem{
					Text = "handles",
					Icon = session.HandlesOn and "check" or nil,
					OnClick = ||-> do
						pose_editor.SetHandles(session, not session.HandlesOn)
						h.refresh()
					end,
				}
				items[#items + 1] = MenuItem{
					Text = "weapon",
					Items = ||-> do
						local weapons = {}

						for _, name in ipairs(get_set_names()) do
							weapons[#weapons + 1] = MenuItem{
								Text = name,
								Icon = name == session.Weapon and "check" or nil,
								OnClick = ||-> do
									session.Weapon = name
									pose_editor.LastWeapon = name
									pose_editor.SpawnAttacker(session)
									h.refresh()
								end,
							}
						end

						return weapons
					end,
				}
				return items
			end,
		},
	}
end

local COLUMNS = {
	{Key = "Text", Text = "Pose", Grow = true, MinWidth = 120},
	{Key = "Source", Text = "Set", Width = 84},
	{Key = "Uses", Text = "Used", Width = 48},
}

function pose_editor.GetNodes(session)
	local nodes = {}

	for _, source in ipairs(pose_editor.GetSources(session)) do
		local dirty = pose_editor.IsDirty(session, source)

		for _, name in ipairs(pose_editor.GetPoseNames(session, source)) do
			nodes[#nodes + 1] = {
				Key = source .. "/" .. name,
				Text = name,
				Source = source,
				Name = name,
				Icon = dirty and "save" or "file",
				Uses = tostring(pose_editor.CountUses(session, name)),
			}
		end
	end

	return nodes
end

local PoseEditor = react.Component(
	|props|-> do
		local version, set_version = react.UseState(0)
		local session = react.UseResource(
			||-> do
				local session = pose_editor.CreateSession()
				local first = pose_editor.GetPoseNames(session, "shared")[1]
				pose_editor.Select(session, "shared", first)
				pose_editor.SetHandles(session, true)
				return session
			end,
			pose_editor.DestroySession,
			{}
		)
		local h = react.UseMemo(
			||-> do
				local h = {}

				function h.refresh()
					set_version(|value|->value + 1)
				end

				function h.changed(force)
					pose_editor.Apply(session)
					pose_editor.Commit(session, force)
					set_version(|value|->value + 1)
				end

				function h.close()
					props.OnClose()
				end

				return h
			end,
			{}
		)
		session.Changed = h.changed
		local menu = react.UseMemo(||->pose_editor.BuildMenu(session, h), {})
		react.UseEvent("Update", |dt|->pose_editor.Step(session, math.min(dt, 0.1)))
		react.UseEvent(
			"KeyInput",
			|key, press|-> do
				local focused = objects:GetFocusedObject()

				if focused and focused:IsValid() and tostring(focused.Type):find("text") then return end

				if press and input.IsControlDown() and (key == "z" or key == "y") then
					pose_editor.StepHistory(session, key == "y" or input.IsShiftDown())
					h.refresh()
					return true
				end
			end
		)
		local items = react.UseMemo(
			||->pose_editor.BuildItems(session, h.changed),
			{session.SelectId, session.Source, session.PoseName}
		)
		local nodes = pose_editor.GetNodes(session)
		local screen = Panel.World.transform:GetSize()
		return ui.Window{
			Title = "POSE EDITOR",
			Name = "pose editor",
			RequestMouse = true,
			Size = Vec2(LEFT_WIDTH, screen.y),
			Position = Vec2(0, 0),
			Padding = Rect(),
			Minimizable = false,
			Maximizable = false,
			layout = {FitHeight = false, FitWidth = false},
			OnClose = props.OnClose,
		}{
			ui.MenuBar{MenuKey = "PoseEditorMenuBarContextMenu", Items = menu, layout = {GrowWidth = 1}},
			ui.TreeTable{
				Mode = "list",
				AlternateRows = false,
				Items = nodes,
				Columns = COLUMNS,
				SelectedKey = session.Source and session.PoseName and session.Source .. "/" .. session.PoseName or nil,
				OnSelect = |node|-> do
					if node and node.Name then
						pose_editor.Select(session, node.Source, node.Name)
						h.refresh()
					end
				end,
				layout = {GrowWidth = 1, GrowHeight = 0, MinSize = Vec2(0, LIST_HEIGHT), MaxSize = Vec2(0, LIST_HEIGHT)},
			},
			session.NameDraft ~= nil and
			ui.Row{layout = {GrowWidth = 1, ChildGap = 6, AlignmentY = "center", Padding = Rect(8, 6, 8, 6)}}{
				ui.TextEdit{
					Key = "new pose name",
					Hint = string.format("name of the new pose in %s", session.Source or "shared"),
					Text = session.NameDraft,
					Size = Vec2(0, 28),
					MinSize = Vec2(100, 28),
					MaxSize = Vec2(0, 28),
					Wrap = false,
					ScrollX = false,
					ScrollY = false,
					OnTextChanged = |_, text|-> do
						session.NameDraft = text
						h.refresh()
					end,
					layout = {GrowWidth = 1},
				},
				ui.Button{
					Key = "create pose",
					Text = "Create",
					Mode = "outline",
					Disabled = not pose_editor.IsNameFree(session, session.NameDraft),
					OnClick = ||-> do
						if pose_editor.AddPose(session, session.NameDraft) then h.changed(true) end
					end,
				},
				ui.Button{
					Key = "cancel pose",
					Text = "Cancel",
					Mode = "outline",
					OnClick = ||-> do
						session.NameDraft = nil
						h.refresh()
					end,
				},
			} or
			false,
			ui.Text{
				Text = pose_editor.GetPose(session) and
					string.format(
						"%s / %s   used by %d   base: %s",
						session.Source,
						session.PoseName,
						pose_editor.CountUses(session, session.PoseName),
						session.Base == "game" and "game default" or session.Base
					) or
					"no pose selected",
				Color = "text_disabled",
				IgnoreMouseInput = true,
				layout = {GrowWidth = 1, Padding = Rect(8, 6, 8, 6)},
			},
			ui.ScrollablePanel{ScrollX = false, ScrollY = true, Padding = "none", layout = {GrowWidth = 1, GrowHeight = 1}}{
				ui.Panel{
					Name = "PoseEditorFrame",
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
						Items = items,
						layout = {GrowWidth = 1, GrowHeight = 1, FitWidth = false, MinSize = Vec2(LEFT_WIDTH - 28, 0)},
					},
				},
			},
			ui.Text{
				Text = session.Status,
				Color = "negative",
				Font = "body XS",
				IgnoreMouseInput = true,
				layout = {GrowWidth = 1},
			},
		}
	end
)

function pose_editor.Create()
	local root

	root = react.Mount(PoseEditor{OnClose = ||->root:Unmount()}, Panel.World)
	return root:GetEntity()
end

return pose_editor
