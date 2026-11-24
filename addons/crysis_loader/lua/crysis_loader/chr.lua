local ffi = require("ffi")
local vfs = import("goluwa/vfs.lua")
local xml = import("goluwa/codecs/xml.lua")
local file_path = import("goluwa/filesystem/path.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local cgf = import("lua/crysis_loader/cgf.lua")
local caf = import("lua/crysis_loader/caf.lua")
local chr = {}

do
	-- engine axes are Cry (x, z, -y)
	local AXIS = {1, 3, 2}
	local SIGN = {1, 1, -1}
	local IDENTITY = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0}

	local function to_engine(m)
		local out = {}

		for i = 1, 3 do
			local row = (AXIS[i] - 1) * 4

			for j = 1, 3 do
				out[(i - 1) * 4 + j] = SIGN[i] * SIGN[j] * m[row + AXIS[j]]
			end

			out[i * 4] = SIGN[i] * m[row + 4]
		end

		return out
	end

	local function relative(parent, child)
		local out = {}

		for i = 0, 2 do
			for j = 1, 4 do
				local sum = 0

				for k = 0, 2 do
					sum = sum + parent[k * 4 + i + 1] * (
							child[k * 4 + j] - (
								j == 4 and
								parent[k * 4 + 4] or
								0
							)
						)
				end

				out[i * 4 + j] = sum
			end
		end

		return out
	end

	local function write_pose(m, out, o)
		local m00, m01, m02 = m[1], m[2], m[3]
		local m10, m11, m12 = m[5], m[6], m[7]
		local m20, m21, m22 = m[9], m[10], m[11]
		local trace = m00 + m11 + m22
		local x, y, z, w

		if trace > 0 then
			local s = math.sqrt(trace + 1) * 2
			x, y, z, w = (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, s / 4
		elseif m00 > m11 and m00 > m22 then
			local s = math.sqrt(1 + m00 - m11 - m22) * 2
			x, y, z, w = s / 4, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s
		elseif m11 > m22 then
			local s = math.sqrt(1 + m11 - m00 - m22) * 2
			x, y, z, w = (m01 + m10) / s, s / 4, (m12 + m21) / s, (m02 - m20) / s
		else
			local s = math.sqrt(1 + m22 - m00 - m11) * 2
			x, y, z, w = (m02 + m20) / s, (m12 + m21) / s, s / 4, (m10 - m01) / s
		end

		local inv = 1 / math.sqrt(x * x + y * y + z * z + w * w)
		out[o], out[o + 1], out[o + 2] = m[4], m[8], m[12]
		out[o + 3], out[o + 4], out[o + 5], out[o + 6] = x * inv, y * inv, z * inv, w * inv
	end

	function chr.BuildSkeleton(bones)
		local count = #bones
		local names, parents, controller_ids, worlds = {}, {}, {}, {}
		local bind = ffi.new("float[?]", count * Skeleton.PoseSize)
		local inverse_bind = ffi.new("float[?]", count * Skeleton.MatrixSize)

		for i, bone in ipairs(bones) do
			names[i] = bone.name
			parents[i] = bone.parent and bone.parent - 1 or -1
			controller_ids[i] = bone.controller_id
			worlds[i] = to_engine(bone.bone_to_world)
			local inverse = relative(worlds[i], IDENTITY)

			for k = 1, 12 do
				inverse_bind[(i - 1) * 12 + k - 1] = inverse[k]
			end

			write_pose(
				bone.parent and relative(worlds[bone.parent], worlds[i]) or worlds[i],
				bind,
				(i - 1) * 7
			)
		end

		local skeleton = Skeleton.New{
			BoneNames = names,
			Parents = parents,
			BindLocal = bind,
			InverseBind = inverse_bind,
		}
		skeleton.CryControllerIds = controller_ids
		return skeleton
	end
end

function chr.ReadAnimationList(model_path)
	local cal_path = vfs.FindMixedCasePath(model_path:gsub("%.[^%./]+$", ".cal"))

	if not cal_path then return {} end

	local root = file_path.GetFolderFromPath(model_path)
	local list = {}

	for line in assert(vfs.Read(cal_path)):gmatch("[^\r\n]+") do
		line = line:gsub("//.*", ""):gsub("%-%-.*", "")
		local key, value = line:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")

		if key == "#filepath" then
			root = file_path.FixPathSlashes(value)

			if not root:ends_with("/") then root = root .. "/" end
		elseif key and not key:starts_with("$") and value:lower():ends_with(".caf") then
			list[#list + 1] = {name = key, path = root .. file_path.FixPathSlashes(value)}
		end
	end

	return list
end

function chr.AddAnimations(skeleton, model_path)
	for _, entry in ipairs(chr.ReadAnimationList(model_path)) do
		local path = vfs.FindMixedCasePath(entry.path)

		if path then
			caf.AddClip(
				skeleton,
				skeleton.CryControllerIds,
				entry.name,
				caf.Parse(assert(vfs.Read(path)))
			)
		else
			logf("crytek animation %q of %q not found\n", entry.path, model_path)
		end
	end
end

local function decode(path, full_path, material_name, mesh_callback, skeleton_callback)
	local file = assert(vfs.Open(full_path))
	local model_path = file.path_used or full_path
	local parsed = cgf.Parse(file)
	local skeleton

	for _, chunk in ipairs(parsed.chunks) do
		if chunk.type == cgf.CHUNK_COMPILED_BONES then
			skeleton = chr.BuildSkeleton(cgf.ReadCompiledBones(file, chunk))
		end
	end

	local entries = cgf.ExtractStaticMeshData(parsed, true)
	file:Close()

	if skeleton then
		chr.AddAnimations(skeleton, model_path)
		skeleton_callback(skeleton)
	end

	local resolved_material_paths = {}

	for _, entry in ipairs(entries) do
		local polygon = Polygon3D.New()
		polygon:SetVertices(entry.vertices)
		local vertices, vertex_count = polygon:PackVertices()
		local index_count = #entry.indices
		local index_type = vertex_count > 65535 and "uint32_t" or "uint16_t"
		local indices = ffi.new(index_type .. "[?]", index_count)

		for i = 1, index_count do
			indices[i - 1] = entry.indices[i] - 1
		end

		polygon:UploadVertexArray(vertices, vertex_count, indices, index_count, true, nil, nil, index_type)

		if skeleton then
			local bone_indices = ffi.new("uint16_t[?]", vertex_count * 4)
			local bone_weights = ffi.new("float[?]", vertex_count * 4)

			for i, vertex in ipairs(entry.vertices) do
				local skin = vertex.skin
				local dropped = 5

				for k = 6, 8 do
					if skin[k] < skin[dropped] then dropped = k end
				end

				local total = skin[5] + skin[6] + skin[7] + skin[8] - skin[dropped]
				local o = (i - 1) * 4

				for k = 1, 4 do
					if k + 4 ~= dropped then
						bone_indices[o] = skin[k] - 1
						bone_weights[o] = skin[k + 4] / total
						o = o + 1
					end
				end
			end

			polygon.Skin = {BoneIndices = bone_indices, BoneWeights = bone_weights, Flexes = {}}
		end

		polygon:SetMaterialSlot(entry.subset_material_id)
		polygon:SetLODLevel(entry.lod_level)
		polygon:SetName(path)
		mesh_callback(
			polygon,
			(
					material_name or
					entry.material_name
				)
				and
				cgf.LoadMaterial(
					model_path,
					material_name or entry.material_name,
					entry.subset_material_id,
					resolved_material_paths
				)
		)
	end
end

function chr.Decode(path, full_path, mesh_callback, physics_callback, skeleton_callback)
	decode(path, full_path, nil, mesh_callback, skeleton_callback)
end

-- a character definition names a .chr and optionally a material for all of it; attachments are not loaded
function chr.DecodeDefinition(path, full_path, mesh_callback, physics_callback, skeleton_callback)
	local document = assert(xml.Decode(assert(vfs.Read(full_path))))
	local model

	for _, node in ipairs(document.children[1].children) do
		if node.tag == "Model" then model = node.attrs end
	end

	assert(model and model.File, full_path .. " names no model")
	local model_path = vfs.FindMixedCasePath(file_path.FixPathSlashes(model.File))
	assert(model_path, full_path .. ": model " .. model.File .. " not found")
	local material = model.Material ~= "" and model.Material or nil
	decode(path, model_path, material, mesh_callback, skeleton_callback)
end

return chr
