local ffi = require("ffi")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local vegetation_pushers = import("goluwa/render3d/vegetation_pushers.lua")
local vertex_layout = import("goluwa/render3d/vertex_layout.lua")
local deformation = {}

local function get_material()
	return render3d.GetMaterial()
end

local function get_previous_positions(polygon)
	local mesh = polygon and polygon.mesh

	return mesh and mesh ~= NULL and mesh.vertex_buffer.previous_positions
end

pvars.StartGroup("Rendering", "Wind", {store = false})
local still_version = 0
local still_pixels = pvars.Setup2{
	key = "r_wind_still_pixels",
	default = 2,
	min = 0,
	help = "a plant whose movement in the wind spans fewer pixels than this stands still in the pose it has at time 0 (its lean, without the sway and the flutter), over a band of twice that. far plants only shimmer. 0 moves every plant at every distance",
	callback = function()
		still_version = still_version + 1
	end,
}
pvars.EndGroup()

do
	local FIELDS = {
		{"Time", "float", "float Time;"},
		{"PrevTime", "float", "float PrevTime;"},
		{"DetailTime", "float", "float DetailTime;"},
		{"PrevDetailTime", "float", "float PrevDetailTime;"},
		{"MainBending", "float", "float MainBending;"},
		{"BendHeight", "float", "float BendHeight;"},
		{"BendSpeed", "float", "float BendSpeed;"},
		{"BendDirection", "vec3", "float BendDirection[3];"},
		{"DetailBending", "int", "int DetailBending;"},
		{"DetailFrequency", "float", "float DetailFrequency;"},
		{"DetailLeafAmplitude", "float", "float DetailLeafAmplitude;"},
		{"DetailBranchAmplitude", "float", "float DetailBranchAmplitude;"},
		{"DetailPhase", "float", "float DetailPhase;"},
		{"Motion", "float", "float Motion;"},
		{"PushBending", "float", "float PushBending;"},
		{"PushRadius", "float", "float PushRadius;"},
		{"PushersLow", "int", "int PushersLow;"},
		{"PushersHigh", "int", "int PushersHigh;"},
		{"HasRoot", "float", "float HasRoot;"},
		{"RootFlex", "float", "float RootFlex;"},
		{"RootPivot", "vec3", "float RootPivot[3];"},
		{"RootMid", "vec3", "float RootMid[3];"},
		{"RootTip", "vec3", "float RootTip[3];"},
		{"PreviousPositionsLow", "int", "int PreviousPositionsLow;"},
		{"PreviousPositionsHigh", "int", "int PreviousPositionsHigh;"},
		{"ExtrasLow", "int", "int ExtrasLow;"},
		{"ExtrasHigh", "int", "int ExtrasHigh;"},
	}
	local DETAIL_BENDING_MODES = {none = 0, leaves = 1, grass = 2}
	local MAIN_MOTION = 0.015 * 12 * 0.45
	local DETAIL_MOTION = 2
	local BEND_RESPONSE = 0.25
	local MAX_DETAIL_BENDING = 6
	local DETAIL_SPEED = 0.3
	local BEND_PER_HEIGHT = 0.25
	local MAX_BENDING = 7
	local BENDING_SPEED = 22

	function deformation.GetBlockDecl()
		local fields = {}

		for i, field in ipairs(FIELDS) do
			fields[i] = field[3]
		end

		return ([[
			struct {
				%s
			}
		]]):format(table.concat(fields, "\n\t\t\t\t"))
	end

	function deformation.BuildUniformDeclaration(binding_index)
		local fields = {}

		for i, field in ipairs(FIELDS) do
			fields[i] = "\t\t\t\t" .. field[2] .. " " .. field[1] .. ";"
		end

		return (
			[[
				layout(scalar, binding = %d) uniform VertexAnimation_t {
			%s
				} vertex_animation;
		]]
		):format(binding_index, table.concat(fields, "\n"))
	end

	function deformation.GetBlock()
		local block = {}

		for i, field in ipairs(FIELDS) do
			block[i] = {field[1], field[2]}
		end

		return block
	end

	-- how far, in meters, the wind moves the farthest vertex of a filled record
	function deformation.GetMotion(block)
		local motion = block.MainBending * MAIN_MOTION

		if block.DetailBending ~= 0 and block.BendSpeed > 0 then
			local strength = block.BendSpeed * block.DetailFrequency

			if block.DetailBending == 2 then
				strength = strength * (block.BendHeight > 0 and block.BendHeight or 1)
			end

			local amplitude = strength < 0.5 and strength * 2 or math.sqrt(strength * 2)
			motion = motion + DETAIL_MOTION * amplitude * math.max(block.DetailLeafAmplitude, block.DetailBranchAmplitude)
		end

		return motion
	end

	function deformation.Fill(block, material, polygon)
		material = material or get_material()
		polygon = polygon or render3d.GetCurrentPolygon3D()
		local wind = atmosphere.GetWind()
		local wind_x = wind.x * BEND_RESPONSE
		local wind_z = wind.z * BEND_RESPONSE
		local wind_length = math.sqrt(wind_x * wind_x + wind_z * wind_z)
		local detail_speed = DETAIL_SPEED * wind_length * MAX_DETAIL_BENDING / (
				MAX_DETAIL_BENDING + wind_length
			)
		local lean = (wind:GetLength() / BENDING_SPEED) ^ 1.6
		local bending = MAX_BENDING * lean / (1 + lean)
		local height = polygon and polygon:GetBendHeight() or 0
		block.Time = atmosphere.GetWindTime()
		block.PrevTime = atmosphere.GetPreviousWindTime()
		block.DetailTime = atmosphere.GetWindDetailTime()
		block.PrevDetailTime = atmosphere.GetPreviousWindDetailTime()
		block.MainBending = height > 0 and bending * material:GetBending() * height * BEND_PER_HEIGHT or 0
		block.BendHeight = height
		block.BendSpeed = detail_speed
		block.BendDirection[0] = wind_length > 0 and wind_x / wind_length or 1
		block.BendDirection[1] = 0
		block.BendDirection[2] = wind_length > 0 and wind_z / wind_length or 0
		block.DetailBending = DETAIL_BENDING_MODES[material:GetDetailBending()]
		block.DetailFrequency = material:GetBendDetailFrequency()
		block.DetailLeafAmplitude = material:GetBendDetailLeafAmplitude()
		block.DetailBranchAmplitude = material:GetBendDetailBranchAmplitude()
		block.DetailPhase = material:GetBendDetailPhase()
		local motion = deformation.GetMotion(block)
		local pixels = still_pixels:Get()
		block.Motion = pixels > 0 and motion / pixels or 1e9
		block.PushBending = height > 0 and material:GetBending() or 0
		local aabb = polygon and polygon:GetAABB()
		block.PushRadius = aabb and
			aabb.max_x >= aabb.min_x and
			math.max(-aabb.min_x, aabb.max_x, -aabb.min_z, aabb.max_z, 0) or
			0
		block.PushersLow, block.PushersHigh = vegetation_pushers.GetAddress()
		local root = polygon and polygon:GetRootChain()
		block.HasRoot = root and 1 or 0
		block.RootFlex = root and root.flex or 0

		for i = 0, 2 do
			block.RootPivot[i] = root and root.pivot[i + 1] or 0
			block.RootMid[i] = root and root.mid[i + 1] or 0
			block.RootTip[i] = root and root.tip[i + 1] or 0
		end

		local mesh = polygon and polygon.mesh
		local valid = mesh and mesh ~= NULL and mesh:IsValid()
		local previous = valid and mesh.vertex_buffer.previous_positions
		local address = previous and previous:GetDeviceAddress() or 0ULL
		block.PreviousPositionsLow = ffi.cast("int32_t", bit.band(address, 0xFFFFFFFFULL))
		block.PreviousPositionsHigh = ffi.cast("int32_t", bit.rshift(address, 32))
		address = valid and material:HasVertexAnimation() and mesh:GetExtrasBufferAddress() or 0ULL
		block.ExtrasLow = ffi.cast("int32_t", bit.band(address, 0xFFFFFFFFULL))
		block.ExtrasHigh = ffi.cast("int32_t", bit.rshift(address, 32))
		return block
	end
