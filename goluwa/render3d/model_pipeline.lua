local render3d = import("goluwa/render3d/render3d.lua")
local Material = import("goluwa/render3d/material.lua")
local system = import("goluwa/system.lua")
local model_pipeline = library()
local MAX_BRANCH_HELPERS = 16
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

function model_pipeline.GetVertexAttributes()
	return {
		{"position", "vec3", "r32g32b32_sfloat"},
		{"normal", "vec3", "r32g32b32_sfloat"},
		{"uv", "vec2", "r32g32_sfloat"},
		{"tangent", "vec4", "r32g32b32a32_sfloat"},
		{"texture_blend", "float", "r32_sfloat"},
		{"vertex_color", "vec4", "r32g32b32a32_sfloat"},
	}
end

function model_pipeline.GetTransformBlock(get_projection_view_world_matrix)
	get_projection_view_world_matrix = get_projection_view_world_matrix or render3d.GetProjectionViewWorldMatrix
	return {
		{
			"projection_view_world",
			"mat4",
			function(self, block, key)
				get_projection_view_world_matrix():CopyToFloatPointer(block[key])
			end,
		},
		{
			"world",
			"mat4",
			function(self, block, key)
				render3d.GetWorldMatrix():CopyToFloatPointer(block[key])
			end,
		},
	}
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

function model_pipeline.CreateVertexStage(options)
	options = options or {}
	local storage_key = options.transform_storage or "push_constants"
	local transform_buffers = {
		{
			name = options.transform_block_name or "vertex",
			block = model_pipeline.GetTransformBlock(options.get_projection_view_world_matrix),
		},
	}
	local animation_buffers = options.vertex_uniform_buffers or
		{
			{
				name = "vertex_animation",
				block = model_pipeline.GetVertexAnimationBlock(),
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

local function build_texture_field(field_name, getter_name)
	return {
		field_name,
		"int",
		function(self, block, key)
			local material = get_material()
			block[key] = self:GetTextureIndex(material[getter_name](material))
		end,
	}
end

local function build_scalar_field(field_name, field_type, getter_name)
	return {
		field_name,
		field_type,
		function(self, block, key)
			local material = get_material()
			block[key] = material[getter_name](material)
		end,
	}
end

local function build_vec4_field(field_name, getter_name)
	return {
		field_name,
		"vec4",
		function(self, block, key)
			local material = get_material()
			material[getter_name](material):CopyToFloatPointer(block[key])
		end,
	}
end

local function build_vec3_field(field_name, getter_name)
	return {
		field_name,
		"vec3",
		function(self, block, key)
			local material = get_material()
			material[getter_name](material):CopyToFloatPointer(block[key])
		end,
	}
end

local function build_material_block(field_defs)
	local block = {}

	for i, def in ipairs(field_defs) do
		if def.type == "texture" then
			block[i] = build_texture_field(def.name, def.getter)
		elseif def.type == "vec3" then
			block[i] = build_vec3_field(def.name, def.getter)
		elseif def.type == "vec4" then
			block[i] = build_vec4_field(def.name, def.getter)
		else
			block[i] = build_scalar_field(def.name, def.type, def.getter)
		end
	end

	return block
end

function model_pipeline.GetSurfaceMaterialBlock()
	return build_material_block(SURFACE_MATERIAL_FIELDS)
end

function model_pipeline.GetPBRMaterialBlock()
	return build_material_block(PBR_MATERIAL_FIELDS)
end

function model_pipeline.GetProbeMaterialBlock()
	return build_material_block(PROBE_MATERIAL_FIELDS)
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
	block.Time = system.GetElapsedTime()
	block.WindAmplitude = material:GetWindAmplitude()
	block.WindFrequency = material:GetWindFrequency()
	block.WindDetailAmplitude = material:GetWindDetailAmplitude()
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
	block.BranchHelperCount = helper_count

	for i = 0, MAX_BRANCH_HELPERS - 1 do
		local field = block["BranchHelper" .. tostring(i)]
		local pivot = pivots and pivots[i + 1] or nil

		if i < helper_count and pivot then
			local world_matrix = render3d.GetWorldMatrix()
			local world_pivot = world_matrix and world_matrix:TransformVector(pivot) or pivot
			field[0] = world_pivot.x
			field[1] = world_pivot.y
			field[2] = world_pivot.z
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
		{
			"Time",
			"float",
			function(self, block, key)
				block[key] = system.GetElapsedTime()
			end,
		},
		{
			"WindAmplitude",
			"float",
			function(self, block, key)
				block[key] = get_material():GetWindAmplitude()
			end,
		},
		{
			"WindFrequency",
			"float",
			function(self, block, key)
				block[key] = get_material():GetWindFrequency()
			end,
		},
		{
			"WindDetailAmplitude",
			"float",
			function(self, block, key)
				block[key] = get_material():GetWindDetailAmplitude()
			end,
		},
		{
			"WindDetailFrequency",
			"float",
			function(self, block, key)
				block[key] = get_material():GetWindDetailFrequency()
			end,
		},
		{
			"WindPhaseScale",
			"float",
			function(self, block, key)
				block[key] = get_material():GetWindPhaseScale()
			end,
		},
		{
			"WindNormalInfluence",
			"float",
			function(self, block, key)
				block[key] = get_material():GetWindNormalInfluence()
			end,
		},
		{
			"WindDirection",
			"vec3",
			function(self, block, key)
				get_material():GetWindDirection():CopyToFloatPointer(block[key])
			end,
		},
		{
			"BranchHelperCount",
			"int",
			function(self, block, key)
				local polygon = render3d.GetCurrentPolygon3D()
				local pivots = polygon and
					polygon.GetBranchHelperPivots and
					polygon:GetBranchHelperPivots() or
					nil
				block[key] = math.min(pivots and #pivots or 0, MAX_BRANCH_HELPERS)
			end,
		},
	}

	for i = 1, MAX_BRANCH_HELPERS do
		local field_name = "BranchHelper" .. tostring(i - 1)
		block[#block + 1] = {
			field_name,
			"vec4",
			function(self, block, key)
				local polygon = render3d.GetCurrentPolygon3D()
				local pivots = polygon and
					polygon.GetBranchHelperPivots and
					polygon:GetBranchHelperPivots() or
					nil
				local pivot = pivots and pivots[i] or nil

				if pivot then
					local world_matrix = render3d.GetWorldMatrix()
					local world_pivot = world_matrix and world_matrix:TransformVector(pivot) or pivot
					block[key][0] = world_pivot.x
					block[key][1] = world_pivot.y
					block[key][2] = world_pivot.z
					block[key][3] = 1
				else
					block[key][0] = 0
					block[key][1] = 0
					block[key][2] = 0
					block[key][3] = 0
				end
			end,
		}
	end

	return block
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
