local ffi = require("ffi")
local commands = require("commands")
local tasks = require("tasks")
local Texture = require("render.texture")
local Color = require("structs.color")
local prototype = require("prototype")
local Material = prototype.CreateTemplate("material")
Material:GetSet("AlbedoTexture", Texture.FromColor(Color(1, 1, 1, 1)))
Material:GetSet("NormalTexture", Texture.FromColor(Color(0.5, 0.5, 1, 1))) -- roughness/g=1.0, metallic/b=0.0
Material:GetSet("MetallicRoughnessTexture", Texture.FromColor(Color(0, 1, 0, 1))) -- roughness/g=1.0, metallic/b=0.0
Material:GetSet("AmbientOcclusionTexture", Texture.FromColor(Color(1, 1, 1, 1))) -- roughness/g=1.0, metallic/b=0.0
Material:GetSet("EmissiveTexture", Texture.FromColor(Color(0, 0, 0, 1))) -- roughness/g=1.0, metallic/b=0.0
Material:GetSet("ColorMultiplier", Color(1.0, 1.0, 1.0, 1.0))
Material:GetSet("MetallicMultiplier", 0.0)
Material:GetSet("RoughnessMultiplier", 1.0)
Material:GetSet("NormalMapMultiplier", 1.0)
Material:GetSet("AmbientOcclusionMultiplier", 1.0)
Material:GetSet("EmissiveMultiplier", Color(0.0, 0.0, 0.0, 0.0))
--
Material:GetSet("DoubleSided", false) -- no culling?
Material:GetSet("AlphaMode", "OPAQUE") -- OPAQUE, MASK, BLEND
Material:GetSet("AlphaCutoff", 0.5)
Material:GetSet("ReverseXZNormalMap", false) -- For Source engine normals
Material:GetSet("Name", "unnamed") -- For Source engine normals
function Material.New(config)
	local self = prototype.CreateObject("material")
	return self
end

