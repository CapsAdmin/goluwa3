-- how long each generator takes to build with its defaults, and how big it is: luajit glw --2d --background lua test/harnesses/foliage/bench.lua
local system = import("goluwa/system.lua")
local foliage = import("lua/foliage/foliage.lua")
local Random = import("lua/foliage/random.lua")
-- the materials first, so the times are only the meshes
for name in pairs(foliage.materials) do foliage.GetMaterial(name) end
local names = {}
for name in pairs(foliage.generators) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
	local resolved, generator = foliage.Resolve(name, {})
	local start = system.GetTime()
	local parts = generator.build(resolved, Random.New(1))
	local elapsed = system.GetTime() - start
	local vertices, triangles = 0, 0
	for _, part in ipairs(parts) do
		if part.mesh:GetLODLevel() == 0 then
			vertices = vertices + part.mesh.packed.vertex_count
			triangles = triangles + part.mesh.packed.index_count / 3
		end
	end
	print(("%-16s %6.1f ms %7d vertices %7d triangles"):format(name, elapsed * 1000, vertices, triangles))
end
system.ShutDown(0)
