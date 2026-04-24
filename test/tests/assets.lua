local T = import("test/environment.lua")
local assets = import("goluwa/assets.lua")
local Texture = import("goluwa/render/texture.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local vfs = import("goluwa/vfs.lua")

local function make_mounted_asset_root(name)
	local mount_root = "os:" .. vfs.GetStorageDirectory("shared") .. "asset_tests/" .. name
	assert(vfs.CreateDirectory("os:" .. vfs.GetStorageDirectory("shared") .. "asset_tests"))
	assert(vfs.CreateDirectory(mount_root))
	vfs.Mount(mount_root, "")
	return mount_root
end

local function cleanup_mounted_asset_root(mount_root)
	vfs.Unmount(mount_root, "")
end

T.Test3D("Assets texture cache key includes config.srgb from the options table", function()
	local old_texture_new = Texture.New
	local created = {}
	local mount_root = make_mounted_asset_root("texture_cache_key")
	assert(vfs.CreateDirectory(mount_root .. "/textures"))
	assert(vfs.Write(mount_root .. "/textures/cache_demo.png", "x"))
	Texture.New = function(config)
		local texture = {
			config = config,
			ready = false,
			IsReady = function(self)
				return self.ready
			end,
		}
		list.insert(created, texture)

		if config.on_ready then
			texture.ready = true
			config.on_ready(texture)
		end

		return texture
	end
	assets.ClearCache()
	local first = assets.GetTexture("textures/cache_demo.png", {config = {srgb = true}})
	local second = assets.GetTexture("textures/cache_demo.png", {config = {srgb = true}})
	local third = assets.GetTexture("textures/cache_demo.png", {config = {srgb = false}})
	T(first == second)["=="](true)
	T(first == third)["=="](false)
	T(#created)["=="](2)
	T(created[1].config.srgb)["=="](true)
	T(created[2].config.srgb)["=="](false)
	Texture.New = old_texture_new
	assets.ClearCache()
	cleanup_mounted_asset_root(mount_root)
end)

T.Test3D("Assets model loading uses an options table and caches by resolved path", function()
	local old_load_model = model_loader.LoadModel
	local load_calls = 0
	local ready_calls = 0
	local mount_root = make_mounted_asset_root("model_cache_key")
	assert(vfs.CreateDirectory(mount_root .. "/models"))
	assert(vfs.Write(mount_root .. "/models/fake_model.mdl", "x"))
	model_loader.LoadModel = function(path, on_ready, on_mesh, on_fail)
		load_calls = load_calls + 1
		on_mesh{mesh = "mesh_a", material = "mat_a"}
		on_ready{{mesh = "mesh_a", material = "mat_a"}}
		return true
	end
	assets.ClearCache()
	local first = assets.GetModel(
		"models/fake_model.mdl",
		{
			on_ready = function(entry)
				ready_calls = ready_calls + 1
				T(entry.is_ready)["=="](true)
			end,
		}
	)
	local second = assets.GetModel(
		"models/fake_model.mdl",
		{
			on_ready = function(entry)
				ready_calls = ready_calls + 1
				T(entry.value[1].mesh)["=="]("mesh_a")
			end,
		}
	)
	T(first == second)["=="](true)
	T(first.entries[1].mesh)["=="]("mesh_a")
	T(load_calls)["=="](1)
	T(ready_calls)["=="](2)
	model_loader.LoadModel = old_load_model
	assets.ClearCache()
	cleanup_mounted_asset_root(mount_root)
end)

T.Test("Assets enumeration wraps VFS file discovery by category", function()
	local mount_root = "os:" .. vfs.GetStorageDirectory("shared") .. "asset_browser_test"
	local texture_root = mount_root .. "/textures/browser"
	local model_root = mount_root .. "/models/browser"
	assert(vfs.CreateDirectory(mount_root))
	assert(vfs.CreateDirectory(mount_root .. "/textures"))
	assert(vfs.CreateDirectory(texture_root))
	assert(vfs.CreateDirectory(mount_root .. "/models"))
	assert(vfs.CreateDirectory(model_root))
	assert(vfs.Write(texture_root .. "/demo.png", "x"))
	assert(vfs.Write(texture_root .. "/helper.txt", "x"))
	assert(vfs.Write(model_root .. "/demo.lua", "return {}"))
	vfs.Mount(mount_root, "")
	local textures = assets.Enumerate("textures", {recursive = true, prefix = "browser"})
	local models = assets.Enumerate("models", {recursive = true, prefix = "browser"})
	T(#textures)["=="](1)
	T(textures[1].path)["=="]("textures/browser/demo.png")
	T(textures[1].kind)["=="]("file")
	T(#models)["=="](1)
	T(models[1].path)["=="]("models/browser/demo.lua")
	T(models[1].kind)["=="]("lua")
	vfs.Unmount(mount_root, "")
end)

T.Test3D("Assets enumerate and load registered virtual textures", function()
	assets.ClearCache()

	assets.RegisterVirtualTexture("textures/render/test_virtual.lua", function()
		return import("goluwa/render/textures/glow_linear.lua")
	end)

	local tex = assets.GetTexture("textures/render/test_virtual.lua")
	local entries = assets.Enumerate("textures", {recursive = true})
	local found = false

	for _, entry in ipairs(entries) do
		if entry.path == "textures/render/test_virtual.lua" then
			found = true

			break
		end
	end

	T(tex ~= nil)["=="](true)
	T(tex:IsReady())["=="](true)
	T(tex:GetWidth())[">"](0)
	T(assets.ResolvePath("textures/render/test_virtual.lua", "textures") ~= nil)["=="](true)
	T(found)["=="](true)
	assets.UnregisterVirtualAsset("textures/render/test_virtual.lua")
	assets.ClearCache()
end)

T.Test3D("Assets load procedural model descriptors from the game addon models folder", function()
	assets.ClearCache()
	vfs.Mount("game/addons/game/")
	local entry = assets.GetModel("models/box.lua")
	T(entry ~= nil)["=="](true)
	T(entry.is_ready)["=="](true)
	T(type(entry.value.create_primitives))["=="]("function")
	local primitives = entry.value.create_primitives{size = Vec3(2, 3, 4)}
	T(#primitives)["=="](1)
	T(primitives[1].mesh ~= nil)["=="](true)
	vfs.Unmount("game/addons/game/", "")
	assets.ClearCache()
end)
