local vfs = import("goluwa/vfs.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local surface_properties = {}
local by_hash, default

function surface_properties.GetByHash(hash)
	if not by_hash then
		by_hash = {}

		for _, entry in ipairs(resource.ReadKV3(resource.Load(vfs, "surfaceproperties/surfaceproperties.vsurf_c")).SurfacePropertiesList) do
			by_hash[entry.m_nameHash] = entry.physics

			if entry.surfacePropertyName == "default" then default = entry.physics end
		end
	end

	return by_hash[hash] or default
end

return surface_properties
