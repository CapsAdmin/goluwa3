local pair_solvers = {}

function pair_solvers.RegisterAll(solver, services)
	local modules = {
		import("goluwa/physics/pair_solvers/polyhedron.lua"),
		import("goluwa/physics/pair_solvers/sphere.lua"),
		import("goluwa/physics/pair_solvers/capsule.lua"),
		import("goluwa/physics/pair_solvers/box.lua"),
	}

	for _, module in ipairs(modules) do
		module.Register(solver, services)
	end
end

return pair_solvers