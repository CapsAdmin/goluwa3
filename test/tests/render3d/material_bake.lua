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

local function without_estimators(callback)
	local previous = table.copy(material_bake.estimators)

	for name in pairs(previous) do
		material_bake.estimators[name] = false
	end

	local ok, err = pcall(callback)

	for name, value in pairs(previous) do
		material_bake.estimators[name] = value
	end

	if not ok then error(err, 0) end
end

local function T3D_equivalence(name, callback)
	T.Test3D(name, function()
		without_estimators(callback)
	end)
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

T3D_equivalence("material_bake reproduces a material's albedo, normal and roughness from its flags", function()
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
		{3, {0, 1}, 8, "metallic roughness"},
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
	assert(fs.create_directory_recursive(directory .. material_bake.GetVersion() .. "/key"))
	material_bake.CacheDirectory = directory
	material_bake.PruneCache(true)
	material_bake.CacheDirectory = previous
	T(fs.exists(directory .. "v0"))["=="](false)
	T(fs.exists(directory .. material_bake.GetVersion() .. "/key"))["=="](true)
	fs.remove_directory_recursive("storage/userdata/test_bake_cache")
end)

T3D_equivalence("material_bake bakes the emissive color and leaves the multiplier on the material", function()
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

T3D_equivalence("material_bake bakes both layers of a vertex blend", function()
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

	for attachment, channels in pairs{[1] = {0, 1, 2}, [2] = {0, 1}, [3] = {0, 1}} do
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

T.Test3D("derived metal albedo keeps bare metal and takes it from painted and rusted texels", function()
	local function render_metal(r, g, b, strength)
		local material = Material.New{}
		material:SetAlbedoTexture(make_texture(function()
			return r, g, b, 255
		end, true))
		material:SetMetallicMultiplier(1)
		material:SetDerivedMetalAlbedo(strength)
		local framebuffer = material_bake.Render(material, SIZE, SIZE)
		local pixels = framebuffer:GetAttachment(3):Download().pixels
		local metal, rough = pixels[(SIZE + 1) * 4], pixels[(SIZE + 1) * 4 + 1]
		framebuffer:Remove()
		return metal / 255, rough / 255
	end

	T(render_metal(150, 152, 156, 1) > 0.9)["=="](true)
	local rust_metal, rust_rough = render_metal(170, 70, 40, 1)
	T(rust_metal < 0.1)["=="](true)
	T(rust_rough >= 0.8)["=="](true)
	T(render_metal(170, 70, 40, 0) > 0.9)["=="](true)
end)

T.Test3D("material_bake estimators lift near black texels without flattening their detail and cap the brightest", function()
	local function bake_albedo(fill)
		local material = Material.New{}
		material:SetAlbedoTexture(make_texture(fill, true))
		local framebuffer = material_bake.Render(material, SIZE, SIZE)
		local pixels = framebuffer:GetAttachment(1):Download().pixels

		local function average(x0, x1)
			local sum = 0

			for y = 20, 40 do
				for x = x0, x1 do
					sum = sum + pixels[(y * SIZE + x) * 4 + 1]
				end
			end

			return sum / (21 * (x1 - x0 + 1))
		end

		local result = {average(8, 11), average(12, 15), pixels[(SIZE + 1) * 4]}
		framebuffer:Remove()
		return result
	end

	local black = bake_albedo(function()
		return 2, 2, 2, 255
	end)
	T(black[1] >= 15)["=="](true)
	local stripes = bake_albedo(function(x)
		local value = (x % 8 < 4) and 12 or 3
		return value, value, value, 255
	end)
	T(stripes[1] - stripes[2] >= 4)["=="](true)
	local white = bake_albedo(function()
		return 255, 255, 255, 255
	end)
	T(white[3] < 250)["=="](true)

	without_estimators(function()
		T(bake_albedo(function()
			return 255, 255, 255, 255
		end)[3] >= 254)["=="](true)
		T(bake_albedo(function()
			return 2, 2, 2, 255
		end)[1] <= 4)["=="](true)
	end)
end)

T.Test3D("material_bake estimators make crevices rougher and leave explicit roughness alone", function()
	local function grout(x, y)
		local line = x % 16 < 3 or y % 16 < 3
		local value = line and 40 or 150
		return value, value, value, 255
	end

	local function roughness_at(configure, x, y)
		local material = Material.New{}
		material:SetAlbedoTexture(make_texture(grout, true))
		configure(material)
		local framebuffer = material_bake.Render(material, SIZE, SIZE)
		local pixels = framebuffer:GetAttachment(3):Download().pixels
		local value = pixels[(y * SIZE + x) * 4 + 1] / 255
		framebuffer:Remove()
		return value
	end

	local function plain(material)
		material:SetMetallicMultiplier(0)
		material:SetRoughnessMultiplier(0.5)
	end

	local function with_mask(material)
		material:SetMetallicMultiplier(0)
		material:SetRoughnessMultiplier(0.5)
		material:SetAlbedoTextureAlphaIsRoughness(true)
	end

	local on_line = roughness_at(plain, 17, 33)
	local on_face = roughness_at(plain, 25, 41)
	local off_line, off_face

	without_estimators(function()
		off_line = roughness_at(plain, 17, 33)
		off_face = roughness_at(plain, 25, 41)
	end)

	T(on_line - on_face > off_line - off_face + 0.05)["=="](true)
	T(math.abs(on_face - off_face) < 0.08)["=="](true)
	local masked_on = roughness_at(with_mask, 17, 33)
	local masked_off

	without_estimators(function()
		masked_off = roughness_at(with_mask, 17, 33)
	end)

	T(math.abs(masked_on - masked_off) < 0.02)["=="](true)
end)

T3D_equivalence("material_bake keeps the derived specular cavity and the specular multiplier", function()
	local material = Material.New{}
	material:SetAlbedoTexture(
		make_texture(
			function(x, y)
				local dark = (x % 16 < 4) and 30 or 150
				return dark, dark, dark, 255
			end,
			true
		)
	)
	material:SetMetallicMultiplier(0)
	material:SetRoughnessMultiplier(0.6)
	material:SetDerivedRoughnessAlbedo(1.5)
	material:SetDerivedRoughnessAlbedoMean(0.6)
	material:SetDerivedSpecularCavity(0.8)
	material:SetDerivedSpecularRoughness(0.5)
	material:SetSpecularMultiplier(0.5)
	local original = material_bake.Render(material, SIZE, SIZE)
	local before = original:GetAttachment(3):Download().pixels
	local dark, bright = before[(8 * SIZE + 2) * 4 + 2], before[(8 * SIZE + 10) * 4 + 2]
	T(bright - dark > 40)["=="](true)
	local baked = material_bake.Bake(material, SIZE, SIZE)
	local copy = material:Copy()
	material_bake.Apply(copy, material_bake.CreateTextures(baked))
	T(copy:GetDerivedSpecularCavity())["=="](0)
	T(copy:GetSpecularMultiplier())["=="](0.5)
	local after = material_bake.Render(copy, SIZE, SIZE)
	local worst, mean = compare(original:GetAttachment(3):Download(), after:GetAttachment(3):Download(), {2})
	T(worst <= 12)["=="](true)
	T(mean < 3)["=="](true)
	original:Remove()
	after:Remove()
end)

T.Test3D("derived specular roughness damps the specular of rough dielectrics and leaves metals alone", function()
	local function specular(roughness, metallic, damping)
		local material = Material.New{}
		material:SetAlbedoTexture(make_texture(function()
			return 120, 110, 100, 255
		end, true))
		material:SetRoughnessMultiplier(roughness)
		material:SetMetallicMultiplier(metallic)
		material:SetDerivedSpecularRoughness(damping)
		local framebuffer = material_bake.Render(material, SIZE, SIZE)
		local value = framebuffer:GetAttachment(3):Download().pixels[(SIZE + 1) * 4 + 2] / 255
		framebuffer:Remove()
		return value
	end

	local plain = specular(0.95, 0, 0)
	T(specular(0.95, 0, 0.5) < plain * 0.65)["=="](true)
	T(specular(0.2, 0, 0.5) > plain * 0.95)["=="](true)
	T(math.abs(specular(0.95, 1, 0.5) - specular(0.95, 1, 0)) < 0.02)["=="](true)
end)

T.Test3D("material_bake estimates a normal from the shading of a texture without a normal map", function()
	local function normal_x(with_normal)
		local material = Material.New{}
		material:SetAlbedoTexture(
			make_texture(
				function(x)
					local groove = x >= 30 and x <= 33
					local value = groove and 25 or 150
					return value, value, value, 255
				end,
				true
			)
		)

		if with_normal then
			material:SetNormalTexture(make_texture(function()
				return 128, 128, 255, 255
			end, false))
		end

		local framebuffer = material_bake.Render(material, SIZE, SIZE)
		local pixels = framebuffer:GetAttachment(2):Download().pixels
		local left, right = pixels[(20 * SIZE + 28) * 4], pixels[(20 * SIZE + 35) * 4]
		framebuffer:Remove()
		return left - 128, right - 128
	end

	local left, right = normal_x(false)
	T(left * right < 0 and math.abs(left) >= 3 and math.abs(right) >= 3)["=="](true)
	left, right = normal_x(true)
	T(math.abs(left) <= 2 and math.abs(right) <= 2)["=="](true)

	without_estimators(function()
		left, right = normal_x(false)
		T(math.abs(left) <= 2 and math.abs(right) <= 2)["=="](true)
	end)
end)

T.Test3D("material_bake renders an estimated normal at twice the size and a real one at the albedo size", function()
	local function dds_width(data)
		local a, b, c, d = data:byte(17, 20)
		return a + b * 256 + c * 65536 + d * 16777216
	end

	local material = Material.New{}
	material:SetAlbedoTexture(make_texture(function(x, y)
		return 40 + x, 40 + y, 90, 255
	end, true))
	local baked = material_bake.Bake(material, SIZE, SIZE)
	T(dds_width(baked.Albedo))["=="](SIZE)
	T(dds_width(baked.Normal))["=="](SIZE * 2)
	material:SetNormalTexture(make_texture(function()
		return 128, 128, 255, 255
	end, false))
	baked = material_bake.Bake(material, SIZE, SIZE)
	T(dds_width(baked.Normal))["=="](SIZE)
end)
