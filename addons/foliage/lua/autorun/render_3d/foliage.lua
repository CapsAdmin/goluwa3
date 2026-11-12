import("lua/foliage/foliage.lua")
local ScatterSet = import("goluwa/render3d/scatter_set.lua")

for _, name in ipairs{
	"foliage_meadow",
	"foliage_forest",
	"foliage_tropical",
	"foliage_rocky",
	"foliage_wetland",
} do
	ScatterSet.AddFactory(name, function()
		return import("lua/foliage/scatter_sets.lua")[name]
	end)
end
