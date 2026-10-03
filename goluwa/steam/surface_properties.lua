local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local surface_properties = {}
local entries
local resolved = {}

local function load_entries()
	entries = {}
	local manifest = steam.VDFToTable(vfs.Read("scripts/surfaceproperties_manifest.txt")).surfaceproperties_manifest
	local files = type(manifest.file) == "string" and {manifest.file} or manifest.file

	for _, path in ipairs(files) do
		if vfs.IsFile(path) then
			for name, properties in pairs(steam.VDFToTable(vfs.Read(path))) do
				name = name:lower()
				entries[name] = entries[name] or {}

				for key, value in pairs(properties) do
					entries[name][key] = value
				end
			end
		end
	end
end

function surface_properties.Get(name)
	if not entries then load_entries() end

	name = name:lower()

	if resolved[name] then return resolved[name] end

	local chain = {}
	local current = entries[name]

	while current do
		table.insert(chain, 1, current)
		current = current.base and entries[current.base:lower()]
		assert(#chain < 32, "surface property base loop for " .. name)
	end

	local out = {}

	for key, value in pairs(entries.default) do
		out[key] = value
	end

	for _, entry in ipairs(chain) do
		for key, value in pairs(entry) do
			out[key] = value
		end
	end

	resolved[name] = out
	return out
end

return surface_properties
