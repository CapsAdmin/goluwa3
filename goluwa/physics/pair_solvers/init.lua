local pair_solvers = {}

function pair_solvers.RegisterAll(solver)
	local modules = {
		import("goluwa/physics/pair_solvers/polyhedron.lua"),
		import("goluwa/physics/pair_solvers/sphere.lua"),
		import("goluwa/physics/pair_solvers/capsule.lua"),
		import("goluwa/physics/pair_solvers/box.lua"),
	}

	for _, pair_solver in ipairs(modules) do
		pair_solver.Register(solver)
	end
end

return pair_solvers