local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local Rect = import("goluwa/structs/rect.lua")
local react = import("goluwa/render2d/ui/react.lua")
local ui = import("goluwa/render2d/ui/react_ui.lua")
local Breadcrumb = react.Element(import("goluwa/render2d/ui/widgets/breadcrumb.lua"))
local Panel = import("goluwa/render2d/ui/panel.lua")
local MenuItem = import("goluwa/render2d/ui/elements/context_menu_item.lua")
local input = import("goluwa/input.lua")
local system = import("goluwa/system.lua")
local easing = import("goluwa/math/easing.lua")
local View = import("goluwa/render3d/view.lua")
local clips = import("goluwa/render3d/clips.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local view_camera = import("lua/view_camera.lua")
local data_items = import("lua/data_items.lua")
local data_schema = import("lua/data_schema.lua")
local data_history = import("lua/data_history.lua")
local Gizmo = import("lua/gizmo.lua")
local npcs = import("lua/npcs.lua")
local sounds = import("lua/sounds.lua")
local emitters = import("lua/emitters.lua")
local grenade_effects = import("lua/grenade_effects.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local effects = import("lua/jrpg/effects.lua")
local effects_schema = import("lua/jrpg/effects_schema.lua")
local clip_edit = import("lua/jrpg/clip_edit.lua")
local particle_shader_library = import("lua/particle_shader_library.lua")
local effects_stage = import("lua/jrpg/effects_stage.lua")
local effects_editor = {}
local LEFT_WIDTH = 440
local BOTTOM_HEIGHT = 260
local UP = Vec3(0, 1, 0)
local CAMERAS = {"front", "side", "high"}
local GIZMO_MODES = {"move", "rotate", "combined"}
local EXPOSURES = {day = 15, dusk = 11, night = 7}
local EXPOSURE_NAMES = {"day", "dusk", "night"}
effects_editor.LastCategory = "damage types"
effects_editor.LastName = "fire"
effects_editor.LastStage = "player"
effects_editor.LastNpc = effects_stage.DefaultNpc
effects_editor.CategoryNames = {
	"damage types",
	"status effects",
	"clips",
	"overlays",
	"particle shaders",
	"gpu emitters",
	"grenade puffs",
	"scripts",
}

local function play_clip(stage, name, params)
	params.duration = 2
	params.position = stage.Chest:Copy()
	params.color = params.color or Color(1, 0.6, 0.2, 1)
	clips.Play("jrpg_" .. name, params)
end

local REF_CATEGORIES = {
	status = "status effects",
	damage = "damage types",
	overlay = "overlays",
	script = "scripts",
	particle_shader = "particle shaders",
	emitter = "gpu emitters",
}
effects_editor.Categories = {
	["damage types"] = {
		Schema = effects_schema.Schemas["damage types"],
		GetSchema = effects_schema.WithShaderParams,
		GetNames = effects_schema.Refs.damage,
		GetSource = |name|->damage_types.Files.Source[name],
		Update = |name, data|-> do
			damage_types.Update(name, data)
			effects.ResetType(name)
		end,
		Reload = damage_types.Reload,
		Save = damage_types.Save,
		Play = |stage, name|-> do
			effects.ShowImpact(stage.Chest, stage.Normal, name, 1.2, false, stage.Normal, 40)
			effects.ShowHitOverlay(stage.Target, name)
		end,
	},
	["status effects"] = {
		Schema = effects_schema.Schemas["status effects"],
		GetNames = effects_schema.Refs.status,
		GetSource = |name|->status_effects.Files.Source[name],
		GetSchema = effects_schema.WithShaderParams,
		Update = status_effects.Update,
		Reload = status_effects.Reload,
		Save = status_effects.Save,
		Play = |stage, name|-> do
			status_effects.Set(stage.Target, name, 0.8)
		end,
	},
	clips = {
		Schema = effects_schema.Schemas.clips,
		Duration = |data|->data.Duration or 2,
		GetNames = ||->effects.ClipNames,
		GetSource = |name|->effects.ClipFiles.Source[name],
		Update = effects.UpdateClip,
		Reload = effects.ReloadClip,
		Save = effects.SaveClip,
		Play = |stage, name|-> do
			if name == "impact" then
				effects.ShowImpact(stage.Chest, stage.Normal, "generic", 1.2, false, stage.Normal, 40)
			elseif name == "magic_circle" then
				effects.ShowMagicCircle(stage.Target, Color(0.5, 0.7, 1, 1), 1, 1.5, 1, true)
			elseif name == "orb" then
				play_clip(stage, name, {size = 0.3, alpha = 1, flicker = 1, lens_scale = 1})
			elseif name == "flash" then
				clips.Play("jrpg_flash", {entity = stage.Target, color = Color(1, 0.3, 0.2, 1), intensity = 1.2, duration = 1})
			elseif name == "low_health" then
				clips.Play("jrpg_low_health", {entity = stage.Target, health = stage.Target.health, duration = 2})
			else
				play_clip(stage, name, {size = 0.3, fade = 1, flicker = 1, lens_scale = 1, trail_radius = 0.03})
			end
		end,
	},
	overlays = {
		Schema = effects_schema.Schemas.overlays,
		GetNames = ||->surface_overlays.GetKindNames(),
		GetSource = |name|->surface_overlays.DefaultFiles.Source[name],
		Update = surface_overlays.SetDefaults,
		Reload = surface_overlays.ReloadDefaults,
		Save = surface_overlays.SaveDefaults,
		Play = |stage, name|-> do
			effects.PlayOverlay(stage.Target, name, {Duration = 3})
		end,
	},
	["particle shaders"] = {
		Schema = effects_schema.Schemas["particle shaders"],
		Duration = ||->5,
		GetNames = ||->particle_shader_library.Names,
		GetSource = |name|->particle_shader_library.Files.Source[name],
		Update = particle_shader_library.Update,
		Reload = particle_shader_library.Reload,
		Save = particle_shader_library.Save,
		Duplicate = |name|->particle_shader_library.Create(particle_shader_library.GetNewName(name), name),
		Play = |stage, name|-> do
			effects.PlayParticleShader(stage.Chest, name)
		end,
	},
	["gpu emitters"] = {
		Schema = effects_schema.Schemas["gpu emitters"],
		GetSchema = effects_schema.WithEmitterShaderParams,
		Duration = ||->3,
		GetNames = ||->emitters.Names,
		GetSource = |name|->emitters.Files.Source[name],
		Update = emitters.Update,
		Reload = emitters.Reload,
		Save = emitters.Save,
		Duplicate = |name|->emitters.Create(emitters.GetNewName(name), name),
		Play = |stage, name|-> do
			effects_stage.PlayEmitter(stage, name)
		end,
	},
	["grenade puffs"] = {
		Schema = effects_schema.Schemas["grenade puffs"],
		Duration = ||->6,
		GetNames = ||->{"grenade_puffs"},
		GetSource = ||->grenade_effects.PuffFiles.Source.grenade_puffs,
		Update = |name, data|->grenade_effects.UpdatePuffs(data),
		Reload = grenade_effects.ReloadPuffs,
		Save = grenade_effects.SavePuffs,
		Play = |stage|-> do
			grenade_effects.Explode(stage.Ground, UP, 3)
		end,
	},
	scripts = {
		ReadOnly = true,
		Schema = {Refs = effects_schema.Refs, Fields = {}},
		GetNames = effects_schema.Refs.script,
		GetSource = |name|-> do
			local script = clips.Scripts[name]
			local functions, used_by = {}, {}

			for key in pairs(script) do
				functions[#functions + 1] = key
			end

			table.sort(functions)

			for _, clip_name in ipairs(effects.ClipNames) do
				if effects_editor.UsesScript(effects.ClipFiles.Source[clip_name], name) then
					used_by[#used_by + 1] = clip_name
				end
			end

			return {functions = functions, used_by = used_by}
		end,
	},
}

function effects_editor.UsesScript(value, name)
	if value == name then return true end

	if type(value) == "table" then
		for _, child in pairs(value) do
			if effects_editor.UsesScript(child, name) then return true end
		end
	end

	return false
end

function effects_editor.GetProblems(session)
	local category = effects_editor.Categories[session.Category]

	if category.ReadOnly then return {} end

	return data_schema.Check(
		category.GetSchema and category.GetSchema(category.Schema, session.Data) or category.Schema,
		session.Data
	)
end

function effects_editor.Load(session, category_name, name)
	local category = effects_editor.Categories[category_name]
	session.Category = category_name
	session.Name = name or category.GetNames()[1]
	session.Trail = {}
	session.Data = table.copy(category.GetSource(session.Name))
	session.History = data_history.New(session.Data)
	session.Status = ""
	session.Selection = nil
	session.LoadId = session.LoadId + 1
	session.Problems = effects_editor.GetProblems(session)
	effects_editor.LastCategory, effects_editor.LastName = session.Category, session.Name
end

function effects_editor.Open(session, category_name, name)
	local trail = session.Trail
	trail[#trail + 1] = {Category = session.Category, Name = session.Name}
	effects_editor.Load(session, category_name, name)
	session.Trail = trail
end

function effects_editor.Back(session, index)
	local entry = session.Trail[index]
	local trail = {table.unpack(session.Trail, 1, index - 1)}
	effects_editor.Load(session, entry.Category, entry.Name)
	session.Trail = trail
end

function effects_editor.GetTrailLabels(session)
	if not session.Trail[1] then return {} end

	local entries = {table.unpack(session.Trail)}
	entries[#entries + 1] = {Category = session.Category, Name = session.Name}
	local labels = {}
	local counts = {}

	for _, entry in ipairs(entries) do
		counts[entry.Name] = (counts[entry.Name] or 0) + 1
	end

	for i, entry in ipairs(entries) do
		labels[i] = counts[entry.Name] > 1 and entry.Name .. " (" .. entry.Category .. ")" or entry.Name
	end

	return labels
end

function effects_editor.Apply(session)
	local category = effects_editor.Categories[session.Category]

	if category.ReadOnly then return false end

	local ok, err = pcall(category.Update, session.Name, table.copy(session.Data))
	session.Status = ok and "" or tostring(err):gsub("^.-:%d+: ", "")
	session.Problems = effects_editor.GetProblems(session)
	return ok
end

function effects_editor.Commit(session, force)
	session.History:Commit(session.Data, system.GetElapsedTime(), force)
	effects_editor.Apply(session)
end

function effects_editor.Step(session, redo)
	local data = redo and session.History:DoRedo() or session.History:DoUndo()

	if not data then return end

	session.Data = data
	session.Selection = nil
	session.LoadId = session.LoadId + 1
	effects_editor.Apply(session)
end

function effects_editor.Play(session)
	local category = effects_editor.Categories[session.Category]

	if category.Play then
		local ok, err = pcall(category.Play, session.Stage, session.Name)
		session.Status = ok and "" or tostring(err)
		session.PlayStart = system.GetElapsedTime()
	end
end

function effects_editor.GetDuration(session)
	local duration = effects_editor.Categories[session.Category].Duration

	return duration and duration(session.Data) or 1.5
end

function effects_editor.SetCamera(session, name)
	local stage = session.Stage
	local offsets = {front = Vec3(0, 0.5, 3.6), side = Vec3(3.6, 0.5, 0), high = Vec3(0, 3, 3)}
	local toward, right = stage.Toward, Vec3(stage.Toward.z, 0, -stage.Toward.x)
	local offset = offsets[name]
	local eye = effects_stage.GetSubject(stage) + toward * offset.z + right * offset.x + Vec3(0, 1 + offset.y, 0)
	local direction = (stage.Chest - eye):GetNormalized()
	view_camera.Set(
		session.Fly,
		eye,
		math.deg(math.asin(direction.y)),
		math.deg(math.atan2(-direction.x, -direction.z))
	)
	session.Camera = name
end

function effects_editor.SetStage(session, kind, npc_name)
	if session.Stage then effects_stage.Remove(session.Stage) end

	effects_editor.LastStage, effects_editor.LastNpc = kind, npc_name
	session.Stage = effects_stage.New(kind, npc_name)
	session.StageKind, session.NpcName = kind, npc_name

	if session.Fly then effects_editor.SetCamera(session, session.Camera) end
end

function effects_editor.CreateSession()
	local session = {
		LoadId = 0,
		SelectId = 0,
		Loop = true,
		Exposure = "day",
		Camera = "front",
		GizmoMode = Gizmo.GetMode(),
	}
	session.View = View.New{
		Priority = 1000,
		ExposureLock = EXPOSURES.day,
		HidePlayer = false,
		HideHud = true,
	}
	session.View:Activate()
	effects_editor.SetStage(session, effects_editor.LastStage, effects_editor.LastNpc)
	session.Fly = view_camera.Start(session.View, 6)
	effects_editor.SetCamera(session, "front")
	effects_editor.Load(session, effects_editor.LastCategory, effects_editor.LastName)
	effects_editor.Current = session
	return session
end

function effects_editor.DestroySession(session)
	effects_editor.Current = nil
	view_camera.Stop(session.Fly)
	session.View:Remove()
	effects_stage.Remove(session.Stage)
end

function effects_editor.BuildItems(session, h)
	local category = effects_editor.Categories[session.Category]
	local options = {
		Changed = h.changed,
		Restructured = h.restructured,
		Name = session.Name,
		Schema = category.GetSchema and category.GetSchema(category.Schema, session.Data) or category.Schema,
		Open = h.open,
		CanOpen = |ref|->REF_CATEGORIES[ref] ~= nil,
		Focus = session.Focus,
		PlaySound = |path|->sounds.Play(path, session.Stage.Chest, 0.8, 1),
	}
	session.Focus = nil
	local items = data_items.Build(session.Data, options)
	local selection = session.Selection

	if selection then
		local children

		if selection.Track then
			local key = session.Data.Tracks[selection.Track][selection.Index]
			local ease_names = {{Text = "(none)", Value = "(none)"}}

			for _, name in ipairs(effects_schema.Refs.easing()) do
				ease_names[#ease_names + 1] = {Text = name, Value = name}
			end

			children = {
				{
					Key = "key/time",
					Text = "time",
					Type = "number",
					Value = key[1],
					Precision = 3,
					ShowStepper = true,
					OnChange = |_, value|-> do
						clip_edit.MoveKey(session.Data, {Track = selection.Track}, selection.Index, value)
						h.changed()
					end,
				},
				{
					Key = "key/value",
					Text = "value",
					Type = "number",
					Value = key[2],
					Precision = 3,
					ShowStepper = true,
					OnChange = |_, value|-> do
						key[2] = value
						h.changed()
					end,
				},
				{
					Key = "key/ease",
					Text = "ease",
					Type = "enum",
					Value = type(key[3]) == "string" and not clips.IsExpression(key[3]) and key[3] or "(none)",
					Options = ease_names,
					OnChange = |_, value|-> do
						key[3] = value ~= "(none)" and value or nil
						h.changed()
					end,
				},
			}
		else
			children = data_items.BuildTable(session.Data.Events[selection.Index], options, "/key", "Events")
		end

		table.insert(items, 1, {Key = "/selected", Text = "selected key", Expanded = true, Children = children})
	end

	return items
end

function effects_editor.BuildMenu(session, h)
	return {
		{
			Text = "FILE",
			Items = ||-> {
				MenuItem{
					Text = "save",
					Icon = "save",
					OnClick = ||-> do
						local category = effects_editor.Categories[session.Category]

						if category.Save and effects_editor.Apply(session) then
							session.Status = "saved " .. category.Save(session.Name)
						end

						h.refresh()
					end,
				},
				MenuItem{
					Text = "duplicate",
					Icon = "copy",
					Disabled = not effects_editor.Categories[session.Category].Duplicate,
					OnClick = ||-> do
						local category = effects_editor.Categories[session.Category]
						effects_editor.Load(session, session.Category, category.Duplicate(session.Name))
						h.refresh()
					end,
				},
				MenuItem{
					Text = "revert to file",
					Icon = "file",
					OnClick = ||-> do
						local category = effects_editor.Categories[session.Category]

						if category.Reload then
							category.Reload(session.Name)
							effects_editor.Load(session, session.Category, session.Name)
						end

						h.refresh()
					end,
				},
				MenuItem{Text = "close", Icon = "close", OnClick = ||->h.close()},
			},
		},
	}
end

local function is_typing()
	local objects = import("goluwa/objects/objects.lua")
	local focused = objects:GetFocusedObject()
	return focused and focused:IsValid() and tostring(focused.Type):find("text") ~= nil
end

local EffectsEditor = react.Component(
	|props|-> do
		local version, set_version = react.UseState(0)
		local session = react.UseResource(effects_editor.CreateSession, effects_editor.DestroySession, {})
		local properties = react.UseRef()
		local h = react.UseMemo(
			||-> do
				local h = {}

				function h.refresh()
					set_version(|value|->value + 1)
				end

				function h.changed()
					effects_editor.Commit(session, false)
					h.refresh()
				end

				function h.restructured(keep_selection, focus)
					if keep_selection ~= true then session.Selection = nil end

					session.Focus = focus

					session.LoadId = session.LoadId + 1
					effects_editor.Commit(session, true)
					h.refresh()
				end

				function h.open(ref, name)
					local category = REF_CATEGORIES[ref]

					if category then
						effects_editor.Open(session, category, name)
						h.refresh()
					end
				end

				function h.on_breadcrumb(index)
					if index <= #session.Trail then
						effects_editor.Back(session, index)
						h.refresh()
					end
				end

				function h.close()
					props.OnClose()
				end

				function h.select(selection)
					session.Selection = selection
					session.SelectId = session.SelectId + 1
					h.refresh()
				end

				return h
			end,
			{}
		)
		react.UseEvent(
			"Update",
			|dt|-> do
				view_camera.Update(session.Fly, math.min(dt, 0.1))
				effects_stage.Update(session.Stage, session.View:GetPosition())
				local now = system.GetElapsedTime()

				if session.PlayStart then
					local duration = effects_editor.GetDuration(session)

					if now - session.PlayStart > duration + 0.4 then
						session.PlayStart = nil

						if session.Loop then effects_editor.Play(session) end
					end

					h.refresh()
				end
			end
		)
		react.UseEvent(
			"KeyInput",
			|key, press|-> do
				if not press or is_typing() then return end

				if key == "space" then
					effects_editor.Play(session)
					h.refresh()
					return true
				end

				if input.IsControlDown() and (key == "z" or key == "y") then
					effects_editor.Step(session, key == "y")
					h.refresh()
					return true
				end
			end
		)
		local menu = react.UseMemo(||->effects_editor.BuildMenu(session, h), {})
		local items = react.UseMemo(
			||->effects_editor.BuildItems(session, h),
			{session.LoadId, session.SelectId}
		)
		local category = effects_editor.Categories[session.Category]
		local screen = Panel.World.transform:GetSize()
		local is_clip = session.Category == "clips"
		local rows = is_clip and clip_edit.Rows(session.Data)
		local playhead = session.PlayStart and
			math.clamp((system.GetElapsedTime() - session.PlayStart) / effects_editor.GetDuration(session), 0, 1) or
			0
		local selected_row

		if is_clip and session.Selection then
			for i, row in ipairs(rows) do
				for j, key in ipairs(row.Keys) do
					if
						(
							session.Selection.Track and
							key.Track == session.Selection.Track and
							key.Index == session.Selection.Index
						) or
						(
							session.Selection.Event and
							key.Event and
							key.Index == session.Selection.Index
						)
					then
						selected_row = {i, j}
					end
				end
			end
		end

		local function dropdown(key, options, value, width, on_select)
			return ui.Dropdown{
				Key = key,
				Options = options,
				Value = value,
				Padding = "XS",
				OnSelect = on_select,
				layout = {MinSize = Vec2(width, 0), MaxSize = Vec2(width, 0), GrowWidth = 0},
			}
		end

		local problem_text = session.Problems[1] and
			(#session.Problems .. " reference problems: " .. session.Problems[1]) or
			""
		return ui.Window{
			Title = "EFFECTS EDITOR",
			Name = "effects editor",
			RequestMouse = true,
			Size = Vec2(LEFT_WIDTH, screen.y),
			Position = Vec2(0, 0),
			Padding = Rect(),
			Minimizable = false,
			Maximizable = false,
			layout = {FitHeight = false, FitWidth = false},
			OnClose = props.OnClose,
		}{
			ui.MenuBar{MenuKey = "EffectsEditorMenuBarContextMenu", Items = menu, layout = {GrowWidth = 1}},
			ui.Row{layout = {GrowWidth = 1, ChildGap = 6, AlignmentY = "center", Padding = Rect() + 6}}{
				dropdown(
					"category",
					effects_editor.CategoryNames,
					session.Category,
					130,
					|value|-> do
						effects_editor.Load(session, value)
						h.refresh()
					end
				),
				dropdown(
					"name" .. session.Category,
					category.GetNames(),
					session.Name,
					130,
					|value|-> do
						effects_editor.Load(session, session.Category, value)
						h.refresh()
					end
				),
				category.Play and ui.Button{
					Text = "Play",
					Mode = "outline",
					Tooltip = "space",
					OnClick = ||-> do
						effects_editor.Play(session)
						h.refresh()
					end,
				},
				ui.Checkbox{Text = "Loop", Value = session.Loop, OnChange = |value|-> do
					session.Loop = value
				end},
			},
			ui.Row{layout = {GrowWidth = 1, ChildGap = 6, AlignmentY = "center", Padding = Rect() + 6}}{
				dropdown(
					"camera",
					CAMERAS,
					session.Camera,
					90,
					|value|-> do
						effects_editor.SetCamera(session, value)
						h.refresh()
					end
				),
				dropdown(
					"exposure",
					EXPOSURE_NAMES,
					session.Exposure,
					90,
					|value|-> do
						session.Exposure = value
						session.View:SetExposureLock(EXPOSURES[value])
					end
				),
				not category.ReadOnly and ui.Button{
					Text = "Undo",
					Mode = "outline",
					Tooltip = "ctrl+z",
					OnClick = ||-> do
						effects_editor.Step(session, false)
						h.refresh()
					end,
				},
				not category.ReadOnly and ui.Button{
					Text = "Redo",
					Mode = "outline",
					Tooltip = "ctrl+y",
					OnClick = ||-> do
						effects_editor.Step(session, true)
						h.refresh()
					end,
				},
			},
			ui.Row{layout = {GrowWidth = 1, ChildGap = 6, AlignmentY = "center", Padding = Rect() + 6}}{
				ui.Text{Text = "preview on", Color = "text_disabled", layout = {FitWidth = true}},
				dropdown(
					"stage",
					effects_stage.Kinds,
					session.StageKind,
					90,
					|value|-> do
						effects_editor.SetStage(session, value, session.NpcName)
						h.refresh()
					end
				),
				session.StageKind == "npc" and dropdown(
					"npc",
					npcs.GetNames(),
					session.NpcName,
					130,
					|value|-> do
						effects_editor.SetStage(session, "npc", value)
						h.refresh()
					end
				),
				session.StageKind == "gizmo" and dropdown(
					"gizmo_mode",
					GIZMO_MODES,
					session.GizmoMode,
					110,
					|value|-> do
						session.GizmoMode = value
						Gizmo.SetMode(value)
						h.refresh()
					end
				),
			},
			Breadcrumb{
				Items = effects_editor.GetTrailLabels(session),
				OnSelect = h.on_breadcrumb,
				layout = {Padding = Rect(6, 0, 6, 4)},
			},
			ui.Text{
				Text = session.Status ~= "" and session.Status or problem_text,
				Color = session.Status ~= "" and "negative" or "text_disabled",
				Font = "body XS",
				IgnoreMouseInput = true,
				layout = {GrowWidth = 1},
			},
			ui.ScrollablePanel{ScrollX = false, ScrollY = true, Padding = "none", layout = {GrowWidth = 1, GrowHeight = 1}}{
				ui.Panel{
					Name = "PropertyEditorFrame",
					transform = true,
					layout = {
						GrowWidth = 1,
						FitHeight = true,
						FitWidth = false,
						Padding = Rect(2, 2, 2, 2),
					},
				}{
					ui.PropertyEditor{
						Ref = properties,
						Items = items,
						layout = {GrowWidth = 1, GrowHeight = 1, FitWidth = false},
					},
				},
			},
			is_clip and react.Portal{Target = Panel.World}{
				ui.Window{
					Key = "EffectsEditorTimeline",
					Title = "TIMELINE",
					Name = "effects editor timeline",
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
								Text = "Delete key",
								Mode = "outline",
								OnClick = ||-> do
									if session.Selection then
										clip_edit.RemoveKey(session.Data, session.Selection)
										h.restructured()
									end
								end,
							},
							ui.Text{
								Text = "click empty space on a row to add a key, drag to move, click a key to edit it",
								Color = "text_disabled",
								Font = "body XS",
								IgnoreMouseInput = true,
								layout = {GrowWidth = 1},
							},
						},
						ui.Timeline{
							Rows = rows,
							Time = playhead,
							Selection = selected_row,
							OnSelect = |row, index|-> do
								local key = row and rows[row].Keys[index]
								h.select(key and {Track = key.Track, Event = key.Event and true, Index = key.Index} or nil)
							end,
							OnKeyMove = |row, index, time|-> do
								clip_edit.MoveKey(session.Data, rows[row], index, time)
								h.changed()

								if properties.current and rows[row].Track then
									properties.current:UpdateValueForKey("key/time", time)
								end
							end,
							OnKeyDrop = ||-> do
								if session.Data.Events then
									local event = session.Selection and session.Selection.Event and
										session.Data.Events[session.Selection.Index]
									clip_edit.SortEvents(session.Data)

									if event then
										for index, other in ipairs(session.Data.Events) do
											if other == event then session.Selection.Index = index end
										end
									end
								end

								h.restructured(true)
							end,
							OnKeyAdd = |row, time|-> do
								local selection = clip_edit.AddKey(session.Data, rows[row], time)

								if selection then
									h.restructured(true)
									h.select(selection)
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

function effects_editor.Create()
	local root

	root = react.Mount(EffectsEditor{OnClose = ||->root:Unmount()}, Panel.World)
	return root:GetEntity()
end

return effects_editor