end

function deformation.GetVersion()
	return atmosphere.GetWindVersion() + still_version
end

do
	local frame, position, pixel_scale = -1, nil, 0

	function deformation.GetView()
		local now = system.GetFrameNumber()

		if now ~= frame then
			local camera = render3d.GetCamera()
			position = camera:GetPosition()
			pixel_scale = math.abs(camera:BuildProjectionMatrix().m11) * render3d.GetRenderSize().y * 0.5
			frame = now
		end

		return position, pixel_scale
	end
end

function deformation.WriteBlock(self, block)
	return deformation.Fill(block)
end

function deformation.GetUploadKey()
	local material = get_material()

	if not material then return render3d.GetDefaultMaterial() end

	if material:HasVertexAnimation() or get_previous_positions(render3d.GetCurrentPolygon3D()) then
		return nil
	end

	return render3d.GetMaterialUploadKey()
end

function deformation.BuildGlsl(world_matrix_expr, camera_position_expr, pixel_scale_expr)
	local still = camera_position_expr and
		(
			[[
				mat4 world = ]] .. world_matrix_expr .. [[;
				float meters = vertex_animation.Motion * length(world[1].xyz);
				float pixels = meters * ]] .. pixel_scale_expr .. [[ / max(distance(world[3].xyz, ]] .. camera_position_expr .. [[), 0.5);
				return 1.0 - smoothstep(1.0, 2.0, pixels);
		]]
		)
		or
		"return 0.0;"
	return [[

			struct VegetationChain {
				vec4 pivot;
				vec3 mid;
				vec3 tip;
			};

			layout(buffer_reference, scalar) readonly buffer VegetationPushers { vec4 p[]; };
			layout(buffer_reference, scalar) readonly buffer PreviousPositions { float p[]; };

			vec3 get_previous_local_position(vec3 position, uint index) {
				uvec2 address = uvec2(uint(vertex_animation.PreviousPositionsLow), uint(vertex_animation.PreviousPositionsHigh));

				if (address == uvec2(0u)) return position;

				PreviousPositions previous = PreviousPositions(packUint2x32(address));
				uint at = index * 3u;
				return vec3(previous.p[at], previous.p[at + 1u], previous.p[at + 2u]);
			}

			VegetationPushers get_vegetation_pushers() {
				return VegetationPushers(packUint2x32(uvec2(uint(vertex_animation.PushersLow), uint(vertex_animation.PushersHigh))));
			}

			vec4 vegetation_push(vec3 point, vec4 shape, vec3 half_size, bool over_root, vec3 shared_direction, float reach) {
				vec3 q = point - shape.xyz;
				vec3 core = max(half_size - vec3(shape.w), vec3(0.0));
				vec3 d = abs(q) - core;
				vec3 outside = max(d, vec3(0.0));
				float outside_length = length(outside);
				float surface;
				vec3 normal;

				if (outside_length > 0.0001) {
					surface = outside_length - shape.w;
					normal = vec3(q.x >= 0.0 ? 1.0 : -1.0, q.y >= 0.0 ? 1.0 : -1.0, q.z >= 0.0 ? 1.0 : -1.0) * outside / outside_length;
				} else if (over_root) {
					surface = -(q.y + half_size.y);
					normal = vec3(0.0, -1.0, 0.0);
				} else {
					surface = max(d.x, max(d.y, d.z)) - shape.w;

					if (d.x > d.y && d.x > d.z) normal = vec3(q.x >= 0.0 ? 1.0 : -1.0, 0.0, 0.0);
					else if (d.y > d.z) normal = vec3(0.0, q.y >= 0.0 ? 1.0 : -1.0, 0.0);
					else normal = vec3(0.0, 0.0, q.z >= 0.0 ? 1.0 : -1.0);
				}

				float penetration = reach - surface;

				if (penetration <= 0.0) return vec4(0.0);

				if (!over_root) normal = normalize(mix(normal, shared_direction, smoothstep(0.0, -0.4, surface)) + vec3(0.0001));

				float t = clamp(penetration / reach, 0.0, 1.0);
				return vec4(normal, penetration * t * t * (3.0 - 2.0 * t));
			}

			vec3 vegetation_rotate(vec3 point, vec3 pivot, vec3 rotation) {
				float angle = min(length(rotation), 1.0);

				if (angle < 0.0001) return point;

				vec3 axis = normalize(rotation);
				vec3 arm = point - pivot;
				return pivot + arm * cos(angle) + cross(axis, arm) * sin(angle) + axis * (dot(axis, arm) * (1.0 - cos(angle)));
			}

			float vegetation_polyline_distance(vec3 point, vec3 a, vec3 b, vec3 c) {
				vec3 ab = b - a;
				vec3 bc = c - b;
				vec3 on_ab = a + ab * clamp(dot(point - a, ab) / max(dot(ab, ab), 0.000001), 0.0, 1.0);
				vec3 on_bc = b + bc * clamp(dot(point - b, bc) / max(dot(bc, bc), 0.000001), 0.0, 1.0);
				return min(distance(point, on_ab), distance(point, on_bc));
			}

			vec3 vegetation_polyline_turn(VegetationPushers pushers, int pusher_count, vec3 origin, float plant_bound, float plant_height, vec3 pivot, vec3 mid, vec3 tip) {
				vec3 chain = tip - pivot;
				vec3 chain_direction = dot(chain, chain) > 0.0001 ? normalize(chain) : vec3(0.0, 1.0, 0.0);
				vec3 turn = vec3(0.0);

				for (int i = 0; i < pusher_count; i++) {
					int base = 1 + i * ]] .. vegetation_pushers.STRIDE .. [[;
					float rounding = pushers.p[base].w;
					vec3 half_size = pushers.p[base + 1].xyz;
					float reach = (0.4 + 0.5 * min(max(half_size.x, half_size.z), 1.5)) * pushers.p[0].z;
				
					for (int j = 0; j < ]] .. vegetation_pushers.POSES .. [[; j++) {
						vec4 pose = pushers.p[base + 2 + j];
						vec4 shape = vec4(pose.xyz, rounding);
				
						if (pose.w == 0.0 || distance(origin, shape.xyz) > plant_bound + reach + length(half_size)) continue;

						// a dynamic plant's own collision body would otherwise push it: skip a body of about the plant's height that holds the plant's root
						vec3 root_offset = origin - shape.xyz;
						if (abs(root_offset.x) < half_size.x && abs(root_offset.z) < half_size.z && root_offset.y > -half_size.y - 0.3 && root_offset.y < half_size.y && half_size.y * 2.0 > plant_height * 0.3 && half_size.y * 2.0 < plant_height * 1.2) continue;
				
						vec2 away = origin.xz - shape.xz;
						float away_length = length(away);
						vec3 shared_direction = away_length > 0.001 ? vec3(away.x, 0.0, away.y) / away_length : vec3(1.0, 0.0, 0.0);
						vec3 shared_sideways = shared_direction - chain_direction * dot(shared_direction, chain_direction);
				
						if (dot(shared_sideways, shared_sideways) < 0.09) {
							shared_direction = abs(chain_direction.y) < 0.9 ? normalize(cross(chain_direction, vec3(0.0, 1.0, 0.0))) : vec3(1.0, 0.0, 0.0);
						}
				
						bool over_root = origin.y < shape.y - half_size.y - 0.05;
						vec3 best = vec3(0.0);
				
						for (int k = 0; k < 4; k++) {
							vec3 sample_point = k == 0 ? mix(pivot, mid, 0.5) : (k == 1 ? mid : (k == 2 ? mix(mid, tip, 0.5) : tip));
							vec3 sample_arm = sample_point - pivot;
							vec4 contact = vegetation_push(sample_point, shape, half_size, over_root, shared_direction, reach);
							vec3 candidate = cross(sample_arm, contact.xyz * contact.w) / max(dot(sample_arm, sample_arm), 0.0625);
				
							if (dot(candidate, candidate) > dot(best, best)) best = candidate;
						}
				
						turn += best * pose.w * pushers.p[0].y;
					}
				}

				return turn;
			}

			bool has_vertex_animation() {
				#ifdef VERTEX_ANIMATION_STATIC
				return false;
				#else
				return vertex_animation.MainBending > 0.0 ||
					(vertex_animation.DetailBending != 0 && vertex_animation.BendSpeed > 0.0) ||
					(vertex_animation.PushBending > 0.0 && get_vegetation_pushers().p[0].x > 0.0);
				#endif
			}

			vec4 vegetation_smooth_triangle_wave(vec4 x) {
				vec4 t = abs(fract(x + 0.5) * 2.0 - 1.0);
				return t * t * (3.0 - 2.0 * t);
			}

			vec3 get_instance_conform_offset(vec3 world_pos) {
				mat4 world = ]] .. world_matrix_expr .. [[;
				uint bits = floatBitsToUint(world[3][3]);

				if ((bits & 0x80000000u) == 0u) return vec3(0.0);

				float radius = 0.02 * pow(1.12, float((bits >> 24u) & 63u));
				mat3 world_matrix3 = mat3(world);
				vec3 local = inverse(world_matrix3) * (world_pos - world[3].xyz);
				vec2 edge = clamp(local.xz / radius, -1.0, 1.0);
				vec4 heights = vec4(float(int(bits & 31u) - 16), float(int((bits >> 5u) & 31u) - 16), float(int((bits >> 10u) & 31u) - 16), float(int((bits >> 15u) & 31u) - 16)) / 15.0;
				float lift = (heights.x - heights.y) * 0.5 * edge.x + (heights.x + heights.y) * 0.5 * edge.x * edge.x + (heights.z - heights.w) * 0.5 * edge.y + (heights.z + heights.w) * 0.5 * edge.y * edge.y;
				float follow = 1.0 - smoothstep(0.0, radius, max(local.y, 0.0));
				return world_matrix3 * vec3(0.0, lift * radius * follow, 0.0);
			}

			vec3 get_vertex_animation_offset_at_time(vec3 world_pos, vec3 world_normal, vec4 vertex_color, VegetationChain vertex_chain, float anim_time, float detail_time) {
				vec3 conform = get_instance_conform_offset(world_pos);

				if (!has_vertex_animation()) return conform;

				mat4 world = ]] .. world_matrix_expr .. [[;
				mat3 world_matrix3 = mat3(world);
				mat3 inv_world_matrix3 = inverse(world_matrix3);
				vec3 origin = world[3].xyz;
				vec3 start_pos = inv_world_matrix3 * (world_pos - origin);
				vec3 pos = start_pos;
				float speed = vertex_animation.BendSpeed;
				float instance_phase = fract(sin(dot(origin, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
				vec2 bend_dir = normalize((inv_world_matrix3 * vertex_animation.BendDirection).xz);
				if (vertex_animation.PushBending > 0.0) {
					VegetationPushers pushers = get_vegetation_pushers();
					int pusher_count = int(pushers.p[0].x);
					float plant_bound = (vertex_animation.PushRadius + vertex_animation.BendHeight) * length(world_matrix3[0]);
					float plant_height = vertex_animation.BendHeight * length(world_matrix3[0]);
					vec4 push_color = clamp(vertex_color, 0.0, 1.0);
					float height_fraction = clamp(pos.y / max(vertex_animation.BendHeight, 0.01), 0.0, 1.0);
					float flex = vertex_animation.DetailBending == 0 ? 0.1 : clamp(0.2 + 0.8 * (1.0 - push_color.b) + 0.25 * push_color.r, 0.0, 1.0);
					if (vertex_animation.DetailBending == 2) flex = max(flex, height_fraction * height_fraction);
					bool has_chain = vertex_chain.pivot.w > 0.5;
					float horizontal_radius = length(world_pos.xz - origin.xz);
					vec3 pivot = has_chain ? origin + world_matrix3 * vertex_chain.pivot.xyz : vec3(origin.x, mix(origin.y, world_pos.y, smoothstep(0.1, 0.6, horizontal_radius)), origin.z);
					vec3 chain_mid = has_chain ? origin + world_matrix3 * vertex_chain.mid : mix(pivot, world_pos, 0.5);
					vec3 chain_tip = has_chain ? origin + world_matrix3 * vertex_chain.tip : world_pos;
					vec3 target = world_pos;

					if (has_chain && vertex_animation.HasRoot > 0.5) {
						vec3 root_pivot = origin + world_matrix3 * vertex_animation.RootPivot;
						vec3 root_mid = origin + world_matrix3 * vertex_animation.RootMid;
						vec3 root_tip = origin + world_matrix3 * vertex_animation.RootTip;
						float root_length = distance(root_pivot, root_tip);
						float attached = distance(pivot, root_pivot) > 0.05 ? 1.0 - smoothstep(0.1 * root_length, 0.25 * root_length, vegetation_polyline_distance(pivot, root_pivot, root_mid, root_tip)) : 0.0;

						if (attached > 0.0) {
							vec3 root_rotation = vegetation_polyline_turn(pushers, pusher_count, origin, plant_bound, plant_height, root_pivot, root_mid, root_tip) * (vertex_animation.RootFlex * vertex_animation.PushBending * attached);
							target = vegetation_rotate(target, root_pivot, root_rotation);
							pivot = vegetation_rotate(pivot, root_pivot, root_rotation);
							chain_mid = vegetation_rotate(chain_mid, root_pivot, root_rotation);
							chain_tip = vegetation_rotate(chain_tip, root_pivot, root_rotation);
						}
					}

					vec3 rotation = vegetation_polyline_turn(pushers, pusher_count, origin, plant_bound, plant_height, pivot, chain_mid, chain_tip) * (flex * vertex_animation.PushBending);
					pos += inv_world_matrix3 * (vegetation_rotate(target, pivot, rotation) - world_pos);
				}

				if (vertex_animation.DetailBending != 0) {
					vec4 color = clamp(vertex_color, 0.0, 1.0);
					float edge_atten = color.r;
					float branch_atten = 1.0 - color.b;
					float detail_speed = speed;
					if (vertex_animation.DetailBending == 2) detail_speed *= pos.y;

					float branch_phase = color.g + instance_phase * 7.0;
					float vertex_phase = dot(pos, vec3(vertex_animation.DetailPhase + branch_phase));
					vec2 waves_in = detail_time + vec2(vertex_phase, branch_phase);
					vec4 waves = vegetation_smooth_triangle_wave(waves_in.xxyy * vec4(1.975, 0.793, 0.375, 0.193)) - 0.5;
					float strength = detail_speed * vertex_animation.DetailFrequency;
					float amplitude = strength < 0.5 ? strength * 2.0 : sqrt(strength * 2.0);
					vec2 waves_sum = (waves.xz + waves.yw) * amplitude;
					vec3 object_normal = normalize(transpose(world_matrix3) * world_normal);
					vec2 facing = object_normal.xz;
					pos.xz += facing * (waves_sum.x + dot(facing, bend_dir) * (amplitude + waves_sum.y) * 0.5) * edge_atten * vertex_animation.DetailLeafAmplitude;
					pos.y += waves_sum.y * branch_atten * vertex_animation.DetailBranchAmplitude;
					pos.xz += bend_dir * ((amplitude + waves_sum.y) * 0.5 * branch_atten * vertex_animation.DetailBranchAmplitude);
				}

				if (vertex_animation.MainBending > 0.0) {
					vec2 bend = bend_dir * vertex_animation.MainBending;

					float gust_time = anim_time - dot(origin.xz, vertex_animation.BendDirection.xz) / 6.0 + instance_phase * 3.0;
					float gust = 0.5 * sin(gust_time * 0.71) + 0.3 * sin(gust_time * 1.63 + 1.7) + 0.2 * sin(gust_time * 2.87 + 4.1);
					float sway_time = anim_time * 6.2832 * 1.2 / sqrt(max(vertex_animation.BendHeight, 0.5)) + instance_phase * 6.2832;
					float strength = 0.6 + 0.4 * gust;
					float along = 0.25 * gust + 0.15 * strength * sin(sway_time);
					float across = 0.12 * strength * sin(sway_time * 1.13 + 1.3);
					bend += (bend_dir * along + vec2(-bend_dir.y, bend_dir.x) * across) * vertex_animation.MainBending;
					bend *= 0.015;

					float bend_factor = pos.y / vertex_animation.BendHeight + 1.0;
					bend_factor *= bend_factor;
					bend_factor = bend_factor * bend_factor - bend_factor;
					float len = length(pos);

					if (len > 0.0) {
						vec3 bent = pos;
						bent.xz += bend * bend_factor;
						pos = normalize(bent) * len;
					}
				}

				return conform + world_matrix3 * (pos - start_pos);
			}

			float get_vertex_animation_still() {
				]] .. still .. [[
			}

			vec3 get_vertex_animation_offset_still(vec3 world_pos, vec3 world_normal, vec4 vertex_color, VegetationChain vertex_chain, float anim_time, float detail_time) {
				if (!has_vertex_animation()) return get_instance_conform_offset(world_pos);

				float still = get_vertex_animation_still();

				if (still <= 0.0) return get_vertex_animation_offset_at_time(world_pos, world_normal, vertex_color, vertex_chain, anim_time, detail_time);

				vec3 at_rest = get_vertex_animation_offset_at_time(world_pos, world_normal, vertex_color, vertex_chain, 0.0, 0.0);

				if (still >= 1.0) return at_rest;

				return mix(get_vertex_animation_offset_at_time(world_pos, world_normal, vertex_color, vertex_chain, anim_time, detail_time), at_rest, still);
			}

			vec3 get_vertex_animation_offset(vec3 world_pos, vec3 world_normal, vec4 vertex_color, VegetationChain vertex_chain) {
				#ifdef VERTEX_ANIMATION_OFFSET
				return VERTEX_ANIMATION_OFFSET;
				#else
				vec3 offset = get_vertex_animation_offset_still(world_pos, world_normal, vertex_color, vertex_chain, vertex_animation.Time, vertex_animation.DetailTime);
				#ifdef VERTEX_ANIMATION_RECORD
				VERTEX_ANIMATION_RECORD = offset;
				#endif
				return offset;
				#endif
			}

			vec3 get_previous_vertex_animation_offset(vec3 world_pos, vec3 world_normal, vec4 vertex_color, VegetationChain vertex_chain) {
				#ifdef VERTEX_ANIMATION_PREVIOUS_OFFSET
				return VERTEX_ANIMATION_PREVIOUS_OFFSET;
				#else
				vec3 offset = get_vertex_animation_offset_still(world_pos, world_normal, vertex_color, vertex_chain, vertex_animation.PrevTime, vertex_animation.PrevDetailTime);
				#ifdef VERTEX_ANIMATION_PREVIOUS_RECORD
				VERTEX_ANIMATION_PREVIOUS_RECORD = offset;
				#endif
				return offset;
				#endif
			}

			layout(buffer_reference, scalar) readonly buffer DeformVertexData { float v[]; };

			]] .. vertex_layout.BuildGlslAccessors("deform_vertex", "DeformVertexData") .. [[

			struct Deformation {
				vec3 position;
				vec3 previous_position;
				vec3 offset;
			};

			Deformation deform(vec3 local_position, vec3 local_normal, uint vertex_index, mat4 previous_world, bool with_previous) {
				mat4 world = ]] .. world_matrix_expr .. [[;
				Deformation deformed;
				deformed.position = (world * vec4(local_position, 1.0)).xyz;
				deformed.previous_position = with_previous ? (previous_world * vec4(get_previous_local_position(local_position, vertex_index), 1.0)).xyz : deformed.position;
				vec3 world_normal = vec3(0.0, 1.0, 0.0);
				vec4 color = vec4(0.0);
				VegetationChain chain = VegetationChain(vec4(0.0), vec3(0.0), vec3(0.0));
				uvec2 extras_address = uvec2(uint(vertex_animation.ExtrasLow), uint(vertex_animation.ExtrasHigh));

				if (has_vertex_animation() && extras_address != uvec2(0u)) {
					DeformVertexData extras = DeformVertexData(packUint2x32(extras_address));
					world_normal = normalize(transpose(inverse(mat3(world))) * local_normal);
					color = deform_vertex_color(extras, vertex_index);
					chain = VegetationChain(deform_vertex_pivot(extras, vertex_index), deform_vertex_chain_mid(extras, vertex_index), deform_vertex_chain_tip(extras, vertex_index));
				}

				deformed.offset = get_vertex_animation_offset(deformed.position, world_normal, color, chain);
				deformed.position += deformed.offset;

				if (with_previous) {
					deformed.previous_position += get_previous_vertex_animation_offset(deformed.previous_position, world_normal, color, chain);
				}

				return deformed;
			}
	]]
end


return deformation
