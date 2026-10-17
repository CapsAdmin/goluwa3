local startup = import("goluwa/startup.lua")
local billboard = {}
import.loaded["goluwa/render3d/billboard.lua"] = billboard
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local ffi = require("ffi")
local Entity = import("goluwa/entities/entity.lua")
local Material = import("goluwa/render3d/material.lua")
local ForwardPreview = import("goluwa/render3d/forward_preview.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local cutout_texture = import("goluwa/render/cutout_texture.lua")
local lod = import("goluwa/render3d/lod.lua")
local Quat = import("goluwa/structs/quat.lua")
local Rect = import("goluwa/structs/rect.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
billboard.HEIGHT = 128
billboard.MAX_WIDTH = 256
billboard.TILE_COUNT = 3
billboard.NORMAL_TILT = 0.4
billboard.PADDING = 1.02
billboard.BAKE_TIMEOUT_FRAMES = 600
billboard.DILATE_PASSES = 8
-- seconds a frame may spend baking, a bake is not interrupted so one that starts before the budget is spent finishes after it
billboard.BAKE_BUDGET = 0.1
local cache = {}
local pending = {}
local uint8_ptr_t = ffi.typeof("uint8_t *")
local VIEW_FORWARDS = {Vec3(0, 0, -1), Vec3(-1, 0, 0), Vec3(0, -1, 0)}

local function configure_camera(self)
	local view = self.view
	local rotation = Quat()
	rotation:Identity()
	rotation:RotateYaw(math.atan2(-view.forward.x, -view.forward.z))
	rotation:RotatePitch(math.asin(view.forward.y))
	view.right = rotation:GetRight()
	view.up = rotation:GetUp()
	self.camera:SetViewport(Rect(0, 0, self:GetWidth(), self:GetHeight()))
	self.camera:SetOrthoMode(true)
	self.camera:SetOrthoHalfHeight(view.half_height)
	self.camera:SetNearZ(0.01)
	self.camera:SetFarZ(view.depth * 3)
	self.camera:SetPosition(view.center - rotation:GetForward() * view.depth)
	self.camera:SetRotation(rotation)
	return self.camera
end

local function are_textures_ready(visual)
	for _, entry in ipairs(visual:GetRenderEntries()) do
		local texture = visual:GetResolvedMaterial(entry):GetAlbedoTexture()

		if texture and not texture:IsReady() then return false end
	end

	return true
end

function billboard.Bake(visual)
	local aabb = visual:BuildAABB()
	local center = Vec3(
		(aabb.min_x + aabb.max_x) * 0.5,
		(aabb.min_y + aabb.max_y) * 0.5,
		(aabb.min_z + aabb.max_z) * 0.5
	)
	local half_height = (aabb.max_y - aabb.min_y) * 0.5 * billboard.PADDING
	local half_depth = (aabb.max_z - aabb.min_z) * 0.5 * billboard.PADDING
	local half_width = math.max(aabb.max_x - aabb.min_x, aabb.max_z - aabb.min_z) * 0.5 * billboard.PADDING
	local depth = math.max(half_width, half_height) * 2 + 1
	local height = billboard.HEIGHT
	local width = math.min(
		math.max(math.floor(height * half_width / half_height + 0.5), 16),
		billboard.MAX_WIDTH
	)
	local top_scale = math.max(1, half_depth / half_height)
	local views = {}
	local atlas_width = width * billboard.TILE_COUNT
	local atlas = ffi.new("uint8_t[?]", atlas_width * height * 4)
	local preview = ForwardPreview.New{
		Width = width,
		Height = height,
		AmbientStrength = 1,
		LightStrength = 0,
		ConfigureCamera = configure_camera,
	}

	for i, forward in ipairs(VIEW_FORWARDS) do
		local scale = i == 3 and top_scale or 1
		preview.view = {
			center = center,
			forward = forward,
			half_width = half_width * scale,
			half_height = half_height * scale,
			depth = depth,
		}
		local pixels = ffi.cast(uint8_ptr_t, preview:RenderTarget(visual):Download().pixels)

		for y = 0, height - 1 do
			ffi.copy(
				atlas + (y * atlas_width + (i - 1) * width) * 4,
				pixels + y * width * 4,
				width * 4
			)
		end

		views[i] = preview.view
	end

	preview:Remove()
	local material = Material.New{
		Billboard = true,
		AlphaTest = true,
		DoubleSided = true,
		MetallicMultiplier = 0,
		RoughnessMultiplier = 0.9,
	}

	for _, entry in ipairs(visual:GetRenderEntries()) do
		local source = visual:GetResolvedMaterial(entry)

		if source:GetAlphaTest() then
			material:SetDiffuseTransmission(source:GetDiffuseTransmission())
			material:SetTransmissionColor(source:GetTransmissionColor())
			material:SetTransmissionScattering(source:GetTransmissionScattering())
			material:SetSpecularMultiplier(source:GetSpecularMultiplier())

			break
		end
	end

	material:SetAlbedoTexture(
		cutout_texture.New(
			atlas,
			atlas_width,
			height,
			{tile_width = width, dilate_passes = billboard.DILATE_PASSES, cutoff = material:GetAlphaCutoff()}
		)
	)
	local polygon = Polygon3D.New()
	local indices = {}
	local tile_uv = 1 / billboard.TILE_COUNT

	for i, view in ipairs(views) do
		local first = #polygon.Vertices

		for _, corner in ipairs{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}} do
			local offset = view.right * (
					corner[1] * view.half_width
				) + view.up * (
					corner[2] * view.half_height
				)
			local normal = view.forward + offset:GetNormalized() * billboard.NORMAL_TILT
			polygon:AddVertex{
				pos = center + offset,
				normal = normal:GetNormalized(),
				uv = Vec2((i - 1) * tile_uv + (corner[1] * 0.5 + 0.5) * tile_uv, 0.5 - corner[2] * 0.5),
			}
		end

		for _, k in ipairs{1, 2, 3, 1, 3, 4} do
			indices[#indices + 1] = first + k
		end
	end

	polygon:Upload(indices)
	local last_level, last_distance = 0, 0

	for _, entry in ipairs(visual:GetLODRenderEntries()) do
		local level = entry.polygon3d.LODLevel

		if level >= last_level then
			last_level = level
			last_distance = math.max(last_distance, entry.polygon3d.LODDistance)
		end
	end

	polygon:SetLODLevel(last_level + 1)
	polygon:SetLODDistance(math.max(lod.BILLBOARD_MIN_RADII, last_distance + lod.CRY_RADII_PER_LEVEL))
	polygon:SetLODBillboard(true)
	return polygon, material
end

local function update()
	local deadline = system.GetTime() + billboard.BAKE_BUDGET

	for path, request in pairs(pending) do
		local visual = request.entity.visual
		request.frames = request.frames + 1

		if
			not visual.Loading and
			visual:GetRenderEntries()[1] and
			(
				are_textures_ready(visual) or
				request.frames > billboard.BAKE_TIMEOUT_FRAMES
			)
		then
			pending[path] = nil
			local started = startup.Start()
			local ok, polygon, material = xpcall(billboard.Bake, debug.traceback, visual)
			startup.Add("billboard bake", started)
			request.entity:Remove()
			local callbacks = request.callbacks
			request.callbacks = nil

			if ok then
				request.polygon, request.material = polygon, material

				for _, callback in ipairs(callbacks) do
					callback(polygon, material)
				end
			else
				logf("billboard bake failed for %q: %s\n", path, polygon)
			end

			if system.GetTime() > deadline then break end
		end
	end

	if not next(pending) then event.RemoveListener("Update", "billboard_bake") end
end

function billboard.Request(model_path, callback)
	local request = cache[model_path]

	if request then
		if request.callbacks then
			list.insert(request.callbacks, callback)
		elseif request.polygon then
			callback(request.polygon, request.material)
		end

		return
	end

	local entity = Entity.New{Name = "billboard_bake"}
	entity:AddComponent("transform")
	entity:AddComponent("visual")
	entity.visual.NoBillboard = true
	entity.visual:SetVisible(false)
	entity.visual:SetCastShadows(false)
	entity.visual:SetModelPath(model_path)
	request = {callbacks = {callback}, entity = entity, frames = 0}
	cache[model_path] = request
	pending[model_path] = request
	event.AddListener("Update", "billboard_bake", update)
end

return billboard
