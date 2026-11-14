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

function fog_volumes.GetGLSL()
	return medium_common.GetGLSL() .. [[
		float fog_volume_density(optical_volume volume, vec3 p) {
			vec3 local = (volume.to_local * vec4(p, 1.0)).xyz;
			vec3 inside = volume.shape - abs(local);
			float edge_distance = min(inside.x, min(inside.y, inside.z));

			if (edge_distance <= 0.0) return 0.0;

			float edge = volume.softness > 0.0 ? smoothstep(0.0, volume.softness, edge_distance) : 1.0;
			return edge * (volume.falloff > 0.0 ? exp(-(local.y + volume.shape.y) / volume.falloff) : 1.0);
		}

		float fog_volume_segment_density(optical_volume volume, vec3 origin, vec3 dir, float t0, float t1) {
			float a;
			float b;

			if (!medium_box_intersect(volume.to_local, -volume.shape, volume.shape, origin, dir, a, b)) return 0.0;

			a = max(a, t0);
			b = min(b, t1);

			if (b <= a) return 0.0;

			return fog_volume_density(volume, origin + dir * (0.5 * (a + b))) * (b - a) / max(t1 - t0, 1e-6);
		}

		vec3 fog_volume_segment_extinction(vec3 origin, vec3 dir, float t0, float t1) {
			vec3 extinction = vec3(0.0);

			for (int i = 0; i < optical_ranges.w; i++) {
				optical_volume volume = optical_volumes[optical_ranges.z + i];
				extinction += volume.extinction * fog_volume_segment_density(volume, origin, dir, t0, t1);
			}

			return extinction;
		}
	]]
end

return fog_volumes
