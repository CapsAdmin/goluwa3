local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local nav_mesh = import("goluwa/source_engine/nav_mesh.lua")
local fluid = import("goluwa/physics/fluid.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("nav_mesh")
META:StartStorable()
META:GetSet("Path", "", {callback = "Load"})
META:EndStorable()
local DEBUG_RADIUS = 30
local DEBUG_LIFETIME = 0.1
local OUTLINE = Color(0.1, 1, 0.3, 1)
local BLOCKED = Color(1, 0.2, 0.2, 1)
local AVOID = Color(1, 0.7, 0.1, 1)
local LIFT = Vec3(0, 0.03, 0)

-- the navigation mesh of the world, there is one active at a time
function META.GetActive()
	return META.active
end

-- a character wades through this much water, any more and the area is not walkable
local WADE_DEPTH = 0.6

-- areas that are deeper under water than a character wades through are blocked, the mesh was made for a dry world
function META:BlockFlooded()
	local mesh = self.mesh
	local volumes = fluid.volumes
	local ocean = fluid.GetOceanLevel()
	self.flooded_volumes = #volumes

	for _, volume in ipairs(volumes) do
		local inverse = volume.Owner.transform:GetWorldMatrixInverse()
		local size = volume:GetSize()

		for _, area in ipairs(mesh:GetAreas()) do
			local x, y, z = area.center_x, area.center_y, area.center_z
			local local_x = x * inverse.m00 + y * inverse.m10 + z * inverse.m20 + inverse.m30
			local local_y = x * inverse.m01 + y * inverse.m11 + z * inverse.m21 + inverse.m31
			local local_z = x * inverse.m02 + y * inverse.m12 + z * inverse.m22 + inverse.m32

			if
				math.abs(local_x) < size.x / 2 and
				math.abs(local_z) < size.z / 2 and
				local_y < -WADE_DEPTH and
				local_y > -size.y
			then
				area.Blocked = true
			end
		end
	end

	if ocean then
		for _, area in ipairs(mesh:GetAreas()) do
			if area.center_y < ocean - WADE_DEPTH then area.Blocked = true end
		end
	end
end

-- the water volumes of a map are made after its navigation mesh, so areas are blocked once there are volumes
function META.GetMesh()
	local active = META.active

	if not active then return nil end

	if active.flooded_volumes ~= #fluid.volumes then active:BlockFlooded() end

	return active.mesh
end

function META:Initialize()
	self.initialized = true
	self:Load()
end

function META:Load()
	if not self.initialized then return end

	self.mesh = nil
	self.flooded_volumes = nil

	if META.active == self then META.active = nil end

	if self.Path == "" then return end

	self.mesh = nav_mesh.Load(self.Path)
	META.active = self
	logn("loaded navigation mesh ", self.Path, " with ", #self.mesh:GetAreas(), " areas")
end

-- for a mesh that was made in code
function META:SetMesh(mesh)
	self.mesh = mesh
	self.flooded_volumes = nil
	META.active = self
end

function META:OnRemove()
	if META.active == self then META.active = nil end
end

local draw_events = false

function META.SetDebugDraw(enabled)
	if enabled == draw_events then return end

	draw_events = enabled

	if not enabled then
		event.RemoveListener("Update", "nav_mesh_debug")
		return
	end

	local debug_draw = import("goluwa/debug_draw.lua")
	local render3d = import("goluwa/render3d/render3d.lua")

	event.AddListener("Update", "nav_mesh_debug", function()
		local mesh = META.GetMesh()

		if not mesh then return end

		for _, area in ipairs(mesh:GetAreasNear(render3d.GetCamera():GetPosition(), DEBUG_RADIUS)) do
			local p = area.points
			local color = area.Blocked and BLOCKED or area.Cost > 1 and AVOID or OUTLINE

			for i = 0, area.count - 1 do
				local o, n = i * 3, (i + 1) % area.count * 3
				debug_draw.DrawLine{
					id = "nav_" .. area.Index .. "_" .. i,
					from = Vec3(p[o + 1], p[o + 2], p[o + 3]) + LIFT,
					to = Vec3(p[n + 1], p[n + 2], p[n + 3]) + LIFT,
					color = color,
					width = 2,
					time = DEBUG_LIFETIME,
				}
			end
		end
	end)
end

commands.Add("nav_show", function()
	META.SetDebugDraw(not draw_events)
end)

return META:Register()
