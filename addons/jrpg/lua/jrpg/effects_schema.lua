local clips = import("goluwa/render3d/clips.lua")
local easing = import("goluwa/math/easing.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local effects_schema = {}
local EXPRESSION = "a number, the name of a track or param, or an expression: p.<param>, v.<track>, v.time, math functions"
local LAYER_TYPES = {"sprite", "quad", "orb", "gpu_trail", "custom"}

local function sorted_names(source)
	local names = {}

	for name in pairs(source) do
		names[#names + 1] = name
	end

	table.sort(names)
	return names
end

local refs = {
	status = ||->status_effects.Names,
	damage = ||-> do
		local names = {}

		for _, name in ipairs(damage_types.Names) do
			names[#names + 1] = name
		end

		for _, name in ipairs(damage_types.Base) do
			names[#names + 1] = name
		end

		return names
	end,
	overlay = ||->surface_overlays.GetKindNames(),
	texture = ||->vfx.GetTextureNames(),
	flipbook = ||->vfx.GetFlipbookNames(),
	script = ||->sorted_names(clips.Scripts),
	easing = ||->sorted_names(easing),
	layer_type = LAYER_TYPES,
}
effects_schema.Refs = refs

local function expression(text)
	return {Description = text or EXPRESSION}
end

local COMMON = {
	Glow = {Min = 0, Max = 4},
	Light = {Min = 0, Max = 4},
	Flicker = {Min = 0, Max = 1},
	Overlay = {Ref = "overlay"},
	Rate = {Min = 0.02, Max = 5},
	Decay = {Min = 0, Max = 1},
	Max = {Min = 0.1, Max = 2},
	Spread = {Min = 0, Max = 180},
	SizeStart = {Min = 0, Max = 2},
	SizeEnd = {Min = 0, Max = 2},
	Drag = {Min = 0, Max = 10},
	["Apply.Remove"] = {Ref = "status"},
	["Apply.Add"] = {Ref = "status"},
	["Apply.Max"] = {Ref = "status"},
	["Attributes[]"] = {Ref = "damage"},
	["Think.Type"] = {Options = {"magic", "slash", "generic"}},
}

local function merge(base, extra)
	local out = table.shallow_copy(base)

	for key, value in pairs(extra) do
		out[key] = value
	end

	return out
end

local function label_layer(layer)
	return tostring(layer.Type or "custom") .. " " .. tostring(layer.Texture or layer.Script or "")
end

local function label_event(event)
	return tostring(event.Call or event.Burst or event.Debris or event.Flash and "flash" or "event")
end

local schemas = {
	["damage types"] = {
		Refs = refs,
		Labels = {Apply = function(action)
			return tostring(action.Remove or action.Add or action.Max or action.HealAttacker and "heal attacker")
		end},
		Fields = merge(
			COMMON,
			{
				Apply = {Template = {Add = "poison", Divisor = 100}},
				Knockback = {Min = 0, Max = 20},
			}
		),
		Root = {
			Keys = {
				Apply = {{Add = "poison", Divisor = 100}},
				Debris = {Count = 8, Material = {}, Emitter = {}},
				Knockback = 2,
				Heals = true,
				Physical = true,
			},
		},
	},
	["status effects"] = {
		Refs = refs,
		Fields = merge(
			COMMON,
			{
				Solid = {Min = 0, Max = 1},
				SlowSlope = {Min = 0, Max = 2},
				AnimationSlope = {Min = 0, Max = 2},
				AttackFail = {Min = 0, Max = 2},
				Think = {
					Keys = {
						Gate = 0.8,
						Spread = {Above = 0.75, Radius = 3},
						Force = {Scale = 3, Min = {-1, 0, -1}, Max = {1, 1, 1}},
						DrainMana = 4,
					},
				},
				Attributes = {},
			}
		),
		Root = {
			Keys = {
				Think = {
					Damage = {Base = 1, PerAmount = 3},
					Type = "magic",
					Attributes = {"fire"},
				},
				Solid = 0.75,
				SlowSlope = 1,
				AnimationSlope = 0.8,
				AttackFail = 0.5,
				Wobble = {{3, 1}},
				Orbit = true,
			},
		},
	},
	clips = {
		Refs = refs,
		Labels = {Layers = label_layer, Events = label_event},
		Fields = {
			Follow = {Ref = "script"},
			["Layers.Type"] = {Ref = "layer_type"},
			["Layers.Texture"] = {Ref = "texture"},
			["Layers.Script"] = {Ref = "script"},
			["Events.Call"] = {Ref = "script"},
			["Events.1"] = {Text = "time", Min = 0, Max = 1},
			["Layers.Alpha"] = expression(),
			["Layers.Radius"] = expression(),
			["Layers.Brightness"] = expression(),
			["Layers.Scale"] = expression(),
			["Layers.Yaw"] = expression(),
			["Layers.Size"] = expression(),
			["Layers.Flicker"] = expression(),
			["Layers.LensScale"] = expression(),
			["Layers.Strength"] = expression(),
			["Layers.Offset"] = expression("three comma separated expressions, for example 1, p.height, 3"),
			["Layers.Tint"] = {Min = 0, Max = 1},
			Layers = {
				Template = function(last)
					return last and table.copy(last) or {Type = "sprite", Texture = "glow", Radius = 1, Brightness = 1, Alpha = 1}
				end,
			},
			Events = {Template = {0, Flash = true, Lumen = 10, Time = 0.3}},
			Tracks = {NewKey = {Name = "track", Template = {{0, 0}, {1, 1}}}},
		},
		Root = {
			Keys = {
				Duration = 1,
				Loop = true,
				EndWithEntity = true,
				Follow = "entity",
				Tracks = {},
				Events = {},
				Layers = {},
			},
		},
	},
	overlays = {
		Refs = refs,
		Fields = {
			FadeIn = {Min = 0, Max = 5},
			FadeOut = {Min = 0, Max = 5},
			Intensity = {Min = 0, Max = 8},
			Scale = {Min = 0.05, Max = 8},
			Speed = {Min = 0, Max = 8},
			Daylight = {Min = 0, Max = 4},
		},
		Root = {},
	},
	["weapon bursts"] = {Refs = refs, Fields = {Spread = {Min = 0, Max = 180}}, Root = {}},
	["grenade puffs"] = {
		Refs = refs,
		Labels = {Styles = function(style)
			return tostring(style.Flipbook) .. " x" .. tostring(style.Count)
		end},
		Fields = {
			["Styles.Flipbook"] = {Ref = "flipbook"},
			Styles = {Template = function(last)
				return table.copy(last)
			end},
		},
		Root = {},
	},
}
effects_schema.Schemas = schemas
return effects_schema
