local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Rect = import("goluwa/structs/rect.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local objects = import("goluwa/objects/objects.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local View = import("goluwa/render3d/view.lua")
local Quat = import("goluwa/structs/quat.lua")
local view_camera = import("lua/view_camera.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local keyframes = import("lua/keyframes.lua")
local actors = import("lua/actors.lua")
local npcs = import("lua/npcs.lua")
local jrpg = import("lua/jrpg/jrpg.lua")
local movesets = import("lua/movesets.lua")
local move_edit = import("lua/jrpg/move_edit.lua")
local move_preview = import("lua/jrpg/move_preview.lua")
local data_history = import("lua/data_history.lua")
local camera_shots = import("lua/camera_shots.lua")
local faces = import("lua/faces.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local input = import("goluwa/input.lua")
local system = import("goluwa/system.lua")
local move_editor = {}
local NPC_OFFSET = 3
local LEFT_WIDTH = 400
local BOTTOM_HEIGHT = 320
local TIMELINE_RULER = 22
local TIMELINE_ROW = 22
local TIMELINE_CHROME = 34 + 6 * 2
local CAMERAS = {"three", "side", "front"}
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
	local grabber = assert(_G.PLAYER_RIG, "the move editor previews on the local player")
	jrpg.SetEnabled(grabber, true)
	local forward = actors.GetForward(grabber)
	local victim = npcs.Spawn("citizen", grabber.transform:GetPosition() + forward * 2.6, 0)
	victim.ai_controller.Wander = false
	local session = {
		Player = grabber,
		Grabber = grabber,
		Victim = victim,
		Camera = "three",
		Phase = 0,
		Playing = false,
		Loop = true,
		Speed = 1,
		Status = "",
		SelectId = 0,
		Selected = {},
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

	if session.Npc and session.Npc:IsValid() then session.Npc:Remove() end

	session.View:Remove()
	view_camera.Stop(session.Fly)

	if session.Victim:IsValid() then session.Victim:Remove() end
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

function move_editor.UseAttacker(session, set_name)
	if session.Preview then
		session.Preview:Stop()
		session.Preview = nil
	end

	local npc_name = set_name:match("^npc_(.+)$")

	if session.Npc and session.Npc:IsValid() then session.Npc:Remove() end

	session.Npc = nil

	if npc_name then
		local player = session.Player
		local forward = actors.GetForward(player)
		local position = player.transform:GetPosition() + Vec3(forward.z, 0, -forward.x) * NPC_OFFSET
		local npc = npcs.Spawn(npc_name, position, 0)
		npc.ai_controller.Wander = false
		session.Npc = npc
		session.Grabber = npc
		session.Victim.character_movement:TeleportTo(position + actors.GetForward(npc) * 2.6)
	else
		session.Grabber = session.Player
		session.Victim.character_movement:TeleportTo(
			session.Player.transform:GetPosition() + actors.GetForward(session.Player) * 2.6
		)
	end

	move_editor.SetCameraPreset(session, session.Camera)
end

function move_editor.LoadSet(session, set_name, move_name)
	move_editor.UseAttacker(session, set_name)
	session.SetName = set_name
	session.Data = table.copy(movesets.Source[set_name])

	for _, move in pairs(session.Data.Moves) do
		if move.Clip then move.Keys = move.Keys or {} end
	end

	session.History = data_history.New(session.Data)
	session.MoveName = move_name or get_move_names(session.Data)[1]
	move_editor.Select(session, nil)
	move_editor.Restart(session)
end

function move_editor.GetMove(session)
	return session.Data.Moves[session.MoveName]
end

function move_editor.Restart(session)
	if session.Preview then
		session.Preview:Stop()
		session.Preview = nil
	end

	session.Phase = 0
end

function move_editor.Apply(session)
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

function move_editor.Step(session, dt)
	local registered = movesets.Get(session.SetName).Moves[session.MoveName]
	local holder = session.Grabber.weapon_holder
	local weapon = holder and holder:FindWeapon("weapon_" .. session.SetName)

	if weapon and holder:GetWeapon("right") ~= weapon then holder:Equip(weapon, "right") end

	if weapon then weapon.weapon:SetDrawn(true) end

	if not session.Preview then
		if not session.Victim:IsValid() then return end

		session.Preview = move_preview.Start(session.Grabber, session.Victim, registered)
	end

	session.Preview.Move = registered

	if session.Playing then
		session.Phase = session.Phase + dt * session.Speed / registered.Duration

		if session.Phase >= 1 then
			session.Phase = session.Loop and 0 or 1
			session.Playing = session.Loop
		end
	end

	session.Preview:SetPhase(session.Phase)
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

	local skeleton = session.Grabber.animator and session.Grabber.animator.skeleton

	if move.Clip and skeleton then
		local options = {}

		for i, clip in ipairs(skeleton.Clips) do
			options[i] = {Text = string.format("%s (%.2fs)", clip.Name, clip.Duration), Value = clip.Name}
		end

		move_children[#move_children + 1] = {
			Key = "move/Clip",
			Text = "clip",
			Type = "enum",
			Value = move.Clip,
			Options = options,
			OnChange = |_, value|-> do
				move.Clip = value
				move.Duration = skeleton.ClipsByName[value].Duration
				changed(true)
			end,
		}
		move_children[#move_children + 1] = number_node(
			"move/ClipSpeed",
			"clip speed",
			move.ClipSpeed or 0,
			|value|-> do
				move.ClipSpeed = value > 0 and value or nil
				changed()
			end
		)
	end

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
		local rows = move_edit.Rows(move)
		local addable = move_edit.AddableTracks(move)

		if addable[1] then rows[#rows + 1] = {Name = "+ add track", Button = true, Keys = {}} end

		local timeline_height = TIMELINE_CHROME + TIMELINE_RULER + #rows * TIMELINE_ROW

		local screen = Panel.World.transform:GetSize()
		local registered = movesets.Get(session.SetName).Moves[session.MoveName]

		local function add_track_key(name, time)
			local frame = move_edit.AddTrackKey(move, name, time, move_edit.Sample(registered, name, time))
			move_editor.Select(session, {Frame = frame, Track = name})
			h.changed()
		end

		return ui.Window{
			Title = "MOVE EDITOR",
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
							OnKeyMenu = |row, index|-> do
								local count = #session.Selected
								local linked = false

								for _, key in ipairs(session.Selected) do
									linked = linked or move_edit.IsLinked(key)
								end

								Panel.OpenContextMenu(
									{},
									{
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
								)
							end,
							OnKeyMove = |row, index, time|-> do
								local key = rows[row].Keys[index]

								if key.Entry then
									if key.List == "Locks" then
										key.Entry[2] = math.min(time + key.Entry[2] - key.Entry[1], 1)
									end

									key.Entry[1] = time
									move_edit.Sort(move[key.List])
								elseif key.Event then
									key.Event.At = time
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
