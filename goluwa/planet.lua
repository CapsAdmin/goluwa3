local planet = {}
planet.RADIUS = 6371000
local R = planet.RADIUS

function planet.GetDrop(x, z)
	local d2 = x * x + z * z
	return d2 / (R + math.sqrt(math.max(R * R - d2, 0)))
end

function planet.GetDropRange(min_x, min_z, max_x, max_z)
	local near_x = math.clamp(0, min_x, max_x)
	local near_z = math.clamp(0, min_z, max_z)
	local far_x = math.max(math.abs(min_x), math.abs(max_x))
	local far_z = math.max(math.abs(min_z), math.abs(max_z))
	return planet.GetDrop(near_x, near_z), planet.GetDrop(far_x, far_z)
end

planet.GLSL = [[
#ifndef PLANET_GLSL
#define PLANET_GLSL
const float PLANET_RADIUS_METERS = ]] .. string.format("%.1f", R) .. [[;

float planet_drop(vec2 xz) {
	float d2 = dot(xz, xz);
	return d2 / (PLANET_RADIUS_METERS + sqrt(max(PLANET_RADIUS_METERS * PLANET_RADIUS_METERS - d2, 0.0)));
}

vec3 planet_up(vec3 p) {
	return normalize(vec3(p.x, p.y + PLANET_RADIUS_METERS, p.z));
}

// rotates a direction from the flat frame (+y up) to the frame whose up is the planet's up
vec3 planet_to_world(vec3 n, vec3 up) {
	vec3 v = vec3(up.z, 0.0, -up.x);
	return n * up.y + cross(v, n) + v * (dot(v, n) / (1.0 + up.y));
}

// distances along dir to the sphere at height above the datum, (-1, -1) on a miss; written without R^2 so float32 keeps meters
vec2 planet_sphere_intersect(vec3 origin, vec3 dir, float height) {
	float b = dot(origin, dir) + PLANET_RADIUS_METERS * dir.y;
	float c = dot(origin.xz, origin.xz) + (origin.y - height) * (origin.y + height + 2.0 * PLANET_RADIUS_METERS);
	float disc = b * b - c;

	if (disc < 0.0) return vec2(-1.0);

	float q = b > 0.0 ? -b - sqrt(disc) : -b + sqrt(disc);

	if (q == 0.0) return vec2(0.0);

	float t0 = q;
	float t1 = c / q;
	return vec2(min(t0, t1), max(t0, t1));
}
// the distance to the sphere at height y above the datum with the sign rules of a plane at y: positive only toward the surface
float planet_surface_t(vec3 origin, vec3 dir, float y) {
	vec2 hit = planet_sphere_intersect(origin, dir, y);
	bool above = origin.y + planet_drop(origin.xz) > y;

	if (above) return hit.x >= 0.0 ? hit.x : -1.0;

	return dot(dir, planet_up(origin)) > 0.0 ? hit.y : -1.0;
}
#endif
]]
return planet
