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
local MouseInput = import("goluwa/render2d/ui/components/mouse_input.lua")
local camera = import("lua/camera.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local keyframes = import("lua/keyframes.lua")
local actors = import("lua/actors.lua")
local npcs = import("lua/npcs.lua")
local jrpg = import("lua/jrpg/jrpg.lua")
local movesets = import("lua/movesets.lua")
local move_edit = import("lua/jrpg/move_edit.lua")
local move_preview = import("lua/jrpg/move_preview.lua")
local move_editor = {}
local LEFT_WIDTH = 400
local BOTTOM_HEIGHT = 320
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

local function find_selection(rows, selection)
	if not selection then return end

	for i, row in ipairs(rows) do
		for j, key in ipairs(row.Keys) do
			if
				selection.Event and
				key.Event == selection.Event or
				selection.Frame and
				key.Frame == selection.Frame and
				key.Track == selection.Track
			then
				return {i, j}
			end
		end
	end
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
		camera.SetPosition(eye)
		camera.SetRotation(QuatDeg3(pitch, yaw, 0))
		camera.pitch = -math.rad(pitch)
		camera.velocity = Vec3()
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
		Grabber = grabber,
		Victim = victim,
		Camera = "three",
		Phase = 0,
		Playing = false,
		Loop = true,
		Speed = 1,
		Status = "",
		SelectId = 0,
	}
	session.View = View.New{
		Priority = 1000,
		ExposureLock = 16,
		HidePlayer = false,
		HideHud = true,
	}
	session.View:Activate()
	session.SavedSpeed = camera.speed
	session.SavedKeys = {camera.key_up, camera.key_down}
	camera.speed = 6
	camera.key_up, camera.key_down = "e", "q"
	move_editor.SetCameraPreset(session, session.Camera)
	move_editor.Current = session
	return session
end

function move_editor.DestroySession(session)
	move_editor.Current = nil

	if session.Preview then session.Preview:Stop() end

	session.View:Remove()
	camera.speed = session.SavedSpeed
	camera.key_up, camera.key_down = unpack(session.SavedKeys)
	camera.SetBlockMovement(false)
	camera.SetBlockDragging(false)

	if session.Victim:IsValid() then session.Victim:Remove() end
end

function move_editor.Select(session, selection)
	session.Selection = selection
	session.SelectId = session.SelectId + 1
end

function move_editor.LoadSet(session, set_name, move_name)
	session.SetName = set_name
	session.Data = table.copy(movesets.Source[set_name])
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

function move_editor.TogglePlaying(session)
	session.Playing = not session.Playing

	if session.Playing and session.Phase >= 1 then session.Phase = 0 end
end

function move_editor.Step(session, dt)
	local registered = movesets.Get(session.SetName).Moves[session.MoveName]
	local holder = session.Grabber.weapon_holder
	local weapon = holder:FindWeapon("weapon_" .. session.SetName)

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

