local event = import("goluwa/event.lua")
local pvars = import("goluwa/cli/pvars.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d, Visual
local texture_streaming = {}
pvars.StartGroup("Engine", "Textures", {prefix = "texture_"})
local budget_mib = pvars.Setup2{
	key = "r_texture_stream_budget",
	default = 1536,
	min = 64,
	integer = true,
	help = "MiB of streamed textures kept resident, the ones nothing needs up close are cut back past this",
}
pvars.EndGroup()
local PASS_FRAMES = 12
local MAX_LOADING = 8
local MAX_STARTS = 4
local MAX_UPLOADS = 3
local UPLOAD_BYTES = 24 * 1024 * 1024
local MIN_DISTANCE = 0.25
local tan, sqrt, floor, log, max, min = math.tan, math.sqrt, math.floor, math.log, math.max, math.min
local material_textures = setmetatable({}, {__mode = "k"})
local polygon_density = setmetatable({}, {__mode = "k"})
local scan_index = 0
local up, down = {}, {}

local function by_score(a, b)
	return a.stream.score > b.stream.score
end

local function by_need(a, b)
	return a.stream.need > b.stream.need
end

local function get_textures(material)
	local list = material_textures[material]

	if not list then
		list = {}

		for _, info in ipairs(material:GetTextures()) do
			list[#list + 1] = info.texture
		end

		material_textures[material] = list
	end

	return list
end

-- uv units per meter, from a sample of the triangles
local function get_uv_density(polygon, entry)
	local density = polygon_density[polygon]

	if density then return density end

	local packed = polygon.packed

	if not packed or packed.index_count < 3 then
		local box = entry.source_aabb
		local extent = max(box.max_x - box.min_x, box.max_y - box.min_y, box.max_z - box.min_z, 0.01)
		return 1 / extent
	end

	local vertices, indices = packed.vertices, packed.indices
	local step = max(1, floor(packed.index_count / 3 / 200))
	local world_area, uv_area = 0, 0

	for t = 0, packed.index_count / 3 - 1, step do
		local a, b, c = vertices[indices[t * 3]], vertices[indices[t * 3 + 1]], vertices[indices[t * 3 + 2]]
		local ax, ay, az = a.position[0], a.position[1], a.position[2]
		local e1x, e1y, e1z = b.position[0] - ax, b.position[1] - ay, b.position[2] - az
		local e2x, e2y, e2z = c.position[0] - ax, c.position[1] - ay, c.position[2] - az
		local cx, cy, cz = e1y * e2z - e1z * e2y, e1z * e2x - e1x * e2z, e1x * e2y - e1y * e2x
		world_area = world_area + sqrt(cx * cx + cy * cy + cz * cz) * 0.5
		uv_area = uv_area + math.abs(
				(
						b.uv[0] - a.uv[0]
					) * (
						c.uv[1] - a.uv[1]
					) - (
						c.uv[0] - a.uv[0]
					) * (
						b.uv[1] - a.uv[1]
					)
			) * 0.5
	end

	density = world_area > 0 and uv_area > 0 and sqrt(uv_area / world_area) or 1
	polygon_density[polygon] = density
	return density
end

local function scan(components, first, last, camera_x, camera_y, camera_z, pixels_per_meter_at_one)
	for i = first, last do
		local component = components[i]
		local box = component:GetWorldAABB()

		if box and box.min_x <= box.max_x then
			local dx = max(box.min_x - camera_x, 0, camera_x - box.max_x)
			local dy = max(box.min_y - camera_y, 0, camera_y - box.max_y)
			local dz = max(box.min_z - camera_z, 0, camera_z - box.max_z)
			local pixels_per_meter = pixels_per_meter_at_one / max(sqrt(dx * dx + dy * dy + dz * dz), MIN_DISTANCE)

			for _, entry in ipairs(component:GetRenderEntries()) do
				local material = component:GetResolvedMaterial(entry)
				local list = get_textures(material)

				for t = 1, #list do
					local stream = list[t].stream

					if stream then
						local uv_scale = 1
						local transform = material:GetBaseTextureTransformU()

						if transform then uv_scale = max(math.abs(transform.x), 1e-3) end

						local need = pixels_per_meter / (get_uv_density(entry.polygon3d, entry) * uv_scale)

						if need > stream.need_next then stream.need_next = need end
					end
				end
			end
		end
	end
end

function texture_streaming.Update()
	Texture.PollStreamUploads()
	local streamed = Texture.GetStreamed()

	if not next(streamed) then return end

	render3d = render3d or import("goluwa/render3d/render3d.lua")
	Visual = Visual or import("goluwa/entities/components/visual.lua")
	local camera = render3d.GetCamera()

	if not camera then return end

	local position = camera:GetPosition()
	local components = Visual.Instances
	local count = #components
	local slice = math.ceil(count / PASS_FRAMES)
	local first = scan_index + 1
	local last = min(first + slice - 1, count)
	local height = render.GetRenderImageSize().y
	scan(
		components,
		first,
		last,
		position.x,
		position.y,
		position.z,
		height / (2 * tan(camera:GetFOV() / 2))
	)
	scan_index = last

	if scan_index >= count then
		scan_index = 0

		for texture in pairs(streamed) do
			local stream = texture.stream
			stream.need = stream.need_next
			stream.need_next = 0
			local ratio = stream.full_size / max(min(stream.need, stream.full_size), 1)
			stream.wanted = min(stream.base_drop, stream.min_drop + floor(log(ratio) / log(2) + 1e-6))
		end
	end

	local total = 0
	local uploads, upload_bytes = 0, 0
	local loading = 0
	local n_up, n_down = 0, 0

	for texture in pairs(streamed) do
		local stream = texture.stream

		if stream.pending and uploads < MAX_UPLOADS and upload_bytes < UPLOAD_BYTES then
			upload_bytes = upload_bytes + stream.bytes_from[stream.target + 1]
			texture:UploadStreamLevel(stream.pending, stream.target)
			stream.pending = nil
			uploads = uploads + 1
		end

		total = total + stream.bytes

		if stream.pending then
			total = total + stream.bytes_from[stream.target + 1] - stream.bytes
		elseif stream.loading or stream.uploading then
			loading = loading + 1
			total = total + stream.bytes_from[stream.target + 1] - stream.bytes
		elseif stream.wanted < stream.drop then
			n_up = n_up + 1
			up[n_up] = texture
		elseif stream.wanted > stream.drop then
			n_down = n_down + 1
			down[n_down] = texture
		end
	end

	local budget = budget_mib:Get() * 1024 * 1024
	local starts = 0
	local to_free = total - budget

	if n_up > 0 then
		table.sort(up, by_need)

		for i = 1, n_up do
			if starts >= MAX_STARTS or loading >= MAX_LOADING then break end

			local stream = up[i].stream
			local extra = stream.bytes_from[stream.wanted + 1] - stream.bytes

			if total + extra > budget then
				to_free = max(to_free, total + extra - budget)

				break
			end

			up[i]:RequestStreamLevel(stream.wanted)
			total = total + extra
			to_free = total - budget
			starts = starts + 1
			loading = loading + 1
		end
	end

	if to_free > 0 and n_down > 0 then
		for i = 1, n_down do
			local stream = down[i].stream
			stream.score = stream.bytes - stream.bytes_from[stream.wanted + 1]
		end

		table.sort(down, by_score)

		for i = 1, n_down do
			if starts >= MAX_STARTS or loading >= MAX_LOADING or to_free <= 0 then break end

			down[i]:RequestStreamLevel(down[i].stream.wanted)
			to_free = to_free - down[i].stream.score
			starts = starts + 1
			loading = loading + 1
		end
	end

	for i = 1, max(n_up, n_down) do
		up[i], down[i] = nil, nil
	end
end

event.AddListener("Update", "texture_streaming", texture_streaming.Update)
return texture_streaming
