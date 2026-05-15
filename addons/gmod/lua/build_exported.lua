-- copy this script to gmod
-- lua_openscript_cl build_exported.lua
-- lua_openscript build_exported.lua
-- copy data/cl_exported.lua to this script's directory
-- copy data/sv_exported.lua to this script's directory
local exported = {}
exported.functions = {}
exported.globals = {}
exported.meta = {}
exported.enums = {}
local meta_blacklist = {
	__index = true,
	__gc = true,
	MetaID = true,
	MetaName = true,
	MetaBaseClass = true,
}
local meta_names = {
	"CSoundPatchCMoveData",
	"NPC",
	"IRestoreFile",
	"Entity",
	"Weapon",
	"File",
	"Panel",
	"IVideoWriter",
	"Color",
	"PhysObj",
	"Angle",
	"CSEnt",
	"dlight_t",
	"IMesh",
	"bf_read",
	"CLuaParticle",
	"CLuaEmitter",
	"pixelvis_handle_t",
	"ProjectedTexture",
	"ConVar",
	"IMaterial",
	"ITexture",
	"VMatrix",
	"CMoveData",
	"CUserCmd",
	"CEffectData",
	"CTakeDamageInfo",
	"CNewParticleEffect",
	"Vector",
	"NextBot",
	"PhysCollide",
	"Player",
	"ISave",
	"IRestore",
	"CSoundPatch",
	"IGModAudioChannel",
	"SurfaceInfo",
	"Vehicle",
}

-- enums
for key, val in pairs(_G) do
	if isnumber(val) or isbool(val) then
		exported.enums[key] = val
	elseif istable(val) then
		local everything_number = true

		for _, val in pairs(val) do
			if not isnumber(val) then
				everything_number = false

				break
			end
		end

		if everything_number then exported.enums[key] = val end
	end
end

local whitelist = {
	[_G.Material] = true,
	[FindMetaTable("Player").ConCommand] = true,
}
local blacklist = {}

if CLIENT then
	whitelist[vgui.Create] = true
	whitelist[FindMetaTable("Panel").SetFGColor] = true
	whitelist[FindMetaTable("Panel").SetBGColor] = true
	blacklist[vgui.CreateX] = true
	blacklist[FindMetaTable("Panel").SetFGColorEx] = true
	blacklist[FindMetaTable("Panel").SetBGColorEx] = true
end

local function get_func_type(func)
	if blacklist[func] then return end

	if whitelist[func] or debug.getinfo(func).source == "=[C]" then return "C" end

	return "L"
end

local function add_meta(meta)
	if not (istable(meta) and isstring(meta.MetaName)) then return end

	exported.meta[meta.MetaName] = exported.meta[meta.MetaName] or {}

	for func_name, func in pairs(meta) do
		if not meta_blacklist[func_name] and isfunction(func) then
			local func_type = get_func_type(func)

			if func_type then exported.meta[meta.MetaName][func_name] = func_type end
		end
	end
end

local blacklist = {
	_M = true,
	_NAME = true,
	_PACKAGE = true,
	SpawniconGenFunctions = true,
}

-- functions
for key, val in pairs(_G) do
	if key == "_G" then goto _continue end

	if isfunction(val) then
		exported.globals[key] = get_func_type(val)
	elseif istable(val) and not blacklist[key] then
		for func_name, func in pairs(val) do
			if not blacklist[func_name] then
				if isfunction(func) then
					local func_type = get_func_type(func)

					if func then
						exported.functions[key] = exported.functions[key] or {}
						exported.functions[key][func_name] = func_type
					end
				else

				--print("unexpected value in library " .. key .. ": ", func_name, func)
				end
			end
		end
	end

	::_continue::
end

-- meta
for _, meta_name in ipairs(meta_names) do
	local meta = FindMetaTable(meta_name)

	if istable(meta) then add_meta(meta) end
end

local output = "return {\n"
output = output .. "\tenums = {\n"

for k, v in pairs(exported.enums) do
	if isnumber(v) or isbool(v) then
		output = output .. "\t\t" .. k .. " = " .. tostring(v) .. ",\n"
	else
		output = output .. "\t\t" .. k .. " = {\n"

		for k, v in pairs(v) do
			output = output .. "\t\t\t[\"" .. k .. "\"] = " .. v .. ",\n"
		end

		output = output .. "\t\t},\n"
	end
end

output = output .. "\t},\n"
output = output .. "\tmeta = {\n"

for meta_name, functions in pairs(exported.meta) do
	output = output .. "\t\t" .. meta_name .. " = {\n"

	for name, type in pairs(functions) do
		output = output .. "\t\t\t" .. name .. " = \"" .. type .. "\",\n"
	end

	output = output .. "\t\t},\n"
end

output = output .. "\t},\n"
output = output .. "\tfunctions = {\n"

for lib_name, functions in pairs(exported.functions) do
	output = output .. "\t\t" .. lib_name .. " = {\n"

	for name, type in pairs(functions) do
		output = output .. "\t\t\t" .. name .. " = \"" .. type .. "\",\n"
	end

	output = output .. "\t\t},\n"
end

output = output .. "\t},\n"
output = output .. "\tglobals = {\n"

for name, type in pairs(exported.globals) do
	output = output .. "\t\t\t" .. name .. " = \"" .. type .. "\",\n"
end

output = output .. "\t},\n"
output = output .. "}\n"
CompileString(output, "test")
file.Write((SERVER and "sv_" or "cl_") .. "exported.txt", output)
