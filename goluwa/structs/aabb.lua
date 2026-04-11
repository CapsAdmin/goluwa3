local Vec3 = import("goluwa/structs/vec3.lua")
local structs = import("goluwa/structs/structs.lua")
local META = structs.Template("AABB")
local CTOR
local LOCAL_AABB_CORNERS = {
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
	Vec3(),
}
META.Args = {{"min_x", "min_y", "min_z", "max_x", "max_y", "max_z"}}
structs.AddAllOperators(META)

function META:IsBoxInside(box)
	return self.min_x <= box.min_x and
		self.min_y <= box.min_y and
		self.min_z <= box.min_z and
		self.max_x >= box.max_x and
		self.max_y >= box.max_y and
		self.max_z >= box.max_z
end

function META:IsSphereInside(pos, radius)
	if pos.x - radius < self.min_x then return false end

	if pos.y - radius < self.min_y then return false end

	if pos.z - radius < self.min_z then return false end

	if pos.x + radius > self.max_x then return false end

	if pos.y + radius > self.max_y then return false end

	if pos.z + radius > self.max_z then return false end

	return true
end

function META:IsOverlappedSphereInside(pos, radius)
	if
		pos.x > self.min_x and
		pos.x < self.max_x and
		pos.y > self.min_y and
		pos.y < self.max_y and
		pos.z > self.min_z and
		pos.z < self.max_z
	then
		return true
	end

	if pos.x + radius < self.min_x then return false end

	if pos.y + radius < self.min_y then return false end

	if pos.z + radius < self.min_z then return false end

	if pos.x - radius > self.max_x then return false end

	if pos.y - radius > self.max_y then return false end

	if pos.z - radius > self.max_z then return false end

	return true
end

function META:IsPointInside(pos)
	if pos.x < self.min_x then return false end

	if pos.y < self.min_y then return false end

	if pos.z < self.min_z then return false end

	if pos.x > self.max_x then return false end

	if pos.y > self.max_y then return false end

	if pos.z > self.max_z then return false end

	return true
end

function META:IsBoxIntersecting(box)
	if self.min_x > box.max_x or box.min_x > self.max_x then return false end

	if self.min_y > box.max_y or box.min_y > self.max_y then return false end

	if self.min_z > box.max_z or box.min_z > self.max_z then return false end

	return true
end

function META.BuildLocalAABBFromWorldAABB(world_aabb, world_to_local)
	if not world_to_local then return world_aabb end

	local corners = LOCAL_AABB_CORNERS
	corners[1].x, corners[1].y, corners[1].z = world_aabb.min_x, world_aabb.min_y, world_aabb.min_z
	corners[2].x, corners[2].y, corners[2].z = world_aabb.min_x, world_aabb.min_y, world_aabb.max_z
	corners[3].x, corners[3].y, corners[3].z = world_aabb.min_x, world_aabb.max_y, world_aabb.min_z
	corners[4].x, corners[4].y, corners[4].z = world_aabb.min_x, world_aabb.max_y, world_aabb.max_z
	corners[5].x, corners[5].y, corners[5].z = world_aabb.max_x, world_aabb.min_y, world_aabb.min_z
	corners[6].x, corners[6].y, corners[6].z = world_aabb.max_x, world_aabb.min_y, world_aabb.max_z
	corners[7].x, corners[7].y, corners[7].z = world_aabb.max_x, world_aabb.max_y, world_aabb.min_z
	corners[8].x, corners[8].y, corners[8].z = world_aabb.max_x, world_aabb.max_y, world_aabb.max_z
	local local_min_x = math.huge
	local local_min_y = math.huge
	local local_min_z = math.huge
	local local_max_x = -math.huge
	local local_max_y = -math.huge
	local local_max_z = -math.huge

	for i = 1, 8 do
		local point = world_to_local:TransformVector(corners[i])
		local x = point.x
		local y = point.y
		local z = point.z

		if x < local_min_x then local_min_x = x end

		if y < local_min_y then local_min_y = y end

		if z < local_min_z then local_min_z = z end

		if x > local_max_x then local_max_x = x end

		if y > local_max_y then local_max_y = y end

		if z > local_max_z then local_max_z = z end
	end

	return CTOR(local_min_x, local_min_y, local_min_z, local_max_x, local_max_y, local_max_z)
end

function META:ExtendMax(pos)
	if pos.x > self.max_x then self.max_x = pos.x end

	if pos.y > self.max_y then self.max_y = pos.y end

	if pos.z > self.max_z then self.max_z = pos.z end
end

function META:ExtendMin(pos)
	if pos.x < self.min_x then self.min_x = pos.x end

	if pos.y < self.min_y then self.min_y = pos.y end

	if pos.z < self.min_z then self.min_z = pos.z end
end

function META:SetMin(pos)
	self.min_x = pos.x
	self.min_y = pos.y
	self.min_z = pos.z
end

function META:GetMin()
	return Vec3(self.min_x, self.min_y, self.min_z)
end

function META:SetMax(pos)
	self.max_x = pos.x
	self.max_y = pos.y
	self.max_z = pos.z
end

function META:GetMax()
	return Vec3(self.max_x, self.max_y, self.max_z)
end

function META.Expand(a, b)
	if b.min_x < a.min_x then a.min_x = b.min_x end

	if b.min_y < a.min_y then a.min_y = b.min_y end

	if b.min_z < a.min_z then a.min_z = b.min_z end

	if b.max_x > a.max_x then a.max_x = b.max_x end

	if b.max_y > a.max_y then a.max_y = b.max_y end

	if b.max_z > a.max_z then a.max_z = b.max_z end
end

function META:ExpandVec3(vec)
	if vec.x < self.min_x then self.min_x = vec.x end

	if vec.y < self.min_y then self.min_y = vec.y end

	if vec.z < self.min_z then self.min_z = vec.z end

	if vec.x > self.max_x then self.max_x = vec.x end

	if vec.y > self.max_y then self.max_y = vec.y end

	if vec.z > self.max_z then self.max_z = vec.z end
end

function META:GetLength()
	return self:GetMin():Distance(self:GetMax())
end

CTOR = structs.Register(META)
return CTOR
