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
	return [[
		float fog_volume_density(optical_volume volume, vec3 p) {
			vec3 local = (volume.to_local * vec4(p, 1.0)).xyz;
			vec3 inside = volume.shape - abs(local);
			float edge_distance = min(inside.x, min(inside.y, inside.z));

			if (edge_distance <= 0.0) return 0.0;

			float edge = volume.softness > 0.0 ? smoothstep(0.0, volume.softness, edge_distance) : 1.0;
			return edge * (volume.falloff > 0.0 ? exp(-(local.y + volume.shape.y) / volume.falloff) : 1.0);
		}

		vec3 fog_volume_extinction(vec3 p) {
			vec3 extinction = vec3(0.0);

			for (int i = 0; i < optical_ranges.w; i++) {
				optical_volume volume = optical_volumes[optical_ranges.z + i];
				extinction += volume.extinction * fog_volume_density(volume, p);
			}

			return extinction;
		}
	]]
end

return fog_volumes
