local fluid = library()
fluid.OCEAN_DENSITY = 1025
fluid.DRAG_COEFFICIENT = 1
fluid.LINEAR_VISCOSITY = 5
fluid.ANGULAR_VISCOSITY = 5
fluid.MAX_ACCELERATION = 6
fluid.volumes = {}
fluid.regions = {}
local ocean_region = {ocean = true, density = fluid.OCEAN_DENSITY, level = 0}

function fluid.GetOceanLevel() end

function fluid.AddVolume(volume)
	volume.FluidRegion = {ocean = false, density = 0}
	list.insert(fluid.volumes, volume)
end

function fluid.RemoveVolume(volume)
	for i, other in ipairs(fluid.volumes) do
		if other == volume then
			list.remove(fluid.volumes, i)
			return
		end
	end
end

function fluid.HasRegions()
	return fluid.regions[1] ~= nil
end

-- once per physics step: snapshots the volume transforms and the ocean level into plain numbers
function fluid.Refresh()
	local regions = fluid.regions
	local count = 0
	local volumes = fluid.volumes

	for i = 1, #volumes do
		local volume = volumes[i]
		local region = volume.FluidRegion
		local inverse = volume.Owner.transform:GetWorldMatrixInverse()
		local size = volume:GetSize()
		region.density = volume:GetDensity()
		region.half_x = size.x / 2
		region.depth = size.y
		region.half_z = size.z / 2
		region.m00, region.m01, region.m02 = inverse.m00, inverse.m01, inverse.m02
		region.m10, region.m11, region.m12 = inverse.m10, inverse.m11, inverse.m12
		region.m20, region.m21, region.m22 = inverse.m20, inverse.m21, inverse.m22
		region.m30, region.m31, region.m32 = inverse.m30, inverse.m31, inverse.m32
		count = count + 1
		regions[count] = region
	end

	local level = fluid.GetOceanLevel()

	if level then
		ocean_region.level = level
		count = count + 1
		regions[count] = ocean_region
	end

	for i = #regions, count + 1, -1 do
		regions[i] = nil
	end
end

-- whether a sphere at x, y, z could touch the region
function fluid.Overlaps(region, x, y, z, radius)
	if region.ocean then return y - radius < region.level end

	local lx = x * region.m00 + y * region.m10 + z * region.m20 + region.m30
	local ly = x * region.m01 + y * region.m11 + z * region.m21 + region.m31
	local lz = x * region.m02 + y * region.m12 + z * region.m22 + region.m32
	return lx > -region.half_x - radius and
		lx < region.half_x + radius and
		lz > -region.half_z - radius and
		lz < region.half_z + radius and
		ly < radius and
		ly > -region.depth - radius
end

return fluid
