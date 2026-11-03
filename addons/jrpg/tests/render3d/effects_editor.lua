local T = import("test/environment.lua")
local data_schema = import("lua/data_schema.lua")
local data_history = import("lua/data_history.lua")
local Color = import("goluwa/structs/color.lua")

T.Test3D("the effects editor loads, edits, undoes and checks every effect definition", function()
	local effects_editor = import("lua/jrpg/effects_editor.lua")
	local clips = import("goluwa/render3d/clips.lua")
	local session = {LoadId = 0, SelectId = 0, Count = 24}
	local changes = 0
	local handlers = {
		changed = function()
			changes = changes + 1
		end,
		restructured = function()
			changes = changes + 1
		end,
		open = function() end,
	}

	for _, category_name in ipairs(effects_editor.CategoryNames) do
		local category = effects_editor.Categories[category_name]

		for _, name in ipairs(category.GetNames()) do
			effects_editor.Load(session, category_name, name)
			T(#effects_editor.BuildItems(session, handlers) > 0)["=="](true)
			T(#session.Problems)["=="](0)

			if not category.ReadOnly then T(effects_editor.Apply(session))["=="](true) end
		end
	end

	local function check_defaults(items, allowed)
		for _, item in ipairs(items) do
			if item.Type and item.Default ~= nil then T(allowed)["=="](true) end

			if item.Children then check_defaults(item.Children, allowed) end
		end
	end

	local function find_text(items, text)
		for _, item in ipairs(items) do
			if item.Text == text then return item end

			local found = item.Children and find_text(item.Children, text)

			if found then return found end
		end
	end

	for _, case in ipairs{
		{"damage types", "holy"},
		{"status effects", "lightning"},
		{"clips", "impact"},
		{"particle shaders", "puff"},
	} do
		effects_editor.Load(session, case[1], case[2])
		check_defaults(effects_editor.BuildItems(session, handlers), false)
	end

	effects_editor.Load(session, "status effects", "frozen")
	local frozen_items = effects_editor.BuildItems(session, handlers)
	local emitter_row = find_text(frozen_items, "Emitter")
	T(emitter_row.Type)["=="]("enum")
	T(emitter_row.RowButtons ~= nil)["=="](true)
	T(session.Data.Particles.Emitter)["=="]("frozen_snow")
	effects_editor.Open(session, "gpu emitters", "frozen_snow")
	T(session.Category)["=="]("gpu emitters")
	effects_editor.Back(session, 1)
	T(session.Name)["=="]("frozen")
	effects_editor.Load(session, "gpu emitters", "frozen_snow")
	local frozen_snow_items = effects_editor.BuildItems(session, handlers)
	local shader_row = find_text(frozen_snow_items, "Shader")
	T(shader_row.Type)["=="]("enum")
	T(shader_row.RowButtons ~= nil)["=="](true)
	T(find_text(frozen_snow_items, "Sway").Max)["=="](3)
	T(find_text(frozen_snow_items, "Flake").Type)["=="]("enum")
	shader_row.OnChange(nil, "glow")
	T(session.Data.Shader)["=="]("glow")
	T(session.Data.ShaderParams)["=="](nil)
	shader_row.OnChange(nil, "snow")
	T(session.Data.ShaderParams.Sway)["=="](0.35)
	T(#effects_editor.GetProblems(session))["=="](0)
	effects_editor.Load(session, "status effects", "poison")
	session.Data.Particles.Shader = "snow"
	session.Data.Particles.ShaderParams = {Sway = 0.2}
	T(find_text(effects_editor.BuildItems(session, handlers), "Sway").Max)["=="](3)
	session.Data.Particles.Emitter = "nope"
	T(#effects_editor.GetProblems(session))["=="](1)
	effects_editor.Load(session, "particle shaders", "snow")
	local shader_items = effects_editor.BuildItems(session, handlers)
	T(find_text(shader_items, "Source").Type)["=="]("code")
	T(find_text(shader_items, "Source").CodeLanguage)["=="]("glsl")
	T(find_text(shader_items, "Source").GetStatus())["=="](nil)
	T(find_text(shader_items, "Sprite").Type)["=="]("string")
	local good_source = session.Data.Source
	session.Data.Source = "float helper() { return 1.0; }"
	T(effects_editor.Apply(session))["=="](false)
	T(session.Status:find("defines none of the functions", 1, true) ~= nil)["=="](true)
	session.Data.Source = good_source
	T(effects_editor.Apply(session))["=="](true)
	effects_editor.Load(session, "gpu emitters", "hit_force")
	local force_items = effects_editor.BuildTestInputs(session)
	T(find_text(force_items, "count").Value)["=="](24)
	local strength = find_text(force_items, "Strength")
	T(strength.Value)["=="](3)
	T(strength.Max)["=="](12)
	strength.OnChange(nil, 8)
	T(session.Inputs.Strength)["=="](8)
	T(find_text(effects_editor.BuildTestInputs(session), "Strength").Value)["=="](8)
	session.Data.Inputs.Strength.Targets[1][2] = "nope"
	T(effects_editor.Apply(session))["=="](false)
	session.Data.Inputs.Strength.Targets[1][2] = "set"
	T(effects_editor.Apply(session))["=="](true)
	effects_editor.Load(session, "gpu emitters", "melee_sparks")
	T(find_text(effects_editor.BuildTestInputs(session), "Tint").Type)["=="]("color")
	local range_items = effects_editor.BuildItems(session, handlers)
	local size = find_text(range_items, "Size")
	T(size.Type)["=="]("curve")
	T(size.Kind)["=="]("scalar")
	T(size.ContextActions[1].Text)["=="]("Random")
	T(size.ContextActions[1].Checked)["=="](true)
	T(size.ContextActions[2].Text)["=="]("Curve over life")
	T(size.ContextActions[2].Checked)["=="](true)
	T(size.ContextActions[3].Text)["=="]("Reset to the default")
	local drag = find_text(range_items, "Drag")
	T(drag.Type)["=="]("number")
	T(drag.Value)["=="](12)
	T(drag.Default)["=="](0.1)
	T(drag.RowButtons)["=="](nil)
	T(drag.ContextActions[1].Text)["=="]("Random")
	T(drag.ContextActions[1].Checked)["=="](false)
	T(drag.ContextActions[2])["=="](nil)
	drag.ContextActions[1].OnClick()
	T(session.Data.Drag[1])["=="](12)
	T(session.Data.Drag[2])["=="](12)
	T(effects_editor.Apply(session))["=="](true)
	T(import("lua/emitters.lua").Get("melee_sparks").Drag[2])["=="](12)
	T(session.Data.Collision)["=="](nil)
	T(session.Data.Color)["=="](nil)
	T(import("lua/emitters.lua").Get("melee_sparks", {Tint = Color(0.2, 0.4, 0.6, 1)}).Color.Keys[2][2].a)["=="](0)
	effects_editor.Load(session, "gpu emitters", "melee_sparks")
	local grouped = effects_editor.BuildItems(session, handlers)
	local max_particles = find_text(grouped, "MaxParticles")
	T(max_particles.Type)["=="]("integer")
	T(max_particles.Precision)["=="](0)
	T(find_text(grouped, "Rate").Type)["=="]("number")
	session.Data.MaxParticles = 100.5
	T(effects_editor.Apply(session))["=="](false)
	T(session.Status:find("MaxParticles: expected an integer", 1, true) ~= nil)["=="](true)
	T(import("lua/emitters.lua").Get("melee_sparks").MaxParticles)["=="](512)
	session.Data.MaxParticles = 512
	T(effects_editor.Apply(session))["=="](true)
	T(session.Status)["=="]("")
	effects_editor.Load(session, "gpu emitters", "melee_sparks")
	grouped = effects_editor.BuildItems(session, handlers)

	for _, group in ipairs{"Emission", "Shape", "Motion", "Look", "Collision"} do
		T(find_text(grouped, group) ~= nil)["=="](true)
	end

	local rate = find_text(grouped, "Rate")
	T(rate.Value)["=="](0)
	T(rate.RowButtons)["=="](nil)
	T(rate.Default)["=="](50)
	local spread = find_text(grouped, "Spread")
	T(spread.Value)["=="](80)
	local fizzle_start = find_text(grouped, "FizzleStart")
	T(fizzle_start.Value)["=="](0.6)
	T(fizzle_start.Default)["=="](0.6)
	T(fizzle_start.RowButtons)["=="](nil)
	T(session.Data.FizzleStart)["=="](nil)
	fizzle_start.OnChange(nil, 0.9)
	T(session.Data.FizzleStart)["=="](0.9)
	fizzle_start.OnChange(nil, 0.6)
	T(effects_editor.Apply(session))["=="](true)
	T(session.Data.FizzleStart)["=="](nil)
	local drag_row = find_text(grouped, "Drag (min, max)")
	T(drag_row.ContextActions[2].Text)["=="]("Reset to the default")
	drag_row.ContextActions[2].OnClick()
	T(session.Data.Drag)["=="](nil)
	T(find_text(effects_editor.BuildItems(session, handlers), "Drag").Value)["=="](0.1)
	effects_editor.Load(session, "gpu emitters", "melee_sparks")
	local emitter_items = effects_editor.BuildItems(session, handlers)
	T(find_text(emitter_items, "RatePerMeter").Max)["=="](10000)
	T(find_text(find_text(emitter_items, "Shape").Children, "Shape").Type)["=="]("enum")
	T(find_text(emitter_items, "Color").Type)["=="]("curve")
	T(find_text(emitter_items, "Color").Kind)["=="]("color")
	session.Data.RatePerMeter = 40
	T(effects_editor.Apply(session))["=="](true)
	T(import("lua/emitters.lua").Get("melee_sparks").RatePerMeter)["=="](40)
	effects_editor.Load(session, "gpu emitters", "melee_sparks")
	T(session.Data.RatePerMeter)["=="](40)
	import("lua/emitters.lua").Reload("melee_sparks")
	T(import("lua/emitters.lua").Get("melee_sparks").RatePerMeter)["=="](20)
	effects_editor.Load(session, "damage types", "fire")
	local overlay = effects_editor.Categories.overlays.GetNames()[1]
	effects_editor.Open(session, "overlays", overlay)
	effects_editor.Open(session, "clips", "impact")
	T(#session.Trail)["=="](2)
	T(table.concat(effects_editor.GetTrailLabels(session), ","))["=="]("fire," .. overlay .. ",impact")
	effects_editor.Back(session, 2)
	T(session.Category)["=="]("overlays")
	T(session.Name)["=="](overlay)
	T(#session.Trail)["=="](1)
	effects_editor.Back(session, 1)
	T(session.Name)["=="]("fire")
	T(#session.Trail)["=="](0)
	T(#effects_editor.GetTrailLabels(session))["=="](0)
	effects_editor.Load(session, "overlays", "status_lightning")
	T(session.Data.Params[1].Name)["=="]("Emissive")
	T(session.Data.Params[1].Default)["=="](7)
	T(session.Data.Params[3].Max)["=="](8)
	T(session.Data.Source:find("strike", 1, true) ~= nil)["=="](true)
	T(#effects_editor.GetProblems(session))["=="](0)
	effects_editor.Load(session, "damage types", "fire")
	session.Data.Apply[2].Add = "nope"
	T(#effects_editor.GetProblems(session))["=="](1)
	session.Data.Apply[2].Add = "fire"
	effects_editor.Load(session, "clips", "impact")
	session.Data.Layers[1].Alpha = "p.cut and and 0"
	T(effects_editor.Apply(session))["=="](false)
	T(session.Status ~= "")["=="](true)
	session.Data.Layers[1].Alpha = "p.cut and 0 or v.fade"
	T(effects_editor.Apply(session))["=="](true)
	effects_editor.Commit(session, true)
	session.Data.Duration = 0.9
	effects_editor.Commit(session, true)
	T(clips.Source.jrpg_impact.Duration)["=="](0.9)
	effects_editor.Step(session, false)
	T(session.Data.Duration)["=="](0.45)
	T(clips.Source.jrpg_impact.Duration)["=="](0.45)
	effects_editor.Step(session, true)
	T(session.Data.Duration)["=="](0.9)
	effects_editor.Load(session, "clips", "impact")
	import("lua/jrpg/effects.lua").ReloadClip("impact")
	T(clips.Source.jrpg_impact.Duration)["=="](0.45)
end)

T.Test3D("the effects stage bursts one shot emitters and sweeps path emitters", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Entity = import("goluwa/entities/entity.lua")
	local vfx = import("goluwa/render3d/vfx.lua")
	local effects_stage = import("lua/jrpg/effects_stage.lua")
	local effects_drive = import("lua/jrpg/effects_drive.lua")
	local Color = import("goluwa/structs/color.lua")
	local weapon_effects = import("lua/weapon_effects.lua")
	local marker = Entity.New{Name = "emitter_test_marker", transform = {Position = Vec3(0, 1, 0)}}
	marker:SetTransient(true)
	local stage = {
		Marker = marker,
		Chest = Vec3(0, 1, 0),
		Normal = Vec3(0, 1, 0),
		Toward = Vec3(0, 0, 1),
	}
	weapon_effects.Init()
	effects_stage.PlayEmitter(stage, "hit_position", {}, 24)
	T(stage.Drive)["=="](nil)
	effects_stage.PlayEmitter(stage, "hit_force", {Strength = 5}, 10)
	T(vfx.HasBurst(import("lua/emitters.lua").GetBurstKey("hit_force", {Strength = 5})))["=="](true)
	effects_stage.PlayEmitter(stage, "melee_sparks", {}, 24)
	T(stage.Drive ~= nil)["=="](true)
	local state = stage.Drive.State
	local start = state.Position:Copy()
	state.Start = state.Start - 0.5
	effects_stage.Update(stage)
	T((state.Position - start):GetLength() > 1)["=="](true)
	state.Start = state.Start - 1
	effects_stage.Update(stage)
	T(stage.Drive)["=="](nil)
	effects_stage.PlayEmitter(stage, "melee_sparks", {}, 24, {Type = "sweep", Length = 6, Time = 2})
	T(stage.Drive.State.Spec.Length)["=="](6)
	effects_stage.StopDrive(stage)
	import("lua/jrpg/effects.lua")
	local params = {color = Color(1, 0.5, 0.2, 1), base = Vec3(), tip = Vec3(), position = Vec3()}
	local clip = effects_stage.PlayClip(stage, "jrpg_blade_trail", params, effects_drive.Defaults.blade, 0.2)
	local first_tip = params.tip:Copy()
	T((params.tip - params.base):GetLength() > 1)["=="](true)
	stage.Drive.State.Start = stage.Drive.State.Start - 0.25
	effects_stage.Update(stage)
	T((params.tip - first_tip):GetLength() > 0.5)["=="](true)
	T(clip.release_duration)["=="](nil)
	stage.Drive.State.Start = stage.Drive.State.Start - 1
	effects_stage.Update(stage)
	T(stage.Drive)["=="](nil)
	T(clip.release_duration)["=="](0.2)
	clip:Stop()
	local resolved = effects_stage.ResolveParams(
		stage,
		{
			entity = "$normal",
			color = {1, 0.5, 0.25},
			size = 2,
			list = {1, 2},
			ColorA = {0, 0, 1, 1},
		}
	)
	T(resolved.entity.y)["=="](1)
	T(resolved.color.g)["=="](0.5)
	T(resolved.color.a)["=="](1)
	T(resolved.ColorA.b)["=="](1)
	T(resolved.size)["=="](2)
	T(resolved.list[2])["=="](2)
	T(pcall(effects_stage.ResolveParams, stage, {x = "$nope"}))["=="](false)

	for _, child in ipairs(Entity.World:GetChildrenList()) do
		child:Remove()
	end
end)

T.Test3D("a particles block starts from the emitter it names and its own keys win", function()
	local effects = import("lua/jrpg/effects.lua")
	local status_effects = import("lua/jrpg/status_effects.lua")
	local emitters = import("lua/emitters.lua")
	local frozen = effects.GetParticles((status_effects.GetDefinition("frozen")))
	T(frozen.Emitter)["=="](nil)
	T(frozen.Shader)["=="]("snow")
	T(frozen.ShaderParams.Sway)["=="](0.35)
	T(frozen.Speed[2])["=="](emitters.Get("frozen_snow").Speed[2])
	local resolved = effects.GetParticles{
		ParticleBase = {Speed = {0.3, 1}, Spread = 180, Drag = 9},
		Particles = {Emitter = "frozen_snow", Speed = 0.5, ShaderParams = {Sway = 1}},
	}
	T(resolved.Speed)["=="](0.5)
	T(resolved.Spread)["=="](180)
	T(resolved.Drag)["=="](3)
	T(resolved.ShaderParams.Sway)["=="](1)
	T(resolved.ShaderParams.Tumble)["=="](1.5)
	T(emitters.Get("frozen_snow").ShaderParams.Sway)["=="](0.35)
	local plain = effects.GetParticles{Particles = {Drag = 2}}
	T(plain.Drag)["=="](2)
	T(plain.Spread)["=="](nil)
	local properties = effects.GetParticleProperties((status_effects.GetDefinition("frozen")))
	T(properties.Shader)["=="]("snow")
	T(properties.Color.Keys[1][2].b)["=="](1)
end)

T.Test3D("an effect's preview block sets the view, the duration and the play params", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Entity = import("goluwa/entities/entity.lua")
	local view_camera = import("lua/view_camera.lua")
	local effects_editor = import("lua/jrpg/effects_editor.lua")
	local effects_stage = import("lua/jrpg/effects_stage.lua")
	local marker = Entity.New{Name = "preview_test_marker", transform = {Position = Vec3(0, 1, 0)}}
	marker:SetTransient(true)
	local view = {
		SetPosition = function() end,
		SetRotation = function() end,
	}

	function view:SetExposureLock(lock)
		self.Lock = lock
	end

	local fly = {View = view}
	local session = {
		LoadId = 0,
		SelectId = 0,
		Count = 24,
		Stage = {Marker = marker, Chest = Vec3(0, 1, 0)},
		StageKind = "gizmo",
		Exposure = "dusk",
		Loop = false,
		View = view,
		Fly = fly,
	}
	effects_editor.Load(session, "gpu emitters", "hit_force")
	T(effects_editor.GetDuration(session))["=="](3)
	view_camera.Set(fly, Vec3(2, 2.5, 5), -10, 30)
	effects_editor.SaveView(session)
	local preview = session.Data.Preview
	T(preview.Stage)["=="]("gizmo")
	T(preview.Exposure)["=="]("dusk")
	T(preview.Loop)["=="](false)
	T(preview.View.Offset[1])["=="](2)
	T(preview.View.Offset[2])["=="](1.5)
	T(preview.View.Offset[3])["=="](5)
	T(math.abs(preview.View.Pitch + 10) < 0.01)["=="](true)
	T(math.abs(preview.View.Yaw - 30) < 0.01)["=="](true)
	T(#effects_editor.GetProblems(session))["=="](0)
	T(effects_editor.Apply(session))["=="](true)
	T(import("lua/emitters.lua").Get("hit_force").Preview)["=="](nil)
	preview.Duration = 7
	preview.Exposure = "night"
	preview.Loop = true
	T(effects_editor.GetDuration(session))["=="](7)
	view_camera.Set(fly, Vec3(9, 9, 9), 0, 0)
	effects_editor.ApplyPreview(session)
	local eye, pitch, yaw = view_camera.Get()
	T((eye - Vec3(2, 2.5, 5)):GetLength() < 0.01)["=="](true)
	T(math.abs(pitch + 10) < 0.01)["=="](true)
	T(math.abs(yaw - 30) < 0.01)["=="](true)
	T(session.Exposure)["=="]("night")
	T(view.Lock)["=="](effects_stage.Exposures.night)
	T(session.Loop)["=="](true)
	local stub = {
		Target = {health = 5, transform = {GetPosition = ||->Vec3(1, 2, 3)}},
		Chest = Vec3(),
		Ground = Vec3(),
		Normal = Vec3(0, 1, 0),
	}

	for _, name in ipairs(effects_editor.Categories.clips.GetNames()) do
		local clip_preview = effects_editor.Categories.clips.GetSource(name).Preview

		if clip_preview and clip_preview.Params then
			effects_stage.ResolveParams(stub, clip_preview.Params)
		end
	end

	marker:Remove()
end)

T.Test3D("play restarts what it started, stop ends it and an applied edit restarts after a pause", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Entity = import("goluwa/entities/entity.lua")
	local system = import("goluwa/system.lua")
	local effects_editor = import("lua/jrpg/effects_editor.lua")
	local stage = {Chest = Vec3(0, 1, 0), Normal = Vec3(0, 1, 0), Toward = Vec3(0, 0, 1)}
	local session = {
		LoadId = 0,
		SelectId = 0,
		Count = 24,
		AutoRestart = true,
		Loop = false,
		Stage = stage,
		StageKind = "gizmo",
	}
	local category = effects_editor.Categories["gpu emitters"]
	local original = category.Play
	local plays, stops = 0, 0
	category.Play = function()
		plays = plays + 1
		return function()
			stops = stops + 1
		end
	end
	effects_editor.Load(session, "gpu emitters", "hit_force")
	effects_editor.Play(session)
	T(plays)["=="](1)
	T(session.PlayStart ~= nil)["=="](true)
	effects_editor.Play(session)
	T(plays)["=="](2)
	T(stops)["=="](1)
	effects_editor.Stop(session)
	T(stops)["=="](2)
	T(session.PlayStart)["=="](nil)
	effects_editor.Stop(session)
	T(stops)["=="](2)
	session.Data.Drag = 5
	effects_editor.Commit(session, true)
	T(session.RestartAt ~= nil)["=="](true)
	local first = session.RestartAt
	effects_editor.Tick(session, first - 0.01)
	T(plays)["=="](2)
	session.Data.Drag = 6
	effects_editor.Commit(session, true)
	T(session.RestartAt >= first)["=="](true)
	effects_editor.Tick(session, session.RestartAt + 0.01)
	T(plays)["=="](3)
	T(session.RestartAt)["=="](nil)
	session.Data.Inputs.Strength.Targets[1][2] = "nope"
	effects_editor.Commit(session, true)
	T(session.RestartAt)["=="](nil)
	session.Data.Inputs.Strength.Targets[1][2] = "set_max"
	session.AutoRestart = false
	effects_editor.Commit(session, true)
	T(session.RestartAt)["=="](nil)
	session.AutoRestart = true
	effects_editor.Step(session, false)
	T(session.RestartAt)["=="](nil)
	effects_editor.Step(session, false)
	T(session.RestartAt ~= nil)["=="](true)
	effects_editor.Stop(session)
	T(session.RestartAt)["=="](nil)
	session.Loop = true
	effects_editor.Play(session)
	local played = plays
	effects_editor.Tick(session, system.GetElapsedTime() + 60)
	T(plays)["=="](played + 1)
	session.Loop = false
	effects_editor.Tick(session, system.GetElapsedTime() + 120)
	T(plays)["=="](played + 1)
	effects_editor.Stop(session)
	category.Play = original
	T(effects_editor.BuildTestInputs(session)[1].Text)["=="]("count")

	for _, child in ipairs(Entity.World:GetChildrenList()) do
		child:Remove()
	end
end)

T.Test3D("a particle shader is previewed on the emitter its preview block names", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Entity = import("goluwa/entities/entity.lua")
	local effects = import("lua/jrpg/effects.lua")
	local emitters = import("lua/emitters.lua")
	local library = import("lua/particle_shader_library.lua")
	local shapes = {puff = "sphere", glow = "point", sprite = "sphere", snow = "box"}

	for name, shape in pairs(shapes) do
		local preview = library.Files.Source[name].Preview
		T(preview ~= nil)["=="](true)
		T(not not table.has_value(emitters.Names, preview.Emitter))["=="](true)
		local emitter = effects.PlayParticleShader(Vec3(), name, preview).particle_emitter_gpu
		T(emitter:GetShader())["=="](name)
		T(emitter:GetShape())["=="](shape)
	end

	local puff = effects.PlayParticleShader(Vec3(), "puff", library.Files.Source.puff.Preview).particle_emitter_gpu
	T(puff:GetShaderParams().Grow)["=="](2)
	T(puff:GetShaderParams().Sprite)["=="]("fire")
	local tuned = effects.PlayParticleShader(
		Vec3(),
		"puff",
		{Emitter = "puff_preview", Offset = {0, 0, 0}, ShaderParams = {Grow = 3}}
	)
	T(tuned.particle_emitter_gpu:GetShaderParams().Grow)["=="](3)
	T(tuned.particle_emitter_gpu:GetShaderParams().Sprite)["=="]("fire")
	local fallback = effects.PlayParticleShader(Vec3(), "glow")
	T(fallback.particle_emitter_gpu:GetShape())["=="]("box")
	T(fallback.transform:GetPosition().y)["=="](1)

	for _, child in ipairs(Entity.World:GetChildrenList()) do
		child:Remove()
	end
end)

T.Test3D("the preview block offers the keys that apply to the category and an npc alone picks the npc stage", function()
	local effects_editor = import("lua/jrpg/effects_editor.lua")
	local session = {LoadId = 0, SelectId = 0, Count = 24}
	local handlers = {
		changed = function() end,
		restructured = function() end,
		open = function() end,
	}

	local function offered(category, name)
		effects_editor.Load(session, category, name)
		session.Data.Preview = {}
		local preview

		for _, item in ipairs(effects_editor.BuildItems(session, handlers)) do
			if item.Text == "Preview" then preview = item end
		end

		local out = {}

		for _, child in ipairs(preview.Children) do
			if child.Type == "add" then
				for _, entry in ipairs(child.Items) do
					out[entry.Text] = true
				end
			end
		end

		return out, preview
	end

	local clips, clip_preview = offered("clips", "impact")
	T(
		clips.Params and
			clips.Drive and
			clips.Release and
			clips.Npc and
			clips.Stage and
			clips.Camera
	)["=="](true)
	T(clips.Emitter == nil and clips.Offset == nil and clips.ShaderParams == nil)["=="](true)
	T(clip_preview.Description ~= nil)["=="](true)
	local emitters = offered("gpu emitters", "melee_sparks")
	T(emitters.Drive and emitters.Loop and emitters.View)["=="](true)
	T(emitters.Params == nil and emitters.Release == nil and emitters.Emitter == nil)["=="](true)
	local shaders = offered("particle shaders", "puff")
	T(shaders.Emitter and shaders.Offset and shaders.ShaderParams and shaders.Duration)["=="](true)
	T(shaders.Drive == nil and shaders.Params == nil and shaders.Release == nil)["=="](true)
	local damage = offered("damage types", "fire")
	T(damage.Stage and damage.Npc and damage.Exposure)["=="](true)
	T(damage.Drive == nil and damage.Params == nil and damage.Emitter == nil)["=="](true)
	local original = effects_editor.SetStage
	local calls = {}
	effects_editor.SetStage = function(_, kind, npc)
		calls[#calls + 1] = kind .. ":" .. tostring(npc)
	end
	session.StageKind, session.NpcName = "player", "citizen"
	session.Data.Preview = {Npc = "antlion_worker"}
	effects_editor.ApplyPreview(session)
	session.Data.Preview = {Stage = "npc", Npc = "antlion_worker"}
	effects_editor.ApplyPreview(session)
	session.StageKind, session.NpcName = "npc", "antlion_worker"
	effects_editor.ApplyPreview(session)
	session.Data.Preview = {Stage = "gizmo"}
	effects_editor.ApplyPreview(session)
	effects_editor.SetStage = original
	T(table.concat(calls, ","))["=="]("npc:antlion_worker,npc:antlion_worker,gizmo:antlion_worker")
end)

T.Test3D("the source particles category edits a converted pcf system without adding it to the emitter list", function()
	local effects_editor = import("lua/jrpg/effects_editor.lua")
	local emitters = import("lua/emitters.lua")
	local pcf = import("lua/pcf.lua")
	local system = {
		name = "test_fire",
		properties = {max_particles = 64, material = "particle\\fire_particle_1.vmt", radius = 5},
		operators = {
			emitters = {{name = "emit_continuously", ["emission_rate"] = 12}},
			initializers = {
				{name = "Lifetime Random", lifetime_min = 0.5, lifetime_max = 1.5},
				{name = "Mystery Operator"},
			},
		},
		children = {{name = "test_embers", delay = 0.5}},
	}
	system.file = "test_file"
	local embers = {
		name = "test_embers",
		file = "test_file",
		properties = {},
		operators = {},
		children = {},
	}
	local old_cache, old_lookup, old_by_name = pcf.names_cache, pcf.lookup, pcf.by_name
	pcf.names_cache = {"test_file/test_embers", "test_file/test_fire"}
	pcf.lookup = {["test_file/test_fire"] = system, ["test_file/test_embers"] = embers}
	pcf.by_name = {test_fire = "test_file/test_fire", test_embers = "test_file/test_embers"}
	local children = pcf.GetChildren("test_file/test_fire")
	T(#children)["=="](1)
	T(children[1].name)["=="]("test_file/test_embers")
	T(children[1].delay)["=="](0.5)
	local names_before = #emitters.Names
	local session = {LoadId = 0, SelectId = 0, Count = 24}
	effects_editor.Load(session, "source particles", "test_file/test_fire")
	T(session.Data.Rate)["=="](12)
	T(session.Data.ShaderParams.Sprite)["=="]("fire")
	T(session.Data.Lifetime[2])["=="](1.5)
	T(session.Notes:find("Mystery Operator", 1, true) ~= nil)["=="](true)
	T(session.Notes:find("test_embers", 1, true) ~= nil)["=="](true)
	session.Data.Shader = "sprite"
	session.Data.ShaderParams = {Sprite = "lua/emitters/hit_force.lua"}
	T(#effects_editor.GetProblems(session))["=="](0)
	session.Data.ShaderParams.Sprite = "nothing/here.vtf"
	T(#effects_editor.GetProblems(session))["=="](1)
	session.Data.Shader, session.Data.ShaderParams = nil, nil
	session.Data.Rate = 30
	T(effects_editor.Apply(session))["=="](true)
	T(emitters.Files.Source["source test_file/test_fire"].Rate)["=="](30)
	T(#emitters.Names)["=="](names_before)
	T(#effects_editor.ListSourceParticles("test_fire"))["=="](1)
	T(#effects_editor.ListSourceParticles("nothing_like_this"))["=="](0)
	T(effects_editor.SelectSourceParticle("test_fire"))["=="]("test_file/test_fire")
	T(effects_editor.LastCategory)["=="]("source particles")
	T(select(2, effects_editor.SelectSourceParticle("nothing_like_this")))["=="]("no source particle matches nothing_like_this")
	pcf.names_cache, pcf.lookup, pcf.by_name = old_cache, old_lookup, old_by_name
	effects_editor.LastCategory, effects_editor.LastName = "damage types", "fire"
end)

T.Test3D("source particles are only scanned once the source particles category is used", function()
	local effects_editor = import("lua/jrpg/effects_editor.lua")
	local pcf = import("lua/pcf.lua")
	local scans = 0
	local get_files = pcf.GetFiles
	local old_cache, old_lookup = pcf.names_cache, pcf.lookup
	pcf.names_cache, pcf.lookup = nil, nil
	pcf.GetFiles = function(...)
		scans = scans + 1
		return {}
	end
	local session = {LoadId = 0, SelectId = 0, Count = 24}

	for _, category in ipairs{"damage types", "status effects", "gpu emitters", "particle shaders"} do
		effects_editor.Load(session, category)
	end

	T(scans)["=="](0)
	effects_editor.Load(session, "source particles")
	T(scans)[">"](0)
	pcf.GetFiles = get_files
	pcf.names_cache, pcf.lookup = old_cache, old_lookup
	effects_editor.LastCategory, effects_editor.LastName = "damage types", "fire"
end)

T.Test3D("an overlay preview lasts until cleared and its fade slider holds the layers", function()
	local Vec2 = import("goluwa/structs/vec2.lua")
	local surface_overlay_preview = import("goluwa/render3d/surface_overlay_preview.lua")
	local effects_editor = import("lua/jrpg/effects_editor.lua")
	local session = {
		LoadId = 0,
		SelectId = 0,
		Count = 24,
		AutoRestart = true,
		Loop = true,
		Stage = {},
		StageKind = "gizmo",
	}
	local category = effects_editor.Categories.overlays
	local original = category.Play
	local handle = {active = true, removed = 0}

	function handle:IsActive()
		return self.active
	end

	function handle:SetFade(fade)
		self.fade = fade
	end

	function handle:GetFade()
		return self.fade or 0
	end

	function handle:Remove()
		self.removed = self.removed + 1
	end

	local plays = 0
	category.Play = function(_, _, s)
		plays = plays + 1
		s.OverlayHandles = {handle}
		return function()
			s.OverlayHandles = nil
		end
	end
	effects_editor.Load(session, "overlays", "status_lightning")
	T(category.Lasting)["=="](true)
	session.Status = ""
	effects_editor.RenderOverlayPreview(session)
	T(session.Status)["=="]("")
	T(effects_editor.OverlayPreviewTexture ~= nil)["=="](true)
	effects_editor.OverlayPreviewCanvas = Vec2(200.6, 120)
	effects_editor.RenderOverlayPreview(session)
	T(effects_editor.OverlayPreviewTexture:GetWidth())["=="](200 * surface_overlay_preview.SCALE)
	T(effects_editor.OverlayPreviewTexture:GetHeight())["=="](120 * surface_overlay_preview.SCALE)
	T(session.Status)["=="]("")
	effects_editor.OverlayPreviewCanvas = nil
	session.AutoRestart = false
	effects_editor.QueueRestart(session)
	T(session.RestartAt ~= nil)["=="](true)
	session.RestartAt = nil
	effects_editor.SetOverlayFade(session, 0.4)
	T(plays)["=="](1)
	T(handle.fade)["=="](0.4)
	T(session.PlayStart)["=="](nil)
	T(effects_editor.GetOverlayFade(session))["=="](0.4)
	effects_editor.SetOverlayFade(session, 0.6)
	T(plays)["=="](1)
	effects_editor.Tick(session, 1e6)
	T(plays)["=="](1)
	effects_editor.FadeOutOverlay(session)
	T(handle.removed)["=="](1)
	handle.active = false
	T(effects_editor.GetOverlayFade(session))["=="](0.6)
	effects_editor.SetOverlayFade(session, 0.1)
	T(plays)["=="](2)
	effects_editor.StartPreview(session)
	T(plays)["=="](3)
	effects_editor.Load(session, "gpu emitters", "hit_force")
	effects_editor.StartPreview(session)
	T(session.OverlayHandles)["=="](nil)
	T(plays)["=="](3)
	effects_editor.Load(session, "overlays", "status_lightning")
	effects_editor.StartPreview(session)
	T(plays)["=="](4)
	effects_editor.Stop(session)
	T(session.OverlayHandles)["=="](nil)
	T(effects_editor.GetOverlayFade(session))["=="](0)
	category.Play = original
end)

T.Test3D("the vfx textures category edits a texture and keeps the last good one when the glsl is wrong", function()
	local effects_editor = import("lua/jrpg/effects_editor.lua")
	local vfx = import("goluwa/render3d/vfx.lua")
	local session = {
		LoadId = 0,
		SelectId = 0,
		Count = 24,
		AutoRestart = true,
		Loop = true,
		Stage = {},
		StageKind = "gizmo",
	}
	T(table.has_value(effects_editor.CategoryNames, "vfx textures") and true or false)["=="](true)
	effects_editor.Load(session, "vfx textures", "fire")
	T(session.Data.Columns)["=="](8)
	T(session.Data.Source:find("flipbook_frame", 1, true) ~= nil)["=="](true)
	T(#effects_editor.GetProblems(session))["=="](0)
	T(effects_editor.GetTextureInfo("fire"))["=="]("8 x 8 frames of 256 px")
	T(effects_editor.GetPreviewTexture("fire", "color"))["=="](vfx.GetFlipbook("fire").Texture)
	T(#effects_editor.GetTexturePreviewViews("fire"))["=="](2)
	T(#effects_editor.GetTexturePreviewViews("smoke"))["=="](3)
	effects_editor.Load(session, "vfx textures", "glow")
	T(effects_editor.GetTextureInfo("glow"))["=="]("256 x 256")
	local source = session.Data.Source
	session.Data.Source = source .. "\nbroken_call(1);\n"
	T(effects_editor.Apply(session))["=="](false)
	T(session.Status:find("line", 1, true) ~= nil)["=="](true)
	session.Data.Source = source
	T(effects_editor.Apply(session))["=="](true)
	T(vfx.GetFileStatus("glow"))["=="](nil)
end)
