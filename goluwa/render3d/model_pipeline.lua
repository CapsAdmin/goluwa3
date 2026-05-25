local ffi = require("ffi")
local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local system = import("goluwa/system.lua")
local model_pipeline = library()
local MAX_BRANCH_HELPERS = 16
local BRANCH_HELPER_KEYS = {}
local FLOAT_SIZE = ffi.sizeof("float")

for i = 0, MAX_BRANCH_HELPERS - 1 do
	BRANCH_HELPER_KEYS[i + 1] = "BranchHelper" .. tostring(i)
end

local SURFACE_MATERIAL_FIELDS = {
	{type = "int", name = "Flags", getter = "GetFillFlags"},
	{type = "texture", name = "AlbedoTexture", getter = "GetAlbedoTexture"},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
	{type = "vec4", name = "EmissiveMultiplier", getter = "GetEmissiveMultiplier"},
	{type = "float", name = "AlphaCutoff", getter = "GetAlphaCutoff"},
}
local PBR_MATERIAL_FIELDS = {
	{type = "int", name = "Flags", getter = "GetFillFlags"},
	{type = "texture", name = "AlbedoTexture", getter = "GetAlbedoTexture"},
	{type = "texture", name = "Albedo2Texture", getter = "GetAlbedo2Texture"},
	{type = "texture", name = "NormalTexture", getter = "GetNormalTexture"},
	{type = "texture", name = "Normal2Texture", getter = "GetNormal2Texture"},
	{type = "texture", name = "HeightTexture", getter = "GetHeightTexture"},
	{type = "texture", name = "BlendTexture", getter = "GetBlendTexture"},
	{
		type = "texture",
		name = "TerrainMaterialTexture",
		getter = "GetTerrainMaterialTexture",
	},
	{
		type = "texture",
		name = "MetallicRoughnessTexture",
		getter = "GetMetallicRoughnessTexture",
	},
	{
		type = "texture",
		name = "AmbientOcclusionTexture",
		getter = "GetAmbientOcclusionTexture",
	},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
	{
		type = "vec4",
		name = "TerrainCheckerScales",
		getter = "GetTerrainCheckerScales",
	},
	{type = "vec4", name = "TerrainLayer1ColorA", getter = "GetTerrainLayer1ColorA"},
	{type = "vec4", name = "TerrainLayer1ColorB", getter = "GetTerrainLayer1ColorB"},
	{type = "vec4", name = "TerrainLayer2ColorA", getter = "GetTerrainLayer2ColorA"},
	{type = "vec4", name = "TerrainLayer2ColorB", getter = "GetTerrainLayer2ColorB"},
	{type = "vec4", name = "TerrainLayer3ColorA", getter = "GetTerrainLayer3ColorA"},
	{type = "vec4", name = "TerrainLayer3ColorB", getter = "GetTerrainLayer3ColorB"},
	{type = "vec4", name = "TerrainLayer4ColorA", getter = "GetTerrainLayer4ColorA"},
	{type = "vec4", name = "TerrainLayer4ColorB", getter = "GetTerrainLayer4ColorB"},
	{
		type = "vec4",
		name = "TerrainLayerRoughness",
		getter = "GetTerrainLayerRoughness",
	},
	{
		type = "vec4",
		name = "TerrainLayerAmbientOcclusion",
		getter = "GetTerrainLayerAmbientOcclusion",
	},
	{type = "float", name = "MetallicMultiplier", getter = "GetMetallicMultiplier"},
	{type = "float", name = "RoughnessMultiplier", getter = "GetRoughnessMultiplier"},
	{type = "float", name = "HeightScale", getter = "GetHeightScale"},
	{type = "float", name = "HeightCenter", getter = "GetHeightCenter"},
	{type = "int", name = "HeightLayers", getter = "GetHeightLayers"},
	{type = "float", name = "TessellationFactor", getter = "GetTessellationFactor"},
	{
		type = "float",
		name = "AmbientOcclusionMultiplier",
		getter = "GetAmbientOcclusionMultiplier",
	},
	{type = "vec4", name = "EmissiveMultiplier", getter = "GetEmissiveMultiplier"},
	{
		type = "vec4",
		name = "TransmissionColor",
		getter = "GetTransmissionColor",
	},
	{
		type = "float",
		name = "TransmissionViewDependency",
		getter = "GetTransmissionViewDependency",
	},
	{
		type = "float",
		name = "TransmissionBlocking",
		getter = "GetTransmissionBlocking",
	},
	{type = "float", name = "AlphaCutoff", getter = "GetAlphaCutoff"},
	{type = "texture", name = "MetallicTexture", getter = "GetMetallicTexture"},
	{type = "texture", name = "RoughnessTexture", getter = "GetRoughnessTexture"},
	{type = "texture", name = "OpacityTexture", getter = "GetOpacityTexture"},
}
local PROBE_MATERIAL_FIELDS = {
	{type = "int", name = "Flags", getter = "GetFillFlags"},
	{type = "texture", name = "AlbedoTexture", getter = "GetAlbedoTexture"},
	{type = "texture", name = "Albedo2Texture", getter = "GetAlbedo2Texture"},
	{type = "texture", name = "NormalTexture", getter = "GetNormalTexture"},
	{type = "texture", name = "Normal2Texture", getter = "GetNormal2Texture"},
	{type = "texture", name = "HeightTexture", getter = "GetHeightTexture"},
	{type = "texture", name = "BlendTexture", getter = "GetBlendTexture"},
	{
		type = "texture",
		name = "TerrainMaterialTexture",
		getter = "GetTerrainMaterialTexture",
	},
	{
		type = "texture",
		name = "MetallicRoughnessTexture",
		getter = "GetMetallicRoughnessTexture",
	},
	{type = "texture", name = "EmissiveTexture", getter = "GetEmissiveTexture"},
	{type = "vec4", name = "ColorMultiplier", getter = "GetColorMultiplier"},
	{
		type = "vec4",
		name = "TerrainCheckerScales",
		getter = "GetTerrainCheckerScales",
	},
	{type = "vec4", name = "TerrainLayer1ColorA", getter = "GetTerrainLayer1ColorA"},
	{type = "vec4", name = "TerrainLayer1ColorB", getter = "GetTerrainLayer1ColorB"},
	{type = "vec4", name = "TerrainLayer2ColorA", getter = "GetTerrainLayer2ColorA"},
	{type = "vec4", name = "TerrainLayer2ColorB", getter = "GetTerrainLayer2ColorB"},
	{type = "vec4", name = "TerrainLayer3ColorA", getter = "GetTerrainLayer3ColorA"},
	{type = "vec4", name = "TerrainLayer3ColorB", getter = "GetTerrainLayer3ColorB"},
	{type = "vec4", name = "TerrainLayer4ColorA", getter = "GetTerrainLayer4ColorA"},
	{type = "vec4", name = "TerrainLayer4ColorB", getter = "GetTerrainLayer4ColorB"},
	{type = "float", name = "MetallicMultiplier", getter = "GetMetallicMultiplier"},
	{type = "float", name = "RoughnessMultiplier", getter = "GetRoughnessMultiplier"},
	{type = "float", name = "HeightScale", getter = "GetHeightScale"},
	{type = "float", name = "HeightCenter", getter = "GetHeightCenter"},
	{type = "int", name = "HeightLayers", getter = "GetHeightLayers"},
	{type = "float", name = "TessellationFactor", getter = "GetTessellationFactor"},
	{type = "vec4", name = "EmissiveMultiplier", getter = "GetEmissiveMultiplier"},
}

