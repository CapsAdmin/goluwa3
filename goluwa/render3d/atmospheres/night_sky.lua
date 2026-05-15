return [[
	float night_hash1(float n) {
		return fract(sin(n) * 43758.5453);
	}

	float night_hash1v2(vec2 p) {
		return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
	}

	vec2 night_hash2v2(vec2 p) {
		p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
		return fract(sin(p) * 43758.5453);
	}

	float night_hash1v3(vec3 p) {
		return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
	}

	float night_noise3(vec3 x) {
		vec3 i = floor(x);
		vec3 f = fract(x);
		f = f * f * (3.0 - 2.0 * f);

		float n000 = night_hash1v3(i + vec3(0.0, 0.0, 0.0));
		float n100 = night_hash1v3(i + vec3(1.0, 0.0, 0.0));
		float n010 = night_hash1v3(i + vec3(0.0, 1.0, 0.0));
		float n110 = night_hash1v3(i + vec3(1.0, 1.0, 0.0));
		float n001 = night_hash1v3(i + vec3(0.0, 0.0, 1.0));
		float n101 = night_hash1v3(i + vec3(1.0, 0.0, 1.0));
		float n011 = night_hash1v3(i + vec3(0.0, 1.0, 1.0));
		float n111 = night_hash1v3(i + vec3(1.0, 1.0, 1.0));

		return mix(
			mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
			mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
			f.z
		);
	}

	float night_fbm(vec3 p) {
		float value = 0.0;
		float amplitude = 0.5;

		for (int i = 0; i < 5; i++) {
			value += amplitude * night_noise3(p);
			p *= 2.07;
			amplitude *= 0.5;
		}

		return value;
	}

	vec3 night_rotate_y(vec3 dir, float angle) {
		float c = cos(angle);
		float s = sin(angle);
		return vec3(
			dir.x * c - dir.z * s,
			dir.y,
			dir.x * s + dir.z * c
		);
	}

	vec3 night_rotate_x(vec3 dir, float angle) {
		float c = cos(angle);
		float s = sin(angle);
		return vec3(
			dir.x,
			dir.y * c - dir.z * s,
			dir.y * s + dir.z * c
		);
	}

	vec3 night_rotate_z(vec3 dir, float angle) {
		float c = cos(angle);
		float s = sin(angle);
		return vec3(
			dir.x * c - dir.y * s,
			dir.x * s + dir.y * c,
			dir.z
		);
	}

	vec3 night_blackbody(float temperature) {
		float t = clamp(temperature, 1000.0, 25000.0);
		float t2 = t * t;
		float r;
		float g;
		float b;

		if (t <= 6600.0) {
			r = 1.0;
		} else {
			r = clamp(1.292 * pow(t / 6600.0 - 0.5, -0.1332), 0.0, 1.0);
		}

		if (t <= 6600.0) {
			g = clamp(-0.4494 + 0.0101 * log(t) * log(t) - 0.000195 * t + 0.00000001 * t2, 0.0, 1.0);
		} else {
			g = clamp(1.130 * pow(t / 6600.0 - 0.5, -0.0755), 0.0, 1.0);
		}

		if (t >= 6600.0) {
			b = 1.0;
		} else if (t <= 1900.0) {
			b = 0.0;
		} else {
			b = clamp(-0.744 + 0.0517 * log(t - 1890.0), 0.0, 1.0);
		}

		vec3 color = pow(clamp(vec3(r, g, b), 0.0, 1.0), vec3(2.2));
		float luminance = dot(color, vec3(0.299, 0.587, 0.114));
		float warm = 1.0 - smoothstep(4200.0, 6500.0, t);
		float saturation = mix(1.0, 0.45, warm);
		return mix(vec3(luminance), color, saturation);
	}

	float night_star_temperature(float seed) {
		float r = night_hash1(seed * 13.1 + 0.7);
		if (r < 0.22) return mix(3800.0, 5000.0, night_hash1(seed * 3.3));
		if (r < 0.56) return mix(5000.0, 6200.0, night_hash1(seed * 7.1));
		if (r < 0.80) return mix(6200.0, 7800.0, night_hash1(seed * 2.9));
		if (r < 0.93) return mix(7800.0, 12000.0, night_hash1(seed * 5.5));
		if (r < 0.985) return mix(12000.0, 22000.0, night_hash1(seed * 1.7));
		return mix(22000.0, 35000.0, night_hash1(seed * 9.3));
	}

	float night_galactic_density(vec3 dir) {
		float cos_t = 0.866;
		float sin_t = 0.5;
		float gy = dir.y * cos_t - dir.z * sin_t;
		float latitude = asin(clamp(gy, -1.0, 1.0));
		float plane = exp(-latitude * latitude / 0.055);
		vec3 galactic_center = vec3(0.0, sin_t, cos_t);
		float center_glow = exp(-dot(dir - galactic_center, dir - galactic_center) * 4.0) * 2.0;
		return clamp(plane * (1.0 + center_glow), 0.0, 1.0);
	}

	vec3 night_milky_way(vec3 dir) {
		float density = night_galactic_density(dir);
		float dust_a = night_fbm(dir * 3.5 + vec3(2.1, 0.5, 1.3));
		float dust_b = night_fbm(dir * 8.0 + vec3(0.2, 3.1, 0.8));
		vec3 color = mix(vec3(0.7, 0.55, 0.35), vec3(0.45, 0.55, 0.85), dust_a);
		color += vec3(0.25, 0.18, 0.35) * dust_b * 0.4;
		return color * density * density * 0.07;
	}

	vec3 night_airglow(vec3 dir) {
		float h = clamp(1.0 - dir.y * 5.0, 0.0, 1.0);
		return vec3(0.05, 0.18, 0.03) * h * h * 0.035;
	}

	vec3 night_rotate_celestial(vec3 dir, vec3 sun_dir) {
		float sun_azimuth = atan(sun_dir.z, sun_dir.x);
		float sun_elevation = asin(clamp(sun_dir.y, -1.0, 1.0));
		float pitch = 0.35 - sun_elevation * 0.65;
		vec3 rotated = night_rotate_y(dir, -sun_azimuth);
		rotated = night_rotate_x(rotated, pitch);
		rotated = night_rotate_z(rotated, 0.41);
		return normalize(rotated);
	}

	vec3 night_star_field(vec3 rotated_dir) {
		vec3 color = vec3(0.0);
		float layer_scale[3];
		layer_scale[0] = 80.0;
		layer_scale[1] = 300.0;
		layer_scale[2] = 1100.0;

		float layer_brightness[3];
		layer_brightness[0] = 2.5;
		layer_brightness[1] = 0.6;
		layer_brightness[2] = 0.15;

		for (int layer = 0; layer < 3; layer++) {
			float scale = layer_scale[layer];
			float brightness = layer_brightness[layer];
			vec3 ad = abs(rotated_dir);
			int face;
			vec2 uv;

			if (ad.x >= ad.y && ad.x >= ad.z) {
				face = rotated_dir.x > 0.0 ? 0 : 1;
				uv = (rotated_dir.x > 0.0 ? vec2(-rotated_dir.z, rotated_dir.y) : vec2(rotated_dir.z, rotated_dir.y)) / ad.x;
			} else if (ad.y >= ad.z) {
				face = rotated_dir.y > 0.0 ? 2 : 3;
				uv = (rotated_dir.y > 0.0 ? vec2(rotated_dir.x, -rotated_dir.z) : vec2(rotated_dir.x, rotated_dir.z)) / ad.y;
			} else {
				face = rotated_dir.z > 0.0 ? 4 : 5;
				uv = (rotated_dir.z > 0.0 ? vec2(rotated_dir.x, rotated_dir.y) : vec2(-rotated_dir.x, rotated_dir.y)) / ad.z;
			}

			vec2 scaled = uv * scale;
			vec2 cell = floor(scaled);
			vec2 frac_uv = fract(scaled);

			for (int dy = -1; dy <= 1; dy++) {
				for (int dx = -1; dx <= 1; dx++) {
					vec2 nc = cell + vec2(float(dx), float(dy));
					vec2 jitter = night_hash2v2(nc + float(face) * 37.3 + float(layer) * 113.7);
					float seed = night_hash1v2(nc + float(face) * 17.1 + float(layer) * 91.3);

					vec2 star_uv = (nc + jitter) / scale;
					vec3 star_dir;
					if (face == 0) star_dir = normalize(vec3(1.0, star_uv.y, -star_uv.x));
					else if (face == 1) star_dir = normalize(vec3(-1.0, star_uv.y, star_uv.x));
					else if (face == 2) star_dir = normalize(vec3(star_uv.x, 1.0, -star_uv.y));
					else if (face == 3) star_dir = normalize(vec3(star_uv.x, -1.0, star_uv.y));
					else if (face == 4) star_dir = normalize(vec3(star_uv.x, star_uv.y, 1.0));
					else star_dir = normalize(vec3(-star_uv.x, star_uv.y, -1.0));

					float galactic_density = night_galactic_density(star_dir);
					float probability = mix(0.04, 0.80, galactic_density);
					if (seed > probability) continue;

					float luminance = pow(night_hash1(seed * 7.3 + 1.1), 3.0) * brightness;
					if (luminance < 0.0002) continue;

					vec2 delta = frac_uv - jitter - vec2(float(dx), float(dy));
					vec2 delta_screen = delta * scale;
					float star_sigma_sq = mix(1.4, 4.0, min(luminance / brightness, 1.0));
					float final_sigma_sq = max(star_sigma_sq, 1.2 * 1.2);
					float d2 = dot(delta_screen, delta_screen);
					float disc = exp(-d2 / (2.0 * final_sigma_sq));
					disc *= star_sigma_sq / final_sigma_sq;
					if (disc < 0.00005) continue;

					vec3 star_color = night_blackbody(night_star_temperature(seed * 4.1 + float(layer) * 0.7));

					float altitude = clamp(rotated_dir.y, 0.0, 1.0);
					float twinkle = mix(1.15, 0.98, altitude);
					color += star_color * disc * luminance * twinkle;
				}
			}
		}

		return color;
	}

	vec3 get_stars(vec3 dir, vec3 sunDir) {
		dir = normalize(dir);
		vec3 celestial_dir = night_rotate_celestial(dir, normalize(sunDir));
		vec3 hdr = night_star_field(celestial_dir);

		float night_visibility = smoothstep(0.04, -0.18, sunDir.y);
		return hdr * night_visibility;
	}
]]
