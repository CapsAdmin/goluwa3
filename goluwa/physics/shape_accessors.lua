local shape_accessors = {}

function shape_accessors.GetSphereRadius(body)
	local shape = body:GetPhysicsShape()
	return shape and shape.GetRadius and shape:GetRadius() or 0
end

function shape_accessors.GetBodyPolyhedron(body)
	local shape = body:GetPhysicsShape()

	if not (shape and shape.GetPolyhedron) then return nil end

	return shape:GetPolyhedron(body)
end

function shape_accessors.BodyHasSignificantRotation(body)
	return math.abs(body:GetPreviousRotation():Dot(body:GetRotation())) < 0.9995
end

return shape_accessors