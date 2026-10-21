local assets = import("goluwa/assets.lua")
local Material = import("goluwa/render3d/material.lua")
local textures = import("lua/foliage/textures.lua")
local Random = import("lua/foliage/random.lua")
local foliage = {}
foliage.generators = {}
foliage.materials = {}
foliage.models = {}
foliage.cache = {}
foliage.Random = Random
foliage.textures = textures

function foliage.AddGenerator(name, generator)
	assert(generator.category and generator.defaults and generator.build, name .. " needs a category, defaults and build")
	generator.defaults.seed = generator.defaults.seed or 1
	foliage.generators[name] = generator
end

function foliage.Resolve(name, config)
	local generator = foliage.generators[name]

	if not generator then error("unknown foliage generator " .. tostring(name), 3) end

	local out = {}

	for key, value in pairs(generator.defaults) do
		out[key] = value
	end

	for key, value in pairs(config or {}) do
		if generator.defaults[key] == nil then
			error(("unknown %s key %s"):format(name, tostring(key)), 3)
		end

		out[key] = value
	end

	return out, generator
end

do
	local function serialize(value)
		if type(value) ~= "table" then return tostring(value) end

		local keys = {}

		for key in pairs(value) do
			keys[#keys + 1] = key
		end

		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)

		local out = {}

		for i, key in ipairs(keys) do
			out[i] = tostring(key) .. "=" .. serialize(value[key])
		end

		return "{" .. table.concat(out, ",") .. "}"
	end

	foliage.Serialize = serialize

	function foliage.Build(name, config)
		local resolved, generator = foliage.Resolve(name, config)
		local key = name .. serialize(resolved)
		local parts = foliage.cache[key]

		if parts then return parts end

		parts = generator.build(resolved, Random.New(resolved.seed))
		assert(parts[1], name .. " made nothing")
		foliage.cache[key] = parts
		return parts
	end
end

do
	local TEXTURE_KEYS = {
		albedo = "AlbedoTexture",
		normal = "NormalTexture",
		roughness = "RoughnessTexture",
		transmission = "TransmissionTexture",
	}

	function foliage.GetTexturePath(name, channel)
		return "textures/foliage/" .. name .. "_" .. channel .. ".lua"
	end

	function foliage.GetMaterialPath(name)
		return "materials/foliage/" .. name .. ".lua"
	end

	function foliage.AddMaterial(name, definition)
		foliage.materials[name] = definition

		for _, channel in ipairs{"albedo", "normal", "roughness"} do
			assert(definition.textures[channel], name .. " has no " .. channel .. " map")
		end

		for channel, texture in pairs(definition.textures) do
			assert(TEXTURE_KEYS[channel], "unknown texture channel " .. channel)
			textures.Register(foliage.GetTexturePath(name, channel), texture[1], channel, texture[2])
		end

		local material

		assets.RegisterVirtualAsset(
			foliage.GetMaterialPath(name),
			{
				category = "materials",
				kind = "lua",
				load = function()
					if material then return material end

					local config = {}

					for key, value in pairs(definition.material) do
						config[key] = value
					end

					for channel in pairs(definition.textures) do
						config[TEXTURE_KEYS[channel]] = assets.GetTexture(foliage.GetTexturePath(name, channel))
					end


					material = Material.New(config)
					material:SetName("foliage/" .. name)
					return material
				end,
			}
		)
	end

	function foliage.GetMaterial(name)
		assert(foliage.materials[name], "unknown foliage material " .. tostring(name))
		return assets.GetMaterial(foliage.GetMaterialPath(name))
	end
end

function foliage.RegisterModel(path, name, config)
	foliage.Resolve(name, config)
	foliage.models[path] = {generator = name, config = config}
	assets.RegisterVirtualAsset(
		path,
		{
			category = "models",
			kind = "lua",
			load = function()
				return {
					name = path:match("([^/]+)%.lua$"),
					kind = "procedural_model",
					generator = name,
					create_primitives = function(options)
						local merged = {}

						for key, value in pairs(config) do
							merged[key] = value
						end

						for key, value in pairs(options or {}) do
							merged[key] = value
						end

						return foliage.Build(name, merged)
					end,
				}
			end,
		}
	)
	return path
end

function foliage.GetModelPath(category, preset)
	return "models/foliage/" .. category .. "/" .. preset .. ".lua"
end

foliage.presets = {}

function foliage.AddPreset(category, preset, generator, config)
	foliage.presets[category] = foliage.presets[category] or {}
	foliage.presets[category][preset] = {generator = generator, config = config or {}}
end

function foliage.RegisterAll()
	for category, presets in pairs(foliage.presets) do
		for preset, entry in pairs(presets) do
			foliage.RegisterModel(foliage.GetModelPath(category, preset), entry.generator, entry.config)
		end
	end
end

function foliage.GetModelPaths(category)
	local out = {}

	for preset in pairs(foliage.presets[category] or {}) do
		out[#out + 1] = foliage.GetModelPath(category, preset)
	end

	table.sort(out)
	return out
end

import.loaded["lua/foliage/foliage.lua"] = foliage
import("lua/foliage/materials.lua")
import("lua/foliage/trees.lua")
import("lua/foliage/grass.lua")
import("lua/foliage/rocks.lua")
import("lua/foliage/plants.lua")
foliage.RegisterAll()
return foliage