local function action_node(key, text, on_action)
	return {Key = key, Text = "", Type = "action", ButtonText = text, OnAction = on_action}
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

	local items = {
		{
			Key = "move",
			Text = session.SetName .. " / " .. session.MoveName,
			Expanded = true,
			Children = move_children,
		},
	}

	if not selection then return items end

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

			for i = 1, field.Count do
				values[i] = values[i] or 0
			end

			local key = "key/" .. field.Name
			local text = field.Name:lower()

			if field.Count == 1 then
				children[#children + 1] = number_node(
					key,
					text,
					values[1],
					|value|-> do
						move_edit.SetEventValue(event, field, 1, value)
						changed()
					end
				)
			else
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

		children[#children + 1] = action_node(
			"key/delete",
			"Delete event",
			||-> do
				move_edit.RemoveEvent(move, event)
				move_editor.Select(session, nil)
				changed()
			end
		)
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
			action_node(
				"key/delete",
				"Delete key",
				||-> do
					move_edit.RemoveFrame(move, frame)
					move_editor.Select(session, nil)
					changed()
				end
			),
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

		if #names > 1 or type(frame[2]) == "string" then
			children[#children + 1] = action_node(
				track_name .. "/split",
				"Split to its own key",
				||-> do
					move_editor.Select(session, {Frame = move_edit.Split(move, frame, track_name), Track = track_name})
					changed()
				end
			)
		end

		children[#children + 1] = action_node(
			track_name .. "/remove",
			"Remove " .. track_name,
			||-> do
				move_edit.RemoveTrack(move, frame, track_name)
				move_editor.Select(session, nil)
				changed()
			end
		)
		items[#items + 1] = {Key = track_name, Text = track_name, Expanded = true, Children = children}
	end

	return items
end

function move_editor.BuildMenu(session, h)
	return {
		{
			Text = "FILE",
			Items = ||-> do
				local load_items = {}

				for _, set_name in ipairs(move_editor.GetSetNames()) do
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

					load_items[#load_items + 1] = MenuItem{Text = set_name, Icon = "folder", Items = ||->moves}
				end

				return {
					MenuItem{
						Text = "save",
						Icon = "save",
						OnClick = ||-> do
							if move_editor.Apply(session) then
								session.Status = "saved " .. movesets.Save(session.SetName)
							end

							h.refresh()
						end,
					},
					MenuItem{Text = "load", Icon = "folder_open", Items = ||->load_items},
					MenuItem{
						Text = "revert to file",
						Icon = "file",
						OnClick = ||-> do
							movesets.Reload(session.SetName)
							move_editor.LoadSet(session, session.SetName, session.MoveName)
							h.refresh()
						end,
					},
					MenuItem{Text = "close", Icon = "close", OnClick = ||->h.close()},
				}
			end,
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

				function h.changed()
					move_editor.Apply(session)
					set_version(|value|->value + 1)
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
				local focused = objects:GetFocusedObject()
				local hovered = MouseInput.GetHoveredObject()
				camera.SetBlockMovement(focused:IsValid() and tostring(focused.Type):find("text") ~= nil)
				camera.SetBlockDragging(hovered:IsValid() and hovered ~= Panel.World)
				camera.Update(dt)
				session.View:SetPosition(camera.GetPosition():Copy())
				session.View:SetRotation(camera.GetRotation():Copy())

				if session.Playing or session.ShownPhase ~= session.Phase then
					session.ShownPhase = session.Phase
					set_version(|value|->value + 1)
				end
			end
		)
		react.UseEvent(
			"KeyInput",
			|key, press|-> do
				if key ~= "space" then return end

				local focused = objects:GetFocusedObject()

				if focused and focused:IsValid() and tostring(focused.Type):find("text") then return end

				if press then
					move_editor.TogglePlaying(session)
					h.refresh()
				end

				return true
			end
		)
		local items = react.UseMemo(
			||->move_editor.BuildItems(session, h.changed),
			{session.SelectId, session.SetName, session.MoveName}
		)
		local move = move_editor.GetMove(session)
		local rows = move_edit.Rows(move)
		local addable = move_edit.AddableTracks(move)
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
					Title = "TIMELINE",
					Name = "move editor timeline",
					RequestMouse = true,
					Size = Vec2(screen.x - LEFT_WIDTH, BOTTOM_HEIGHT),
					Position = Vec2(LEFT_WIDTH, screen.y - BOTTOM_HEIGHT),
					Padding = Rect(),
					Closable = false,
					Minimizable = false,
					Maximizable = false,
					layout = {FitHeight = false, FitWidth = false},
				}{
					ui.Column{
						layout = {
							GrowWidth = 1,
							GrowHeight = 1,
							FitHeight = false,
							AlignmentX = "stretch",
							ChildGap = 6,
							Padding = Rect() + 8,
						},
					}{
						ui.Row{layout = {GrowWidth = 1, ChildGap = 8, AlignmentY = "center"}}{
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
							ui.Text{Text = "Camera", Color = "text_disabled", layout = {FitWidth = true}},
							ui.Dropdown{
								Key = "camera",
								Options = CAMERAS,
								Value = session.Camera,
								Padding = "XS",
								OnSelect = |value|-> do
									move_editor.SetCameraPreset(session, value)
								end,
								layout = {MinSize = Vec2(90, 0), MaxSize = Vec2(90, 0), GrowWidth = 0},
							},
							#addable > 0 and ui.Dropdown{
								Key = "addtrack" .. #addable,
								Options = {"add track", unpack(addable)},
								Value = "add track",
								Padding = "XS",
								OnSelect = |value|-> do
									if value ~= "add track" then add_track_key(value, session.Phase) end
								end,
								layout = {MinSize = Vec2(110, 0), MaxSize = Vec2(110, 0), GrowWidth = 0},
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
						ui.Timeline{
							Rows = rows,
							Time = session.Phase,
							Selection = find_selection(rows, session.Selection),
							OnScrub = |time|-> do
								session.Playing = false
								session.Phase = time
								h.refresh()
							end,
							OnSelect = |row, index|-> do
								local key = row and rows[row].Keys[index]
								move_editor.Select(session, key and {Frame = key.Frame, Track = key.Track, Event = key.Event} or nil)
								h.refresh()
							end,
							OnKeyMove = |row, index, time|-> do
								local key = rows[row].Keys[index]

								if key.Event then
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
								else
									move_editor.Select(session, {Event = move_edit.AddEvent(move, name, time)})
									h.changed()
								end
							end,
							layout = {GrowWidth = 1, GrowHeight = 1},
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