do
	local steam = require("steam")
	local vlg = require("steam/vertex_lit_generic")

	local function unpack_numbers(str)
		str = str:gsub("%s+", " ")
		local t = str:split(" ")

		for k, v in ipairs(t) do
			t[k] = tonumber(v) or 0
		end

		return unpack(t)
	end

	local SRGBTexture = function(path)
		--return render.CreateTextureFromPath("[srgb]" .. path)
		return Texture.New({
			path = path,
			srgb = true,
		})
	end
	local LinearTexture = function(path)
		--return render.CreateTextureFromPath("[~srgb]" .. path)
		return Texture.New({
			path = path,
			srgb = false,
		})
	end
	local property_translate = {
		basetexture = {"AlbedoTexture", SRGBTexture},
		basetexture2 = {"Albedo2Texture", SRGBTexture},
		texture2 = {"Albedo2Texture", SRGBTexture},
		bumpmap = {"NormalTexture", LinearTexture},
		bumpmap2 = {"Normal2Texture", LinearTexture},
		envmapmask = {"MetallicTexture", LinearTexture},
		phongexponenttexture = {"RoughnessTexture", LinearTexture},
		blendmodulatetexture = {"BlendTexture", LinearTexture},
		selfillummask = {"SelfIlluminationTexture", LinearTexture},
		selfillum = {
			"SelfIllumination",
			function(num)
				return num ~= 0
			end,
		},
		selfillumtint = {
			"IlluminationColor",
			function(v)
				if type(v) == "string" then
					if v:starts_with("[") then v = v:sub(2, -2) end

					local r, g, b = unpack_numbers(v)
					return Color(r, g, b, 1)
				elseif typex(v) == "vec3" then
					return Color(v.x, v.y, v.z, 1)
				end

				return v
			end,
		},
		alphatest = {
			"AlphaTest",
			function(num)
				return num == 1
			end,
		},
		ssbump = {
			"SSBump",
			function(num)
				return num == 1
			end,
		},
		nocull = {"NoCull"},
		translucent = {
			"Translucent",
			function(num)
				return num == 1
			end,
		},
		normalmapalphaenvmapmask = {
			"NormalAlphaMetallic",
			function(num)
				return num == 1
			end,
		},
		basealphaenvmapmask = {
			"AlbedoAlphaMetallic",
			function(num)
				return num == 1
			end,
		},
		basemapluminancephongmask = {
			"AlbedoLuminancePhongMask",
			function(num)
				return num == 1
			end,
		},
		basemapalphaphongmask = {
			"AlbedoPhongMask",
			function(num)
				return num == 1
			end,
		},
		blendtintbybasealpha = {
			"BlendTintByBaseAlpha",
			function(num)
				return num == 1
			end,
		},
		phongexponent = {
			"RoughnessMultiplier",
			function(num)
				return 1 / (-num + 1) ^ 3
			end,
		},
		envmaptint = {
			"MetallicMultiplier",
			function(num)
				if type(num) == "string" then
					return Vec3(unpack_numbers(num)):GetLength()
				elseif type(num) == "number" then
					return num
				elseif typex(num) == "vec3" then
					return num:GetLength()
				elseif typex(num) == "color" then
					return Vec3(num.r, num.g, num.b):GetLength()
				end
			end,
		},
		envmap = {
			"HasEnvmap",
			function(val)
				return val ~= nil and val ~= ""
			end,
		},
	}
	local special_textures = {
		_rt_fullframefb = "error",
		[1] = "error", -- huh
	}
	steam.unused_vmt_properties = steam.unused_vmt_properties or {}

	function Material:SetError(err) end

	function Material.FromVMT(path)
		local self = Material.New()
		--self:SetName(path)
		self.vmt = {}
		self.vmt_path = path -- Store path for debugging
		local cb = steam.LoadVMT(path, function(key, val, full_path)
			self:SetReverseXZNormalMap(true) -- Source engine normals need XY flip
			self.vmt.fullpath = full_path
			self.vmt[key] = val
			local unused = false

			if property_translate[key] then
				local field_name, convert = unpack(property_translate[key])

				if self["Set" .. field_name] then
					if convert then val = convert(val) end

					self["Set" .. field_name](self, val)
				else
					unused = true
				end
			else
				unused = true
			end

			if unused then
				steam.unused_vmt_properties[full_path] = steam.unused_vmt_properties[full_path] or {}
				steam.unused_vmt_properties[full_path][key] = val
			end
		end, function(err)
			print("Material error for " .. path .. ": " .. err)
			self:SetError(err)
		end)

		if tasks.GetActiveTask() then cb:Get() end

		return self
	end

	if RELOAD then
		for _, v in pairs(prototype.GetCreated()) do
			if v.Type == "material" and v.ClassName == "model" and v.vmt then

			--v:SetMetallicMultiplier(v:GetMetallicMultiplier()/3)
			end
		end
	end

	commands.Add("dump_unused_vmt_materials", function()
		for k, v in pairs(steam.unused_vmt_properties) do
			local properties = {}

			for k, v in pairs(v) do
				if
					k ~= "shader" and
					k ~= "fullpath" and
					k ~= "envmap" and
					k ~= "%keywords" and
					k ~= "surfaceprop"
				then
					properties[k] = v
				end
			end

			if next(properties) then
				logf("%s %s:\n", v.shader, k)

				for k, v in pairs(properties) do
					logf("\t%s = %s\n", k, v)
				end
			end
		end
	end)

	commands.Add("dump_unused_vmt_properties", function()
		local properties = {}

		for k, v in pairs(steam.unused_vmt_properties) do
			for k, v in pairs(v) do
				if
					k ~= "shader" and
					k ~= "fullpath" and
					k ~= "envmap" and
					k ~= "%keywords" and
					k ~= "surfaceprop"
				then
					properties[k] = properties[k] or {}
					table.insert(properties[k], v)
				end
			end
		end

		if next(properties) then
			for k, tbl in pairs(properties) do
				tbl = list.map(tbl, function(v)
					return tostring(v)
				end)
				tbl = list.unique(tbl)
				logf("%s = %s\n", k, table.concat(tbl, " | "))
			end
		end
	end)
end

-- Check if material needs alpha blending
function Material:NeedsBlending()
	return self.AlphaMode == "BLEND"
end

-- Check if material needs alpha testing
function Material:NeedsAlphaTest()
	return self.AlphaMode == "MASK"
end

-- Get alpha mode as integer for shader (0=OPAQUE, 1=MASK, 2=BLEND)
function Material:GetAlphaModeInt()
	if self.AlphaMode == "MASK" then
		return 1
	elseif self.AlphaMode == "BLEND" then
		return 2
	else
		return 0 -- OPAQUE
	end
end

-- Create a default material
local def = nil

function Material.GetDefault()
	def = def or Material.New()
	return def
end

return Material:Register()
