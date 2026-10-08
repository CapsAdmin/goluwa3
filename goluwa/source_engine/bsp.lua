local vmt_material = import("goluwa/source_engine/vmt_material.lua")
local vfs = import("goluwa/vfs.lua")
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
local bsp = {}
local loaded = {}
bsp.resolved = {}
local CUBEMAPS = true
local SKY_CUT_MARGIN = 0.5
local GROUP_WALL_MARGIN = 256
local BSP_CONTENTS_SOLID = collision.BSP_CONTENTS_SOLID
local build_bsp_physics_body = collision.build_bsp_physics_body
local build_displacement_collision_shape = collision.build_displacement_collision_shape
local get_displacement_corners = collision.get_displacement_corners
local collect_water_volumes = collision.collect_water_volumes
local get_model_lowest_point = collision.get_model_lowest_point
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

	do
		tasks.Wait()
		tasks.Report("mounting pak")
		local pak = bsp_data:sub(header.pakfile_offset + 1, header.pakfile_offset + header.pakfile_length)
		local name = "os:cache/temp_bsp.zip"
		vfs.Write(name, pak)
		local ok, err = vfs.Mount(R(name))

		if not vfs.IsDirectory(R(name)) then
			wlog("cannot mount bsp zip " .. name .. " because the zip file is not a directory")
			wlog("assets from this map will be missing")
		end
	end

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
	local group_bounds = {}

	for _, leaf in ipairs(leafs) do
		local id = area_groups[leaf.area]

		if id and bit.band(leaf.contents, BSP_CONTENTS_SOLID) == 0 then
			local bounds = group_bounds[id]

			if not bounds then
				bounds = {
					min = Vec3(math.huge, math.huge, math.huge),
					max = Vec3(-math.huge, -math.huge, -math.huge),
				}
				group_bounds[id] = bounds
			end

			for _, axis in ipairs({"x", "y", "z"}) do
				bounds.min[axis] = math.min(bounds.min[axis], leaf.mins[axis] - GROUP_WALL_MARGIN)
				bounds.max[axis] = math.max(bounds.max[axis], leaf.maxs[axis] + GROUP_WALL_MARGIN)
			end
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

		local margin = SKY_CUT_MARGIN / units.meters

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

		sky_cut_min = (world_min - Vec3(margin, margin, margin)) / sky_scale + sky_origin
		sky_cut_max = (world_max + Vec3(margin, margin, margin)) / sky_scale + sky_origin
	end

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
				end
			end
		end
	end

	header.visibility = {
		point_leaf = point_leaf,
		area_groups = area_groups,
		group_count = group_count,
		group_bounds = group_bounds,
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

	local models = {}
	local displacement_collision_meshes = {}
	local weld_groups = {}
	header.lowest_point = get_model_lowest_point(header.models and header.models[1])
	header.ocean_level = nil

	do
		local function add_vertex(model, texinfo, texdata, in_sky, pos, blend, uv_pos, disp_normal)
			local a = texinfo.textureVecs
			local uv_source = uv_pos or pos

			if blend then blend = blend / 255 else blend = 0 end

			blend = math.clamp(blend, 0, 1)
			local uv = Vec2(
				(
						a[1] * uv_source.x + a[2] * uv_source.y + a[3] * uv_source.z + a[4]
					) / texdata.width,
				(
						a[5] * uv_source.x + a[6] * uv_source.y + a[7] * uv_source.z + a[8]
					) / texdata.height
			)

			if in_sky then pos = (pos - sky_origin) * sky_scale end

			local vertex = {
				pos = units.PositionToEngine(pos),
				texture_blend = blend,
				uv = uv,
				disp_normal = disp_normal,
			}

			if model.AddVertex then
				model:AddVertex(vertex)
			else
				list.insert(model, vertex)
			end
		end

		local add_sky_polygon

		do
			local function split_polygon(polygon, axis, value)
				local below, above = {}, {}
				local prev = polygon[#polygon]
				local prev_d = prev.pos[axis] - value

				for _, vertex in ipairs(polygon) do
					local d = vertex.pos[axis] - value

					if (prev_d < 0) ~= (d < 0) then
						local t = prev_d / (prev_d - d)
						local mid = {
							pos = prev.pos + (vertex.pos - prev.pos) * t,
							blend = prev.blend + (vertex.blend - prev.blend) * t,
							flat = prev.flat and prev.flat + (vertex.flat - prev.flat) * t,
						}
						list.insert(below, mid)
						list.insert(above, mid)
					end

					list.insert(d < 0 and below or above, vertex)
					prev, prev_d = vertex, d
				end

				return below, above
			end

			local function add_polygon(mesh, texinfo, texdata, polygon)
				for i = 2, #polygon - 1 do
					add_vertex(
						mesh,
						texinfo,
						texdata,
						true,
						polygon[1].pos,
						polygon[1].blend,
						polygon[1].flat,
						polygon[1].dn
					)
					add_vertex(
						mesh,
						texinfo,
						texdata,
						true,
						polygon[i].pos,
						polygon[i].blend,
						polygon[i].flat,
						polygon[i].dn
					)
					add_vertex(
						mesh,
						texinfo,
						texdata,
						true,
						polygon[i + 1].pos,
						polygon[i + 1].blend,
						polygon[i + 1].flat,
						polygon[i + 1].dn
					)
				end
			end

			function add_sky_polygon(mesh, texinfo, texdata, polygon)
				for _, axis in ipairs({"x", "y", "z"}) do
					local outside
					outside, polygon = split_polygon(polygon, axis, sky_cut_min[axis])
					add_polygon(mesh, texinfo, texdata, outside)

					if not polygon[3] then return end

					polygon, outside = split_polygon(polygon, axis, sky_cut_max[axis])
					add_polygon(mesh, texinfo, texdata, outside)

					if not polygon[3] then return end
				end
			end
		end

		local function lerp_corners(dims, corners, start_corner, dispinfo, x, y)
			local index = (y - 1) * dims + x
			local data = dispinfo.heightmap[index]
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

		local welded_normals = {}
		local disp_x, disp_y, disp_z = {}, {}, {}
		local disp_nx, disp_ny, disp_nz = {}, {}, {}

		local function accumulate_triangle(i, j, k)
			local ux, uy, uz = disp_x[k] - disp_x[i], disp_y[k] - disp_y[i], disp_z[k] - disp_z[i]
			local vx, vy, vz = disp_x[j] - disp_x[i], disp_y[j] - disp_y[i], disp_z[j] - disp_z[i]
			local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
			disp_nx[i], disp_ny[i], disp_nz[i] = disp_nx[i] + nx, disp_ny[i] + ny, disp_nz[i] + nz
			disp_nx[j], disp_ny[j], disp_nz[j] = disp_nx[j] + nx, disp_ny[j] + ny, disp_nz[j] + nz
			disp_nx[k], disp_ny[k], disp_nz[k] = disp_nx[k] + nx, disp_ny[k] + ny, disp_nz[k] + nz
		end

		local meshes = {}
		local displacement_surfaces = {}

		for _, model in ipairs(header.models) do
			for i = 1, model.numfaces do
				local face = header.faces[model.firstface + i]
				local area = get_face_area(model.firstface + i)
				local in_sky = sky_areas[area] == true
				local group = area_groups[area]
				local texinfo = header.texinfos[1 + face.texinfo]
				local texdata = texinfo and header.texdatas[1 + texinfo.texdata]
				local texname = header.texdatastringdata[1 + texdata.nameStringTableID]
				local texname_lower = texname:lower()
				local key = (group or 0) .. " " .. texname

				if texname_lower:find("skyb", nil, true) then goto continue end

				if texname_lower:find("water", nil, true) then
					if header.ocean_level == nil then
						local source_height = get_face_first_source_height(header, face)

						if source_height ~= nil then
							if in_sky then
								source_height = (source_height - sky_origin.z) * sky_scale
							end

							header.ocean_level = source_height_to_engine_y(source_height)
						end
					end

					goto continue
				end

				if not meshes[key] then
					local mesh = RENDER_2D and Polygon3D.New() or {}
					local material_path = "materials/" .. texname .. ".vmt"
					local material = RENDER_2D and vmt_material.FromVMT(material_path)
					meshes[key] = {
						mesh = mesh,
						material = material,
						visibility_group = group,
					}

					if RENDER_2D then
						mesh:SetName(path .. ": " .. texname)
						mesh.material = material
					end

					list.insert(models, meshes[key])
				end

				do
					local mesh = meshes[key].mesh

					if face.dispinfo == -1 and in_sky then
						local polygon = {}

						for j = 1, face.numedges do
							local surfedge = header.surfedges[face.firstedge + j]
							polygon[j] = {
								pos = header.vertices[1 + header.edges[1 + math.abs(surfedge)][surfedge < 0 and 2 or 1]],
								blend = 0,
							}
						end

						add_sky_polygon(mesh, texinfo, texdata, polygon)
					elseif face.dispinfo == -1 then
						local first, previous

						for j = 1, face.numedges do
							local surfedge = header.surfedges[face.firstedge + j]
							local edge = header.edges[1 + math.abs(surfedge)]
							local current = edge[surfedge < 0 and 2 or 1] + 1

							if j >= 3 then
								if header.vertices[first] and header.vertices[current] and header.vertices[previous] then
									local a = header.vertices[first]
									local b = header.vertices[previous]
									local c = header.vertices[current]
									add_vertex(mesh, texinfo, texdata, false, a)
									add_vertex(mesh, texinfo, texdata, false, b)
									add_vertex(mesh, texinfo, texdata, false, c)
								end
							elseif j == 1 then
								first = current
							end

							previous = current
						end
					else
						local info = header.displacements[face.dispinfo + 1]
						local corners, start_corner = get_displacement_corners(header, info)
						local dims = 2 ^ info.power + 1
						local positions, blends, flats, normals = {}, {}, {}, {}
						local scale = units.meters
						displacement_surfaces[model.firstface + i - 1] = {positions = positions, dims = dims}

						for y = 1, dims do
							for x = 1, dims do
								local i = (y - 1) * dims + x
								local pos, blend, flat = lerp_corners(dims, corners, start_corner, info, x, y)
								positions[i], blends[i], flats[i] = pos, blend, flat
								disp_x[i], disp_y[i], disp_z[i] = -pos.y * scale, pos.z * scale, -pos.x * scale
								disp_nx[i], disp_ny[i], disp_nz[i] = 0, 0, 0
							end
						end

						for x = 1, dims - 1 do
							for y = 1, dims - 1 do
								local a = y * dims + x
								local b = (y - 1) * dims + x
								local c = a + 1
								local d = b + 1
								accumulate_triangle(a, c, b)
								accumulate_triangle(c, d, b)
							end
						end

						for y = 1, dims do
							for x = 1, dims do
								local i = (y - 1) * dims + x

								if x == 1 or y == 1 or x == dims or y == dims then
									local pos = positions[i]
									local key = (
											(
												math.floor(pos.x * 4 + 0.5) + 65536
											) * 131072 + math.floor(pos.y * 4 + 0.5) + 65536
										) * 131072 + math.floor(pos.z * 4 + 0.5) + 65536
									local group = welded_normals[key]

									if not group then
										group = {}
										welded_normals[key] = group
									end

									normals[i] = Vec3(disp_nx[i], disp_ny[i], disp_nz[i])
									weld_groups[normals[i]] = group
									group[#group + 1] = normals[i]
								else
									normals[i] = Vec3(disp_nx[i], disp_ny[i], disp_nz[i])
								end
							end
						end

						for x = 1, dims - 1 do
							for y = 1, dims - 1 do
								local a = y * dims + x
								local b = (y - 1) * dims + x
								local c = a + 1
								local d = b + 1

								if in_sky then
									add_sky_polygon(
										mesh,
										texinfo,
										texdata,
										{
											{pos = positions[a], blend = blends[a], flat = flats[a], dn = normals[a]},
											{pos = positions[c], blend = blends[c], flat = flats[c], dn = normals[c]},
											{pos = positions[b], blend = blends[b], flat = flats[b], dn = normals[b]},
										}
									)
									add_sky_polygon(
										mesh,
										texinfo,
										texdata,
										{
											{pos = positions[c], blend = blends[c], flat = flats[c], dn = normals[c]},
											{pos = positions[d], blend = blends[d], flat = flats[d], dn = normals[d]},
											{pos = positions[b], blend = blends[b], flat = flats[b], dn = normals[b]},
										}
									)
								else
									add_vertex(mesh, texinfo, texdata, false, positions[a], blends[a], flats[a], normals[a])
									add_vertex(mesh, texinfo, texdata, false, positions[c], blends[c], flats[c], normals[c])
									add_vertex(mesh, texinfo, texdata, false, positions[b], blends[b], flats[b], normals[b])
									add_vertex(mesh, texinfo, texdata, false, positions[c], blends[c], flats[c], normals[c])
									add_vertex(mesh, texinfo, texdata, false, positions[d], blends[d], flats[d], normals[d])
									add_vertex(mesh, texinfo, texdata, false, positions[b], blends[b], flats[b], normals[b])
								end
							end
						end

						do
							local collision_shape = build_displacement_collision_shape(positions, dims)

							if collision_shape then
								list.insert(displacement_collision_meshes, collision_shape)
							end
						end
					end
				end

				::continue::

				tasks.ReportProgress("building meshes", model.numfaces)
				tasks.Wait()
			end

			break
		end

		local add_decal_fragment
		local add_displacement_decal

		do
			local offset_from_surface = 0.3
			local edges = {
				{"x", 1},
				{"x", -1},
				{"y", 1},
				{"y", -1},
			}
			local emit_polygon

			function emit_polygon(polygon, area, min_x, max_x, min_y, max_y, u_range, v_range, texname)
				for _, edge in ipairs(edges) do
					local axis, sign = edge[1], edge[2]
					local limit = axis == "x" and (sign == 1 and min_x or max_x) or (sign == 1 and min_y or max_y)
					local clipped = {}
					local previous = polygon[#polygon]
					local previous_d = (previous[axis] - limit) * sign

					for _, vertex in ipairs(polygon) do
						local d = (vertex[axis] - limit) * sign

						if (previous_d < 0) ~= (d < 0) then
							local t = previous_d / (previous_d - d)
							list.insert(
								clipped,
								{
									x = previous.x + (vertex.x - previous.x) * t,
									y = previous.y + (vertex.y - previous.y) * t,
									pos = previous.pos + (vertex.pos - previous.pos) * t,
								}
							)
						end

						if d >= 0 then list.insert(clipped, vertex) end

						previous, previous_d = vertex, d
					end

					polygon = clipped

					if #polygon < 3 then return end
				end

				local group = area_groups[area]
				local key = (group or 0) .. " overlay " .. texname

				if not meshes[key] then
					local mesh = Polygon3D.New()
					mesh:SetName(path .. ": overlay " .. texname)
					local material = vmt_material.FromVMT("materials/" .. texname .. ".vmt")
					mesh.material = material
					meshes[key] = {mesh = mesh, material = material, visibility_group = group}
					list.insert(models, meshes[key])
				end

				local mesh = meshes[key].mesh

				for j = 2, #polygon - 1 do
					for _, vertex in ipairs{polygon[1], polygon[j], polygon[j + 1]} do
						local position = vertex.pos
						mesh:AddVertex{
							pos = units.PositionToEngine(position),
							texture_blend = 0,
							uv = Vec2(
								u_range[1] + (u_range[2] - u_range[1]) * (vertex.x - min_x) / (max_x - min_x),
								v_range[1] + (v_range[2] - v_range[1]) * (vertex.y - min_y) / (max_y - min_y)
							),
						}
					end
				end
			end

			function add_decal_fragment(
				face_index,
				origin,
				normal,
				u_axis,
				v_axis,
				min_x,
				max_x,
				min_y,
				max_y,
				u_range,
				v_range,
				texname
			)
				local face = header.faces[1 + face_index]
				local area = get_face_area(face_index + 1)

				if sky_areas[area] then return end

				local polygon = {}

				for j = 1, face.numedges do
					local surfedge = header.surfedges[face.firstedge + j]
					local position = header.vertices[1 + header.edges[1 + math.abs(surfedge)][surfedge < 0 and
					2 or
					1]]
					local offset = position - origin
					polygon[j] = {
						x = offset:Dot(u_axis),
						y = offset:Dot(v_axis),
						pos = position + normal * offset_from_surface,
					}
				end

				emit_polygon(polygon, area, min_x, max_x, min_y, max_y, u_range, v_range, texname)
			end

			function add_displacement_decal(
				face_indices,
				origin,
				normal,
				u_axis,
				v_axis,
				min_x,
				max_x,
				min_y,
				max_y,
				u_range,
				v_range,
				texname
			)
				local verts = {}
				local vert_count = 0
				local tris = {}
				local edge_tris = {}

				for _, face_index in ipairs(face_indices) do
					local area = get_face_area(face_index + 1)

					if not sky_areas[area] then
						local surface = displacement_surfaces[face_index]
						local positions, dims = surface.positions, surface.dims
						local plane_normal = header.planes[header.faces[1 + face_index].planenum + 1].normal
						local grid = {}

						for i = 1, dims * dims do
							local position = positions[i]
							local key = (
									(
										math.floor(position.x * 4 + 0.5) + 65536
									) * 131072 + math.floor(position.y * 4 + 0.5) + 65536
								) * 131072 + math.floor(position.z * 4 + 0.5) + 65536
							local vert = verts[key]

							if not vert then
								vert_count = vert_count + 1
								local offset = position - origin
								vert = {
									id = vert_count,
									pos = position,
									x0 = offset:Dot(u_axis),
									y0 = offset:Dot(v_axis),
									sum = Vec3(0, 0, 0),
								}
								verts[key] = vert
							end

							grid[i] = vert
						end

						for x = 1, dims - 1 do
							for y = 1, dims - 1 do
								local a = y * dims + x
								local b = (y - 1) * dims + x
								local c = a + 1
								local d = b + 1

								for _, corners in ipairs{{a, c, b}, {c, d, b}} do
									local v1, v2, v3 = grid[corners[1]], grid[corners[2]], grid[corners[3]]
									local tri_normal = (v2.pos - v1.pos):Cross(v3.pos - v1.pos):GetNormalized()

									if tri_normal:Dot(plane_normal) < 0 then tri_normal = -tri_normal end

									v1.sum = v1.sum + tri_normal
									v2.sum = v2.sum + tri_normal
									v3.sum = v3.sum + tri_normal
									local tri = {v1, v2, v3, normal = tri_normal, area = area}
									list.insert(tris, tri)

									for k = 1, 3 do
										local p, q = tri[k], tri[k % 3 + 1]
										local edge_key = math.min(p.id, q.id) * 1048576 + math.max(p.id, q.id)
										local shared = edge_tris[edge_key]

										if not shared then
											shared = {}
											edge_tris[edge_key] = shared
										end

										list.insert(shared, tri)
									end
								end
							end
						end
					end
				end

				if #tris == 0 then return end

				local center_x, center_y = (min_x + max_x) / 2, (min_y + max_y) / 2
				local seeds = {}

				for _, tri in ipairs(tris) do
					if tri.normal:Dot(normal) >= 0.2 then
						local v1, v2, v3 = tri[1], tri[2], tri[3]
						local dx = (v1.x0 + v2.x0 + v3.x0) / 3 - center_x
						local dy = (v1.y0 + v2.y0 + v3.y0) / 3 - center_y
						tri.seed_distance = dx * dx + dy * dy
						list.insert(seeds, tri)
					end
				end

				table.sort(seeds, function(a, b)
					return a.seed_distance < b.seed_distance
				end)

				local queue = {}

				for _, seed in ipairs(seeds) do
					if not seed.visited then
						seed.visited = true

						for k = 1, 3 do
							local vert = seed[k]

							if not vert.x then vert.x, vert.y = vert.x0, vert.y0 end
						end

						local head, tail = 1, 0

						for k = 1, 3 do
							local p, q, o = seed[k], seed[k % 3 + 1], seed[(k + 1) % 3 + 1]
							local edge_key = math.min(p.id, q.id) * 1048576 + math.max(p.id, q.id)

							for _, neighbor in ipairs(edge_tris[edge_key]) do
								if not neighbor.visited then
									tail = tail + 1
									queue[tail] = {neighbor, p, q, o}
								end
							end
						end

						while head <= tail do
							local entry = queue[head]
							queue[head] = nil
							head = head + 1
							local tri, va, vb, vo = entry[1], entry[2], entry[3], entry[4]

							if not tri.visited then
								tri.visited = true

								if tri.normal:Dot(normal) < -0.2 then
									tri.skip = true
								else
									local vc

									for k = 1, 3 do
										if tri[k] ~= va and tri[k] ~= vb then vc = tri[k] end
									end

									if not vc.x then
										local ab = (vb.pos - va.pos):GetLength()
										local ac = (vc.pos - va.pos):GetLength()
										local bc = (vc.pos - vb.pos):GetLength()
										local dir_x, dir_y = vb.x - va.x, vb.y - va.y
										local dir_length = math.sqrt(dir_x * dir_x + dir_y * dir_y)

										if dir_length < 1e-6 then
											dir_x, dir_y = 1, 0
										else
											dir_x, dir_y = dir_x / dir_length, dir_y / dir_length
										end

										local along = ab > 1e-6 and (ac * ac + ab * ab - bc * bc) / (2 * ab) or 0
										local height = math.sqrt(math.max(ac * ac - along * along, 0))
										local side = (dir_x * (vo.y - va.y) - dir_y * (vo.x - va.x)) > 0 and -1 or 1
										vc.x = va.x + dir_x * along - dir_y * height * side
										vc.y = va.y + dir_y * along + dir_x * height * side
									end

									for k = 1, 3 do
										local p, q = tri[k], tri[k % 3 + 1]
										local o = tri[(k + 1) % 3 + 1]
										local edge_key = math.min(p.id, q.id) * 1048576 + math.max(p.id, q.id)

										for _, neighbor in ipairs(edge_tris[edge_key]) do
											if not neighbor.visited then
												tail = tail + 1
												queue[tail] = {neighbor, p, q, o}
											end
										end
									end
								end
							end
						end
					end
				end

				for _, tri in ipairs(tris) do
					if tri.visited and not tri.skip then
						local polygon = {}

						for k = 1, 3 do
							local vert = tri[k]

							if not vert.out then
								vert.out = {
									x = vert.x,
									y = vert.y,
									pos = vert.pos + vert.sum:GetNormalized() * offset_from_surface,
								}
							end

							polygon[k] = vert.out
						end

						emit_polygon(polygon, tri.area, min_x, max_x, min_y, max_y, u_range, v_range, texname)
					end
				end
			end
		end

		if RENDER_2D and header.overlays then
			for _, overlay in ipairs(header.overlays) do
				local normal = overlay.normal
				local points = overlay.uv_points
				local dominant_x, dominant_y = math.abs(normal.x), math.abs(normal.y)
				local axis_a, axis_b

				if dominant_x > dominant_y and dominant_x >= math.abs(normal.z) then
					axis_b = (Vec3(0, 1, 0) - normal * normal.y):GetNormalized()
					axis_a = axis_b:GetCross(normal)
				else
					axis_a = (Vec3(1, 0, 0) - normal * normal.x):GetNormalized()
					axis_b = normal:GetCross(axis_a)
				end

				local u_axis = (axis_a * points[3] + axis_b * points[6]):GetNormalized()
				local v_axis = normal:GetCross(u_axis)
				local texinfo = header.texinfos[1 + overlay.texinfo]
				local texname = header.texdatastringdata[1 + header.texdatas[1 + texinfo.texdata].nameStringTableID]
				local displaced = {}

				for i = 1, bit.band(overlay.face_count_and_render_order, 0x3fff) do
					local face_index = overlay.faces[i]
					local face = header.faces[1 + face_index]

					if header.planes[face.planenum + 1].normal:Dot(normal) >= 0.5 then
						if face.dispinfo == -1 then
							add_decal_fragment(
								face_index,
								overlay.origin,
								normal,
								u_axis,
								v_axis,
								points[1],
								points[7],
								points[2],
								points[5],
								overlay.u_range,
								overlay.v_range,
								texname
							)
						else
							list.insert(displaced, face_index)
						end
					end
				end

				if displaced[1] then
					add_displacement_decal(
						displaced,
						overlay.origin,
						normal,
						u_axis,
						v_axis,
						points[1],
						points[7],
						points[2],
						points[5],
						overlay.u_range,
						overlay.v_range,
						texname
					)
				end
			end
		end

		if RENDER_2D then
			local unit_range = {0, 1}
			local decal_sizes = {}
			local world = header.models[1]
			local decal_count = 0

			for _, ent in ipairs(header.entities) do
				if ent.classname ~= "infodecal" or ent.model_size_mult or not ent.texture then
					goto next_decal
				end

				do
					local size = decal_sizes[ent.texture]

					if size == nil then
						size = false
						local material = vmt_material.FromVMT("materials/" .. ent.texture .. ".vmt")
						local vmt = material.vmt
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

						decal_sizes[ent.texture] = size
					end

					if not size then goto next_decal end

					local half_width, half_height = size[1] / 2, size[2] / 2

					for i = 1, world.numfaces do
						local face = header.faces[world.firstface + i]
						local plane = header.planes[face.planenum + 1]

						if math.abs(plane.normal:Dot(ent.origin) - plane.dist) < 1.5 then
							local normal = plane.normal
							local vecs = header.texinfos[1 + face.texinfo].textureVecs
							local u_axis = (
								Vec3(vecs[1], vecs[2], vecs[3]) - normal * (
									vecs[1] * normal.x + vecs[2] * normal.y + vecs[3] * normal.z
								)
							):GetNormalized()
							local v_axis = Vec3(vecs[5], vecs[6], vecs[7])
							v_axis = (
								v_axis - u_axis * u_axis:Dot(v_axis) - normal * normal:Dot(v_axis)
							):GetNormalized()
							local add_fragment = face.dispinfo == -1 and add_decal_fragment or add_displacement_decal
							add_fragment(
								face.dispinfo == -1 and world.firstface + i - 1 or {world.firstface + i - 1},
								ent.origin,
								normal,
								u_axis,
								v_axis,
								-half_width,
								half_width,
								-half_height,
								half_height,
								unit_range,
								unit_range,
								ent.texture
							)
						end
					end

					decal_count = decal_count + 1
					tasks.Wait()
				end

				::next_decal::
			end

			logn("placed ", decal_count, " infodecals")
		end
	end

	if RENDER_2D then
		for i, data in ipairs(models) do
			local mesh = data.mesh
			local vertices = mesh:GetVertices()

			for i = 1, #vertices, 3 do
				local a = vertices[i + 0]
				local b = vertices[i + 1]
				local c = vertices[i + 2]
				local normal = (c.pos - a.pos):Cross(b.pos - a.pos):GetNormalized()
				a.normal = normal
				b.normal = normal
				c.normal = normal

				for k = 0, 2 do
					local vertex = vertices[i + k]
					local disp_normal = vertex.disp_normal

					if disp_normal and (disp_normal.x ~= 0 or disp_normal.y ~= 0 or disp_normal.z ~= 0) then
						local group = weld_groups[disp_normal]

						if group then
							local own = disp_normal:GetNormalized()
							local sum = Vec3(0, 0, 0)

							for _, other in ipairs(group) do
								if other:GetNormalized():Dot(own) > 0.5 then sum = sum + other end
							end

							vertex.normal = sum:GetNormalized()
						else
							vertex.normal = disp_normal:GetNormalized()
						end
					end
				end

				if i % 3000 == 0 then tasks.Wait() end
			end

			tasks.ReportProgress("generating normals", #models)
			tasks.Wait()
		end

		for _, data in ipairs(models) do
			data.mesh:BuildBoundingBox()
			tasks.Wait()
		end

		for _, data in ipairs(models) do
			data.mesh:BuildTangents()
			data.mesh:Upload(nil)
			tasks.ReportProgress("creating meshes", #models)
			tasks.Wait()
		end
	end

	local render_meshes = {}

	for _, v in ipairs(models) do
		if RENDER_2D and v.mesh and v.mesh.Vertices then
			list.insert(render_meshes, v)
		elseif SERVER and type(v.mesh) == "table" and v.mesh[1] and v.mesh[1].pos then
			list.insert(render_meshes, v)
		end
	end

	local physics_body, physics_body_info = build_bsp_physics_body(header, render_meshes, displacement_collision_meshes, nil)
	local ocean_level = header.ocean_level

	if ocean_level == nil then ocean_level = header.lowest_point or 0 end

	loaded[path] = {
		render_meshes = render_meshes,
		entities = header.entities,
		physics_body = physics_body,
		physics_body_info = physics_body_info,
		cubemaps = header.cubemaps,
		visibility = header.visibility,
		water_volumes = header.water_volumes,
		ocean_level = ocean_level,
		path = path,
	}

	if physics_body_info then
		logn(
			"BSP physics body for ",
			path,
			": mode=",
			physics_body_info.mode,
			", collidable_brushes=",
			physics_body_info.collidable_brushes or 0,
			", displacement_primitives=",
			physics_body_info.displacement_primitives or 0,
			", primitives=",
			physics_body_info.primitives or 0
		)
	end

	tasks.ReportProgress("finished reading " .. path)
	return loaded[path]
end

function bsp.BindOwner(data, owner)
	for _, shape in ipairs(data.physics_body.Shapes) do
		if shape.Model then shape.Model.Owner = owner end
	end
end

return bsp
