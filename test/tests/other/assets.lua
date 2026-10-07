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
	local nested_model_root = model_root .. "/props_c17"
	assert(vfs.CreateDirectory(mount_root))
	assert(vfs.CreateDirectory(mount_root .. "/textures"))
	assert(vfs.CreateDirectory(texture_root))
	assert(vfs.CreateDirectory(mount_root .. "/models"))
	assert(vfs.CreateDirectory(model_root))
	assert(vfs.CreateDirectory(nested_model_root))
	assert(vfs.Write(texture_root .. "/demo.png", "x"))
	assert(vfs.Write(texture_root .. "/helper.txt", "x"))
	assert(vfs.Write(model_root .. "/demo.lua", "return {}"))
	assert(vfs.Write(nested_model_root .. "/barrel001.mdl", "x"))
	vfs.Mount(mount_root, "")
	local textures = assets.Enumerate("textures", {recursive = true, prefix = "browser"})
	local models = assets.Enumerate("models", {recursive = true, prefix = "browser"})
	T(#textures)["=="](1)
	T(textures[1].path)["=="]("textures/browser/demo.png")
	T(textures[1].kind)["=="]("file")
	T(#models)["=="](2)
	T(models[1].path)["=="]("models/browser/demo.lua")
	T(models[1].kind)["=="]("lua")
	T(models[2].path)["=="]("models/browser/props_c17/barrel001.mdl")
	T(models[2].kind)["=="]("file")
	vfs.Unmount(mount_root, "")
end)

T.Test("Assets folder enumeration lists immediate child folders by category", function()
	local mount_root = "os:" .. vfs.GetStorageDirectory("shared") .. "asset_browser_folders_test"
	local model_root = mount_root .. "/models/browser"
	local nested_model_root = model_root .. "/props_c17"
	local deep_model_root = nested_model_root .. "/furniture"
	assert(vfs.CreateDirectory(mount_root))
	assert(vfs.CreateDirectory(mount_root .. "/models"))
	assert(vfs.CreateDirectory(model_root))
	assert(vfs.CreateDirectory(nested_model_root))
	assert(vfs.CreateDirectory(deep_model_root))
	assert(vfs.Write(deep_model_root .. "/chair001.mdl", "x"))
	vfs.Mount(mount_root, "")
	local roots = assets.EnumerateFolders("models")
	local children = assets.EnumerateFolders("models", {prefix = "models/browser/"})
	T(#roots)[">="](1)
	T(roots[1].path)["=="]("models/browser/")
	T(#children)["=="](1)
	T(children[1].path)["=="]("models/browser/props_c17/")
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
	vfs.Mount("addons/game/")
	local entry = assets.GetModel("models/box.lua")
	T(entry ~= nil)["=="](true)
	T(entry.is_ready)["=="](true)
	T(type(entry.value.create_primitives))["=="]("function")
	local primitives = entry.value.create_primitives{size = Vec3(2, 3, 4)}
	T(#primitives)["=="](1)
	T(primitives[1].mesh ~= nil)["=="](true)
	vfs.Unmount("addons/game/", "")
	assets.ClearCache()
end)

local function write_index_fixture(name)
	local mount_root = make_mounted_asset_root(name)
	local root = mount_root .. "/models/" .. name
	assert(vfs.CreateDirectory(mount_root .. "/models"))
	assert(vfs.CreateDirectory(root))
	assert(vfs.CreateDirectory(root .. "/sub"))
	assert(vfs.CreateDirectory(root .. "/sub/deeper"))
	assert(vfs.CreateDirectory(root .. "/Sub2"))
	assert(vfs.Write(root .. "/a.mdl", "x"))
	assert(vfs.Write(root .. "/subtitle.mdl", "x"))
	assert(vfs.Write(root .. "/notes.txt", "x"))
	assert(vfs.Write(root .. "/sub/b.mdl", "x"))
	assert(vfs.Write(root .. "/sub/deeper/c.lua", "return {}"))
	assert(vfs.Write(root .. "/Sub2/D.MDL", "x"))
	vfs.Mount(mount_root, "")
	return mount_root
end

T.Test("Assets index builds a sorted folder tree with recursive counts", function()
	local mount_root = write_index_fixture("index_tree")
	local index = assets.GetIndex("models")
	local folder = index.folders["models/index_tree/"]
	T(folder ~= nil)["=="](true)
	T(folder.count)["=="](5)
	T(#folder.entries)["=="](2)
	T(folder.entries[1].path)["=="]("models/index_tree/a.mdl")
	T(folder.entries[2].path)["=="]("models/index_tree/subtitle.mdl")
	T(#folder.folders)["=="](2)
	T(folder.folders[1].name)["=="]("sub")
	T(folder.folders[2].name)["=="]("Sub2")
	T(index.folders["models/index_tree/sub/deeper/"].count)["=="](1)
	T(index.folders["models/index_tree/sub/deeper/"].parent == index.folders["models/index_tree/sub/"])["=="](true)
	T(index.by_path["models/index_tree/sub2/d.mdl"].extension)["=="](".mdl")
	T(index.by_path["models/index_tree/notes.txt"] == nil)["=="](true)
	local previous = ""

	for _, entry in ipairs(index.entries) do
		T(entry.lower_path >= previous)["=="](true)
		previous = entry.lower_path
	end

	cleanup_mounted_asset_root(mount_root)
end)

T.Test("Assets search matches every word and ranks name matches first", function()
	local mount_root = write_index_fixture("index_search")
	local results = assets.Search("models", "sub", {prefix = "models/index_search/"})
	T(#results)["=="](4)
	T(results[1].path)["=="]("models/index_search/subtitle.mdl")
	T(results[2].path)["=="]("models/index_search/sub/b.mdl")
	results = assets.Search("models", "b.mdl", {prefix = "models/index_search/"})
	T(#results)["=="](1)
	results = assets.Search("models", "deeper c")
	T(#results)["=="](1)
	T(results[1].path)["=="]("models/index_search/sub/deeper/c.lua")
	results = assets.Search("models", "index_search MDL")
	T(#results)["=="](4)
	local narrowed = assets.Search("models", "index_search sub", {entries = results})
	T(#narrowed)["=="](3)
	T(#assets.Search("models", "zzz_no_such_asset"))["=="](0)
	cleanup_mounted_asset_root(mount_root)
end)

T.Test("Assets index follows mounts and virtual assets without rescanning", function()
	local mount_root = write_index_fixture("index_follow")
	local index = assets.GetIndex("models")
	T(index.by_path["models/index_follow/a.mdl"] ~= nil)["=="](true)
	T(assets.GetIndex("models") == index)["=="](true)
	assets.RegisterVirtualAsset(
		"models/index_follow/virtual_one.lua",
		{
			category = "models",
			load = function() end,
		}
	)
	T(assets.GetIndex("models") == index)["=="](true)
	T(index.by_path["models/index_follow/virtual_one.lua"].source)["=="]("virtual")
	T(index.folders["models/index_follow/"].count)["=="](6)
	assets.UnregisterVirtualAsset("models/index_follow/virtual_one.lua")
	T(index.by_path["models/index_follow/virtual_one.lua"] == nil)["=="](true)
	T(index.folders["models/index_follow/"].count)["=="](5)
	cleanup_mounted_asset_root(mount_root)
	local after = assets.GetIndex("models")
	T(after == index)["=="](false)
	T(after.by_path["models/index_follow/a.mdl"] == nil)["=="](true)
end)

T.Test("vfs.FindRecursive lists every file below a folder across mounts", function()
	local mount_root = write_index_fixture("find_recursive")
	local found = {}
	local sizes = 0

	vfs.FindRecursive("models/find_recursive/", function(path, size, data)
		found[path] = data.context.Name
		sizes = sizes + 1
	end)

	T(sizes)["=="](6)
	T(found["models/find_recursive/a.mdl"])["=="]("os")
	T(found["models/find_recursive/sub/deeper/c.lua"])["=="]("os")
	T(found["models/find_recursive/Sub2/D.MDL"])["=="]("os")
	cleanup_mounted_asset_root(mount_root)
end)