local function get_material()
	return render3d.GetMaterial()
end

local VERTEX_ATTRIBUTE_DEFS = {
	{name = "position", type = "vec3", format = "r32g32b32_sfloat", float_count = 3},
	{name = "normal", type = "vec3", format = "r32g32b32_sfloat", float_count = 3},
	{name = "uv", type = "vec2", format = "r32g32_sfloat", float_count = 2},
	{
		name = "tangent",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		float_count = 4,
	},
	{name = "texture_blend", type = "float", format = "r32_sfloat", float_count = 1},
	{
		name = "vertex_color",
		type = "vec4",
		format = "r32g32b32a32_sfloat",
		float_count = 4,
	},
}

local function get_vertex_stride()
	local stride = 0

	for _, def in ipairs(VERTEX_ATTRIBUTE_DEFS) do
		stride = stride + def.float_count * FLOAT_SIZE
	end

	return stride
end

function model_pipeline.GetVertexAttributes()
	local attributes = {}

	for i, def in ipairs(VERTEX_ATTRIBUTE_DEFS) do
		attributes[i] = {def.name, def.type, def.format}
	end

	return attributes
end

function model_pipeline.GetVertexStride()
	return get_vertex_stride()
end

function model_pipeline.GetVertexBufferBinding(binding_index)
	return {
		binding = binding_index or 0,
		stride = get_vertex_stride(),
		input_rate = "vertex",
	}
end

function model_pipeline.GetVertexAttributeLayout(binding_index)
	binding_index = binding_index or 0
	local attributes = {}
	local offset = 0

	for i, def in ipairs(VERTEX_ATTRIBUTE_DEFS) do
		attributes[i] = {
			binding = binding_index,
			location = i - 1,
			format = def.format,
			offset = offset,
		}
		offset = offset + def.float_count * FLOAT_SIZE
	end

	return attributes
end

function model_pipeline.GetTransformBlock(get_projection_view_world_matrix)
	return {
		{"projection_view_world", "mat4"},
		{"world", "mat4"},
	}
end

function model_pipeline.BuildTransformBlockWriter(get_projection_view_world_matrix)
	get_projection_view_world_matrix = get_projection_view_world_matrix or render3d.GetProjectionViewWorldMatrix
	return function(self, block)
		get_projection_view_world_matrix():CopyToFloatPointer(block.projection_view_world)
		render3d.GetWorldMatrix():CopyToFloatPointer(block.world)
		return block
	end
end

function model_pipeline.GetInstancedTransformBlock(get_projection_view_matrix)
	return {
		{"projection_view", "mat4"},
	}
end

function model_pipeline.BuildInstancedTransformBlockWriter(get_projection_view_matrix)
	get_projection_view_matrix = get_projection_view_matrix or render3d.GetProjectionViewMatrix
	return function(self, block)
		get_projection_view_matrix():CopyToFloatPointer(block.projection_view)
		return block
	end
end

function model_pipeline.GetInstanceAttributes()
	return {
		{"instance_world", "mat4"},
	}
end

local function get_instance_world_expr()
	return "mat4(in_instance_world_row_0, in_instance_world_row_1, in_instance_world_row_2, in_instance_world_row_3)"
end

