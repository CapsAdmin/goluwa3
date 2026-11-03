local vfs = import("goluwa/vfs.lua")
local data_files = import("goluwa/data_files.lua")
local emitter_data = import("goluwa/render3d/emitter_data.lua")
local emitters = {}
emitters.Files = data_files.New("lua/emitters/")
emitters.Names = {}

function emitters.Init()
	if emitters.Initialized then return end

	emitters.Initialized = true

	for _, file in ipairs(vfs.Find("lua/emitters/%.lua$")) do
		local name = file:gsub("%.lua$", "")
		emitters.Names[#emitters.Names + 1] = name
		emitters.Files:Remember(name, emitters.Files:Read(name))
		emitter_data.Set(name, emitters.Files.Source[name])
	end

	table.sort(emitters.Names)
end

function emitters.Get(name, inputs)
	return emitter_data.Get(name, inputs)
end

emitters.GetBurstKey = emitter_data.GetBurstKey
emitters.DefineBurst = emitter_data.DefineBurst
emitters.Burst = emitter_data.Burst

function emitters.Update(name, data)
	emitter_data.Set(name, data)
	emitters.Files:Remember(name, data)

	if not table.has_value(emitters.Names, name) then
		emitters.Names[#emitters.Names + 1] = name
		table.sort(emitters.Names)
	end
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

emitters.Init()
return emitters
