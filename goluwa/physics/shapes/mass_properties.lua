local Matrix33 = import("goluwa/structs/matrix33.lua")

local mass_properties = {}

function mass_properties.ResolveBodyMass(body, automatic_mass)
	local mass = body:GetMass()

	if body.IsDynamic and not body:IsDynamic() then
		return 0
	end

	if body:GetAutomaticMass() then return automatic_mass end

	return mass
end

function mass_properties.ZeroIfStatic(mass)
	if mass <= 0 then return 0, Matrix33():SetZero() end
	return nil
end

function mass_properties.BuildBoxInertia(mass, sx, sy, sz)
	local zero_mass, zero_inertia = mass_properties.ZeroIfStatic(mass)

	if zero_mass then return zero_mass, zero_inertia end

	local ix = (1 / 12) * mass * (sy * sy + sz * sz)
	local iy = (1 / 12) * mass * (sx * sx + sz * sz)
	local iz = (1 / 12) * mass * (sx * sx + sy * sy)
	return mass, Matrix33():SetDiagonal(ix, iy, iz)
end

function mass_properties.BuildSphereInertia(mass, radius)
	local zero_mass, zero_inertia = mass_properties.ZeroIfStatic(mass)

	if zero_mass then return zero_mass, zero_inertia end

	local inertia = (2 / 5) * mass * radius * radius
	return mass, Matrix33():SetDiagonal(inertia, inertia, inertia)
end

return mass_properties