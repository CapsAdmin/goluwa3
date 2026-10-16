local list = import("goluwa/list.lua")
local system = import("goluwa/system.lua")
local particles = import("goluwa/render3d/particles.lua")
local particle_emitter = import("goluwa/render3d/particle_emitter.lua")
-- the gpu backend of particle emitters (the particle_emitter_gpu component): every emitter gets a range of slots in the pool of one
-- particle system, "emitters". Each frame the cpu says how many slots of the range (a ring) spawn, and the shader spawns
-- them from the emitter's parameters in its uniform block, moves all of them, collides them with what the emitter asks
-- for, and lights them (or not) and colors them. Particles are in world space
local gpu = {}
gpu.MAX_EMITTERS = 32
gpu.POOL_SIZE = 65536
local ranges = {}
local free_slots = {}
local next_uid = 1
local high_water = 0
local last_sync_frame

local SHAPES = {point = 0, sphere = 1, cone = 2, box = 3, disc = 4}
local COLLISIONS = {none = 0, shelter_map = 1, scene_depth = 2, rays = 3}
local ON_HIT = {bounce = 0, stick = 1, kill = 2}

local function release(range)
	list.remove_value(ranges, range)
	range.emitter.gpu_range = nil
end

local function by_first(a, b)
	return a.first < b.first
end

-- finds room for count slots between the ranges that are taken
local function allocate(count)
	table.sort(ranges, by_first)

	local first = 0

	for _, range in ipairs(ranges) do
		if range.first - first >= count then return first end

		first = range.first + range.count
	end

	assert(first + count <= gpu.POOL_SIZE, "the gpu particle pool is full")
	return first
end

