local T = import("test/environment.lua")
local data_schema = import("lua/data_schema.lua")
local data_history = import("lua/data_history.lua")

T.Test3D("the effects editor loads, edits, undoes and checks every effect definition", function()
	local effects_editor = import("lua/jrpg/effects_editor.lua")
	local clips = import("goluwa/render3d/clips.lua")
	local session = {LoadId = 0, SelectId = 0}
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
	local style_row = find_text(frozen_items, "Style")
	T(style_row.Type)["=="]("enum")
	T(style_row.RowButtons ~= nil)["=="](true)
	T(find_text(frozen_items, "Sway").Max)["=="](3)
	T(find_text(frozen_items, "Flake").Type)["=="]("enum")
	style_row.OnChange(nil, "glow")
	T(session.Data.Particles.Style)["=="]("glow")
	T(session.Data.Particles.Params)["=="](nil)
	style_row.OnChange(nil, "snow")
	T(session.Data.Particles.Params.Sway)["=="](0.35)
	T(#effects_editor.GetProblems(session))["=="](0)
	effects_editor.Load(session, "particle styles", "snow")
	local style_items = effects_editor.BuildItems(session, handlers)
	T(find_text(style_items, "Update").Type)["=="]("code")
	T(find_text(style_items, "Update").CodeLanguage)["=="]("glsl")
	T(find_text(style_items, "Update").GetStatus())["=="](nil)
	T(find_text(style_items, "Sprite").Type)["=="]("string")
	effects_editor.Load(session, "emitters", "melee_sparks")
	local emitter_items = effects_editor.BuildItems(session, handlers)
	T(find_text(emitter_items, "RatePerMeter").Max)["=="](10000)
	T(find_text(emitter_items, "Shape").Type)["=="]("enum")
	T(find_text(emitter_items, "ColorStart").Type)["=="]("color")
	session.Data.RatePerMeter = 40
	T(effects_editor.Apply(session))["=="](true)
	T(import("lua/emitters.lua").Get("melee_sparks").RatePerMeter)["=="](40)
	effects_editor.Load(session, "emitters", "melee_sparks")
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
	T(vfx.HasBurst("hit_position"))["=="](true)
	effects_stage.PlayEmitter(stage, "hit_position")
	T(stage.Sweep)["=="](nil)
	effects_stage.PlayEmitter(stage, "melee_sparks")
	T(stage.Sweep ~= nil)["=="](true)
	local entity = stage.Sweep.Entity
	local start = entity.transform:GetPosition():Copy()
	stage.Sweep.Start = stage.Sweep.Start - 0.5
	effects_stage.Update(stage)
	T((entity.transform:GetPosition() - start):GetLength() > 1)["=="](true)
	stage.Sweep.Start = stage.Sweep.Start - 1
	effects_stage.Update(stage)
	T(stage.Sweep)["=="](nil)

	for _, child in ipairs(Entity.World:GetChildrenList()) do
		child:Remove()
	end
end)
