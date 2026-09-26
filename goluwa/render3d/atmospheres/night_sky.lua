-- what is behind the atmosphere: stars, the milky way, the night glow and the moon, in cd/m2 like the sky
-- the star sphere is turned by ATMOSPHERE_CELESTIAL_X/Y/Z, so it follows render3d/weather.lua's time and place
return [[
	// a magnitude 0 star gives 2.08e-6 lux, and there are 10^(0.5 m) times more stars brighter than m
	const float STAR_MAX_MAGNITUDE = 7.5;
	const float STAR_FACE_CELLS = 64.0;
	// stars are gaussians this wide in radians, about a pixel at 1080p and a 70 degree fov
	const float STAR_SIGMA = 0.0007;
	// airglow and zodiacal light at the zenith of a dark site, ~21.8 mag/arcsec2
	const float NIGHT_GLOW_ZENITH_LUMINANCE = 1.5e-4;
	// the brightest parts of the milky way, ~20 mag/arcsec2
	const float MILKY_WAY_LUMINANCE = 1.0e-3;
	// equatorial (j2000) directions of the galactic north pole and center
	const vec3 GALACTIC_NORTH_POLE = vec3(-0.8677, -0.1981, 0.4560);
	const vec3 GALACTIC_CENTER = vec3(-0.0549, -0.8734, -0.4838);
	// allen's full moon at its mean distance, 0.263 lux, over the disc's 6.42e-5 sr
	const float MOON_FULL_LUMINANCE = 4098.0;
	// the full earth lighting the moon's dark side, relative to the sun lighting its bright side
	const float MOON_EARTHSHINE = 3e-4;

	uvec3 night_pcg3d(uvec3 v) {
		v = v * 1664525u + 1013904223u;
		v.x += v.y * v.z;
		v.y += v.z * v.x;
		v.z += v.x * v.y;
		v ^= v >> 16u;
		v.x += v.y * v.z;
		v.y += v.z * v.x;
		v.z += v.x * v.y;
		return v;
	}

	vec3 night_random3(uvec3 v) {
		return vec3(night_pcg3d(v)) * (1.0 / 4294967296.0);
	}

	float night_noise(vec3 p) {
		vec3 i = floor(p);
		vec3 f = fract(p);
		f = f * f * (3.0 - 2.0 * f);
		uvec3 c = uvec3(ivec3(i) + 32768);
		return mix(
			mix(
				mix(night_random3(c).x, night_random3(c + uvec3(1, 0, 0)).x, f.x),
				mix(night_random3(c + uvec3(0, 1, 0)).x, night_random3(c + uvec3(1, 1, 0)).x, f.x),
				f.y
			),
			mix(
				mix(night_random3(c + uvec3(0, 0, 1)).x, night_random3(c + uvec3(1, 0, 1)).x, f.x),
				mix(night_random3(c + uvec3(0, 1, 1)).x, night_random3(c + uvec3(1, 1, 1)).x, f.x),
				f.y
			),
			f.z
		);
	}

	float night_fbm(vec3 p) {
		float value = 0.0;
		float amplitude = 0.5;

		for (int i = 0; i < 5; i++) {
			value += amplitude * night_noise(p);
			p *= 2.03;
			amplitude *= 0.5;
		}

		return value / 0.96875;
	}

	// color of a random naked eye star with luminance 1: many orange giants, fewer blue-white stars
	vec3 night_star_color(float r) {
		float t = r < 0.3 ? mix(3500.0, 5000.0, r / 0.3) :
			r < 0.55 ? mix(5000.0, 6500.0, (r - 0.3) / 0.25) :
			r < 0.8 ? mix(6500.0, 10000.0, (r - 0.55) / 0.25) :
			mix(10000.0, 25000.0, (r - 0.8) / 0.2);
		// tanner helland's blackbody fit, in srgb
		t /= 100.0;
		vec3 c;
		c.r = t <= 66.0 ? 1.0 : clamp(1.29293618606 * pow(t - 60.0, -0.1332047592), 0.0, 1.0);
		c.g = t <= 66.0 ? clamp(0.39008157876 * log(t) - 0.63184144378, 0.0, 1.0) : clamp(1.12989086089 * pow(t - 60.0, -0.0755148492), 0.0, 1.0);
		c.b = t >= 66.0 ? 1.0 : (t <= 19.0 ? 0.0 : clamp(0.54320678911 * log(t - 10.0) - 1.19625408914, 0.0, 1.0));
		c = pow(c, vec3(2.2));
		// the eye barely sees color in stars
		c = mix(vec3(dot(c, vec3(0.2126, 0.7152, 0.0722))), c, 0.6);
		return c / dot(c, vec3(0.2126, 0.7152, 0.0722));
	}

	// one candidate star in each cell of a cube around the sky
	vec3 get_stars(vec3 eq) {
		vec3 a = abs(eq);
		uint face;
		vec2 uv;

		if (a.x >= a.y && a.x >= a.z) {
			face = eq.x > 0.0 ? 0u : 1u;
			uv = eq.yz / a.x;
		} else if (a.y >= a.z) {
			face = eq.y > 0.0 ? 2u : 3u;
			uv = eq.xz / a.y;
		} else {
			face = eq.z > 0.0 ? 4u : 5u;
			uv = eq.xy / a.z;
		}

		vec2 cell = min(floor((uv * 0.5 + 0.5) * STAR_FACE_CELLS), STAR_FACE_CELLS - 1.0);
		vec3 r = night_random3(uvec3(uvec2(cell), face));
		vec3 r2 = night_random3(uvec3(uvec2(cell) + 7919u, face + 17u));
		// kept off the cell's edges so its glow never crosses into the next cell
		vec2 star_uv = (cell + 0.15 + 0.7 * r.xy) / STAR_FACE_CELLS * 2.0 - 1.0;

		// cells near the cube's corners cover less sky, thinning them keeps the stars even
		if (r2.x > pow(1.0 + dot(star_uv, star_uv), -1.5)) return vec3(0.0);

		vec3 star = face < 2u ? vec3(face == 0u ? 1.0 : -1.0, star_uv) :
			face < 4u ? vec3(star_uv.x, face == 2u ? 1.0 : -1.0, star_uv.y) :
			vec3(star_uv, face == 4u ? 1.0 : -1.0);
		star = normalize(star);
		// the inverse of the magnitude counts, a uniform r.z gives the right share of bright stars
		float magnitude = STAR_MAX_MAGNITUDE + 2.0 * log(max(r.z, 1e-7)) * 0.4342945;

		// faint stars crowd toward the galactic plane
		if (magnitude > 4.0 && r2.y > mix(1.0, 0.45, smoothstep(0.0, 0.5, abs(dot(star, GALACTIC_NORTH_POLE))))) {
			return vec3(0.0);
		}

		vec3 d = eq - star;
		float glow = exp(-dot(d, d) / (2.0 * STAR_SIGMA * STAR_SIGMA)) / (2.0 * PI * STAR_SIGMA * STAR_SIGMA);
		return night_star_color(r2.z) * (2.08e-6 * pow(10.0, -0.4 * magnitude) * glow);
	}

	vec3 get_milky_way(vec3 eq) {
		float sin_latitude = dot(eq, GALACTIC_NORTH_POLE);
		float latitude = asin(clamp(sin_latitude, -1.0, 1.0));
		vec3 in_plane = eq - GALACTIC_NORTH_POLE * sin_latitude;
		// 1 toward the galactic center, 0 toward the anticenter
		float toward_center = dot(in_plane / max(length(in_plane), 1e-5), GALACTIC_CENTER) * 0.5 + 0.5;
		float width = mix(0.10, 0.20, toward_center);
		float band = exp(-latitude * latitude / (2.0 * width * width)) * mix(0.25, 1.0, toward_center * toward_center);
		vec3 to_center = eq - GALACTIC_CENTER;
		float bulge = exp(-dot(to_center, to_center) / 0.06) * 1.2;
		float clumps = night_fbm(eq * 9.0);
		// the dark dust lanes along the plane, the great rift toward the center
		float dust = smoothstep(0.45, 0.7, night_fbm(eq * 6.0 + 3.1)) * exp(-latitude * latitude / (2.0 * 0.05 * 0.05)) * mix(0.3, 1.0, toward_center);
		vec3 color = mix(vec3(0.85, 0.92, 1.08), vec3(1.08, 0.97, 0.82), toward_center);
		return color * ((band + bulge) * mix(0.6, 1.4, clumps) * (1.0 - 0.8 * dust) * MILKY_WAY_LUMINANCE);
	}

	// the glowing layer ~100 km up is seen through a longer path toward the horizon (van rhijn)
	vec3 get_night_glow(vec3 dir) {
		float sin_zenith_sq = 1.0 - clamp(dir.y, 0.0, 1.0) * clamp(dir.y, 0.0, 1.0);
		return vec3(0.85, 1.0, 0.8) * (NIGHT_GLOW_ZENITH_LUMINANCE / sqrt(1.0 - 0.9693 * sin_zenith_sq));
	}

	// everything behind the atmosphere but the moon's disc
	vec3 get_night_sky(vec3 dir) {
		vec3 color = get_night_glow(dir);

		// the moon hides what is behind it
		if (length(dir - ATMOSPHERE_MOON_DIRECTION) < ATMOSPHERE_MOON_ANGULAR_RADIUS) return color;

		vec3 eq = normalize(vec3(dot(ATMOSPHERE_CELESTIAL_X, dir), dot(ATMOSPHERE_CELESTIAL_Y, dir), dot(ATMOSPHERE_CELESTIAL_Z, dir)));
		return color + get_stars(eq) + get_milky_way(eq);
	}

	// the dark seas on the face the moon always turns to us, 1 on average
	float get_moon_albedo(vec2 p) {
		float seas = smoothstep(0.5, 0.62, night_fbm(vec3(p * 2.2, 5.3)));
		return mix(1.15, 0.6, seas) * mix(0.9, 1.1, night_fbm(vec3(p * 9.0, 1.7)));
	}

	vec3 get_moon_disc(vec3 dir, vec3 cam_pos) {
		float radius = ATMOSPHERE_MOON_ANGULAR_RADIUS;

		if (radius <= 0.0) return vec3(0.0);

		vec3 moon = ATMOSPHERE_MOON_DIRECTION;

		// the chord, cos and acos are too coarse in float this close to 1
		if (length(dir - moon) > radius * 1.03) return vec3(0.0);

		vec3 ray_origin = get_atmosphere_camera_origin(cam_pos);

		if (ray_sphere_intersect(ray_origin, dir, PLANET_RADIUS).x > 0.0) return vec3(0.0);

		// the disc's up is the celestial north pole
		vec3 up = normalize(ATMOSPHERE_CELESTIAL_Z - moon * dot(ATMOSPHERE_CELESTIAL_Z, moon));
		vec3 right = cross(moon, up);
		vec2 p = vec2(dot(dir, right), dot(dir, up)) / sin(radius);
		float r = length(p);
		float edge = clamp((1.0 - r) / 0.03 + 0.5, 0.0, 1.0);
		vec3 normal = p.x * right + p.y * up - sqrt(max(1.0 - r * r, 0.0)) * moon;
		vec3 sun = ATMOSPHERE_SKY_SUN_DIRECTION;
		// lommel-seeliger, regolith looks like a flat disc at full moon rather than a lit ball
		float mu0 = dot(normal, sun);
		float mu = max(dot(normal, -moon), 1e-4);
		float lit = mu0 > 0.0 ? 2.0 * mu0 / (mu0 + mu) : 0.0;
		// the earth is full seen from a new moon
		float earthshine = MOON_EARTHSHINE * (0.5 - 0.5 * dot(sun, -moon));
		vec3 transmittance = sample_transmittance_lut(ray_origin, moon);
		return transmittance * (MOON_FULL_LUMINANCE * get_moon_albedo(p) * (lit + earthshine) * edge);
	}
]]
