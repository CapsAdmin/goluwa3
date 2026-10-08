local screen_refraction = library()
screen_refraction.WAVELENGTH_C = 0.6563
screen_refraction.WAVELENGTH_D = 0.5876
screen_refraction.WAVELENGTH_F = 0.4861
screen_refraction.WAVELENGTH_RGB = {0.61, 0.55, 0.465}

function screen_refraction.GetGLSL(block_name)
	return [[
		// the index of refraction at the red, green and blue wavelengths from the one at the
		// d line and the Abbe number V = (n_d - 1) / (n_F - n_C), by Cauchy's n = A + B / l^2.
		// an Abbe number of 0 is a medium without dispersion
		vec3 screen_refraction_dispersed_ior(float ior, float abbe) {
			if (abbe <= 0.0) return vec3(ior);
			float b = (ior - 1.0) / abbe / (1.0 / (]] .. screen_refraction.WAVELENGTH_C .. [[ * ]] .. screen_refraction.WAVELENGTH_C .. [[) - 1.0 / (]] .. screen_refraction.WAVELENGTH_F .. [[ * ]] .. screen_refraction.WAVELENGTH_F .. [[));
			float a = ior - b / (]] .. screen_refraction.WAVELENGTH_D .. [[ * ]] .. screen_refraction.WAVELENGTH_D .. [[);
			const vec3 wavelengths = vec3(]] .. table.concat(screen_refraction.WAVELENGTH_RGB, ", ") .. [[);
			return a + b / (wavelengths * wavelengths);
		}


		// xy = uv, z = clip depth. uv is negative behind the camera
		vec3 screen_refraction_project(vec3 world_pos) {
			vec4 clip = ]] .. block_name .. [[.projection * ]] .. block_name .. [[.view * vec4(world_pos, 1.0);
			if (clip.w <= 1e-5) return vec3(-1.0);
			return vec3(clip.xy / clip.w * 0.5 + 0.5, clip.z / clip.w);
		}

		bool screen_refraction_on_screen(vec2 uv) {
			return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
		}

		// false when target is off screen, or when the scene there is in front of
		// the surface
		bool screen_refraction_uv(vec3 surface_pos, vec3 target_pos, out vec2 uv) {
			vec3 target = screen_refraction_project(target_pos);
			uv = target.xy;

			if (!screen_refraction_on_screen(uv)) return false;

			return texture(TEXTURE(]] .. block_name .. [[.depth_tex), uv).r >= screen_refraction_project(surface_pos).z;
		}

		// is the point at p (projected) behind the opaque scene, and is what it
		// is behind itself behind the surface
		bool screen_refraction_behind(vec3 p, float surface_depth) {
			float scene_depth = texture(TEXTURE(]] .. block_name .. [[.depth_tex), p.xy).r;
			return scene_depth >= surface_depth && p.z >= scene_depth;
		}

		// marches from origin along dir, in steps that grow towards
		// max_distance. hit_distance is how far along the ray the scene was met.
		// a ray that meets nothing goes on to the sky where the depth is empty;
		// otherwise it slipped past something thin between steps and takes what
		// is where it stopped. false when the ray leaves the screen first.
		// jitter (0..1) shifts the steps; varied per pixel and frame, taa turns
		// the steps' stairs into a smooth result
		bool screen_refraction_trace(vec3 surface_pos, vec3 origin, vec3 dir, float max_distance, float jitter, out vec2 uv, out float hit_distance) {
			float surface_depth = screen_refraction_project(surface_pos).z;
			float previous = 0.0;

			for (int i = 1; i <= 16; i++) {
				float step = (float(i) - jitter) / 16.0;
				float t = max_distance * step * step;
				vec3 p = screen_refraction_project(origin + dir * t);

				if (!screen_refraction_on_screen(p.xy)) return false;

				if (screen_refraction_behind(p, surface_depth)) {
					float near = previous;
					float far = t;

					for (int j = 0; j < 5; j++) {
						float middle = (near + far) * 0.5;

						if (screen_refraction_behind(screen_refraction_project(origin + dir * middle), surface_depth)) {
							far = middle;
						} else {
							near = middle;
						}
					}

					uv = screen_refraction_project(origin + dir * far).xy;
					hit_distance = far;
					return true;
				}

				previous = t;
			}

			hit_distance = 1000.0;
			uv = screen_refraction_project(origin + dir * hit_distance).xy;

			if (screen_refraction_on_screen(uv) && texture(TEXTURE(]] .. block_name .. [[.depth_tex), uv).r >= 1.0) return true;

			hit_distance = max_distance;
			uv = screen_refraction_project(origin + dir * hit_distance).xy;
			return true;
		}
	]]
end

return screen_refraction
