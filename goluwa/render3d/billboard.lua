local billboard = library()
import.loaded["goluwa/render3d/billboard.lua"] = billboard
local event = import("goluwa/event.lua")
local ffi = require("ffi")
local Entity = import("goluwa/entities/entity.lua")
local Material = import("goluwa/render3d/material.lua")
local ModelPreview = import("goluwa/render3d/model_preview.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Texture = import("goluwa/render/texture.lua")
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

local function dilate(pixels, width, height, tile_width, passes)
	local count = width * height
	local filled = ffi.new("uint8_t[?]", count)
	local queue = ffi.new("uint32_t[?]", count)
	local depths = ffi.new("uint8_t[?]", count)
	local tail = 0
	local sum_r, sum_g, sum_b = 0, 0, 0

	for i = 0, count - 1 do
		if pixels[i * 4 + 3] > 0 then
			filled[i] = 1
			queue[tail] = i
			tail = tail + 1
			sum_r, sum_g, sum_b = sum_r + pixels[i * 4], sum_g + pixels[i * 4 + 1], sum_b + pixels[i * 4 + 2]
		end
	end

	if tail == 0 then return end

	local opaque = tail
	local head = 0

	while head < tail do
		local i = queue[head]
		head = head + 1
		local depth = depths[i]

		if depth < passes then
			local x, y = i % width, math.floor(i / width)
			local tile_start = x - x % tile_width

			for dy = -1, 1 do
				local ny = y + dy

				if ny >= 0 and ny < height then
					for dx = -1, 1 do
						local nx = x + dx

						if nx >= tile_start and nx < tile_start + tile_width then
							local j = ny * width + nx

							if filled[j] == 0 then
								filled[j] = 1
								depths[j] = depth + 1
								pixels[j * 4], pixels[j * 4 + 1], pixels[j * 4 + 2] = pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]
								queue[tail] = j
								tail = tail + 1
							end
						end
					end
				end
			end
		end
	end

	local r, g, b = sum_r / opaque, sum_g / opaque, sum_b / opaque

	for i = 0, count - 1 do
		if filled[i] == 0 then
			pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2] = r, g, b
		end
	end
end

local function build_mip_chain(pixels, width, height, cutoff)
	local levels = {{width = width, height = height, offset = 0, size = width * height * 4}}
	local total = width * height * 4
	local w, h = width, height

	while w > 1 or h > 1 do
		w, h = math.max(math.floor(w / 2), 1), math.max(math.floor(h / 2), 1)
		levels[#levels + 1] = {width = w, height = h, offset = total, size = w * h * 4}
		total = total + w * h * 4
	end

	local data = ffi.new("uint8_t[?]", total)
	ffi.copy(data, pixels, width * height * 4)
	local threshold = cutoff * 255
	local passing = 0

	for i = 0, width * height - 1 do
		if pixels[i * 4 + 3] >= threshold then passing = passing + 1 end
	end

	local coverage = passing / (width * height)

	for level = 2, #levels do
		local source, destination = levels[level - 1], levels[level]
		local source_pixels, destination_pixels = data + source.offset, data + destination.offset
		local alpha = ffi.new("float[?]", destination.width * destination.height)

		for y = 0, destination.height - 1 do
			local y0 = math.min(y * 2, source.height - 1)
			local y1 = math.min(y * 2 + 1, source.height - 1)

			for x = 0, destination.width - 1 do
				local x0 = math.min(x * 2, source.width - 1)
				local x1 = math.min(x * 2 + 1, source.width - 1)
				local i = y * destination.width + x
				local a, b, c, d = (y0 * source.width + x0) * 4,
				(y0 * source.width + x1) * 4,
				(y1 * source.width + x0) * 4,
				(y1 * source.width + x1) * 4

				for k = 0, 2 do
					destination_pixels[i * 4 + k] = (
							source_pixels[a + k] + source_pixels[b + k] + source_pixels[c + k] + source_pixels[d + k] + 2
						) / 4
				end

				alpha[i] = (source_pixels[a + 3] + source_pixels[b + 3] + source_pixels[c + 3] + source_pixels[d + 3]) / 4
			end
		end

		local count = destination.width * destination.height
		local histogram = ffi.new("uint32_t[256]")

		for i = 0, count - 1 do
			histogram[math.min(math.floor(alpha[i] + 0.5), 255)] = histogram[math.min(math.floor(alpha[i] + 0.5), 255)] + 1
		end

		local wanted, seen, quantile = coverage * count, 0, 0

		for bin = 255, 1, -1 do
			seen = seen + histogram[bin]
			quantile = bin

			if seen >= wanted then break end
		end

		local high = math.min(math.max(threshold / math.max(quantile, 1), 1), 32)

		for i = 0, count - 1 do
			destination_pixels[i * 4 + 3] = math.min(alpha[i] * high + 0.5, 255)
		end

		if destination.width == 1 and destination.height == 1 then
			destination_pixels[3] = alpha[0] > 0 and 255 or 0
		end
	end

	return data, levels, total
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
	local preview = ModelPreview.New{
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
	dilate(atlas, atlas_width, height, width, billboard.DILATE_PASSES)
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

	local mips, levels, mip_size = build_mip_chain(atlas, width * billboard.TILE_COUNT, height, material:GetAlphaCutoff())

	for _, level in ipairs(levels) do
		level.depth = 1
	end

	material:SetAlbedoTexture(
		Texture.New{
			decoded = {
				width = width * billboard.TILE_COUNT,
				height = height,
				vulkan_format = "r8g8b8a8_srgb",
				is_compressed = true,
				mip_count = #levels,
				mip_info = levels,
				data_size = mip_size,
				data = mips,
			},
			image = {usage = {"sampled", "transfer_dst", "transfer_src"}},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				mipmap_mode = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
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
			local ok, polygon, material = xpcall(billboard.Bake, debug.traceback, visual)
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

			break
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
