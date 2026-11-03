local list = import("goluwa/list.lua")
local clips = import("goluwa/render3d/clips.lua")
local easing = import("goluwa/math/easing.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local status_effects = import("lua/jrpg/status_effects.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local vfx = import("goluwa/render3d/vfx.lua")
local particle_shader_library = import("lua/particle_shader_library.lua")
local emitters = import("lua/emitters.lua")
local npcs = import("lua/npcs.lua")
local effects_stage = import("lua/jrpg/effects_stage.lua")
local effects_drive = import("lua/jrpg/effects_drive.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
local effects_schema = {}
local EXPRESSION = "a number, the name of a track or param, or an expression: p.<param>, v.<track>, v.time, math functions"
local LAYER_TYPES = {"sprite", "quad", "orb", "gpu_trail", "emitter", "slash", "custom"}

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
	particle_shader = ||->particle_shader_library.Names,
	emitter = ||->emitters.Names,
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
	Size = {Min = 0, Max = 2, Band = "scalar"},
	Drag = {Min = 0, Max = 10, Range = true},
	Speed = {Min = 0, Max = 100, Range = true},
	Lifetime = {Min = 0.01, Max = 60, Range = true},
	GravityScale = {Min = -5, Max = 5, Range = true},
	["Apply.Remove"] = {Ref = "status"},
	["Apply.Add"] = {Ref = "status"},
	["Apply.Max"] = {Ref = "status"},
	["Attributes[]"] = {Ref = "damage"},
	["HitSounds[]"] = {Sound = true},
	Names = {Display = "chips"},
	Adjectives = {Display = "chips"},
	["Think.Type"] = {Options = {"magic", "slash", "generic"}},
	Particles = {Keys = {Emitter = "hit_position", Shader = "snow"}},
	["Particles.Emitter"] = {
		Ref = "emitter",
		Description = "start from this gpu emitter, the keys written here replace its values",
	},
	["Particles.Shader"] = {
		Ref = "particle_shader",
		Restructure = true,
		OnSet = function(particles, name)
			local defaults = particle_shader_library.GetDefaults(name)
			particles.ShaderParams = next(defaults) and defaults or nil
		end,
		Description = "how the particles are drawn and move beyond the common properties, see particle shaders",
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
			["Layers.Emitter"] = {Ref = "emitter", Description = "a gpu emitter file by name, or write the properties inline"},
			["Events.Emitter"] = {Ref = "emitter", Description = "a gpu emitter file by name, or write the properties inline"},
			["Layers.Overlay"] = {Ref = "overlay"},
			["Layers.At"] = {Description = "the param holding the point the emitter follows, position by default"},
			["Layers.Inputs"] = {Description = "emitter input name to the param that feeds it"},
			["Events.Inputs"] = {Description = "emitter input name to the param that feeds it"},
			["Events.When"] = {Description = "only fire when this param is set"},
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
		Labels = {Params = |param|->tostring(param.Name)},
		Fields = {
			FadeIn = {Min = 0, Max = 5},
			FadeOut = {Min = 0, Max = 5},
			Intensity = {Min = 0, Max = 8},
			Scale = {Min = 0.05, Max = 8},
			Speed = {Min = 0, Max = 8},
			Daylight = {Min = 0, Max = 4},
			Source = {
				Code = "glsl",
				Description = OVERLAY_SOURCE_DESCRIPTION,
				GetStatus = |data, options|->surface_overlays.GetStatus(options.Name),
			},
			Params = {
				Description = "up to four numbers the glsl reads by name, each a config key for surface_overlays.Add",
				Template = function(last)
					return {Name = "Param" .. math.random(100, 999), Default = 0, Min = 0, Max = 1}
				end,
			},
		},
		Root = {},
	},
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
	local function to_data(value)
		if type(value) == "cdata" and value.r then
			return {value.r, value.g, value.b, value.a}
		elseif type(value) == "cdata" then
			return {value.x, value.y, value.z}
		elseif type(value) == "table" then
			local copy = {}

			for key, child in pairs(value) do
				copy[key] = to_data(child)
			end

			return copy
		end

		return value
	end

	local EXCLUDED = {Visible = true, Playing = true, Loop = true, Duration = true, Seed = true, ShaderParams = true}
	local GROUP_ORDER = {"Emission", "Shape", "Motion", "Look", "Collision"}
	local fields = {}
	local defaults = {}
	local members = {}
	local input_targets = {}

	for _, properties in ipairs{particle_emitter.common, particle_emitter.gpu} do
		for _, entry in ipairs(properties) do
			local name, default, check = entry[1], entry[2], entry[3]

			if check and check.validate then
				fields[name] = {
					Min = check.min,
					Max = check.max,
					Range = entry[5] == "range" or nil,
					Band = entry[5] == "band" and "scalar" or entry[5] == "color_band" and "color" or nil,
					Integer = check.validate == "integer" or nil,
				}
			elseif check then
				fields[name] = {Options = check}
			end

			if not EXCLUDED[name] then
				if
					type(default) == "number" or
					type(default) == "cdata" and
					default.r or
					entry[5] == "color_band"
				then
					input_targets[#input_targets + 1] = name
				end

				default = to_data(default)

				defaults[name] = default
				members[entry[4]] = members[entry[4]] or {}
				table.insert(members[entry[4]], name)
			end
		end
	end

	local groups = {}

	for _, group in ipairs(GROUP_ORDER) do
		groups[#groups + 1] = {Name = group, Keys = members[group]}
	end

	fields.Shader = {
		Ref = "particle_shader",
		Restructure = true,
		OnSet = function(data, name)
			local defaults = particle_shader_library.GetDefaults(name)
			data.ShaderParams = next(defaults) and defaults or nil
		end,
		Description = "how the particles are drawn and move beyond the common properties, see particle shaders",
	}
	fields.ShaderParams = {}
	fields.Inputs = {
		NewKey = {Name = "Input", Template = {Default = 1, Min = 0, Max = 10, Targets = {{"Speed", "set_max"}}}},
		Description = "values the caller passes by name when it plays this emitter (emitters.Burst, emitters.Get), each one sets, scales or adds to properties; a color input has DefaultColor instead of Default and only sets the color",
	}
	fields.Targets = {
		Display = "table",
		Columns = {
			{Text = "property", Key = 1, Options = input_targets},
			{Text = "mode", Key = 2, Options = {"set", "set_min", "set_max", "scale", "add", "set_first", "set_last"}},
		},
		Template = {"Speed", "set_max"},
	}
	fields.ShapeSize = {Min = 0, Max = 100}
	schemas["gpu emitters"] = {
		Refs = refs,
		Fields = fields,
		Root = {Keys = {Inputs = {}}, Defaults = defaults, Groups = groups},
	}
	schemas.clips.Fields = merge(fields, schemas.clips.Fields)
end
local OVERLAY_SOURCE_DESCRIPTION = "glsl, the body of a function that changes the surface under a layer. In scope: Surface s (albedo, emissive, roughness_alpha, metallic, ao, alpha, N, world_pos), SurfaceWeather w, OverlayLayer l (l.color_a, l.color_b, l.scale, l.speed, l.intensity), OverlayContext c (P and N for noise, V, height 0 to 1, ndv), float age, t (age times speed), grow (0 to 1 over FadeIn), outro (1 to 0 over FadeOut) and fade (both times intensity). Every param is a float named after it in snake case (RayCount is ray_count). Helpers: overlay_noise(c, scale), overlay_noise_at, overlay_voronoi, overlay_fbm, overlay_hash, overlay_hue, overlay_reveal, overlay_cover, overlay_bump, overlay_set_roughness, overlay_tilt"
local VFX_SOURCE_DESCRIPTION = "glsl. A texture is the body of a function that returns the vec4 color for uv (0 to 1, y down), for example `return vec4(vec3(v), v);`, or your own helpers and a full `vec4 shade(vec2 uv, vec3 _cube_dir)`. A flipbook (it has Columns) defines `vec4 flipbook_frame(vec2 local, float phase, float frame)`, and optionally `vec4 flipbook_normal(...)` with the same arguments for a normal map: local is 0 to 1 inside the frame, phase 0 to 2 pi over the frames. The noise helpers (value_noise3, pcg3d) are available"
local PARAM_TYPES = {"float", "int", "bool", "vec3", "color", "texture"}
local SOURCE_DESCRIPTION = "glsl with up to four functions, any you leave out do nothing (visibility counts as 1): void spawn(emitters_t e, uint index, uint generation, inout Particle p) runs once when a particle is born, after the common spawn; void update(emitters_t e, uint index, float dt, float t, inout Particle p) runs every frame before drag and integration, t is 0 to 1 over the lifetime; float visibility(emitters_t e, uint index, float t, Particle p) returns a number multiplied into the alpha; void shade(emitters_t e, uint index, float t, inout Particle p) runs after the common shading, p.radiance is the color. Every param is a name that reads e.params, so the functions need their e argument; helpers that read params take an emitters_t e too"
local SOURCE_TEMPLATE = [[
void update(emitters_t e, uint index, float dt, float t, inout Particle p) {
}
]]
local source_field = {
	Code = "glsl",
	Description = SOURCE_DESCRIPTION,
	GetStatus = |data, options|->particle_shader_library.GetStatus(options.Name),
}

schemas["vfx textures"] = {
	Refs = refs,
	Fields = {
		Size = {Min = 16, Max = 2048, Description = "width and height of a texture, 256 by default"},
		Columns = {Min = 1, Max = 16, Description = "frames across, makes this a flipbook"},
		Rows = {Min = 1, Max = 16},
		TileSize = {Min = 16, Max = 512, Description = "pixels of one frame"},
		MipLevels = {Min = 1, Max = 8},
		Source = {
			Code = "glsl",
			Description = VFX_SOURCE_DESCRIPTION,
			GetStatus = |data, options|->vfx.GetFileStatus(options.Name),
		},
	},
	Root = {Keys = {Size = 256, Columns = 8, Rows = 8, TileSize = 256, MipLevels = 3}},
}

schemas["particle shaders"] = {
	Refs = refs,
	Labels = {Params = |param|->tostring(param.Name) .. " (" .. tostring(param.Type) .. ")"},
	Fields = merge(
		{Source = source_field},
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
			Source = SOURCE_TEMPLATE,
		},
	},
}

function effects_schema.WithEmitterShaderParams(schema, data)
	if not data.Shader then return schema end

	local fields = table.shallow_copy(schema.Fields)
	local keys = {}

	for _, param in ipairs(particle_shader_library.GetParams(data.Shader)) do
		local field = {Description = param.Description, Min = param.Min, Max = param.Max}

		if param.Type == "texture" then field.Ref, field.Paths = "sprite", true end

		fields["ShaderParams." .. param.Name] = field
		keys[param.Name] = table.copy(param.Default)
	end

	fields.ShaderParams = {Keys = keys}
	local out = table.shallow_copy(schema)
	out.Fields = fields
	return out
end

function effects_schema.WithShaderParams(schema, data)
	local shader = data.Particles and data.Particles.Shader

	if not shader then return schema end

	local fields = table.shallow_copy(schema.Fields)
	local keys = {}

	for _, param in ipairs(particle_shader_library.GetParams(shader)) do
		local field = {Description = param.Description, Min = param.Min, Max = param.Max}

		if param.Type == "texture" then field.Ref, field.Paths = "sprite", true end

		fields["ShaderParams." .. param.Name] = field
		keys[param.Name] = table.copy(param.Default)
	end

	fields.ShaderParams = {Keys = keys}
	local out = table.shallow_copy(schema)
	out.Fields = fields
	return out
end

do
	local fields = {
		["Preview.Stage"] = {
			Options = effects_stage.Kinds,
			Description = "what the preview plays on: the player, a spawned npc, or a gizmo point whose position and up axis are the hit position and normal",
		},
		["Preview.Npc"] = {
			Options = ||->npcs.GetNames(),
			Description = "the npc the preview is played on; setting it previews on that npc even without a Stage",
		},
		["Preview.Camera"] = {
			Options = effects_stage.Cameras,
			Description = "a starting camera preset (front, side or high), View replaces it",
		},
		["Preview.Exposure"] = {Options = effects_stage.ExposureNames, Description = "the lighting the preview opens with"},
		["Preview.Release"] = {Min = 0.05, Max = 10, Description = "seconds a clip fades out after the drive ends"},
		["Preview.Duration"] = {Min = 0.1, Max = 30, Description = "seconds the play head runs, and when Loop plays it again"},
		["Preview.Loop"] = {Description = "play again when the play head ends"},
		["Preview.View"] = {Description = "the camera as an offset from the stage subject, set with Save view"},
		["Preview.Params"] = {
			Description = "values the clip is played with: numbers, strings, colors (keys named color), and the stage tokens $target, $target.health, $target.position, $chest, $ground and $normal",
		},
		["Preview.Drive"] = {
			Description = "moves a point or a blade through the stage while it plays, for effects that follow a path",
		},
		["Preview.Emitter"] = {
			Ref = "emitter",
			Description = "the gpu emitter that plays this shader in the preview, its Shader and ShaderParams are replaced",
		},
		["Preview.Offset"] = {Description = "where the preview emitter sits, in metres from the stage chest"},
		["Preview.ShaderParams"] = {Description = "shader params for the preview, over the shader's defaults"},
		["Drive.Type"] = {Options = effects_drive.Types},
		["Drive.Time"] = {Min = 0.05, Max = 10},
	}
	local common_keys = {
		Stage = "gizmo",
		Npc = "citizen",
		Camera = "front",
		Exposure = "day",
		Duration = 2,
		Loop = true,
		View = {Offset = {0, 1.5, 3.6}, Pitch = 0, Yaw = 0},
	}
	local extra_keys = {
		clips = {Params = {}, Drive = table.copy(effects_drive.Defaults.sweep), Release = 1},
		["gpu emitters"] = {Drive = table.copy(effects_drive.Defaults.sweep)},
		["particle shaders"] = {Emitter = "shader_preview", Offset = {0, 1, 0}, ShaderParams = {}},
	}

	for _, name in ipairs{"damage types", "status effects", "clips", "gpu emitters", "particle shaders"} do
		local schema = schemas[name]
		schema.Fields = merge(schema.Fields, fields)
		schema.Fields.Preview = {
			Keys = merge(common_keys, extra_keys[name] or {}),
			Description = "how the editor previews this effect when it is opened, saved in the file and ignored by the game; a key that is not here leaves the editor's current setting",
		}
		schema.Root.Keys = merge(schema.Root.Keys or {}, {Preview = {}})
	end
end

effects_schema.Schemas = schemas
return effects_schema
