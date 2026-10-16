local T = import("test/environment.lua")
local ffi = require("ffi")
local assets = import("goluwa/assets.lua")
local Entity = import("goluwa/entities/entity.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local foliage = import("lua/foliage/foliage.lua")
local textures = import("lua/foliage/textures.lua")
local Random = import("lua/foliage/random.lua")

local function raises(fn, text)
	local ok, err = pcall(fn)
	T(ok)["=="](false)
	T(tostring(err))["contains"](text)
end

-- a hash of every vertex and index of the parts, the same for the same geometry
local function checksum(parts)
	local h = 0

	for _, part in ipairs(parts) do
		local packed = part.mesh.packed
		local bytes = ffi.cast("const uint8_t *", packed.vertices)

		for i = 0, ffi.sizeof(packed.vertices) - 1, 7 do
			h = (h * 31 + bytes[i]) % 4294967291
		end

		for i = 0, packed.index_count - 1 do
			h = (h * 31 + packed.indices[i]) % 4294967291
		end
	end

	return h
end

-- made fresh, without the cache of foliage.Build
local function build(name, config)
	local resolved, generator = foliage.Resolve(name, config)
	return generator.build(resolved, Random.New(resolved.seed))
end

T.Test("foliage random numbers come from the seed alone", function()
	local a, b, c = Random.New(7), Random.New(7), Random.New(8)
	local same, different = true, false

	for _ = 1, 100 do
		local x, y, z = a:Next(), b:Next(), c:Next()
		same = same and x == y
		different = different or x ~= z
		T(x >= 0 and x < 1)["=="](true)
	end

	T(same)["=="](true)
	T(different)["=="](true)
	-- a fork is the same stream whatever was drawn from its parent
	local first = Random.New(3):Fork("leaves"):Next()
	local parent = Random.New(3)
	parent:Next()
	parent:Next()
	T(parent:Fork("leaves"):Next())["=="](first)
	T(Random.New(3):Fork("trunk"):Next() ~= first)["=="](true)
end)

T.Test("foliage generators refuse keys they do not have", function()
	raises(function()
		foliage.Resolve("oak", {sede = 1})
	end, "unknown oak key sede")
	raises(function()
		foliage.Resolve("no_such_tree", {})
	end, "unknown foliage generator")
	raises(function()
		textures.GetSource("bark", {colour = {1, 1, 1}})
	end, "unknown bark texture key colour")
end)

T.Test3D("foliage assets are the same for the same seed and config and differ for another seed", function()
	for _, case in ipairs{
		{"oak", {seed = 4}},
		{"palm", {seed = 4}},
		{"grass_meadow", {seed = 4, blades = 20}},
		{"boulder", {seed = 4, resolution = 6}},
		{"daisies", {seed = 4}},
		{"mushrooms", {seed = 4}},
	} do
		local name, config = case[1], case[2]
		local first = checksum(build(name, config))
		T(checksum(build(name, config)))["=="](first)
		T(checksum(build(name, {seed = 5, blades = config.blades, resolution = config.resolution})) ~= first)["=="](true)
	end

	-- a config key changes it too
	T(checksum(build("boulder", {seed = 4, resolution = 6, noise = 0.4})) ~= checksum(build("boulder", {seed = 4, resolution = 6})))["=="](true)
	-- and foliage.Build makes a config once
	T(foliage.Build("boulder", {seed = 9, resolution = 4}) == foliage.Build("boulder", {resolution = 4, seed = 9}))["=="](true)
end)

T.Test3D("foliage trees bend in the wind and their leaves let light through", function()
	local parts = foliage.Build("birch", {seed = 1})
	local wood, leaves = parts[1], parts[2]
	T(wood.mesh:GetBendHeight())[">"](5)
	T(leaves.mesh:GetBendHeight())["=="](wood.mesh:GetBendHeight())
	T(wood.material:GetBending())[">"](0)
	T(leaves.material:GetBending())[">"](0)
	T(leaves.material:GetDetailBending())["=="]("leaves")
	T(leaves.material:GetDiffuseTransmission())[">"](0)
	T(leaves.material:GetAlphaTest())["=="](true)
	T(leaves.material:GetDoubleSided())["=="](true)
	-- the veins and the twigs let less through than the leaf
	T(leaves.material:GetTransmissionTexture() ~= nil)["=="](true)
	local grass = foliage.Build("grass_meadow", {seed = 1, blades = 10})[1]
	T(grass.material:GetDetailBending())["=="]("grass")
	T(grass.material:GetDiffuseTransmission())[">"](0)
	-- the detail bending is meters and its phase changes over the position: a blade a few centimeters wide must not
	-- move a tree branch's 0.2 m up and down or have its two edges flutter apart
	T(grass.material:GetBendDetailBranchAmplitude())["<="](0.05)
	T(grass.material:GetBendDetailPhase())["<="](2)
end)

T.Test("foliage branches measure how far out they reach", function()
	local trees = import("lua/foliage/trees.lua")
	local Vec3 = import("goluwa/structs/vec3.lua")
	local spec = {taper = 0.5}
	local up = trees.Grow(Random.New(1), Vec3(0, 0, 0), Vec3(0, 1, 0), 4, 0.1, spec, 8)
	local out = trees.Grow(Random.New(1), Vec3(0, 0, 0), Vec3(1, 0, 0), 4, 0.1, spec, 8)
	T(up[#up].reach)["~"](0)
	T(out[#out].reach)["~"](4)
	T(trees.Stiffness(out[#out].reach, 0.1))["~"](0.6)
	-- something going straight up from a point is as stiff as the point, it is moved with it and not stretched
	T(trees.StiffnessAlong(0.7, Vec3(0, 2, 0), 0.1))["~"](0.7)
	T(trees.StiffnessAlong(0.7, Vec3(1, 2, 0), 0.1))["~"](0.6)
end)

-- the bending colors of a part's vertices: r flutter, g phase, b stiffness
local function colors(part)
	local packed = part.mesh.packed
	local out = {}

	for i = 0, packed.vertex_count - 1 do
		local v = packed.vertices[i]
		out[i + 1] = {y = v.position[1], x = v.position[0], z = v.position[2], r = v.vertex_color[0], g = v.vertex_color[1], b = v.vertex_color[2]}
	end

	return out
end

T.Test3D("foliage trunks only sway in the wind and what grows on them turns about where it is held", function()
	-- the trunk (and the limbs it splits into) moves with the sway of the whole and not up and down along itself
	for _, name in ipairs{"pine", "oak", "birch", "willow", "bush"} do
		for _, v in ipairs(colors(build(name, {seed = 1, levels = {}})[1])) do
			T(v.b)["=="](1)
		end
	end

	-- a branch is held where it leaves the trunk, its stiffness falls with how far out it reaches from there and not with
	-- how high up the trunk it is. the pine's trunk is near the middle and its crown starts 3.7 m up, a branch reaches at
	-- most 2 m further along its own wander than it is from the middle
	local pine = foliage.generators.pine.defaults

	for _, v in ipairs(colors(build("pine", {seed = 1, levels = {pine.levels[1]}})[1])) do
		T(v.b >= 1 - pine.flex * (math.sqrt(v.x * v.x + v.z * v.z) + 2))["=="](true)
	end

	for _, name in ipairs{"pine", "oak", "birch", "willow"} do
		local parts = build(name, {seed = 1})

		-- a leaf card is held at its bottom edge and does not flutter there, its top is no stiffer
		local leaves = colors(parts[2])

		for i = 1, #leaves, 4 do
			T(leaves[i].r)["=="](0)
			T(leaves[i + 1].r)["=="](0)
			T(leaves[i + 2].b <= leaves[i].b + 1e-6)["=="](true)
		end
	end

	local palm = build("palm", {seed = 1})

	for _, v in ipairs(colors(palm[1])) do
		T(v.b)["=="](1)
	end

	-- the fronds are held at the crown, the same as the trunk's top
	local top = palm[1].mesh:GetAABB().max_y

	for _, v in ipairs(colors(palm[2])) do
		if v.r == 0 and math.abs(v.y - top) < 0.5 then T(v.b)["~"](1) end
	end
end)

T.Test3D("foliage leaves have their normals lean away from the trunk", function()
	local pine = foliage.generators.pine.defaults
	local leaves = {}

	for key, value in pairs(pine.leaves) do
		leaves[key] = value
	end

	leaves.bend = 1
	local parts = build("pine", {seed = 1, leaves = leaves})
	local top = 0

	for _, v in ipairs(colors(parts[1])) do
		if math.sqrt(v.x * v.x + v.z * v.z) < 0.3 then top = math.max(top, v.y) end
	end

	local packed = parts[2].mesh.packed
	local checked = 0

	-- next to the straight trunk of a pine, away from it is level and out from the middle (the trunk leans and wanders
	-- up to 0.6 m from the middle, so only what is further out than that is compared with the middle)
	for i = 0, packed.vertex_count - 1 do
		local v = packed.vertices[i]
		local x, y, z = v.position[0], v.position[1], v.position[2]
		local out = math.sqrt(x * x + z * z)

		if y < top * 0.9 and out > 2.5 then
			T(math.abs(v.normal[1]) < 0.3)["=="](true)
			T((v.normal[0] * x + v.normal[2] * z) / out > 0.8)["=="](true)
			checked = checked + 1
		end
	end

	T(checked)[">"](1000)
end)

T.Test3D("foliage grass and flowers are held at their roots", function()
	for _, name in ipairs{"grass_meadow", "grass_tussock", "daisies", "reeds"} do
		for _, part in ipairs(build(name, {seed = 1})) do
			for _, v in ipairs(colors(part)) do
				-- what is at the ground is the root
				if v.y < 0 then
					T(v.b)["~"](1)
					T(v.r)["=="](0)
				end
			end
		end
	end
end)

T.Test3D("foliage models load by their asset path", function()
	local path = foliage.GetModelPath("rocks", "boulder_a")
	T(assets.ResolvePath(path, "models"))["=="](path)
	local entry = assets.GetModel(path)
	T(entry.is_ready)["=="](true)
	T(entry.value.kind)["=="]("procedural_model")
	local loaded

	model_loader.LoadModel(path, function(data)
		loaded = data
	end)

	T(loaded ~= nil)["=="](true)
	T(loaded[1].mesh)["=="](foliage.Build("boulder", {seed = 1})[1].mesh)
	-- the options of a model component are keys over the preset's config
	local options = entry.value.create_primitives{seed = 2}
	T(options[1].mesh)["=="](foliage.Build("boulder", {seed = 2})[1].mesh)
	local ent = Entity.New{Name = "foliage_test_rock"}
	ent:AddComponent("transform")
	ent:AddComponent("visual"):SetModelPath(path)
	T(ent.visual:IsLoading())["=="](false)
	T(#ent.visual:GetRenderEntries())[">"](0)
	ent:Remove()
end)

T.Test3D("foliage textures and materials are assets and draw the same from the same seed", function()
	-- every material has a color, a normal and a roughness map, whatever it is made of
	for _, name in ipairs{"oak_leaves", "oak_bark", "rock_granite", "grass_meadow", "flower_poppy", "mushroom_amanita"} do
		local material = assets.GetMaterial(foliage.GetMaterialPath(name))
		T(material:GetAlbedoTexture() ~= nil)["=="](true)
		T(material:GetNormalTexture() ~= nil)["=="](true)
		T(material:GetRoughnessTexture() ~= nil)["=="](true)
	end

	for name, definition in pairs(foliage.materials) do
		T(definition.textures.roughness ~= nil)["=="](true)
	end

	local path = foliage.GetTexturePath("oak_bark", "albedo")
	T(assets.ResolvePath(path, "textures"))["=="](path)
	local small = {seed = 3, width = 32, height = 32}
	local a = textures.Build("bark", "albedo", small):Download()
	local b = textures.Build("bark", "albedo", small):Download()
	local c = textures.Build("bark", "albedo", {seed = 4, width = 32, height = 32}):Download()
	T(ffi.string(a.pixels, a.size) == ffi.string(b.pixels, b.size))["=="](true)
	T(ffi.string(a.pixels, a.size) ~= ffi.string(c.pixels, c.size))["=="](true)
	-- the leaves are cut out, some of the card is see through and some is not
	local leaves = textures.Build("leaves", "albedo", {seed = 3, width = 128, height = 32}):Download()
	local clear, solid = 0, 0

	for i = 3, leaves.size - 1, 4 do
		if leaves.pixels[i] < 128 then clear = clear + 1 else solid = solid + 1 end
	end

	T(clear)[">"](0)
	T(solid)[">"](0)
	-- the roughness maps change over the texture: the crevices of bark are rougher than its plates and berries are
	-- glossier than the leaves around them. they are one channel
	local function roughness_range(downloaded)
		local low, high = 255, 0

		for i = 0, downloaded.size - 1 do
			low = math.min(low, downloaded.pixels[i])
			high = math.max(high, downloaded.pixels[i])
		end

		return low, high
	end

	local bark = textures.Build("bark", "roughness", {seed = 3, width = 64, height = 64}):Download()
	T(bark.size)["=="](64 * 64)
	local low, high = roughness_range(bark)
	T(high - low)[">"](25)
	low = roughness_range(textures.Build("leaves", "roughness", {seed = 3, width = 256, height = 64, berries = 6}):Download())
	T(low)["<"](100)
end)

T.Test("foliage scatter sets only grow registered foliage models", function()
	local sets = import("lua/foliage/scatter_sets.lua")
	local count = 0

	for _, set in pairs(sets) do
		for _, proto in ipairs(set.protos) do
			T(assets.virtual_assets[proto.model] ~= nil)["=="](true)
			count = count + 1
		end
	end

	T(count)[">"](40)
end)
