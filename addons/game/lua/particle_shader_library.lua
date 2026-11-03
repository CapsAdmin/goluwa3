local vfs = import("goluwa/vfs.lua")
local list = import("goluwa/list.lua")
local data_files = import("goluwa/data_files.lua")
local shaders = import("goluwa/render3d/particle_shaders.lua")
local library = {}
library.Files = data_files.New(
	"lua/particle_shaders/",
	{"Sprite", "Params", "Spawn", "Update", "Visibility", "Shade"}
)
library.Names = {}
library.Errors = {}
local signatures = {}
local textures_registered = false

local function get_signature(data)
	local params = {}

	for index, param in ipairs(data.Params or {}) do
		params[index] = param.Name .. ":" .. param.Type
	end

	return table.concat(params, ",") .. "|" .. tostring(data.Sprite) .. "|" .. (
			data.Spawn or
			""
		) .. "|" .. (
			data.Update or
			""
		) .. "|" .. (
			data.Visibility or
			""
		) .. "|" .. (
			data.Shade or
			""
		)
end

local function recompile()
	if RENDER_3D and import("goluwa/render/render.lua").IsInitialized() then
		import("goluwa/render3d/particles.lua").Recompile()
	end
end

local function register_textures()
	if textures_registered or not RENDER_3D then return end

	textures_registered = true
	import("goluwa/render3d/vfx.lua").RegisterTexture(
		"snowflake",
		[[
			vec2 p = uv * 2.0 - 1.0;
			float r = length(p);
			float sector = 6.2831853 / 6.0;
			float f = abs(mod(atan(p.y, p.x) + sector * 0.5, sector) - sector * 0.5);
			vec2 q = vec2(cos(f), sin(f)) * r;
			float arm = smoothstep(0.07, 0.02, abs(q.y)) * smoothstep(0.95, 0.75, q.x) * step(0.0, q.x);
			float branch = smoothstep(0.06, 0.015, abs(q.y - (q.x - 0.42) * 0.85)) * step(0.25, q.x) * step(q.x, 0.7);
			float core = smoothstep(0.2, 0.05, r);
			float v = clamp(arm + branch * 0.8 + core, 0.0, 1.0) * (1.0 - smoothstep(0.9, 1.0, r));
			return vec4(vec3(1.0), v);
		]]
	)
end

local function discover()
	library.Names = {}

	for _, file in ipairs(vfs.Find("lua/particle_shaders/%.lua$")) do
		library.Names[#library.Names + 1] = file:gsub("%.lua$", "")
	end

	table.sort(library.Names)
end

function library.Register(name, data)
	library.Files:Remember(name, data)
	shaders.Register(name, data_files.Realize(table.copy(data)))
	signatures[name] = get_signature(data)

	if not table.has_value(library.Names, name) then
		library.Names[#library.Names + 1] = name
		table.sort(library.Names)
	end
end

function library.Init()
	if library.Initialized then return end

	library.Initialized = true
	register_textures()
	discover()

	for _, name in ipairs(library.Names) do
		library.Register(name, library.Files:Read(name))
	end

	recompile()
end

function library.Update(name, data)
	local previous = library.Files.Source[name]
	local previous_signature = signatures[name]
	local ok, err = pcall(library.Register, name, data)

	if ok and signatures[name] ~= previous_signature then
		ok, err = pcall(recompile)
	end

	if ok then
		library.Errors[name] = nil
		return
	end

	local message = shaders.ParseError(tostring(err):gsub("^.-:%d+: ", ""))
	library.Errors[name] = message

	if previous then
		library.Register(name, previous)
	else
		shaders.Remove(name)
		list.remove_value(library.Names, name)
		library.Files.Source[name] = nil
	end

	pcall(recompile)
	error(message, 0)
end

function library.Reload(name)
	return library.Update(name, library.Files:Read(name))
end

function library.Save(name)
	return library.Files:Save(name)
end

function library.GetStatus(name)
	return library.Errors[name]
end

function library.GetDefaults(name)
	return shaders.GetDefaults(name)
end

function library.GetParams(name)
	local entry = shaders.Get(name)
	return entry and entry.definition.Params or {}
end

function library.Create(name, from)
	local data = table.copy(library.Files.Source[from])
	library.Update(name, data)
	return name
end

function library.GetNewName(base)
	local index = 2

	while table.has_value(library.Names, base .. "_" .. index) do
		index = index + 1
	end

	return base .. "_" .. index
end

return library