-- gives the emitters that are in the scene a range and a slot, takes them from the ones that are not or changed size
local function sync()
	local frame = system.GetFrameNumber()

	if last_sync_frame == frame then return end

	last_sync_frame = frame

	for i = #ranges, 1, -1 do
		local range = ranges[i]
		local emitter = range.emitter

		if
			emitter.particle_removed or
			emitter.particle_backend ~= "gpu" or
			not particle_emitter.IsShown(emitter) or
			emitter.MaxParticles ~= range.count
		then
			release(range)
		end
	end

	for _, emitter in ipairs(particle_emitter.instances) do
		if not emitter.gpu_range and emitter.particle_backend == "gpu" and particle_emitter.IsShown(emitter) then
			assert(#ranges < gpu.MAX_EMITTERS, "too many gpu particle emitters")
			local slot = 0
			local taken = {}

			for _, range in ipairs(ranges) do
				taken[range.slot] = true
			end

			while taken[slot] do
				slot = slot + 1
			end

			local range = {
				emitter = emitter,
				first = allocate(emitter.MaxParticles),
				count = emitter.MaxParticles,
				slot = slot,
				uid = next_uid,
				cursor = 0,
			}
			next_uid = next_uid + 1
			ranges[#ranges + 1] = range
			emitter.gpu_range = range
		end
	end

	high_water = 0

	for _, range in ipairs(ranges) do
		high_water = math.max(high_water, range.first + range.count)
	end
end

function gpu.GetRanges()
	sync()
	return ranges
end

local function write_vec3(target, x, y, z)
	target[0], target[1], target[2] = x, y, z
end

local function write_color(target, color)
	target[0], target[1], target[2], target[3] = color.r, color.g, color.b, color.a
end

gpu.system = particles.Register{
	name = "emitters",
	max_count = gpu.POOL_SIZE,
	scatter_g = 0.3,
	streak_time = 1 / 30,
	fade_time = 0.1,
	fade_near = 0.3,
	depth_near = 0.1,
	depth_far = 300,
	collision = "per_particle",
	IsActive = function()
		sync()
		return #ranges > 0
	end,
	GetCount = function()
		sync()
		return high_water, 1
	end,
	UsesRays = function()
		for _, range in ipairs(ranges) do
			if range.emitter.Collision == "rays" then return true end
		end

		return false
	end,
	block = {
		{
			"emitters",
			{
				{"position", "vec3"},
				{"axis", "vec3"},
				{"velocity", "vec3"},
				{"shape_size", "vec3"},
				{"color_start", "vec4"},
				{"color_end", "vec4"},
				{"speed_min", "float"},
				{"speed_max", "float"},
				{"life_min", "float"},
				{"life_max", "float"},
				{"spread", "float"},
				{"size_start", "float"},
				{"size_end", "float"},
				{"gravity", "float"},
				{"drag", "float"},
				{"restitution", "float"},
				{"friction", "float"},
				{"emissive", "float"},
				{"shape", "int"},
				{"collision", "int"},
				{"on_hit", "int"},
				{"lit", "int"},
				{"enabled", "int"},
				{"first", "int"},
				{"count", "int"},
				{"cursor", "int"},
				{"spawn_count", "int"},
				{"uid", "int"},
				{"seed", "int"},
			},
			gpu.MAX_EMITTERS,
		},
		{"emitter_count", "int"},
	},
	WriteBlock = function(self, block)
		sync()
		local dt = particles.GetStepTime()
		local slots = 0

		for i = 0, gpu.MAX_EMITTERS - 1 do
			block.emitters[i].enabled = 0
		end

		for _, range in ipairs(ranges) do
			local emitter = range.emitter
			local state = particle_emitter.Sample(emitter, dt)
			local entry = block.emitters[range.slot]
			slots = math.max(slots, range.slot + 1)
			write_vec3(entry.position, state.position.x, state.position.y, state.position.z)
			write_vec3(entry.axis, state.axis.x, state.axis.y, state.axis.z)
			local inherit = emitter.InheritVelocity
			write_vec3(entry.velocity, state.velocity.x * inherit, state.velocity.y * inherit, state.velocity.z * inherit)
			local size = emitter.ShapeSize
			write_vec3(entry.shape_size, size.x, size.y, size.z)
			write_color(entry.color_start, emitter.ColorStart)
			write_color(entry.color_end, emitter.ColorEnd)
			entry.speed_min = emitter.SpeedMin
			entry.speed_max = math.max(emitter.SpeedMax, emitter.SpeedMin)
			entry.life_min = emitter.LifetimeMin
			entry.life_max = math.max(emitter.LifetimeMax, emitter.LifetimeMin)
			entry.spread = math.rad(emitter.Spread)
			entry.size_start = emitter.SizeStart
			entry.size_end = emitter.SizeEnd
			entry.gravity = emitter.GravityScale
			entry.drag = emitter.Drag
			entry.restitution = emitter.Restitution
			entry.friction = emitter.Friction
			entry.emissive = emitter.Emissive
			entry.shape = SHAPES[emitter.Shape]
			entry.collision = COLLISIONS[emitter.Collision]
			entry.on_hit = ON_HIT[emitter.OnHit]
			entry.lit = emitter.Lit and 1 or 0
			entry.enabled = 1
			entry.first = range.first
			entry.count = range.count
			entry.cursor = range.cursor
			entry.spawn_count = particle_emitter.Step(emitter, dt)
			entry.uid = range.uid
			entry.seed = emitter.Seed
			range.cursor = (range.cursor + entry.spawn_count) % range.count
		end

		block.emitter_count = slots
		return block
	end,
	declarations = [[
		// the slot of the emitter whose range holds index, 32 when none does
		uint find_emitter(uint index) {
			for (int i = 0; i < emitters_data.emitter_count; i++) {
				if (emitters_data.emitters[i].enabled != 0 && index >= uint(emitters_data.emitters[i].first) && index < uint(emitters_data.emitters[i].first + emitters_data.emitters[i].count)) return uint(i);
			}

			return 32u;
		}

		// the emitter of a particle, if it is still the one that spawned it
		bool get_particle_emitter(Particle p, out uint slot) {
			slot = min(p.user.y, 31u);
			return emitters_data.emitters[slot].enabled != 0 && uint(emitters_data.emitters[slot].uid) == p.user.z;
		}

		vec3 get_random_unit_vector(vec2 r) {
			float z = r.x * 2.0 - 1.0;
			float phi = 6.2831853 * r.y;
			return vec3(sqrt(1.0 - z * z) * vec2(cos(phi), sin(phi)), z);
		}
	]],
	should_spawn = [[
		uint slot = find_emitter(index);

		if (slot == 32u) return false;

		emitters_t e = emitters_data.emitters[slot];
		uint local_index = index - uint(e.first);
		return (local_index + uint(e.count) - uint(e.cursor)) % uint(e.count) < uint(e.spawn_count);
	]],
	spawn = [[
		uint slot = find_emitter(index);

		if (slot == 32u) {
			p.life = 0.0;
			return;
		}

		emitters_t e = emitters_data.emitters[slot];
		vec3 r = pcg3d_unorm(uvec3(index, generation, uint(e.seed)));
		vec3 r2 = pcg3d_unorm(uvec3(index, generation, uint(e.seed) + 7919u));
		vec3 r3 = pcg3d_unorm(uvec3(index, generation, uint(e.seed) + 104729u));
		vec3 axis = e.axis;
		vec3 across = normalize(cross(axis, abs(axis.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 along = cross(axis, across);
		float radius = e.shape_size.x * 0.5;
		float base_angle = 6.2831853 * r.x;
		vec3 offset = vec3(0.0);
		vec3 radial = vec3(0.0);

		if (e.shape == 1) {
			radial = get_random_unit_vector(r.xy);
			offset = radial * radius * pow(r3.x, 1.0 / 3.0);
		} else if (e.shape == 2 || e.shape == 4) {
			offset = (across * cos(base_angle) + along * sin(base_angle)) * radius * sqrt(r3.x);
		} else if (e.shape == 3) {
			offset = across * (r.x - 0.5) * e.shape_size.x + axis * (r.y - 0.5) * e.shape_size.y + along * (r.z - 0.5) * e.shape_size.z;
		}

		// a cone around the axis, of the spread, or straight out of a sphere
		float cos_theta = mix(1.0, cos(e.spread), r2.x);
		float phi = 6.2831853 * r2.y;
		vec3 direction = axis * cos_theta + (across * cos(phi) + along * sin(phi)) * sqrt(1.0 - cos_theta * cos_theta);

		if (e.shape == 1) direction = radial;

		p.position = e.position + offset;
		p.velocity = direction * mix(e.speed_min, e.speed_max, r3.y) + e.velocity;
		p.life = mix(e.life_min, e.life_max, r3.z);
		p.width = e.size_start;
		p.user.y = slot;
		p.user.z = uint(e.uid);
	]],
	update = [[
		uint slot;

		if (!get_particle_emitter(p, slot)) {
			p.life = 0.0;
			return;
		}

		emitters_t e = emitters_data.emitters[slot];
		float t = clamp(p.age / p.life, 0.0, 1.0);
		p.width = mix(e.size_start, e.size_end, t);

		// a particle that stuck lies where it is
		if (p.spare != 0u) {
			p.velocity = vec3(0.0);
			return;
		}

		p.velocity.y -= 9.81 * e.gravity * dt;
		p.velocity *= exp(-e.drag * dt);
		p.position += p.velocity * dt;
	]],
	visibility = [[
		uint slot;

		if (!get_particle_emitter(p, slot)) return 0.0;

		emitters_t e = emitters_data.emitters[slot];
		return mix(e.color_start.a, e.color_end.a, clamp(p.age / p.life, 0.0, 1.0));
	]],
	shade = [[
		uint slot;

		if (!get_particle_emitter(p, slot)) return;

		emitters_t e = emitters_data.emitters[slot];
		vec3 tint = mix(e.color_start.rgb, e.color_end.rgb, clamp(p.age / p.life, 0.0, 1.0));
		p.radiance = tint * ((e.lit != 0 ? p.light : vec3(0.0)) + e.emissive);
	]],
	collision_mode = [[
		uint slot;

		if (!get_particle_emitter(p, slot)) return 0;

		return emitters_data.emitters[slot].collision;
	]],
	collide = [[
		uint slot;

		if (!get_particle_emitter(p, slot)) return;

		emitters_t e = emitters_data.emitters[slot];

		if (e.on_hit == 0) {
			particle_bounce(p, hit, normal, e.restitution, e.friction);
		} else if (e.on_hit == 1) {
			particle_stick(p, hit, normal);
			p.spare = 1u;
		} else {
			p.life = 0.0;
		}
	]],
}
return gpu