local function build_vertex_shader(options)
	local lines = {
		model_pipeline.BuildVertexAnimationGlsl("vertex_animation"),
		"void main() {",
		"\tvec3 local_position = in_position;",
		"\tvec3 world_position = (vertex.world * vec4(local_position, 1.0)).xyz;",
		"\tmat3 world_matrix3 = mat3(vertex.world);",
		"\tmat3 inv_world_matrix3 = inverse(world_matrix3);",
		"\tvec3 world_normal = normalize(transpose(inv_world_matrix3) * in_normal);",
		"\tvec3 world_tangent = normalize(world_matrix3 * in_tangent.xyz);",
		"\tvec3 world_offset = get_vertex_animation_offset(world_position, world_normal, world_tangent, in_uv, in_texture_blend, in_vertex_color);",
		"\tif (dot(world_offset, world_offset) > 0.0) {",
		"\t\tlocal_position += inv_world_matrix3 * world_offset;",
		"\t\tworld_position += world_offset;",
		"\t\tworld_normal = bend_vertex_animation_direction(world_normal, world_offset);",
		"\t\tworld_tangent = bend_vertex_animation_direction(world_tangent, world_offset);",
		"\t}",
		"\tgl_Position = vertex.projection_view_world * vec4(local_position, 1.0);",
	}

	if options.position ~= false then
		lines[#lines + 1] = "\tout_position = world_position;"
	end

	if options.normal then lines[#lines + 1] = "\tout_normal = world_normal;" end

	if options.tangent then
		lines[#lines + 1] = "\tout_tangent = vec4(world_tangent, in_tangent.w);"
	end

	if options.uv then lines[#lines + 1] = "\tout_uv = in_uv;" end

	if options.texture_blend then
		lines[#lines + 1] = "\tout_texture_blend = in_texture_blend;"
	end

	if options.vertex_color then
		lines[#lines + 1] = "\tout_vertex_color = in_vertex_color;"
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

local function build_instanced_vertex_shader(options)
	local world_expr = get_instance_world_expr()
	local lines = {
		"void main() {",
		"\tmat4 instance_world = " .. world_expr .. ";",
		"\tvec3 local_position = in_position;",
		"\tvec3 world_position = (instance_world * vec4(local_position, 1.0)).xyz;",
		"\tmat3 world_matrix3 = mat3(instance_world);",
		"\tmat3 inv_world_matrix3 = inverse(world_matrix3);",
		"\tvec3 world_normal = normalize(transpose(inv_world_matrix3) * in_normal);",
		"\tvec3 world_tangent = normalize(world_matrix3 * in_tangent.xyz);",
		"\tgl_Position = vertex.projection_view * vec4(world_position, 1.0);",
	}

	if options.position ~= false then
		lines[#lines + 1] = "\tout_position = world_position;"
	end

	if options.normal then lines[#lines + 1] = "\tout_normal = world_normal;" end

	if options.tangent then
		lines[#lines + 1] = "\tout_tangent = vec4(world_tangent, in_tangent.w);"
	end

	if options.uv then lines[#lines + 1] = "\tout_uv = in_uv;" end

	if options.texture_blend then
		lines[#lines + 1] = "\tout_texture_blend = in_texture_blend;"
	end

	if options.vertex_color then
		lines[#lines + 1] = "\tout_vertex_color = in_vertex_color;"
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

local function get_vertex_stage_outputs(options)
	local outputs = {}

	if options.position ~= false then
		outputs[#outputs + 1] = {"position", "vec3"}
	end

	if options.normal then outputs[#outputs + 1] = {"normal", "vec3"} end

	if options.tangent then outputs[#outputs + 1] = {"tangent", "vec4"} end

	if options.uv then outputs[#outputs + 1] = {"uv", "vec2"} end

	if options.texture_blend then
		outputs[#outputs + 1] = {"texture_blend", "float"}
	end

	if options.vertex_color then outputs[#outputs + 1] = {"vertex_color", "vec4"} end

	return outputs
end

function model_pipeline.CreateVertexStage(options)
	options = options or {}
	local storage_key = options.transform_storage or "push_constants"
	local transform_buffers = {
		{
			name = options.transform_block_name or "vertex",
			block = model_pipeline.GetTransformBlock(options.get_projection_view_world_matrix),
			write = model_pipeline.BuildTransformBlockWriter(options.get_projection_view_world_matrix),
		},
	}
	local animation_buffers = options.vertex_uniform_buffers or
		{
			{
				name = "vertex_animation",
				block = model_pipeline.GetVertexAnimationBlock(),
				write = model_pipeline.WriteVertexAnimationBlock,
			},
		}
	local stage = {
		binding_index = options.binding_index or 0,
		attributes = model_pipeline.GetVertexAttributes(),
		[storage_key] = transform_buffers,
		shader = build_vertex_shader(options),
	}

	if storage_key == "uniform_buffers" then
		for _, buffer in ipairs(animation_buffers) do
			table.insert(transform_buffers, buffer)
		end

		stage.uniform_buffers = transform_buffers
	else
		stage.uniform_buffers = animation_buffers
	end

	return stage
end

function model_pipeline.CreateInstancedVertexStage(options)
	options = options or {}
	local storage_key = options.transform_storage or "push_constants"
	local stage = {
		bindings = {
			{
				binding = options.binding_index or 0,
				input_rate = "vertex",
				attributes = model_pipeline.GetVertexAttributes(),
			},
			{
				binding = options.instance_binding_index or 1,
				input_rate = "instance",
				attributes = model_pipeline.GetInstanceAttributes(),
			},
		},
		[storage_key] = {
			{
				name = options.transform_block_name or "vertex",
				block = model_pipeline.GetInstancedTransformBlock(options.get_projection_view_matrix),
				write = model_pipeline.BuildInstancedTransformBlockWriter(options.get_projection_view_matrix),
			},
		},
		outputs = get_vertex_stage_outputs(options),
		shader = build_instanced_vertex_shader(options),
	}
	stage.uniform_buffers = nil
	return stage
end

local function build_material_block(field_defs)
	local block = {}

	for i, def in ipairs(field_defs) do
		if def.type == "texture" then
			block[i] = {def.name, "int"}
		else
			block[i] = {def.name, def.type}
		end
	end

	return block
end

local function build_material_block_writer(name, field_defs)
	local lines = {
		"return function(get_material)",
		"\treturn function(self, block, material)",
		"\tmaterial = material or get_material()",
	}

	for _, def in ipairs(field_defs) do
		if def.type == "texture" then
			lines[#lines + 1] = string.format("\tblock.%s = self:GetTextureIndex(material:%s())", def.name, def.getter)
		elseif def.type == "vec3" or def.type == "vec4" then
			lines[#lines + 1] = string.format("\tmaterial:%s():CopyToFloatPointer(block.%s)", def.getter, def.name)
		else
			lines[#lines + 1] = string.format("\tblock.%s = material:%s()", def.name, def.getter)
		end
	end

	lines[#lines + 1] = "\t\treturn block"
	lines[#lines + 1] = "\tend"
	lines[#lines + 1] = "end"
	return assert(loadstring(table.concat(lines, "\n"), name .. "_material_block_writer"))()(get_material)
end

local SURFACE_MATERIAL_BLOCK = build_material_block(SURFACE_MATERIAL_FIELDS)
local PBR_MATERIAL_BLOCK = build_material_block(PBR_MATERIAL_FIELDS)
local PROBE_MATERIAL_BLOCK = build_material_block(PROBE_MATERIAL_FIELDS)
local WRITE_SURFACE_MATERIAL_BLOCK = build_material_block_writer("surface", SURFACE_MATERIAL_FIELDS)
local WRITE_PBR_MATERIAL_BLOCK = build_material_block_writer("pbr", PBR_MATERIAL_FIELDS)
local WRITE_PROBE_MATERIAL_BLOCK = build_material_block_writer("probe", PROBE_MATERIAL_FIELDS)

function model_pipeline.GetSurfaceMaterialBlock()
	return SURFACE_MATERIAL_BLOCK
end

function model_pipeline.GetPBRMaterialBlock()
	return PBR_MATERIAL_BLOCK
end

function model_pipeline.GetProbeMaterialBlock()
	return PROBE_MATERIAL_BLOCK
end

function model_pipeline.WriteSurfaceMaterialBlock(self, block)
	return WRITE_SURFACE_MATERIAL_BLOCK(self, block)
end

function model_pipeline.WritePBRMaterialBlock(self, block)
	return WRITE_PBR_MATERIAL_BLOCK(self, block)
end

function model_pipeline.WriteProbeMaterialBlock(self, block)
	return WRITE_PROBE_MATERIAL_BLOCK(self, block)
end

function model_pipeline.GetVertexAnimationUniformBufferDecl()
	local fields = {
		"float Time;",
		"float WindAmplitude;",
		"float WindFrequency;",
		"float WindDetailAmplitude;",
		"float WindDetailFrequency;",
		"float WindPhaseScale;",
		"float WindNormalInfluence;",
		"float WindDirection[3];",
		"int BranchHelperCount;",
	}

	for i = 0, MAX_BRANCH_HELPERS - 1 do
		fields[#fields + 1] = string.format("float BranchHelper%d[4];", i)
	end

	return ([[
		struct {
			%s
		}
	]]):format(table.concat(fields, "\n\t\t\t"))
end

function model_pipeline.BuildVertexAnimationUniformDeclaration(block_name, binding_index)
	block_name = block_name or "vertex_animation"
	binding_index = binding_index or 0
	local fields = {
		"\t\t\t\tfloat Time;",
		"\t\t\t\tfloat WindAmplitude;",
		"\t\t\t\tfloat WindFrequency;",
		"\t\t\t\tfloat WindDetailAmplitude;",
		"\t\t\t\tfloat WindDetailFrequency;",
		"\t\t\t\tfloat WindPhaseScale;",
		"\t\t\t\tfloat WindNormalInfluence;",
		"\t\t\t\tvec3 WindDirection;",
		"\t\t\t\tint BranchHelperCount;",
	}

	for i = 0, MAX_BRANCH_HELPERS - 1 do
		fields[#fields + 1] = string.format("\t\t\t\tvec4 BranchHelper%d;", i)
	end

	return (
		[[
			layout(scalar, binding = %d) uniform VertexAnimation_t {
		%s
			} %s;
	]]
	):format(binding_index, table.concat(fields, "\n"), block_name)
end

function model_pipeline.FillVertexAnimationData(block, material)
	material = material or get_material()
	local wind_amplitude = material:GetWindAmplitude()
	local wind_detail_amplitude = material:GetWindDetailAmplitude()
	block.WindAmplitude = wind_amplitude
	block.WindDetailAmplitude = wind_detail_amplitude

	if wind_amplitude <= 0 and wind_detail_amplitude <= 0 then
		block.BranchHelperCount = 0
		return block
	end

	block.Time = system.GetElapsedTime()
	block.WindFrequency = material:GetWindFrequency()
	block.WindDetailFrequency = material:GetWindDetailFrequency()
	block.WindPhaseScale = material:GetWindPhaseScale()
	block.WindNormalInfluence = material:GetWindNormalInfluence()
	local wind_direction = material:GetWindDirection()
	block.WindDirection[0] = wind_direction.x
	block.WindDirection[1] = wind_direction.y
	block.WindDirection[2] = wind_direction.z
	local polygon = render3d.GetCurrentPolygon3D()
	local pivots = polygon and
		polygon.GetBranchHelperPivots and
		polygon:GetBranchHelperPivots() or
		nil
	local helper_count = math.min(pivots and #pivots or 0, MAX_BRANCH_HELPERS)
	local world_matrix = render3d.GetWorldMatrix()
	local has_world_matrix = world_matrix ~= nil
	local m00, m10, m20, m30
	local m01, m11, m21, m31
	local m02, m12, m22, m32
	local m03, m13, m23, m33

	if has_world_matrix then
		m00 = world_matrix.m00
		m10 = world_matrix.m10
		m20 = world_matrix.m20
		m30 = world_matrix.m30
		m01 = world_matrix.m01
		m11 = world_matrix.m11
		m21 = world_matrix.m21
		m31 = world_matrix.m31
		m02 = world_matrix.m02
		m12 = world_matrix.m12
		m22 = world_matrix.m22
		m32 = world_matrix.m32
		m03 = world_matrix.m03
		m13 = world_matrix.m13
		m23 = world_matrix.m23
		m33 = world_matrix.m33
	end

	block.BranchHelperCount = helper_count

	for i = 0, MAX_BRANCH_HELPERS - 1 do
		local field = block[BRANCH_HELPER_KEYS[i + 1]]
		local pivot = pivots and pivots[i + 1] or nil

		if i < helper_count and pivot then
			local x = pivot.x
			local y = pivot.y
			local z = pivot.z

			if has_world_matrix then
				local div = x * m03 + y * m13 + z * m23 + m33
				field[0] = (x * m00 + y * m10 + z * m20 + m30) / div
				field[1] = (x * m01 + y * m11 + z * m21 + m31) / div
				field[2] = (x * m02 + y * m12 + z * m22 + m32) / div
			else
				field[0] = x
				field[1] = y
				field[2] = z
			end

			field[3] = 1
		else
			field[0] = 0
			field[1] = 0
			field[2] = 0
			field[3] = 0
		end
	end
end

function model_pipeline.GetVertexAnimationBlock()
	local block = {
		{"Time", "float"},
		{"WindAmplitude", "float"},
		{"WindFrequency", "float"},
		{"WindDetailAmplitude", "float"},
		{"WindDetailFrequency", "float"},
		{"WindPhaseScale", "float"},
		{"WindNormalInfluence", "float"},
		{"WindDirection", "vec3"},
		{"BranchHelperCount", "int"},
	}

	for i = 1, MAX_BRANCH_HELPERS do
		block[#block + 1] = {BRANCH_HELPER_KEYS[i], "vec4"}
	end

	return block
end

function model_pipeline.WriteVertexAnimationBlock(self, block)
	return model_pipeline.FillVertexAnimationData(block)
end

function model_pipeline.BuildVertexAnimationGlsl(block_name)
	block_name = block_name or "vertex_animation"
	local helper_cases = {}

	for i = 0, MAX_BRANCH_HELPERS - 1 do
		helper_cases[#helper_cases + 1] = string.format("\t\t\t\tif (index == %d) return %s.BranchHelper%d.xyz;", i, block_name, i)
	end

	return [[
			bool has_authored_vertex_animation(vec4 vertex_color) {
				return dot(vertex_color, vec4(1.0)) > 0.0001;
			}

			float get_vertex_animation_weight(vec2 uv, float texture_blend, vec4 vertex_color) {
				if (has_authored_vertex_animation(vertex_color)) {
					float leaf_mask = clamp(vertex_color.r, 0.0, 1.0);
					float broad_bend = clamp(vertex_color.a, 0.0, 1.0);
					return leaf_mask * broad_bend;
				}

				return clamp(max(texture_blend, uv.y), 0.0, 1.0);
			}

			bool has_vertex_animation() {
				return ]] .. block_name .. [[.WindAmplitude > 0.0 || ]] .. block_name .. [[.WindDetailAmplitude > 0.0;
			}

			vec3 get_branch_helper_pivot(int index) {
]] .. table.concat(helper_cases, "\n") .. [[
				return vec3(0.0);
			}

			int get_nearest_branch_helper_index(vec3 world_pos) {
				int helper_count = ]] .. block_name .. [[.BranchHelperCount;
				if (helper_count <= 0) return -1;

				int nearest_helper = 0;
				float nearest_dist_sq = 1e30;

				for (int i = 0; i < helper_count; i++) {
					vec3 helper_pivot = get_branch_helper_pivot(i);
					vec2 to_helper = world_pos.xz - helper_pivot.xz;
					float dist_sq = dot(to_helper, to_helper);

					if (dist_sq < nearest_dist_sq) {
						nearest_dist_sq = dist_sq;
						nearest_helper = i;
					}
				}

				return nearest_helper;
			}

			float get_branch_helper_height(vec3 world_pos) {
				int nearest_helper = get_nearest_branch_helper_index(world_pos);
				if (nearest_helper < 0) return 0.0;
				vec3 pivot = get_branch_helper_pivot(nearest_helper);
				return max(world_pos.y - pivot.y, 0.0);
			}

			vec3 get_branch_helper_offset(vec3 world_pos, vec3 wind_dir, float carrier_bend) {
				if (abs(carrier_bend) <= 0.00001) return wind_dir * carrier_bend;
				int nearest_helper = get_nearest_branch_helper_index(world_pos);
				if (nearest_helper < 0) return wind_dir * carrier_bend;
				vec3 pivot = get_branch_helper_pivot(nearest_helper);
				float rel_height = max(world_pos.y - pivot.y, 0.0);
				return wind_dir * (rel_height * carrier_bend);
			}

			vec3 get_vertex_animation_offset(vec3 world_pos, vec3 world_normal, vec3 world_tangent, vec2 uv, float texture_blend, vec4 vertex_color) {
				if (!has_vertex_animation()) return vec3(0.0);

				vec3 wind_dir = ]] .. block_name .. [[.WindDirection;
				float wind_len = length(wind_dir.xz);
				if (wind_len <= 0.0001) wind_dir = vec3(1.0, 0.0, 0.0);
				else wind_dir = normalize(vec3(wind_dir.x, 0.0, wind_dir.z));

				vec4 authored = clamp(vertex_color, 0.0, 1.0);
				bool use_authored = has_authored_vertex_animation(authored);
				float weight = get_vertex_animation_weight(uv, texture_blend, authored);
				float leaf_mask = use_authored ? authored.r : weight;
				float carrier_weight = use_authored ? authored.g : weight;
				float edge_weight = use_authored ? clamp(1.0 - authored.b, 0.0, 1.0) : clamp(1.0 - abs(uv.x * 2.0 - 1.0), 0.0, 1.0);
				float broad_bend = use_authored ? authored.a : weight;
				float helper_height = get_branch_helper_height(world_pos);
				float white_rgb = use_authored ? smoothstep(0.95, 0.999, min(authored.r, min(authored.g, authored.b))) : 0.0;
				float root_release = smoothstep(0.35, 1.5, helper_height);
				float white_anchor = mix(0.05, 1.0, root_release);
				float stiffness = use_authored ? clamp((1.0 - authored.r) * authored.b, 0.0, 1.0) : clamp(1.0 - weight, 0.0, 1.0);
				stiffness = max(stiffness, white_rgb * (1.0 - root_release) * 0.95);
				float flexibility = (1.0 - stiffness) * mix(1.0, white_anchor, white_rgb);
				float carrier_flexibility = flexibility * flexibility;
				broad_bend *= mix(1.0, white_anchor, white_rgb);
				float phase_offset = uv.x * 6.2831853;
				float carrier_phase = ]] .. block_name .. [[.Time * (]] .. block_name .. [[.WindFrequency * 0.65);
				float carrier_wave = sin(carrier_phase);
				float phase = ]] .. block_name .. [[.Time * ]] .. block_name .. [[.WindFrequency;
				phase += dot(world_pos.xz, wind_dir.xz) * ]] .. block_name .. [[.WindPhaseScale;
				phase += phase_offset;
				float main_wave = sin(phase);

				vec2 detail_dir = vec2(-wind_dir.z, wind_dir.x);
				float detail_phase = ]] .. block_name .. [[.Time * (]] .. block_name .. [[.WindFrequency * ]] .. block_name .. [[.WindDetailFrequency);
				detail_phase += dot(world_pos.xz, detail_dir) * (]] .. block_name .. [[.WindPhaseScale * 2.7);
				detail_phase += phase_offset * 1.37;
				float detail_wave = sin(detail_phase);

				vec3 tangent_dir = normalize(world_tangent - world_normal * dot(world_tangent, world_normal));
				if (length(tangent_dir) <= 0.0001) tangent_dir = normalize(cross(world_normal, vec3(0.0, 1.0, 0.0)));
				if (length(tangent_dir) <= 0.0001) tangent_dir = vec3(1.0, 0.0, 0.0);

				float carrier_bend = carrier_wave * ]] .. block_name .. [[.WindAmplitude * carrier_weight * broad_bend * carrier_flexibility * 0.18;
				float branch_bend = main_wave * ]] .. block_name .. [[.WindAmplitude * broad_bend * leaf_mask * flexibility;
				float edge_bend = detail_wave * ]] .. block_name .. [[.WindDetailAmplitude * broad_bend * edge_weight * leaf_mask * flexibility;
				vec3 offset = get_branch_helper_offset(world_pos, wind_dir, carrier_bend);
				offset += wind_dir * branch_bend;
				offset += tangent_dir * edge_bend;
				return offset;
			}

			vec3 bend_vertex_animation_direction(vec3 direction, vec3 world_offset) {
				float offset_len = length(world_offset);
				if (offset_len <= 0.00001 || ]] .. block_name .. [[.WindNormalInfluence <= 0.0) return normalize(direction);
				return normalize(direction + normalize(world_offset) * (offset_len * ]] .. block_name .. [[.WindNormalInfluence));
			}
	]]
end

function model_pipeline.BuildShadowGeometryDeformationGlsl(block_name, shadow_state_var)
	block_name = block_name or "vertex_animation"
	shadow_state_var = shadow_state_var or "pc"
	return model_pipeline.BuildVertexAnimationGlsl(block_name) .. [[
			bool shadow_has_heightmap() {
				return ]] .. shadow_state_var .. [[.height_texture_index != -1 && ]] .. shadow_state_var .. [[.height_scale > 0.0;
			}

			float shadow_get_height_sample(vec2 uv) {
				if (!shadow_has_heightmap()) {
					return 1.0;
				}

				return texture(textures[nonuniformEXT(]] .. shadow_state_var .. [[.height_texture_index)], uv).r;
			}

			float shadow_get_height_centered_sample(vec2 uv) {
				return shadow_get_height_sample(uv) - ]] .. shadow_state_var .. [[.height_center;
			}

			void apply_shadow_geometry_deformation(
				inout vec3 local_pos,
				inout vec3 world_pos,
				vec3 world_normal,
				vec3 world_tangent,
				vec2 uv,
				float texture_blend,
				vec4 vertex_color,
				mat3 inv_world_matrix3
			) {
				if (shadow_has_heightmap()) {
					world_pos += vec3(0.0, 1.0, 0.0) * (shadow_get_height_centered_sample(uv) * ]] .. shadow_state_var .. [[.height_scale);
				}

				vec3 world_offset = get_vertex_animation_offset(world_pos, world_normal, world_tangent, uv, texture_blend, vertex_color);

				if (dot(world_offset, world_offset) > 0.0) {
					local_pos += inv_world_matrix3 * world_offset;
					world_pos += world_offset;
				}
			}
		]]
end

function model_pipeline.BuildTriangleInterpolationGlsl()
	return [[
			vec3 interpolate_vec3(vec3 a, vec3 b, vec3 c) {
				return a * gl_TessCoord.x + b * gl_TessCoord.y + c * gl_TessCoord.z;
			}

			vec2 interpolate_vec2(vec2 a, vec2 b, vec2 c) {
				return a * gl_TessCoord.x + b * gl_TessCoord.y + c * gl_TessCoord.z;
			}

			vec4 interpolate_vec4(vec4 a, vec4 b, vec4 c) {
				return a * gl_TessCoord.x + b * gl_TessCoord.y + c * gl_TessCoord.z;
			}

			float interpolate_float(float a, float b, float c) {
				return a * gl_TessCoord.x + b * gl_TessCoord.y + c * gl_TessCoord.z;
			}
		]]
end

function model_pipeline.BuildAlphaDiscardGlsl(alpha_cutoff_expr)
	alpha_cutoff_expr = alpha_cutoff_expr or "model.AlphaCutoff"
	return (
		[[
			void compute_translucency_and_discard(inout float alpha) {
				if (AlphaTest) {
					if (alpha < %s) discard;
				} else if (Translucent) {
					if (fract(dot(vec2(171.0, 231.0) + alpha * 0.00001, gl_FragCoord.xy) / 103.0) > (alpha * alpha)) discard;
				}
			}
		]]
	):format(alpha_cutoff_expr)
end

function model_pipeline.BuildBindlessAlphaSamplingGlsl(texture_index_expr, color_multiplier_a_expr, opacity_texture_index_expr)
	texture_index_expr = texture_index_expr or "pc.albedo_texture_index"
	color_multiplier_a_expr = color_multiplier_a_expr or "pc.color_multiplier_a"
	opacity_texture_index_expr = opacity_texture_index_expr or "-1"
	return (
		[[
			float get_alpha_uv(vec2 uv) {
				if (%s != -1) {
					vec4 mask = textureLod(textures[nonuniformEXT(%s)], uv, 0.0);
					return clamp(max(max(mask.r, mask.g), max(mask.b, mask.a)), 0.0, 1.0) * %s;
				}

				if (
					%s == -1 ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoAlphaIsEmissive
				) {
					return %s;
				}

				return textureLod(textures[nonuniformEXT(%s)], uv, 0.0).a * %s;
			}

			float get_alpha() {
				return get_alpha_uv(in_uv);
			}
		]]
	):format(
		opacity_texture_index_expr,
		opacity_texture_index_expr,
		color_multiplier_a_expr,
		texture_index_expr,
		color_multiplier_a_expr,
		texture_index_expr,
		color_multiplier_a_expr
	)
end

function model_pipeline.BuildSurfaceSamplingGlsl(model_var)
	model_var = model_var or "model"
	return Material.BuildGlslFlags(model_var .. ".Flags") .. [[

			vec4 get_surface_color() {
				vec4 color = ]] .. model_var .. [[.ColorMultiplier;

				if (]] .. model_var .. [[.AlbedoTexture != -1) {
					color *= texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), in_uv);
				}

				return color;
			}

			void discard_surface_alpha(vec4 color) {
				if (AlphaTest && color.a < ]] .. model_var .. [[.AlphaCutoff) discard;
			}

			vec3 get_surface_emissive(vec3 albedo) {
				if (AlbedoAlphaIsEmissive) {
					float mask = 1.0;

					if (]] .. model_var .. [[.AlbedoTexture != -1) {
						mask = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), in_uv).a;
					}

					return albedo * mask * ]] .. model_var .. [[.EmissiveMultiplier.rgb * ]] .. model_var .. [[.EmissiveMultiplier.a;
				}

				if (]] .. model_var .. [[.EmissiveTexture != -1) {
					vec3 emissive = texture(TEXTURE(]] .. model_var .. [[.EmissiveTexture), in_uv).rgb;
					return emissive * ]] .. model_var .. [[.EmissiveMultiplier.rgb * ]] .. model_var .. [[.EmissiveMultiplier.a;
				}

				return vec3(0.0);
			}
	]]
end

function model_pipeline.BuildPBRSamplingGlsl(model_var)
	model_var = model_var or "model"
	return Material.BuildGlslFlags(model_var .. ".Flags") .. [[

			bool has_heightmap() {
				return ]] .. model_var .. [[.HeightTexture != -1 && ]] .. model_var .. [[.HeightScale > 0.0;
			}

			float get_height_sample(vec2 uv) {
				if (!has_heightmap()) {
					return 1.0;
				}

				return texture(TEXTURE(]] .. model_var .. [[.HeightTexture), uv).r;
			}

			float get_height_centered_sample(vec2 uv) {
				return get_height_sample(uv) - ]] .. model_var .. [[.HeightCenter;
			}

			bool use_tessellated_displacement() {
				return has_heightmap() && ]] .. model_var .. [[.TessellationFactor > 1.0;
			}

			float get_tessellation_factor() {
				return clamp(]] .. model_var .. [[.TessellationFactor, 1.0, 64.0);
			}

			int get_height_layers() {
				return clamp(]] .. model_var .. [[.HeightLayers, 4, 64);
			}

			float get_texture_blend_uv(vec2 uv) {
				if (]] .. model_var .. [[.BlendTexture == -1) {
					return in_texture_blend;
				}

				float blend = in_texture_blend;
				vec2 blend_data = texture(TEXTURE(]] .. model_var .. [[.BlendTexture), uv).rg;
				float minb = blend_data.r;
				float maxb = blend_data.g;
				blend = clamp((blend - minb) / (maxb - minb + 0.001), 0.0, 1.0);
				return blend;
			}

			float get_texture_blend() {
				return get_texture_blend_uv(in_uv);
			}

			float sample_terrain_hash(vec2 p) {
				return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
			}

			float sample_terrain_noise(vec2 p) {
				vec2 cell = floor(p);
				vec2 frac = fract(p);
				frac = frac * frac * (3.0 - 2.0 * frac);
				return mix(
					mix(sample_terrain_hash(cell), sample_terrain_hash(cell + vec2(1.0, 0.0)), frac.x),
					mix(sample_terrain_hash(cell + vec2(0.0, 1.0)), sample_terrain_hash(cell + vec2(1.0, 1.0)), frac.x),
					frac.y
				);
			}

			vec3 sample_terrain_checker(vec2 world_pos, float checker_scale, vec3 color_a, vec3 color_b) {
				float safe_scale = max(checker_scale, 0.0001);
				vec2 sample_pos = world_pos / safe_scale;
				float macro = sample_terrain_noise(sample_pos);
				float micro = sample_terrain_noise(sample_pos * 2.7 + vec2(19.1, -7.3));
				float blend = clamp(macro * 0.72 + micro * 0.28, 0.0, 1.0);
				return mix(color_a, color_b, blend);
			}

			vec4 get_terrain_material_weights_uv(vec2 uv) {
				if (]] .. model_var .. [[.TerrainMaterialTexture == -1) {
					return vec4(0.0);
				}

				vec4 weights = texture(TEXTURE(]] .. model_var .. [[.TerrainMaterialTexture), uv);
				weights = max(weights, vec4(0.0));
				float weight_sum = dot(weights, vec4(1.0));

				if (weight_sum <= 0.0001) {
					return vec4(0.0);
				}

				return weights / weight_sum;
			}

			vec3 get_terrain_albedo_uv(vec2 uv, vec3 world_pos) {
				vec4 weights = get_terrain_material_weights_uv(uv);

				if (dot(weights, vec4(1.0)) <= 0.0001) {
					return ]] .. model_var .. [[.ColorMultiplier.rgb;
				}
				vec2 terrain_pos = world_pos.xz;
				vec3 layer1 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.x, ]] .. model_var .. [[.TerrainLayer1ColorA.rgb, ]] .. model_var .. [[.TerrainLayer1ColorB.rgb);
				vec3 layer2 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.y, ]] .. model_var .. [[.TerrainLayer2ColorA.rgb, ]] .. model_var .. [[.TerrainLayer2ColorB.rgb);
				vec3 layer3 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.z, ]] .. model_var .. [[.TerrainLayer3ColorA.rgb, ]] .. model_var .. [[.TerrainLayer3ColorB.rgb);
				vec3 layer4 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.w, ]] .. model_var .. [[.TerrainLayer4ColorA.rgb, ]] .. model_var .. [[.TerrainLayer4ColorB.rgb);
				vec3 color = layer1 * weights.r + layer2 * weights.g + layer3 * weights.b + layer4 * weights.a;

				if (]] .. model_var .. [[.AlbedoTexture != -1) {
					vec3 detail = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;
					color *= detail;
				}

				return color * ]] .. model_var .. [[.ColorMultiplier.rgb;
			}

			vec3 get_albedo_world(vec2 uv, vec3 world_pos) {
				if (]] .. model_var .. [[.TerrainMaterialTexture != -1) {
					return get_terrain_albedo_uv(uv, world_pos);
				}

				if (]] .. model_var .. [[.AlbedoTexture == -1) {
					return ]] .. model_var .. [[.ColorMultiplier.rgb;
				}

				vec3 rgb1 = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;

				if (]] .. model_var .. [[.Albedo2Texture != -1) {
					float blend = get_texture_blend_uv(uv);

					if (blend != 0) {
						vec3 rgb2 = texture(TEXTURE(]] .. model_var .. [[.Albedo2Texture), uv).rgb;
						rgb1 = mix(rgb1, rgb2, blend);
					}
				}

				return rgb1 * ]] .. model_var .. [[.ColorMultiplier.rgb;
			}

			vec3 get_albedo_uv(vec2 uv) {
				return get_albedo_world(uv, in_position);
			}

			vec3 get_albedo() {
				return get_albedo_uv(in_uv);
			}

			float get_alpha_uv(vec2 uv) {
				if (
					]] .. model_var .. [[.AlbedoTexture == -1 ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoTextureAlphaIsRoughness ||
					AlbedoAlphaIsEmissive
				) {
					return ]] .. model_var .. [[.ColorMultiplier.a;
				}

				return texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).a * ]] .. model_var .. [[.ColorMultiplier.a;
			}

			float get_alpha() {
				return get_alpha_uv(in_uv);
			}
	]]
end

function model_pipeline.BuildProbeSamplingGlsl(model_var)
	model_var = model_var or "model"
	return Material.BuildGlslFlags(model_var .. ".Flags") .. [[

			float get_texture_blend_uv(vec2 uv) {
				if (]] .. model_var .. [[.BlendTexture == -1) {
					return in_texture_blend;
				}

				float blend = in_texture_blend;
				vec2 blend_data = texture(TEXTURE(]] .. model_var .. [[.BlendTexture), uv).rg;
				float minb = blend_data.r;
				float maxb = blend_data.g;
				blend = clamp((blend - minb) / (maxb - minb + 0.001), 0.0, 1.0);
				return blend;
			}

			float sample_terrain_hash(vec2 p) {
				return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
			}

			float sample_terrain_noise(vec2 p) {
				vec2 cell = floor(p);
				vec2 frac = fract(p);
				frac = frac * frac * (3.0 - 2.0 * frac);
				return mix(
					mix(sample_terrain_hash(cell), sample_terrain_hash(cell + vec2(1.0, 0.0)), frac.x),
					mix(sample_terrain_hash(cell + vec2(0.0, 1.0)), sample_terrain_hash(cell + vec2(1.0, 1.0)), frac.x),
					frac.y
				);
			}

			vec3 sample_terrain_checker(vec2 world_pos, float checker_scale, vec3 color_a, vec3 color_b) {
				float safe_scale = max(checker_scale, 0.0001);
				vec2 sample_pos = world_pos / safe_scale;
				float macro = sample_terrain_noise(sample_pos);
				float micro = sample_terrain_noise(sample_pos * 2.7 + vec2(19.1, -7.3));
				float blend = clamp(macro * 0.72 + micro * 0.28, 0.0, 1.0);
				return mix(color_a, color_b, blend);
			}

			vec4 get_terrain_material_weights_uv(vec2 uv) {
				if (]] .. model_var .. [[.TerrainMaterialTexture == -1) {
					return vec4(0.0);
				}

				vec4 weights = texture(TEXTURE(]] .. model_var .. [[.TerrainMaterialTexture), uv);
				weights = max(weights, vec4(0.0));
				float weight_sum = dot(weights, vec4(1.0));

				if (weight_sum <= 0.0001) {
					return vec4(0.0);
				}

				return weights / weight_sum;
			}

			vec3 get_terrain_albedo_uv(vec2 uv, vec3 world_pos) {
				vec4 weights = get_terrain_material_weights_uv(uv);

				if (dot(weights, vec4(1.0)) <= 0.0001) {
					return ]] .. model_var .. [[.ColorMultiplier.rgb;
				}

				vec2 terrain_pos = world_pos.xz;
				vec3 layer1 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.x, ]] .. model_var .. [[.TerrainLayer1ColorA.rgb, ]] .. model_var .. [[.TerrainLayer1ColorB.rgb);
				vec3 layer2 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.y, ]] .. model_var .. [[.TerrainLayer2ColorA.rgb, ]] .. model_var .. [[.TerrainLayer2ColorB.rgb);
				vec3 layer3 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.z, ]] .. model_var .. [[.TerrainLayer3ColorA.rgb, ]] .. model_var .. [[.TerrainLayer3ColorB.rgb);
				vec3 layer4 = sample_terrain_checker(terrain_pos, ]] .. model_var .. [[.TerrainCheckerScales.w, ]] .. model_var .. [[.TerrainLayer4ColorA.rgb, ]] .. model_var .. [[.TerrainLayer4ColorB.rgb);
				vec3 color = layer1 * weights.r + layer2 * weights.g + layer3 * weights.b + layer4 * weights.a;

				if (]] .. model_var .. [[.AlbedoTexture != -1) {
					vec3 detail = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;
					color *= detail;
				}

				return color * ]] .. model_var .. [[.ColorMultiplier.rgb;
			}

			vec3 get_albedo_world(vec2 uv, vec3 world_pos) {
				if (]] .. model_var .. [[.TerrainMaterialTexture != -1) {
					return get_terrain_albedo_uv(uv, world_pos);
				}

				if (]] .. model_var .. [[.AlbedoTexture == -1) {
					return ]] .. model_var .. [[.ColorMultiplier.rgb;
				}

				vec3 rgb1 = texture(TEXTURE(]] .. model_var .. [[.AlbedoTexture), uv).rgb;

				if (]] .. model_var .. [[.Albedo2Texture != -1) {
					float blend = get_texture_blend_uv(uv);

					if (blend != 0) {
						vec3 rgb2 = texture(TEXTURE(]] .. model_var .. [[.Albedo2Texture), uv).rgb;
						rgb1 = mix(rgb1, rgb2, blend);
					}
				}

				return rgb1 * ]] .. model_var .. [[.ColorMultiplier.rgb;
			}

			vec3 get_albedo_uv(vec2 uv) {
				return get_albedo_world(uv, in_position);
			}

			vec3 get_albedo() {
				return get_albedo_uv(in_uv);
			}
	]]
end

return model_pipeline
