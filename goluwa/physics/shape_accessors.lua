local module = {}

function module.CreateServices()
	local function clamp(value, min_value, max_value)
		return math.max(min_value, math.min(max_value, value))
	end

	local function get_sign(value)
		return value < 0 and -1 or 1
	end

	local function get_sphere_radius(body)
		local shape = body:GetPhysicsShape()
		return shape and shape.GetRadius and shape:GetRadius() or 0
	end

	local function get_box_extents(body)
		return body:GetPhysicsShape():GetExtents()
	end

	local function get_box_axes(body)
		return body:GetPhysicsShape():GetAxes(body)
	end

	local function get_body_polyhedron(body)
		local shape = body:GetPhysicsShape()

		if not (shape and shape.GetPolyhedron) then return nil end

		return shape:GetPolyhedron(body)
	end

	local function body_has_significant_rotation(body)
		return math.abs(body:GetPreviousRotation():Dot(body:GetRotation())) < 0.9995
	end

	return {
		Clamp = clamp,
		GetSign = get_sign,
		GetSphereRadius = get_sphere_radius,
		GetBoxExtents = get_box_extents,
		GetBoxAxes = get_box_axes,
		GetBodyPolyhedron = get_body_polyhedron,
		BodyHasSignificantRotation = body_has_significant_rotation,
	}
end

return module