local vfs = import("goluwa/vfs.lua")
local data_files = import("goluwa/data_files.lua")
local emitters = {}
emitters.Files = data_files.New("lua/emitters/")
emitters.Names = {}
local vfx

function emitters.Init()
	if emitters.Initialized then return end

	emitters.Initialized = true

	for _, file in ipairs(vfs.Find("lua/emitters/%.lua$")) do
		local name = file:gsub("%.lua$", "")
		emitters.Names[#emitters.Names + 1] = name
		emitters.Files:Remember(name, emitters.Files:Read(name))
	end

	table.sort(emitters.Names)
end

function emitters.Get(name)
	return data_files.Realize(table.copy(emitters.Files.Source[name]))
end

function emitters.Update(name, data)
	emitters.Files:Remember(name, data)

	if not table.has_value(emitters.Names, name) then
		emitters.Names[#emitters.Names + 1] = name
		table.sort(emitters.Names)
	end

	if vfx and vfx.HasBurst(name) then vfx.DefineBurst(name, emitters.Get(name)) end
end

function emitters.Reload(name)
	emitters.Update(name, emitters.Files:Read(name))
end

function emitters.Save(name)
	return emitters.Files:Save(name)
end

function emitters.Create(name, from)
	emitters.Update(name, table.copy(emitters.Files.Source[from]))
	return name
end

function emitters.GetNewName(base)
	local index = 2

	while table.has_value(emitters.Names, base .. "_" .. index) do
		index = index + 1
	end

	return base .. "_" .. index
end

function emitters.DefineBurst(name)
	vfx = vfx or import("goluwa/render3d/vfx.lua")
	vfx.DefineBurst(name, emitters.Get(name))
end

function emitters.Burst(name, position, direction, count)
	vfx = vfx or import("goluwa/render3d/vfx.lua")

	if not vfx.HasBurst(name) then vfx.DefineBurst(name, emitters.Get(name)) end

	vfx.Burst(name, position, direction, count)
end

emitters.Init()
return emitters
