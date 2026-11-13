local media = import("goluwa/render3d/media.lua")
local medium_common = import("goluwa/render3d/medium_common.lua")
local fog_volumes = {}
fog_volumes.MAX_VOLUMES = 16
fog_volumes.volumes = {}

function fog_volumes.AddVolume(volume)
	list.insert(fog_volumes.volumes, volume)
end

function fog_volumes.RemoveVolume(volume)
	for i, other in ipairs(fog_volumes.volumes) do
		if other == volume then
			list.remove(fog_volumes.volumes, i)

			break
		end
	end
end

function fog_volumes.GetVolumes()
	return fog_volumes.volumes
end

function fog_volumes.GetBlockLayout()
	return {
		{"fog_volume_to_local", "mat4", fog_volumes.MAX_VOLUMES},
		{"fog_volume_shape", "vec4", fog_volumes.MAX_VOLUMES},
		{"fog_volume_extinction", "vec4", fog_volumes.MAX_VOLUMES},
		{"fog_volume_scattering", "vec4", fog_volumes.MAX_VOLUMES},
		{"fog_volume_count", "int"},
	}
end

function fog_volumes.WriteBlock(block)
	local count = 0

	for _, volume in ipairs(fog_volumes.volumes) do
		if count >= fog_volumes.MAX_VOLUMES then break end

		local size = volume:GetSize()
		local medium = media.presets[volume:GetMedium()]
		local density = volume:GetDensity()
		volume.Owner.transform:GetWorldMatrixInverse():CopyToFloatPointer(block.fog_volume_to_local[count])
		block.fog_volume_shape[count][0] = size.x / 2
		block.fog_volume_shape[count][1] = size.y / 2
		block.fog_volume_shape[count][2] = size.z / 2
		block.fog_volume_shape[count][3] = volume:GetEdgeSoftness()
		block.fog_volume_extinction[count][0] = (medium.Absorption.x + medium.Scattering.x) * density
		block.fog_volume_extinction[count][1] = (medium.Absorption.y + medium.Scattering.y) * density
		block.fog_volume_extinction[count][2] = (medium.Absorption.z + medium.Scattering.z) * density
		block.fog_volume_extinction[count][3] = volume:GetHeightFalloff()
		block.fog_volume_scattering[count][0] = medium.Scattering.x * density
		block.fog_volume_scattering[count][1] = medium.Scattering.y * density
		block.fog_volume_scattering[count][2] = medium.Scattering.z * density
		block.fog_volume_scattering[count][3] = medium.PhaseG
		count = count + 1
	end

	block.fog_volume_count = count
end

function fog_volumes.GetGLSL(block_name)
	return medium_common.GetGLSL() .. [[

		float fog_volume_density(int i, vec3 p) {
			vec4 shape = ]] .. block_name .. [[.fog_volume_shape[i];
			vec3 local = (]] .. block_name .. [[.fog_volume_to_local[i] * vec4(p, 1.0)).xyz;
			vec3 inside = shape.xyz - abs(local);

			if (min(inside.x, min(inside.y, inside.z)) <= 0.0) return 0.0;

			float edge = shape.w > 0.0 ? smoothstep(0.0, shape.w, min(inside.x, min(inside.y, inside.z))) : 1.0;
			float falloff = ]] .. block_name .. [[.fog_volume_extinction[i].w;
			return edge * (falloff > 0.0 ? exp(-(local.y + shape.y) / falloff) : 1.0);
		}

		vec3 fog_volume_extinction(vec3 p) {
			vec3 extinction = vec3(0.0);

			for (int i = 0; i < ]] .. block_name .. [[.fog_volume_count; i++) {
				extinction += ]] .. block_name .. [[.fog_volume_extinction[i].rgb * fog_volume_density(i, p);
			}

			return extinction;
		}

		vec3 fog_volume_tint(vec3 origin, vec3 dir, float distance) {
			vec3 transmitted = vec3(1.0);

			for (int i = 0; i < ]] .. block_name .. [[.fog_volume_count; i++) {
				vec4 shape = ]] .. block_name .. [[.fog_volume_shape[i];
				float t_entry;
				float t_exit;

				if (!medium_box_intersect(]] .. block_name .. [[.fog_volume_to_local[i], -shape.xyz, shape.xyz, origin, dir, t_entry, t_exit)) continue;

				float start = clamp(t_entry, 0.0, distance);
				float finish = min(t_exit, distance);

				if (finish <= start) continue;

				float mean_density = fog_volume_density(i, origin + dir * (0.5 * (start + finish)));
				transmitted *= optical_transmittance(]] .. block_name .. [[.fog_volume_extinction[i].rgb * mean_density, finish - start);
			}

			return transmitted;
		}
	]]
end

return fog_volumes
