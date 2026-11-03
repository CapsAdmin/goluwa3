local T = import("test/environment.lua")
local data_schema = import("lua/data_schema.lua")
local data_history = import("lua/data_history.lua")

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

	local function find_text(items, text)
		for _, item in ipairs(items) do
			if item.Text == text then return item end

			local found = item.Children and find_text(item.Children, text)

			if found then return found end
		end
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
	T(find_text(shader_items, "Update").Type)["=="]("code")
	T(find_text(shader_items, "Update").CodeLanguage)["=="]("glsl")
	T(find_text(shader_items, "Update").GetStatus())["=="](nil)
	T(find_text(shader_items, "Sprite").Type)["=="]("string")
	effects_editor.Load(session, "gpu emitters", "hit_force")
	local force_items = effects_editor.BuildItems(session, handlers)
	T(find_text(force_items, "count").Value)["=="](24)
	local strength = find_text(force_items, "Strength")
	T(strength.Value)["=="](3)
	T(strength.Max)["=="](12)
	strength.OnChange(nil, 8)
	T(session.Inputs.Strength)["=="](8)
	T(find_text(effects_editor.BuildItems(session, handlers), "Strength").Value)["=="](8)
	session.Data.Inputs.Strength.Targets[1][2] = "nope"
	T(effects_editor.Apply(session))["=="](false)
	session.Data.Inputs.Strength.Targets[1][2] = "set"
	T(effects_editor.Apply(session))["=="](true)
	effects_editor.Load(session, "gpu emitters", "melee_sparks")
	T(find_text(effects_editor.BuildItems(session, handlers), "Tint").Type)["=="]("color")
	local emitter_items = effects_editor.BuildItems(session, handlers)
	T(find_text(emitter_items, "RatePerMeter").Max)["=="](10000)
	T(find_text(emitter_items, "Shape").Type)["=="]("enum")
	T(find_text(emitter_items, "ColorStart").Type)["=="]("color")
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
	T(properties.ColorStart.b)["=="](1)
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
