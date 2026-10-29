local ffi = require("ffi")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local vfs = import("goluwa/vfs.lua")
local store = import("goluwa/render3d/scene/store.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local surface_effects = import("goluwa/render3d/surface_effects.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local exposure = import("goluwa/render3d/exposure.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local surface_overlays = {}
surface_overlays.MAX_SLOTS = 255
surface_overlays.MAX_LAYERS = 4
surface_overlays.EMISSION = 40
surface_overlays.REFERENCE_EV = 9
surface_overlays.MAX_EXPOSURE_GAIN_EV = 7
surface_overlays.EXPOSURE_OVERSHOOT = 1.35
surface_overlays.kinds = {}

for _, file in ipairs(vfs.Find("lua/surface_overlays/%.lua$")) do
	surface_overlays.kinds[#surface_overlays.kinds + 1] = import("lua/surface_overlays/" .. file)
end

local kinds = surface_overlays.kinds
local kinds_by_name = {}

for i, kind in ipairs(kinds) do
	kind.index = i
	kinds_by_name[kind.name] = kind
end

local LAYER_FIELDS = [[
	int32_t kind;
	float start;
	float duration;
	float fade_in;
	float fade_out;
	float intensity;
	float scale;
	float speed;
	float daylight;
	float color_a[4];
	float color_b[4];
	float params[4];
]]
local Layer = ffi.typeof("struct {" .. LAYER_FIELDS .. "}")
local Slot = ffi.typeof(
	"struct { float center[3]; float radius; $ layers[" .. surface_overlays.MAX_LAYERS .. "]; }",
	Layer
)
local slot_table
local states = {}
local state_list = {}
local free_slots = {}
local next_slot = 1
local handle_meta = {}
handle_meta.__index = handle_meta
surface_overlays.block = {
	{"overlay_slots", "uint64_t"},
	{"overlay_noise_tex", "int"},
	{"overlay_exposure_tex", "int"},
	{"overlay_time", "float"},
}

function surface_overlays.GetTime()
	return system.GetElapsedTime()
end

local function write_color(destination, color, alpha_default)
	destination[0], destination[1], destination[2], destination[3] = color.r, color.g, color.b, color.a or alpha_default
end

local function release_state(state)
	local list = state.visual:IsValid() and state.visual.scene_instances

	if list then
		for i = 1, #list do
			instances.SetOverlay(list[i].id, 0)
		end
	end

	ffi.fill(slot_table.ptr + state.slot, ffi.sizeof(Slot))
	slot_table:Touch(state.slot)
	states[state.visual] = nil
	free_slots[#free_slots + 1] = state.slot

	for i, other in ipairs(state_list) do
		if other == state then
			table.remove(state_list, i)

			break
		end
	end
end

local function get_state(visual)
	local state = states[visual]

	if state then return state end

	if not slot_table then
		slot_table = store.CreateTable{
			name = "surface_overlay_slots",
			ctype = Slot,
			capacity = surface_overlays.MAX_SLOTS + 1,
			staged = true,
		}
	end

	local slot = table.remove(free_slots)

	if not slot then
		assert(next_slot <= surface_overlays.MAX_SLOTS, "too many visuals with surface overlays")
		slot = next_slot
		next_slot = next_slot + 1
	end

	state = {visual = visual, slot = slot, layers = {}, box = {0, 0, 0, 0}}
	states[visual] = state
	state_list[#state_list + 1] = state
	return state
end

function surface_overlays.Add(visual, kind_name, config)
	local kind = kinds_by_name[kind_name]
	assert(kind, "unknown surface overlay kind " .. tostring(kind_name))
	config = config or {}
	local defaults = kind.defaults
	local state = get_state(visual)
	local index

	for i = 1, surface_overlays.MAX_LAYERS do
		if not state.layers[i] then
			index = i

			break
		end
	end

	if not index then
		index = 1

		for i = 2, surface_overlays.MAX_LAYERS do
			if state.layers[i].layer.start < state.layers[index].layer.start then
				index = i
			end
		end
	end

	local now = surface_overlays.GetTime()
	local layer = slot_table.ptr[state.slot].layers[index - 1]
	layer.kind = kind.index
	layer.start = now + (config.Delay or 0)
	layer.duration = config.Duration or 0
	layer.fade_in = config.FadeIn or defaults.FadeIn
	layer.fade_out = config.FadeOut or defaults.FadeOut
	layer.intensity = config.Intensity or defaults.Intensity
	layer.scale = config.Scale or defaults.Scale
	layer.speed = config.Speed or defaults.Speed
	layer.daylight = config.Daylight or defaults.Daylight
	write_color(layer.color_a, config.ColorA or defaults.ColorA, 1)
	write_color(layer.color_b, config.ColorB or defaults.ColorB, 1)
	local params = config.Params or defaults.Params

	for i = 1, 4 do
		layer.params[i - 1] = params[i] or defaults.Params[i] or 0
	end

	slot_table:Touch(state.slot)
	local handle = setmetatable({state = state, index = index, layer = layer}, handle_meta)
	state.layers[index] = handle
	return handle
end

function handle_meta:IsActive()
	return self.state.layers[self.index] == self
end

function handle_meta:Remove(fade_out)
	if not self:IsActive() then return end

	local layer = self.layer
	layer.duration = math.max(surface_overlays.GetTime() - layer.start, 0.001)
	layer.fade_out = fade_out or layer.fade_out
	slot_table:Touch(self.state.slot)
end

function surface_overlays.Clear(visual)
	local state = states[visual]

	if state then release_state(state) end
end

function surface_overlays.ClearAll()
	for i = #state_list, 1, -1 do
		release_state(state_list[i])
	end
end

function surface_overlays.GetActiveCount()
	return #state_list
end

function surface_overlays.Update()
	local now = surface_overlays.GetTime()

	for i = #state_list, 1, -1 do
		local state = state_list[i]
		local visual = state.visual

		if not visual:IsValid() then
			release_state(state)
		else
			local alive = false

			for index = 1, surface_overlays.MAX_LAYERS do
				local handle = state.layers[index]

				if handle then
					local layer = handle.layer

					if layer.duration > 0 and now > layer.start + layer.duration + layer.fade_out then
						state.layers[index] = nil
						layer.kind = 0
						slot_table:Touch(state.slot)
					else
						alive = true
					end
				end
			end

			if not alive then
				release_state(state)
			else
				local box = visual:GetWorldAABB()
				local row = slot_table.ptr[state.slot]
				local cx, cy, cz = (box.min_x + box.max_x) * 0.5,
				(box.min_y + box.max_y) * 0.5,
				(box.min_z + box.max_z) * 0.5
				local radius = math.max(box.max_x - box.min_x, box.max_y - box.min_y, box.max_z - box.min_z) * 0.5
				local cache = state.box

				if cache[1] ~= cx or cache[2] ~= cy or cache[3] ~= cz or cache[4] ~= radius then
					cache[1], cache[2], cache[3], cache[4] = cx, cy, cz, radius
					row.center[0], row.center[1], row.center[2], row.radius = cx, cy, cz, radius
					slot_table:Touch(state.slot)
				end

				local list = visual.scene_instances

				if list then
					for j = 1, #list do
						instances.SetOverlay(list[j].id, state.slot)
					end
				end
			end
		end
	end
end

function surface_overlays.WriteBlock(self, block)
	local noise = slot_table and #state_list > 0 and surface_effects.GetNoiseTexture()

	if not noise then
		block.overlay_slots = 0
		block.overlay_noise_tex = -1
		block.overlay_exposure_tex = -1
		return block
	end

	block.overlay_slots = slot_table:GetAddress()
	block.overlay_noise_tex = self:GetTextureIndex(noise)
	local exposure_texture = post_source.GetExposureTexture(true)
	block.overlay_exposure_tex = exposure_texture and self:GetTextureIndex(exposure_texture) or -1
	block.overlay_time = surface_overlays.GetTime()
	return block
end

function surface_overlays.GetGLSL(block_name)
	local functions = {}
	local cases = {}

	for _, kind in ipairs(kinds) do
		functions[#functions + 1] = string.format(
			"void overlay_kind_%s(inout Surface s, inout SurfaceWeather w, OverlayLayer l, OverlayContext c, float age, float t, float grow, float outro, float fade) {\n%s\n}\n",
			kind.name,
			kind.glsl
		)
		cases[#cases + 1] = string.format(
			"case %d: overlay_kind_%s(s, w, l, c, age, t, grow, outro, fade); break;",
			kind.index,
			kind.name
		)
	end

	return (
		glsl_common.GetHashGLSL() .. [[
		struct OverlayLayer {]] .. LAYER_FIELDS:gsub("float ([%w_]+)%[4%];", "vec4 %1;"):gsub("int32_t", "int") .. [[};

		struct OverlaySlot {
			vec3 center;
			float radius;
			OverlayLayer layers[]] .. surface_overlays.MAX_LAYERS .. [[];
		};

		layout(buffer_reference, scalar) readonly buffer SurfaceOverlaySlots { OverlaySlot slots[]; };

		struct OverlayContext {
			vec3 P;
			vec3 N;
			vec3 V;
			vec3 world_pos;
			vec3 center;
			float radius;
			float height;
			float ndv;
		};

		vec4 overlay_noise(OverlayContext c, float scale) {
			vec3 w = c.N * c.N;
			w *= w;
			w /= dot(w, vec3(1.0));
			return texture(TEXTURE(BLOCK.overlay_noise_tex), c.P.zy * scale) * w.x + texture(TEXTURE(BLOCK.overlay_noise_tex), c.P.xz * scale) * w.y + texture(TEXTURE(BLOCK.overlay_noise_tex), c.P.xy * scale) * w.z;
		}

		vec4 overlay_noise_at(OverlayContext c, vec3 offset, float scale) {
			c.P += offset;
			return overlay_noise(c, scale);
		}

		float overlay_hash(float x) {
			return pcg_unorm(pcg3d(uvec3(floatBitsToUint(x), 7u, 13u)).x);
		}

		float overlay_hash2(vec2 x) {
			return pcg_unorm(pcg3d(uvec3(floatBitsToUint(x.x), floatBitsToUint(x.y), 31u)).x);
		}

		vec3 overlay_hue(float h) {
			return clamp(abs(fract(h + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
		}

		float overlay_reveal(float height, float progress, float jitter) {
			return smoothstep(0.0, 0.12, progress * 1.25 - height - jitter);
		}

		float overlay_exposure_ev() {
			if (BLOCK.overlay_exposure_tex == -1) return ]] .. surface_overlays.REFERENCE_EV .. [[.0;

			float current = texture(TEXTURE(BLOCK.overlay_exposure_tex), vec2(0.5)).r;

			if (current <= 0.0) return ]] .. surface_overlays.REFERENCE_EV .. [[.0;

			return ]] .. exposure.LOG_EXPOSURE_AT_EV0 .. [[ - log2(current);
		}

		void overlay_cover(inout Surface s, float amount) {
			s.alpha = max(s.alpha, amount);
		}

		void overlay_set_roughness(inout Surface s, float roughness, float amount) {
			s.roughness_alpha = mix(s.roughness_alpha, roughness * roughness, amount);
		}

		void overlay_tilt(inout Surface s, vec3 tilt, float amount) {
			s.N = normalize(mix(s.N, normalize(s.geometric_N + tilt - s.geometric_N * dot(tilt, s.geometric_N)), amount));
		}

		]] .. table.concat(functions, "\n") .. [[

		void apply_surface_overlays(inout Surface s, inout SurfaceWeather w, float slot_value, vec3 noise_P, vec3 noise_N) {
			int slot_index = int(slot_value + 0.5);

			if (slot_index <= 0 || BLOCK.overlay_slots == 0ul) return;

			OverlaySlot slot = SurfaceOverlaySlots(BLOCK.overlay_slots).slots[slot_index];
			OverlayContext c;
			c.P = noise_P;
			c.N = normalize(noise_N);
			c.V = normalize(]] .. block_name .. [[.camera_position.xyz - s.world_pos);
			c.world_pos = s.world_pos;
			c.center = slot.center;
			c.radius = max(slot.radius, 1e-3);
			c.height = clamp((s.world_pos.y - (slot.center.y - c.radius)) / (c.radius * 2.0), 0.0, 1.0);
			c.ndv = abs(dot(s.N, c.V));

			float exposure_gain_ev = clamp(overlay_exposure_ev() - ]] .. surface_overlays.REFERENCE_EV .. [[.0, 0.0, ]] .. surface_overlays.MAX_EXPOSURE_GAIN_EV .. [[.0);

			for (int i = 0; i < ]] .. surface_overlays.MAX_LAYERS .. [[; i++) {
				OverlayLayer l = slot.layers[i];

				if (l.kind == 0) continue;

				float age = BLOCK.overlay_time - l.start;

				if (age < 0.0) continue;

				float grow = clamp(age / max(l.fade_in, 1e-3), 0.0, 1.0);
				float outro = l.duration > 0.0 ? 1.0 - clamp((age - l.duration) / max(l.fade_out, 1e-3), 0.0, 1.0) : 1.0;
				float fade = smoothstep(0.0, 1.0, grow) * smoothstep(0.0, 1.0, outro) * l.intensity;

				if (fade <= 0.0) continue;

				float t = age * l.speed;

				vec3 emissive_before = s.emissive;

				switch (l.kind) {
					]] .. table.concat(cases, "\n") .. [[
					default: break;
				}

				s.emissive = emissive_before + (s.emissive - emissive_before) * ]] .. string.format("%.2f", surface_overlays.EMISSION) .. [[ * exp2(exposure_gain_ev * l.daylight * ]] .. surface_overlays.EXPOSURE_OVERSHOOT .. [[);
			}
		}
	]]
	):gsub("BLOCK%.", block_name .. ".")
end

event.AddListener(
	"PreRenderPass",
	"surface_overlays",
	function()
		if #state_list == 0 then return end

		surface_effects.GetNoiseTexture()
		surface_overlays.Update()
		store.FlushStaged(render.GetCommandBuffer())
	end,
	{priority = 1}
)

return surface_overlays
