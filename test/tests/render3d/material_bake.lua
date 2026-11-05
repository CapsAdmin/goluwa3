local T = import("test/environment.lua")
local ffi = require("ffi")
local Texture = import("goluwa/render/texture.lua")
local Material = import("goluwa/render3d/material.lua")
local Color = import("goluwa/structs/color.lua")
local material_bake = import("goluwa/render3d/material_bake.lua")
local fs = import("goluwa/filesystem/fs.lua")
local SIZE = 64

local function make_texture(fill, srgb)
	local pixels = ffi.new("uint8_t[?]", SIZE * SIZE * 4)

	for y = 0, SIZE - 1 do
		for x = 0, SIZE - 1 do
			local o = (y * SIZE + x) * 4
			pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3] = fill(x, y)
		end
	end

	return Texture.New{
		buffer = pixels,
		width = SIZE,
		height = SIZE,
		format = srgb and "r8g8b8a8_srgb" or "r8g8b8a8_unorm",
		srgb = srgb,
	}
end

local function compare(a, b, channels)
	local worst, sum = 0, 0

	for i = 0, SIZE * SIZE - 1 do
		for _, c in ipairs(channels) do
			local d = math.abs(a.pixels[i * 4 + c] - b.pixels[i * 4 + c])
			worst = math.max(worst, d)
			sum = sum + d
		end
	end

	return worst, sum / (SIZE * SIZE * #channels)
end

T.Test3D("material_bake reproduces a material's albedo, normal and roughness from its flags", function()
	local material = Material.New{}
	material:SetAlbedoTexture(
		make_texture(function(x, y)
			return x * 4, y * 3 + 20, 90 + (x + y) % 40, 255
		end, true)
	)
	material:SetNormalTexture(
		make_texture(
			function(x, y)
				return 128 + (x % 8 - 4) * 6, 128 + (y % 8 - 4) * 6, 255, 40 + (x * y) % 200
			end,
			false
		)
	)
	material:SetNormalTextureAlphaIsRoughness(true)
	material:SetRoughnessMultiplier(0.8)
	material:SetRoughnessMin(0.1)
	material:SetRoughnessMax(0.9)
	material:SetMetallicMultiplier(0.5)
	material:SetColorMultiplier(Color(0.9, 0.8, 0.7, 1))
	material:SetNormalMapMultiplier(1.5)
	T(material_bake.CanBake(material))["=="](true)
	local original = material_bake.Render(material, SIZE, SIZE)
	local baked = material_bake.Bake(material, SIZE, SIZE)
	local copy = material:Copy()
	material_bake.Apply(copy, material_bake.CreateTextures(baked))
	T(copy.baked)["=="](true)
	T(copy:GetNormalTextureAlphaIsRoughness())["=="](false)
	local after = material_bake.Render(copy, SIZE, SIZE)
	local checks = {
		{1, {0, 1, 2}, 12, "albedo"},
		{2, {0, 1}, 6, "normal"},
		{3, {0, 1, 2}, 8, "metallic roughness ao"},
	}

	for _, check in ipairs(checks) do
		local worst, mean = compare(
			original:GetAttachment(check[1]):Download(),
			after:GetAttachment(check[1]):Download(),
			check[2]
		)
		T(worst <= check[3])["=="](true)
		T(mean < 3)["=="](true)
	end

	original:Remove()
	after:Remove()
end)

T.Test3D("material_bake leaves materials it cannot bake yet alone", function()
	local material = Material.New{}
	T(material_bake.CanBake(material))["=="](false)
	material:SetAlbedoTexture(make_texture(function()
		return 255, 255, 255, 255
	end, true))
	T(material_bake.CanBake(material))["=="](true)
	material.Additive = true
	T(select(2, material_bake.CanBake(material)))["=="]("additive")
	material.Additive = false
	material:SetNormal2Texture(make_texture(function()
		return 128, 128, 255, 255
	end, false))
	T(select(2, material_bake.CanBake(material)))["=="]("blend")
	material:SetAlbedo2Texture(make_texture(function()
		return 1, 2, 3, 255
	end, true))
	T(material_bake.CanBake(material))["=="](true)
	T(material_bake.GetLayerKind(material))["=="]("blend")
	material:SetBlendTintByBaseAlpha(true)
	T(select(2, material_bake.CanBake(material)))["=="]("blend")
end)

T.Test3D("material_bake renders without the micro detail and leaves it on the material", function()
	local material = Material.New{}
	material:SetAlbedoTexture(make_texture(function(x, y)
		return x * 4, y * 3 + 20, 90, 255
	end, true))
	local before = material_bake.Render(material, SIZE, SIZE)
	local detail = make_texture(function(x, y)
		return (x * y) % 256, 0, 0, 255
	end, false)
	material:SetMicroDetailTexture(detail)
	material:SetMicroDetailNormal(2)
	material:SetMicroDetailRoughness(0.5)
	local after = material_bake.Render(material, SIZE, SIZE)
	T(material:GetMicroDetailTexture() == detail)["=="](true)

	for attachment = 1, 3 do
		local worst = compare(
			before:GetAttachment(attachment):Download(),
			after:GetAttachment(attachment):Download(),
			{0, 1, 2}
		)
		T(worst)["=="](0)
	end
end)

T.Test3D("material_bake skips materials whose texture is the missing texture fallback", function()
	local texture = Texture.New{path = "this/texture/does/not/exist.vtf", srgb = true}
	T(texture:IsFallback())["=="](true)
	T(make_texture(function()
		return 1, 2, 3, 255
	end, true):IsFallback())["=="](false)
end)

T.Test3D("material_bake names the cache entry after the material and shares it between map patches", function()
	local function key_of(vmt_path)
		local material = Material.New{}
		material:SetAlbedoTexture(Texture.New{path = "textures/a.vtf", srgb = true, defer = true})
		material.vmt_path = vmt_path
		return material_bake.GetKey(material)
	end

	local plain = key_of("materials/building_template/wall01.vmt")
	local patched = key_of("materials/maps/gm_construct/building_template/wall01_-256_1472_96.vmt")
	T(plain)["=="](patched)
	T(plain:find("^building_template_wall01_%x+$") ~= nil)["=="](true)
end)

T.Test3D("material_bake prunes cache folders of other versions", function()
	local directory = "storage/userdata/test_bake_cache/"
	local previous = material_bake.CacheDirectory
	assert(fs.create_directory_recursive(directory .. "v0/key"))
	assert(fs.create_directory_recursive(directory .. "v" .. material_bake.Version .. "/key"))
	material_bake.CacheDirectory = directory
	material_bake.PruneCache(true)
	material_bake.CacheDirectory = previous
	T(fs.exists(directory .. "v0"))["=="](false)
	T(fs.exists(directory .. "v" .. material_bake.Version .. "/key"))["=="](true)
	fs.remove_directory_recursive("storage/userdata/test_bake_cache")
end)

T.Test3D("material_bake bakes the emissive color and leaves the multiplier on the material", function()
	local material = Material.New{}
	material:SetAlbedoTexture(
		make_texture(
			function(x, y)
				return 40 + x * 3, 200 - y * 2, 90, x < SIZE / 2 and 255 or 60
			end,
			true
		)
	)
	material:SetAlbedoAlphaIsEmissive(true)
	material:SetEmissiveAlphaFloor(0.2)
	material:SetEmissiveMultiplier(Color(1, 0.5, 0.25, 6))
	T(material_bake.CanBake(material))["=="](true)
	local original = material_bake.Render(material, SIZE, SIZE)
	local emitted = original:GetAttachment(4):Download().pixels
	T(emitted[(SIZE + 1) * 4] + emitted[(SIZE + 1) * 4 + 1] > 40)["=="](true)
	local baked = material_bake.Bake(material, SIZE, SIZE)
	T(baked.Emissive ~= nil)["=="](true)
	local copy = material:Copy()
	material_bake.Apply(copy, material_bake.CreateTextures(baked))
	T(copy:GetAlbedoAlphaIsEmissive())["=="](false)
	T(copy:GetEmissiveTexture() ~= nil)["=="](true)
	T(copy:GetEmissiveMultiplier().a)["=="](6)
	local after = material_bake.Render(copy, SIZE, SIZE)
	local worst, mean = compare(
		original:GetAttachment(4):Download(),
		after:GetAttachment(4):Download(),
		{0, 1, 2}
	)
	T(worst <= 12)["=="](true)
	T(mean < 3)["=="](true)
	original:Remove()
	after:Remove()
end)

T.Test3D("material_bake bakes both layers of a vertex blend", function()
	local material = Material.New{}
	material:SetAlbedoTexture(make_texture(function(x, y)
		return x * 4, 60, 200 - y * 2, 255
	end, true))
	material:SetNormalTexture(
		make_texture(function(x, y)
			return 128 + (x % 8 - 4) * 6, 128, 255, 90 + x
		end, false)
	)
	material:SetAlbedo2Texture(make_texture(function(x, y)
		return 220 - x * 2, y * 3, 40, 255
	end, true))
	material:SetNormal2Texture(
		make_texture(function(x, y)
			return 128, 128 + (y % 8 - 4) * 6, 255, 200 - y
		end, false)
	)
	material:SetNormalTextureAlphaIsRoughness(true)
	material:SetColorMultiplier(Color(0.9, 0.8, 0.7, 1))
	T(material_bake.GetLayerKind(material))["=="]("blend")
	T(material_bake.CanBake(material))["=="](true)
	local original = material_bake.Render(material, SIZE, SIZE)
	local baked = material_bake.Bake(material, SIZE, SIZE)
	T(baked.Albedo2 ~= nil and baked.Normal2 ~= nil and baked.MetallicRoughness2 ~= nil)["=="](true)
	local copy = material:Copy()
	material_bake.Apply(copy, material_bake.CreateTextures(baked))
	T(copy:GetAlbedo2Texture() ~= nil)["=="](true)
	T(copy:GetMetallicRoughness2Texture() ~= nil)["=="](true)
	local after = material_bake.Render(copy, SIZE, SIZE)

	for attachment, channels in pairs{[1] = {0, 1, 2}, [2] = {0, 1}, [3] = {0, 1, 2}} do
		local worst, mean = compare(
			original:GetAttachment(attachment):Download(),
			after:GetAttachment(attachment):Download(),
			channels
		)
		T(worst <= 12)["=="](true)
		T(mean < 3)["=="](true)
	end

	local layer2 = material:Copy()
	layer2:SetAlbedoTexture(material:GetAlbedo2Texture())
	layer2:SetNormalTexture(material:GetNormal2Texture())
	layer2:SetAlbedo2Texture(nil)
	layer2:SetNormal2Texture(nil)
	layer2:SetNormalMapMultiplier(1)
	local reference = material_bake.Render(layer2, SIZE, SIZE)
	local plain = Material.New{}
	plain:SetAlbedoTexture(material_bake.CreateTextures(baked).Albedo2)
	local from_baked = material_bake.Render(plain, SIZE, SIZE)
	local worst, mean = compare(
		reference:GetAttachment(1):Download(),
		from_baked:GetAttachment(1):Download(),
		{0, 1, 2}
	)
	T(worst <= 12)["=="](true)
	T(mean < 3)["=="](true)
	original:Remove()
	after:Remove()
	reference:Remove()
	from_baked:Remove()
end)
