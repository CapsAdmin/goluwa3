local vmt_loader = import("goluwa/source_engine/vmt.lua")
local vfs = import("goluwa/vfs.lua")
local game = import("goluwa/source_engine/game.lua")
local tasks = import("goluwa/tasks.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Material = import("goluwa/render3d/material.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Color = import("goluwa/structs/color.lua")
local math3d = import("goluwa/render3d/math3d.lua")
local R = vfs.GetAbsolutePath
local bit = require("bit")
local units = import("goluwa/source_engine/units.lua")
local collision = import("goluwa/source_engine/bsp_collision.lua")
local brush_geometry = import("goluwa/source_engine/brush_geometry.lua")
local bsp_clip = import("goluwa/source_engine/bsp_clip.lua")
local static_geometry = import("goluwa/source_engine/static_geometry.lua")
local bsp = {}
bsp.ReplaceNodraw = true
local loaded = {}
local CUBEMAPS = true
local AIR_EPSILON = 2
local BSP_CONTENTS_SOLID = collision.BSP_CONTENTS_SOLID
local get_displacement_corners = collision.get_displacement_corners
local collect_water_volumes = collision.collect_water_volumes
local get_model_lowest_point = collision.get_model_lowest_point
local get_model_brush_set = collision.get_model_brush_set
local is_collidable_brush = collision.is_collidable_brush
local get_face_first_source_height = collision.get_face_first_source_height
local source_pos_to_engine = collision.source_pos_to_engine
local source_height_to_engine_y = collision.source_height_to_engine_y

local function convert_bsp_types(header)
	local function vec3(a)
		return Vec3(a[1], a[2], a[3])
	end

	for _, ent in ipairs(header.entities) do
		for key, value in pairs(ent) do
			if type(value) == "table" and value.type then
				if value.type == "ang3" then
					ent[key] = Ang3(unpack(value))
				elseif value.type == "color" then
					ent[key] = Color.FromBytes(unpack(value))
				else
					ent[key] = Vec3(unpack(value))
				end
			end
		end

		if ent.classname == "sky_camera" then header.sky_camera = ent end
	end

	for _, plane in ipairs(header.planes) do
		plane.normal = vec3(plane.normal)
	end

	for i, vertex in ipairs(header.vertices) do
		header.vertices[i] = vec3(vertex)
	end

	for _, texdata in ipairs(header.texdatas) do
		texdata.reflectivity = vec3(texdata.reflectivity)
	end

	for _, overlay in ipairs(header.overlays or {}) do
		overlay.origin = vec3(overlay.origin)
		overlay.normal = vec3(overlay.normal)
	end

	for _, displacement in ipairs(header.displacements) do
		displacement.startPosition = vec3(displacement.startPosition)

		for _, point in ipairs(displacement.heightmap) do
			point.pos = vec3(point.pos)
		end
	end

	for _, model in ipairs(header.models) do
		model.mins = vec3(model.mins)
		model.maxs = vec3(model.maxs)
		model.origin = vec3(model.origin)
	end

	for _, leaf in ipairs(header.leafs) do
		leaf.mins = vec3(leaf.mins)
		leaf.maxs = vec3(leaf.maxs)
	end

	for _, cubemap in ipairs(header.cubemaps or {}) do
		cubemap.origin = Vec3(-cubemap.origin[2], cubemap.origin[3], -cubemap.origin[1])
	end

	return header
end

local decode_job_source = [=[
	local input = ...
	local bsp = import("goluwa/codecs/bsp.lua")
	local stage = not _G.thread_pool_job and import("goluwa/tasks.lua").Wait or nil
	return assert(bsp.Decode(input.data, {cubemaps = input.cubemaps}, stage))
]=]

function bsp.Load(path)
	path = assert(R(path) or nil)

	if loaded[path] then
		logn("map already loaded: ", path)
		return loaded[path]
	end

	logn("loading map: ", path)
	local bsp_file = assert(vfs.Open(path))

	if bsp_file:GetSize() == 0 then error("map is empty? (size is 0)") end

	tasks.Report("reading bsp")
	local bsp_data = bsp_file:ReadBytes(bsp_file:GetSize())
	bsp_file:Close()
	local header = thread_pool.Run(decode_job_source, {data = bsp_data, cubemaps = CUBEMAPS}, #bsp_data):Await()
	convert_bsp_types(header)
	tasks.Wait()
	tasks.Report("mounting pak")
	game.MountMapPak(path)
	bsp_data = nil

	if CUBEMAPS then
		if not header.cubemaps then
			print("no cubemaps found in map")
		else
			print("found ", #header.cubemaps, " cubemaps in map")
		end
	end

	local nodes = header.nodes
	local leafs = header.leafs
	local leaf_faces = header.leaf_faces
	local areas = header.areas
	local areaportals = header.areaportals
	local headnode = header.models[1].headnode

	local function point_leaf(pos)
		local node = headnode

		while node >= 0 do
			local n = nodes[node + 1]
			local plane = header.planes[n[1] + 1]
			node = plane.normal:Dot(pos) >= plane.dist and n[2] or n[3]
		end

		return leafs[-node]
	end

	local function nearest_area(pos)
		local best_area, best_distance = 0, math.huge

		for _, leaf in ipairs(leafs) do
			if leaf.area ~= 0 and bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 then
				local dx = math.max(leaf.mins.x - pos.x, 0, pos.x - leaf.maxs.x)
				local dy = math.max(leaf.mins.y - pos.y, 0, pos.y - leaf.maxs.y)
				local dz = math.max(leaf.mins.z - pos.z, 0, pos.z - leaf.maxs.z)
				local distance = dx * dx + dy * dy + dz * dz

				if distance < best_distance then
					best_area, best_distance = leaf.area, distance
				end
			end
		end

		return best_area
	end

	local function get_joined_areas(area)
		local out = {}
		local stack = {area}

		while stack[1] do
			local area = list.remove(stack)

			if not out[area] then
				out[area] = true
				local info = areas[area + 1]

				if info then
					for i = 1, info.numareaportals do
						list.insert(stack, areaportals[info.firstareaportal + i])
					end
				end
			end
		end

		return out
	end

	local sky_areas = header.sky_camera and
		get_joined_areas(point_leaf(header.sky_camera.origin).area) or
		{}
	local area_groups = {}
	local group_count = 0

	for area = 1, #areas - 1 do
		if not area_groups[area] and not sky_areas[area] then
			group_count = group_count + 1

			for joined in pairs(get_joined_areas(area)) do
				area_groups[joined] = group_count
			end
		end
	end

	logn("found ", group_count, " visibility groups in ", #areas - 1, " areas")
	local group_boxes = {}

	do
		local candidates = {}

		for _, leaf in ipairs(leafs) do
			local id = area_groups[leaf.area]

			if id and bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 then
				local a = units.PositionToEngine(leaf.mins)
				local b = units.PositionToEngine(leaf.maxs)
				local min_x, min_y, min_z = math.min(a.x, b.x), math.min(a.y, b.y), math.min(a.z, b.z)
				local max_x, max_y, max_z = math.max(a.x, b.x), math.max(a.y, b.y), math.max(a.z, b.z)
				candidates[id] = candidates[id] or {}
				list.insert(
					candidates[id],
					{
						min_x,
						min_y,
						min_z,
						max_x,
						max_y,
						max_z,
						(
							max_x - min_x
						) * (
							max_y - min_y
						) * (
							max_z - min_z
						),
					}
				)
			end
		end

		for id, boxes in pairs(candidates) do
			table.sort(boxes, function(a, b)
				return a[7] > b[7]
			end)

			local kept = {}
			local flat = {}

			for _, box in ipairs(boxes) do
				local contained = false

				for _, other in ipairs(kept) do
					if
						box[1] >= other[1] and
						box[2] >= other[2] and
						box[3] >= other[3] and
						box[4] <= other[4] and
						box[5] <= other[5] and
						box[6] <= other[6]
					then
						contained = true

						break
					end
				end

				if not contained then
					list.insert(kept, box)

					for k = 1, 6 do
						list.insert(flat, box[k])
					end
				end
			end

			group_boxes[id] = flat
			tasks.Wait()
		end
	end

	local face_areas = {}

	for _, leaf in ipairs(leafs) do
		if leaf.area ~= 0 then
			for j = 1, leaf.leaf_face_count do
				local index = leaf_faces[leaf.first_leaf_face + j] + 1
				face_areas[index] = face_areas[index] or leaf.area
			end
		end
	end

	local probe_distances = {1, 16, 64, 256}

	local function get_face_area(index)
		if face_areas[index] then return face_areas[index] end

		local face = header.faces[index]
		local center = Vec3()

		for j = 1, face.numedges do
			local surfedge = header.surfedges[face.firstedge + j]
			center = center + header.vertices[1 + header.edges[1 + math.abs(surfedge)][surfedge < 0 and
				2 or
				1]]
		end

		center = center / face.numedges
		local normal = header.planes[face.planenum + 1].normal

		if face.side ~= 0 then normal = normal * -1 end

		for _, distance in ipairs(probe_distances) do
			local leaf = point_leaf(center + normal * distance)

			if bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 then return leaf.area end

			leaf = point_leaf(center - normal * distance)

			if bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 then return leaf.area end
		end

		return nearest_area(center)
	end

	local sky_clip_aabb
	local sky_origin, sky_scale

	if header.sky_camera then
		sky_origin = header.sky_camera.origin
		sky_scale = header.sky_camera.scale

		function point_leaf_in_sky(pos)
			return sky_areas[point_leaf(pos).area] == true
		end

		local world_min = Vec3(math.huge, math.huge, math.huge)
		local world_max = Vec3(-math.huge, -math.huge, -math.huge)

		for _, leaf in ipairs(leafs) do
			if
				bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 and
				leaf.area ~= 0 and
				not sky_areas[leaf.area]
			then
				for _, axis in ipairs({"x", "y", "z"}) do
					world_min[axis] = math.min(world_min[axis], leaf.mins[axis])
					world_max[axis] = math.max(world_max[axis], leaf.maxs[axis])
				end
			end
		end

		do
			local a = units.PositionToEngine(world_min)
			local b = units.PositionToEngine(world_max)
			sky_clip_aabb = AABB(
				math.min(a.x, b.x),
				math.min(a.y, b.y),
				math.min(a.z, b.z),
				math.max(a.x, b.x),
				math.max(a.y, b.y),
				math.max(a.z, b.z)
			)
		end
	end

	-- the playable air of the map: leaves that are not solid and not part of the 3D skybox. Geometry of the 3D skybox is
	-- placed over the map, what lies in or touches this air has to go, otherwise it z fights with the map or floats in rooms
	local near_map_air, is_map_air

	do
		local air_probes = {
			Vec3(0, 0, 0),
			Vec3(AIR_EPSILON, 0, 0),
			Vec3(-AIR_EPSILON, 0, 0),
			Vec3(0, AIR_EPSILON, 0),
			Vec3(0, -AIR_EPSILON, 0),
			Vec3(0, 0, AIR_EPSILON),
			Vec3(0, 0, -AIR_EPSILON),
		}

		function is_map_air(position)
			local leaf = point_leaf(position)
			return bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 and
				leaf.area ~= 0 and
				not sky_areas[leaf.area]
		end

		function near_map_air(position)
			for _, offset in ipairs(air_probes) do
				if is_map_air(position + offset) then return true end
			end

			return false
		end
	end

	-- cuts the 3D skybox geometry away where it is inside of the map's air
	local sky_clipper = sky_origin and
		bsp_clip.New(
			nodes,
			header.planes,
			leafs,
			headnode,
			function(leaf)
				return bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 and
					leaf.area ~= 0 and
					not sky_areas[leaf.area]
			end
		)

	do
		local probe_offsets = {
			Vec3(0, 0, 16),
			Vec3(0, 0, -16),
			Vec3(16, 0, 0),
			Vec3(-16, 0, 0),
			Vec3(0, 16, 0),
			Vec3(0, -16, 0),
		}

		for _, ent in ipairs(header.entities) do
			if ent.origin then
				local area = 0

				if ent.classname == "static_entity" and ent.leaf_count > 0 then
					for i = 1, ent.leaf_count do
						local leaf_area = leafs[header.static_prop_leafs[ent.first_leaf + i] + 1].area

						if sky_areas[leaf_area] then
							area = leaf_area

							break
						end

						if area == 0 then area = leaf_area end
					end
				else
					area = point_leaf(ent.origin).area

					for _, offset in ipairs(probe_offsets) do
						if area ~= 0 then break end

						area = point_leaf(ent.origin + offset).area
					end

					if area == 0 then area = nearest_area(ent.origin) end
				end

				ent.visibility_group = area_groups[area]

				if sky_areas[area] then
					ent.origin = (ent.origin - sky_origin) * sky_scale
					ent.model_size_mult = sky_scale
					ent.sky_clip = sky_clip_aabb
					ent.dropped = near_map_air(ent.origin)
				end
			end
		end
	end

	header.visibility = {
		point_leaf = point_leaf,
		area_groups = area_groups,
		group_count = group_count,
		group_boxes = group_boxes,
	}

	do
		local function engine_to_source(pos)
			return units.PositionFromEngine(pos)
		end

		header.water_volumes = collect_water_volumes(header, function(min, max)
			local center = (engine_to_source(min) + engine_to_source(max)) / 2
			local area = point_leaf(center).area

			if area == 0 then area = nearest_area(center) end

			if not sky_areas[area] then return min, max, area_groups[area] end

			local a = source_pos_to_engine((engine_to_source(min) - sky_origin) * sky_scale)
			local b = source_pos_to_engine((engine_to_source(max) - sky_origin) * sky_scale)
			return Vec3(math.min(a.x, b.x), math.min(a.y, b.y), math.min(a.z, b.z)),
			Vec3(math.max(a.x, b.x), math.max(a.y, b.y), math.max(a.z, b.z))
		end)
		logn("found ", #header.water_volumes, " water volumes in map")
	end

	header.lowest_point = get_model_lowest_point(header.models and header.models[1])
	header.ocean_level = nil
	local texinfos = {}
	local texinfo_lookup = {}

	local function get_texinfo(index)
		local compact = texinfo_lookup[index]

		if not compact then
			local texinfo = header.texinfos[1 + index]
			local texdata = header.texdatas[1 + texinfo.texdata]
			local vecs = {}

			for k = 1, 8 do
				vecs[k] = texinfo.textureVecs[k] / (k <= 4 and texdata.width or texdata.height)
			end

			texinfos[#texinfos + 1] = {
				texname = header.texdatastringdata[1 + texdata.nameStringTableID],
				vecs = vecs,
			}
			compact = #texinfos
			texinfo_lookup[index] = compact
		end

		return compact
	end

	local sky_texinfo_lookup = {}

	local function get_sky_texinfo(index)
		local compact = sky_texinfo_lookup[index]

		if not compact then
			local base = texinfos[get_texinfo(index)]
			local vecs = {}

			for row = 0, 1 do
				local o = row * 4
				vecs[o + 1] = base.vecs[o + 1] / sky_scale
				vecs[o + 2] = base.vecs[o + 2] / sky_scale
				vecs[o + 3] = base.vecs[o + 3] / sky_scale
				vecs[o + 4] = base.vecs[o + 4] + base.vecs[o + 1] * sky_origin.x + base.vecs[o + 2] * sky_origin.y + base.vecs[o + 3] * sky_origin.z
			end

			texinfos[#texinfos + 1] = {
				texname = base.texname,
				vecs = vecs,
			}
			compact = #texinfos
			sky_texinfo_lookup[index] = compact
		end

		return compact
	end

	local meshes = {}
	local face_meshes = {}

	-- Cuts a displacement of the 3D skybox against the map's air. Returns nil when nothing had to be cut, otherwise the
	-- remaining triangles as a mesh {Texinfo, Vertices} with 9 floats per vertex: position, uv, blend and normal
	local function clip_sky_displacement(dims, scaled, scaled_flats, alphas, texinfo_index)
		local vecs = texinfos[texinfo_index].vecs
		local normals = static_geometry.ComputeDisplacementNormals{dims = dims, positions = scaled}
		local vertices = {}

		for i = 1, dims * dims do
			local flat, normal = scaled_flats[i], normals[i]:GetNormalized()
			vertices[i] = {
				pos = scaled[i],
				attributes = {
					vecs[1] * flat.x + vecs[2] * flat.y + vecs[3] * flat.z + vecs[4],
					vecs[5] * flat.x + vecs[6] * flat.y + vecs[7] * flat.z + vecs[8],
					math.clamp(alphas[i] / 255, 0, 1),
					normal.x,
					normal.y,
					normal.z,
				},
			}
		end

		local clipped = {}
		local affected = false

		for x = 1, dims - 1 do
			for y = 1, dims - 1 do
				local a = y * dims + x
				local b = (y - 1) * dims + x
				local c = a + 1
				local d = b + 1

				for _, triangle in ipairs{{a, c, b}, {c, d, b}} do
					local polygon = {vertices[triangle[1]], vertices[triangle[2]], vertices[triangle[3]]}
					local fragments = sky_clipper:ClipPolygon(polygon)

					if #fragments ~= 1 or fragments[1] ~= polygon then affected = true end

					for _, fragment in ipairs(fragments) do
						list.insert(clipped, fragment)
					end
				end
			end
		end

		if not affected then return nil end

		local floats = {}

		for _, fragment in ipairs(clipped) do
			for j = 2, #fragment - 1 do
				for _, vertex in ipairs{fragment[1], fragment[j], fragment[j + 1]} do
					local attributes = vertex.attributes
					list.insert(floats, vertex.pos.x)
					list.insert(floats, vertex.pos.y)
					list.insert(floats, vertex.pos.z)

					for k = 1, 6 do
						list.insert(floats, attributes[k])
					end
				end
			end
		end

		return {Texinfo = texinfo_index, Vertices = floats}
	end

	local displacements = {}
	local displacement_by_face = {}

	do
		local function lerp_corners(dims, corners, start_corner, dispinfo, x, y)
			local data = dispinfo.heightmap[(y - 1) * dims + x]
			local flat = math3d.BilerpVec3(
				corners[1 + (start_corner + 0) % 4],
				corners[1 + (start_corner + 1) % 4],
				corners[1 + (start_corner + 3) % 4],
				corners[1 + (start_corner + 2) % 4],
				(y - 1) / (dims - 1),
				(x - 1) / (dims - 1)
			)
			return flat + data.pos * data.dist, data.alpha, flat
		end

		local world_model = header.models[1]

		for i = 1, world_model.numfaces do
			local face = header.faces[world_model.firstface + i]
			local area = get_face_area(world_model.firstface + i)
			local in_sky = sky_areas[area] == true
			local texinfo = header.texinfos[1 + face.texinfo]
			local texdata = texinfo and header.texdatas[1 + texinfo.texdata]
			local texname_lower = header.texdatastringdata[1 + texdata.nameStringTableID]:lower()

			if texname_lower:find("skyb", nil, true) then goto continue end

			if texname_lower:find("water", nil, true) then
				if header.ocean_level == nil then
					local source_height = get_face_first_source_height(header, face)

					if source_height ~= nil then
						if in_sky then source_height = (source_height - sky_origin.z) * sky_scale end

						header.ocean_level = source_height_to_engine_y(source_height)
					end
				end

				goto continue
			end

			if face.dispinfo ~= -1 then
				local info = header.displacements[face.dispinfo + 1]
				local corners, start_corner = get_displacement_corners(header, info)
				local dims = 2 ^ info.power + 1
				local positions, alphas, flats, flat_positions = {}, {}, {}, {}

				for y = 1, dims do
					for x = 1, dims do
						local index = (y - 1) * dims + x
						local position, alpha, flat = lerp_corners(dims, corners, start_corner, info, x, y)
						positions[index], alphas[index], flats[index] = position, alpha, flat
						flat_positions[index * 3 - 2], flat_positions[index * 3 - 1], flat_positions[index * 3] = position.x, position.y, position.z
					end
				end

				local record_corners = {
					corners[1 + (
						start_corner + 0
					) % 4],
					corners[1 + (
						start_corner + 1
					) % 4],
					corners[1 + (
						start_corner + 3
					) % 4],
					corners[1 + (
						start_corner + 2
					) % 4],
				}
				local texinfo_index = get_texinfo(face.texinfo)
				local mesh

				if in_sky then
					local scaled, scaled_flats = {}, {}

					for index = 1, dims * dims do
						scaled[index] = (positions[index] - sky_origin) * sky_scale
						scaled_flats[index] = (flats[index] - sky_origin) * sky_scale
						flat_positions[index * 3 - 2], flat_positions[index * 3 - 1], flat_positions[index * 3] = scaled[index].x, scaled[index].y, scaled[index].z
					end

					for k, corner in ipairs(record_corners) do
						record_corners[k] = (corner - sky_origin) * sky_scale
					end

					texinfo_index = get_sky_texinfo(face.texinfo)
					mesh = clip_sky_displacement(dims, scaled, scaled_flats, alphas, texinfo_index)
				end

				if mesh then
					mesh.Group = 0

					if mesh.Vertices[1] then list.insert(meshes, mesh) end
				else
					list.insert(
						displacements,
						{
							Power = info.power,
							Corners = record_corners,
							Positions = flat_positions,
							Alphas = alphas,
							Texinfo = texinfo_index,
							Group = area_groups[area] or 0,
							Normal = header.planes[face.planenum + 1].normal,
							Sky = in_sky or nil,
						}
					)
					displacement_by_face[world_model.firstface + i] = #displacements
				end
			end

			::continue::

			tasks.Wait()
		end
	end

	local brush_list = {}
	local brush_planes = {}
	local side_candidates = {}

	do
		local SURF_SKIP_DRAW = 0x2 + 0x4 + 0x80 + 0x100 + 0x200
		local displacement_corners = {}

		for face_index = 1, #header.faces do
			local face = header.faces[face_index]

			if face.dispinfo ~= -1 then
				local key = bit.rshift(face.planenum, 1) * 65536 + face.texinfo + 1
				local corners = {}

				for j = 1, face.numedges do
					local surfedge = header.surfedges[face.firstedge + j]
					corners[j] = header.vertices[1 + header.edges[1 + math.abs(surfedge)][surfedge < 0 and
					2 or
					1]]
				end

				displacement_corners[key] = displacement_corners[key] or {}
				list.insert(displacement_corners[key], corners)
			end
		end

		local brush_indices = {}

		for index in pairs(get_model_brush_set(header, 0)) do
			list.insert(brush_indices, index + 1)
		end

		table.sort(brush_indices)

		for _, brush_index in ipairs(brush_indices) do
			local brush = header.brushes[brush_index]
			local planes = {}
			local sides = {}

			for side_index = 1, brush.numsides do
				local side = header.brushsides[brush.firstside + side_index]

				if side.bevel == 0 then
					list.insert(planes, header.planes[side.planenum + 1])
					list.insert(sides, side)
				end
			end

			if #sides >= 4 then
				local flat = {}
				local has_geometry = false
				local sky = false
				local side_texinfo = {}
				local hull = false

				for side_index, side in ipairs(sides) do
					local plane = planes[side_index]
					local polygon = brush_geometry.ClipSide(planes, side_index)
					local texinfo = side.texinfo >= 0 and header.texinfos[1 + side.texinfo]
					local texdata = texinfo and header.texdatas[1 + texinfo.texdata]
					local texname = texdata and header.texdatastringdata[1 + texdata.nameStringTableID]
					local visible, group = false, 0
					local center_point, side_area

					if polygon then
						center_point = Vec3(0, 0, 0)

						for _, point in ipairs(polygon) do
							center_point = center_point + point
						end

						center_point = center_point / #polygon
						side_area = 0

						for _, distance in ipairs(probe_distances) do
							local leaf = point_leaf(center_point + plane.normal * distance)

							if bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 and leaf.area ~= 0 then
								side_area = leaf.area

								break
							end
						end

						if side_area == 0 then side_area = nearest_area(center_point) end

						if sky_areas[side_area] then sky = true end
					end

					local texinfo_index = side.texinfo

					-- a nodraw face takes the texture of the face opposite of it, or of the most opposed face that is drawn when the
					-- opposite one is nodraw too. There is nothing to look at otherwise now that the whole map can be seen from the outside
					if
						bsp.ReplaceNodraw and
						polygon and
						texdata and
						(
							bit.band(texinfo.flags, 0x80) ~= 0 or
							texname:lower():find("nodraw", nil, true)
						)
					then
						local best, best_dot = nil, math.huge

						for other_index, other in ipairs(sides) do
							if other_index ~= side_index and other.texinfo >= 0 then
								local other_texinfo = header.texinfos[1 + other.texinfo]
								local other_texdata = header.texdatas[1 + other_texinfo.texdata]
								local other_name = header.texdatastringdata[1 + other_texdata.nameStringTableID]:lower()

								if
									bit.band(other_texinfo.flags, SURF_SKIP_DRAW) == 0 and
									not other_name:find("skyb", nil, true)
									and
									not other_name:find("water", nil, true)
									and
									not other_name:find("nodraw", nil, true)
								then
									local dot = plane.normal:Dot(planes[other_index].normal)

									if dot < best_dot then best, best_dot = other_index, dot end
								end
							end
						end

						if best then
							texinfo_index = sides[best].texinfo
							texinfo = header.texinfos[1 + texinfo_index]
							texdata = header.texdatas[1 + texinfo.texdata]
							texname = header.texdatastringdata[1 + texdata.nameStringTableID]
						end
					end

					side_texinfo[side_index] = texinfo_index

					if polygon and texdata then
						local texname_lower = texname:lower()

						if texname_lower:find("skyb", nil, true) then hull = true end

						if
							bit.band(texinfo.flags, SURF_SKIP_DRAW) == 0 and
							not texname_lower:find("skyb", nil, true)
							and
							not texname_lower:find("water", nil, true)
						then
							local is_displacement = false
							local candidates = displacement_corners[bit.rshift(side.planenum, 1) * 65536 + side.texinfo + 1]

							if candidates then
								for _, corners in ipairs(candidates) do
									local inside = true

									for _, corner in ipairs(corners) do
										for _, other in ipairs(planes) do
											if other.normal:Dot(corner) - other.dist > 1 then
												inside = false

												break
											end
										end

										if not inside then break end
									end

									if inside then
										is_displacement = true

										break
									end
								end
							end

							if not is_displacement then
								group = sky_areas[side_area] and 0 or area_groups[side_area] or 0
								visible = true
								has_geometry = true
							end
						end
					end

					list.insert(flat, plane.normal.x)
					list.insert(flat, plane.normal.y)
					list.insert(flat, plane.normal.z)
					list.insert(flat, plane.dist)
					list.insert(flat, texdata and get_texinfo(texinfo_index) or 0)
					list.insert(flat, group)
					list.insert(flat, visible and 1 or 0)
				end

				local collide = is_collidable_brush(brush)

				if hull then

				-- a brush with a skybox face closes off the map or the 3D skybox, it is invisible and would only be a wall
				elseif sky and not has_geometry then

				-- nothing of it is drawn, such a brush only bounds the 3D skybox and has no use as collision
				elseif sky then
					local brush_sides = {}

					for side_index, plane in ipairs(planes) do
						local o = (side_index - 1) * 7
						brush_sides[side_index] = {
							normal = plane.normal,
							dist = (plane.dist - plane.normal:Dot(sky_origin)) * sky_scale,
							texinfo = flat[o + 5] > 0 and get_sky_texinfo(side_texinfo[side_index]) or 0,
							visible = flat[o + 7],
						}
					end

					for _, piece in ipairs(sky_clipper:ClipBrush(brush_sides)) do
						local piece_flat = {}
						local visible = false

						-- The faces are cut against the map like everything else. A face that is partly cut, for instance one
						-- that lies on a wall of the map, is drawn by a mesh of what is left of it instead of by the brush.
						for side_index, side in ipairs(piece) do
							local polygon = side.visible == 1 and brush_geometry.ClipSide(piece, side_index)

							if polygon then
								local vecs = texinfos[side.texinfo].vecs
								local vertices = {}

								for i, point in ipairs(polygon) do
									vertices[i] = {
										pos = point,
										attributes = {
											vecs[1] * point.x + vecs[2] * point.y + vecs[3] * point.z + vecs[4],
											vecs[5] * point.x + vecs[6] * point.y + vecs[7] * point.z + vecs[8],
										},
									}
								end

								local fragments = sky_clipper:ClipPolygon(vertices)

								if #fragments ~= 1 or fragments[1] ~= vertices then
									local face_mesh = face_meshes[side.texinfo]

									if not face_mesh then
										face_mesh = {Texinfo = side.texinfo, Vertices = {}, Group = 0, Collide = false}
										face_meshes[side.texinfo] = face_mesh
										list.insert(meshes, face_mesh)
									end

									local normal = units.PositionToEngine(side.normal):GetNormalized()

									for _, fragment in ipairs(fragments) do
										for j = 2, #fragment - 1 do
											for _, vertex in ipairs{fragment[1], fragment[j], fragment[j + 1]} do
												local floats = face_mesh.Vertices
												list.insert(floats, vertex.pos.x)
												list.insert(floats, vertex.pos.y)
												list.insert(floats, vertex.pos.z)
												list.insert(floats, vertex.attributes[1])
												list.insert(floats, vertex.attributes[2])
												list.insert(floats, 0)
												list.insert(floats, normal.x)
												list.insert(floats, normal.y)
												list.insert(floats, normal.z)
											end
										end
									end

									piece[side_index] = {normal = side.normal, dist = side.dist, texinfo = side.texinfo}
								end
							end
						end

						for _, side in ipairs(piece) do
							list.insert(piece_flat, side.normal.x)
							list.insert(piece_flat, side.normal.y)
							list.insert(piece_flat, side.normal.z)
							list.insert(piece_flat, side.dist)
							list.insert(piece_flat, side.texinfo or 0)
							list.insert(piece_flat, 0)
							list.insert(piece_flat, side.visible or 0)
							visible = visible or side.visible == 1
						end

						if collide or visible then
							list.insert(brush_list, {Sides = piece_flat, Collide = collide or nil, Sky = true})
						end
					end
				elseif collide or has_geometry then
					list.insert(brush_list, {Sides = flat, Collide = collide or nil})
					brush_planes[#brush_list] = planes

					for side_index, side in ipairs(sides) do
						local key = bit.rshift(side.planenum, 1) * 65536 + side.texinfo + 1
						side_candidates[key] = side_candidates[key] or {}
						list.insert(side_candidates[key], {brush = #brush_list, side = side_index})
					end
				end
			end

			tasks.ReportProgress("reading brushes", #brush_indices)
			tasks.Wait()
		end
	end

	local decals = {}

	do
		local resolved_faces = {}

		local function resolve_face(face_index)
			local cached = resolved_faces[face_index]

			if cached ~= nil then return cached or nil end

			local result = false
			local face = header.faces[1 + face_index]
			local area = get_face_area(face_index + 1)

			if not sky_areas[area] then
				if face.dispinfo ~= -1 then
					local index = displacement_by_face[face_index + 1]

					if index then
						result = {Displacement = index, Group = displacements[index].Group}
					end
				else
					local candidates = side_candidates[bit.rshift(face.planenum, 1) * 65536 + face.texinfo + 1]

					if candidates then
						local face_vertices = {}

						for j = 1, face.numedges do
							local surfedge = header.surfedges[face.firstedge + j]
							face_vertices[j] = header.vertices[1 + header.edges[1 + math.abs(surfedge)][surfedge < 0 and
							2 or
							1]]
						end

						for _, candidate in ipairs(candidates) do
							local planes = brush_planes[candidate.brush]
							local inside = true

							for _, vertex in ipairs(face_vertices) do
								for _, plane in ipairs(planes) do
									if plane.normal:Dot(vertex) - plane.dist > 1 then
										inside = false

										break
									end
								end

								if not inside then break end
							end

							if inside then
								local flat = brush_list[candidate.brush].Sides
								result = {
									Brush = candidate.brush,
									Side = candidate.side,
									Group = flat[(candidate.side - 1) * 7 + 6],
								}

								break
							end
						end
					end
				end
			end

			resolved_faces[face_index] = result
			return result or nil
		end

		for _, overlay in ipairs(header.overlays or {}) do
			local normal = overlay.normal
			local points = {}

			for k = 1, 8 do
				points[k] = overlay.uv_points[k]
			end

			local texinfo = header.texinfos[1 + overlay.texinfo]
			local texname = header.texdatastringdata[1 + header.texdatas[1 + texinfo.texdata].nameStringTableID]
			local targets, displaced = {}, {}
			local group

			for i = 1, bit.band(overlay.face_count_and_render_order, 0x3fff) do
				local face_index = overlay.faces[i]
				local face = header.faces[1 + face_index]

				if header.planes[face.planenum + 1].normal:Dot(normal) >= 0.5 then
					local resolved = resolve_face(face_index)

					if resolved then
						if resolved.Displacement then
							list.insert(displaced, resolved.Displacement)
						else
							list.insert(targets, {Brush = resolved.Brush, Side = resolved.Side})
						end

						group = group or resolved.Group
					end
				end
			end

			if displaced[1] then list.insert(targets, {Displacements = displaced}) end

			if targets[1] then
				list.insert(
					decals,
					{
						Mode = "overlay",
						Texname = texname,
						Origin = overlay.origin,
						Normal = normal,
						UVPoints = points,
						URange = {overlay.u_range[1], overlay.u_range[2]},
						VRange = {overlay.v_range[1], overlay.v_range[2]},
						Targets = targets,
						Group = group or 0,
					}
				)
			end
		end

		local sizes = {}
		local world_model = header.models[1]

		for _, ent in ipairs(header.entities) do
			if ent.classname == "infodecal" and ent.texture and not ent.model_size_mult then
				local size = sizes[ent.texture]

				if size == nil then
					size = false
					local vmt
					vmt_loader.Load("materials/" .. ent.texture .. ".vmt", function(loaded)
						vmt = loaded
					end):TryGet()
					local data = vmt and vmt.basetexture and vfs.Read(vmt.basetexture)

					if data then
						local scale = tonumber(vmt.decalscale) or 1
						size = {
							(
								data:byte(17) + data:byte(18) * 256
							) * scale,
							(
								data:byte(19) + data:byte(20) * 256
							) * scale,
						}
					end

					sizes[ent.texture] = size
				end

				if size then
					local targets = {}
					local group

					for i = 1, world_model.numfaces do
						local face = header.faces[world_model.firstface + i]
						local plane = header.planes[face.planenum + 1]

						if math.abs(plane.normal:Dot(ent.origin) - plane.dist) < 1.5 then
							local resolved = resolve_face(world_model.firstface + i - 1)

							if resolved then
								if resolved.Displacement then
									list.insert(targets, {Displacements = {resolved.Displacement}})
								else
									list.insert(targets, {Brush = resolved.Brush, Side = resolved.Side})
								end

								group = group or resolved.Group
							end
						end
					end

					if targets[1] then
						list.insert(
							decals,
							{
								Mode = "infodecal",
								Texname = ent.texture,
								Origin = ent.origin,
								Size = size,
								Targets = targets,
								Group = group or 0,
							}
						)
					end
				end

				tasks.Wait()
			end
		end
	end

	logn("exported ", #decals, " decals")
	logn("exported ", #brush_list, " brushes, ", #displacements, " displacements")
	local ocean_level = header.ocean_level

	if ocean_level == nil then ocean_level = header.lowest_point or 0 end

	loaded[path] = {
		world = {
			Texinfos = texinfos,
			Brushes = brush_list,
			Displacements = displacements,
			Meshes = meshes,
		},
		decals = decals,
		entities = header.entities,
		cubemaps = header.cubemaps,
		visibility = header.visibility,
		water_volumes = header.water_volumes,
		ocean_level = ocean_level,
		path = path,
	}
	tasks.ReportProgress("finished reading " .. path)
	return loaded[path]
end

return bsp
