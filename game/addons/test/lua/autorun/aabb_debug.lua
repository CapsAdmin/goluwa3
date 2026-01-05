local render3d = require("render3d.render3d")
local event = require("event")
local ecs = require("ecs")
local Material = require("render3d.material")
local Polygon3D = require("render3d.polygon_3d")
local Vec3 = require("structs.vec3")
local Color = require("structs.color")
local Matrix44 = require("structs.matrix44")
local aabb_enabled = false
local unit_cube_mesh = nil

local function get_unit_cube_mesh()
	if not unit_cube_mesh then
		local poly = Polygon3D.New()
		poly:CreateCube(0.5) -- 1x1x1 cube centered at 0,0,0
		poly:AddSubMesh(#poly.Vertices)
		poly:Upload()
		unit_cube_mesh = poly:GetMesh()
	end

	return unit_cube_mesh
end

local aabb_material = Material.New(
	{
		AlbedoTexture = nil,
		ColorMultiplier = Color(1, 1, 1, 1),
		EmissiveMultiplier = Color(1, 1, 1, 1),
		AlbedoAlphaIsEmissive = true,
		Translucent = true,
		DepthWrite = false,
	}
)

event.AddListener("KeyInput", "aabb_debug_toggle", function(key, press)
	if not press then return end

	if key == "b" then
		aabb_enabled = not aabb_enabled
		print("[AABB Debug] " .. (aabb_enabled and "Enabled" or "Disabled"))
	end
end)

event.AddListener(
	"Draw3DGeometry",
	"aabb_debug_draw",
	function(cmd, dt)
		if not aabb_enabled then return end

		local mesh = get_unit_cube_mesh()

		if not mesh then return end

		local entities = ecs.GetEntitiesWithComponent("model")

		for _, ent in ipairs(entities) do
			local model = ent:GetComponent("model")
			local aabb = model:GetAABB()

			if aabb and aabb.min_x ~= math.huge then
				local world_matrix = model:GetWorldMatrix()
				local min = aabb:GetMin()
				local max = aabb:GetMax()
				local center = (min + max) / 2
				local size = max - min
				-- Transform unit cube to AABB
				local m = Matrix44():Identity()
				m:SetTranslation(center:Unpack())
				m:Scale(size:Unpack())
				local final_matrix = m:GetMultiplied(world_matrix)
				render3d.SetWorldMatrix(final_matrix)
				-- Draw solid part
				aabb_material:SetColorMultiplier(Color(1, 1, 1, 0.6))
				render3d.SetMaterial(aabb_material)
				render3d.UploadConstants(cmd)
				mesh:DrawIndexed(cmd)
			end
		end
	end,
	{priority = -100}
)
