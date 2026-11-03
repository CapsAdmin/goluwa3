local list = import("goluwa/list.lua")
local clips = import("goluwa/render3d/clips.lua")
local easing = import("goluwa/math/easing.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local particle_style_library = import("lua/particle_style_library.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
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
	particle_style = ||->particle_style_library.Names,
	flipbook = ||->vfx.GetFlipbookNames(),
	sprite = ||->list.extend(vfx.GetFlipbookNames(), vfx.GetTextureNames()),
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
	["HitSounds[]"] = {Sound = true},
	Names = {Display = "chips"},
	Adjectives = {Display = "chips"},
	["Think.Type"] = {Options = {"magic", "slash", "generic"}},
	Particles = {Keys = {Style = "snow"}},
	["Particles.Style"] = {
		Ref = "particle_style",
		Restructure = true,
		OnSet = function(particles, name)
			local defaults = particle_style_library.GetDefaults(name)
			particles.Params = next(defaults) and defaults or nil
		end,
		Description = "how the particles are drawn and move beyond the common properties, see particle styles",
	},
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
				Wobble = {
					Display = "table",
					Columns = {{Text = "frequency", Key = 1, Min = 0}, {Text = "amplitude", Key = 2, Min = 0}},
					Template = {3, 1},
				},
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
			["Tracks.*"] = {
				Display = "table",
				Columns = {{Text = "time", Key = 1, Min = 0, Max = 1}, {Text = "value", Key = 2}},
				Template = function(last)
					return {math.min((last and last[1] or 0) + 0.1, 1), last and last[2] or 0}
				end,
			},
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
do
	local EXCLUDED = {Visible = true, Playing = true, Loop = true, Duration = true, Seed = true, StyleParams = true}
	local fields = {}
	local keys = {}

	for _, properties in ipairs{particle_emitter.common, particle_emitter.gpu} do
		for _, entry in ipairs(properties) do
			local name, default, check = entry[1], entry[2], entry[3]

			if check and check.validate then
				fields[name] = {Min = check.min, Max = check.max}
			elseif check then
				fields[name] = {Options = check}
			end

			if not EXCLUDED[name] then
				if type(default) == "cdata" and default.r then
					default = {default.r, default.g, default.b, default.a}
				elseif type(default) == "cdata" then
					default = {default.x, default.y, default.z}
				end

				keys[name] = default
			end
		end
	end

	fields.Style = {
		Ref = "particle_style",
		Restructure = true,
		OnSet = function(data, name)
			local defaults = particle_style_library.GetDefaults(name)
			data.StyleParams = next(defaults) and defaults or nil
		end,
		Description = "how the particles are drawn and move beyond the common properties, see particle styles",
	}
	fields.StyleParams = {}
	fields.ShapeSize = {Min = 0, Max = 100}
	schemas.emitters = {Refs = refs, Fields = fields, Root = {Keys = keys}}
end
local PARAM_TYPES = {"float", "int", "bool", "vec3", "color", "texture"}
local HOOK_DESCRIPTION = {
	Spawn = "glsl run once when a particle is born, after the common spawn: p is the particle, e the emitter, index, generation, and every param by name",
	Update = "glsl run every frame before drag and integration: p, e, index, dt, t (0 to 1 over the lifetime) and every param by name",
	Visibility = "glsl that returns a number multiplied into the particle's alpha: t, p, e and every param by name",
	Shade = "glsl run after the common shading, p.radiance is the color: t, p, e and every param by name",
}
local hook_fields = {}

for _, hook in ipairs{"Spawn", "Update", "Visibility", "Shade"} do
	hook_fields[hook] = {
		Code = "glsl",
		Description = HOOK_DESCRIPTION[hook],
		GetStatus = |data, options|->particle_style_library.GetStatus(options.Name),
	}
end

schemas["particle styles"] = {
	Refs = refs,
	Labels = {Params = |param|->tostring(param.Name) .. " (" .. tostring(param.Type) .. ")"},
	Fields = merge(
		hook_fields,
		{
			Sprite = {Description = "the name of the texture param drawn for every particle, leave it out to draw the glow capsules"},
			["Params.Type"] = {Options = PARAM_TYPES},
			["Params.Default"] = {Description = "a number, true or false, a vec3, a color (four numbers, the name should end with Color) or a texture name"},
			["Params.Group"] = {Options = {"Emission", "Shape", "Motion", "Look", "Collision"}},
			Params = {
				Template = function(last)
					return {Name = "Param" .. math.random(100, 999), Type = "float", Default = 0, Min = 0, Max = 1, Group = "Look"}
				end,
			},
		}
	),
	Root = {
		Keys = {
			Sprite = "Flake",
			Spawn = "",
			Update = "",
			Visibility = "return 1.0;",
			Shade = "",
		},
	},
}

function effects_schema.WithEmitterStyleParams(schema, data)
	if not data.Style then return schema end

	local fields = table.shallow_copy(schema.Fields)
	local keys = {}

	for _, param in ipairs(particle_style_library.GetParams(data.Style)) do
		local field = {Description = param.Description, Min = param.Min, Max = param.Max}

		if param.Type == "texture" then field.Ref = "sprite" end

		fields["StyleParams." .. param.Name] = field
		keys[param.Name] = table.copy(param.Default)
	end

	fields.StyleParams = {Keys = keys}
	local out = table.shallow_copy(schema)
	out.Fields = fields
	return out
end

function effects_schema.WithStyleParams(schema, data)
	local style = data.Particles and data.Particles.Style

	if not style then return schema end

	local fields = table.shallow_copy(schema.Fields)
	local keys = {}

	for _, param in ipairs(particle_style_library.GetParams(style)) do
		local field = {Description = param.Description, Min = param.Min, Max = param.Max}

		if param.Type == "texture" then field.Ref = "sprite" end

		fields["Params." .. param.Name] = field
		keys[param.Name] = table.copy(param.Default)
	end

	fields.Params = {Keys = keys}
	local out = table.shallow_copy(schema)
	out.Fields = fields
	return out
end

effects_schema.Schemas = schemas
return effects_schema
