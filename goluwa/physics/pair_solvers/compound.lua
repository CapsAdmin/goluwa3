local module = {}

function module.Register(solver)
	local function solve_compound_against_body(compound_body, other_body, dt)
		local shape = compound_body:GetPhysicsShape()
		local handled = false

		for _, child_body in ipairs(shape:GetChildProxyBodies(compound_body)) do
			local handler = solver:GetPairHandler(child_body:GetShapeType(), other_body:GetShapeType())

			if handler and handler(child_body, other_body, nil, nil, dt) then
				handled = true
			end
		end

		return handled
	end

	local function solve_body_against_compound(body, compound_body, dt)
		local shape = compound_body:GetPhysicsShape()
		local handled = false

		for _, child_body in ipairs(shape:GetChildProxyBodies(compound_body)) do
			local handler = solver:GetPairHandler(body:GetShapeType(), child_body:GetShapeType())

			if handler and handler(body, child_body, nil, nil, dt) then handled = true end
		end

		return handled
	end

	local function solve_compound_pair(body_a, body_b, dt)
		local shape_a = body_a:GetPhysicsShape()
		local shape_b = body_b:GetPhysicsShape()
		local handled = false

		for _, child_a in ipairs(shape_a:GetChildProxyBodies(body_a)) do
			for _, child_b in ipairs(shape_b:GetChildProxyBodies(body_b)) do
				local handler = solver:GetPairHandler(child_a:GetShapeType(), child_b:GetShapeType())

				if handler and handler(child_a, child_b, nil, nil, dt) then handled = true end
			end
		end

		return handled
	end

	solver:RegisterPairHandler("compound", "sphere", function(body_a, body_b, _, _, dt)
		return solve_compound_against_body(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("compound", "box", function(body_a, body_b, _, _, dt)
		return solve_compound_against_body(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("compound", "convex", function(body_a, body_b, _, _, dt)
		return solve_compound_against_body(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("sphere", "compound", function(body_a, body_b, _, _, dt)
		return solve_body_against_compound(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("box", "compound", function(body_a, body_b, _, _, dt)
		return solve_body_against_compound(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("convex", "compound", function(body_a, body_b, _, _, dt)
		return solve_body_against_compound(body_a, body_b, dt)
	end)

	solver:RegisterPairHandler("compound", "compound", function(body_a, body_b, _, _, dt)
		return solve_compound_pair(body_a, body_b, dt)
	end)
end

return module