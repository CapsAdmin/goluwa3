local ffi = require("ffi")
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local vfs = import("goluwa/vfs.lua")
local store = import("goluwa/render3d/scene/store.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local surface_conditions = import("goluwa/render3d/surface_conditions.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local data_files = import("goluwa/data_files.lua")
local exposure_compensation = import("goluwa/render3d/exposure_compensation.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local surface_overlays = {}
surface_overlays.MAX_SLOTS = 255
surface_overlays.MAX_LAYERS = 4
surface_overlays.EMISSION = 40
surface_overlays.REFERENCE_EV = 9
surface_overlays.MAX_EXPOSURE_GAIN_EV = 7
surface_overlays.EXPOSURE_OVERSHOOT = 1.35
surface_overlays.kinds = {}
surface_overlays.Errors = {}
surface_overlays.Files = data_files.New(
	"lua/surface_overlays/",
	{"FadeIn", "FadeOut", "Intensity", "Scale", "Speed", "Daylight", "ColorA", "ColorB", "Params", "Source"}
)
local kinds = surface_overlays.kinds
local kinds_by_name = {}
local RESERVED_PARAMS = {
	s = true,
	w = true,
	l = true,
	c = true,
	age = true,
	t = true,
	grow = true,
	outro = true,
	fade = true,
}

function surface_overlays.GetParamIdentifier(name)
	return (name:gsub("(%l)(%u)", "%1_%2"):lower())
end

function surface_overlays.Register(name, data)
	assert(type(name) == "string" and name:find("^[%w_]+$"), "overlay names are letters, digits and underscores")
	assert(type(data.Source) == "string", name .. " needs a Source")
	local params = data.Params or {}
	assert(#params <= 4, name .. " has more than 4 params")
	local seen = {}

	for _, param in ipairs(params) do
		assert(
			type(param.Name) == "string" and param.Name:find("^[A-Z][%w]*$"),
			name .. " param names are PascalCase letters and digits"
		)
		local identifier = surface_overlays.GetParamIdentifier(param.Name)
		assert(not RESERVED_PARAMS[identifier], name .. " param " .. param.Name .. " is a reserved glsl name")
		assert(not seen[identifier], name .. " has the param " .. param.Name .. " twice")
		seen[identifier] = true
		assert(type(param.Default) == "number", name .. " param " .. param.Name .. " needs a number Default")
	end

	surface_overlays.Files:Remember(name, data)
	local kind = kinds_by_name[name]

	if not kind then
		kind = {name = name, index = #kinds + 1}
		kinds[#kinds + 1] = kind
		kinds_by_name[name] = kind
	end

	local identifiers = {}

	for i, param in ipairs(params) do
		identifiers[i] = surface_overlays.GetParamIdentifier(param.Name)
	end

	kind.signature = data.Source .. "\0" .. table.concat(identifiers, ",")
	kind.params = table.copy(params)
	kind.glsl = data.Source
	kind.defaults = data_files.Realize(table.copy(data))
	return kind
end

do
	local names = {}

	for _, file in ipairs(vfs.Find("lua/surface_overlays/%.lua$")) do
		names[#names + 1] = file:gsub("%.lua$", "")
	end

	table.sort(names)

	for _, name in ipairs(names) do
		surface_overlays.Register(name, surface_overlays.Files:Read(name))
	end
end

function surface_overlays.GetSignature(name)
	return kinds_by_name[name].signature
end

function surface_overlays.GetParams(name)
	return kinds_by_name[name].params
end

function surface_overlays.GetKindNames()
	local names = {}

	for _, kind in ipairs(kinds) do
		names[#names + 1] = kind.name
	end

	return names
end

do
	local PASS_PATHS = {"goluwa/render3d/passes/gbuffer.lua", "goluwa/render3d/passes/translucent.lua"}
	local REBUILD_DELAY = 1.5
	local rebuild = {active = 0}

	local function on_rebuild_done()
		rebuild.active = rebuild.active - 1
	end

	local function rebuild_pipelines()
		local render3d = import("goluwa/render3d/render3d.lua")
		local passes = {}

		for _, path in ipairs(PASS_PATHS) do
			local old = import.loaded[path]
			import.loaded[path] = nil
			passes[path] = {old = old, fresh = import(path)}
		end

		for bundle in pairs(render3d.bundles) do
			local names = {}

			for _, path in ipairs(PASS_PATHS) do
				local entry = passes[path]

				for index, pass in ipairs(bundle.options.passes or {}) do
					if pass == entry.old then bundle.options.passes[index] = entry.fresh end
				end

				for _, config in ipairs(entry.fresh) do
					if bundle.pipelines[config.name] then names[#names + 1] = config.name end
				end
			end

			if names[1] then
				rebuild.active = rebuild.active + 1
				local ok, err = pcall(render3d.RebuildPipelinesAsync, bundle, names, on_rebuild_done)

				if not ok then
					rebuild.active = rebuild.active - 1
					surface_overlays.BuildError = surface_overlays.ParseError(tostring(err))
					logn("failed to rebuild overlay pipelines: ", surface_overlays.BuildError)
				end
			end
		end
	end

	event.AddListener("Update", "surface_overlays_rebuild", function()
		if rebuild.at and system.GetTime() >= rebuild.at and rebuild.active == 0 then
			rebuild.at = nil
			surface_overlays.BuildError = nil
			rebuild_pipelines()
		end
	end)

	function surface_overlays.IsRebuilding()
		return rebuild.at ~= nil or rebuild.active > 0
	end

	function surface_overlays.UpdateKind(name, data)
		local previous = surface_overlays.Files.Source[name]
		local previous_signature = kinds_by_name[name] and kinds_by_name[name].signature
		local ok, err = pcall(surface_overlays.Register, name, data)

		if ok and RENDER_3D and render.IsInitialized() then
			local message = import("goluwa/render3d/surface_overlay_preview.lua").Check(name)

			if message then ok, err = false, message end
		end

		if not ok then
			if previous then
				surface_overlays.Register(name, previous)
			elseif kinds[#kinds] and kinds[#kinds].name == name then
				kinds[#kinds] = nil
				kinds_by_name[name] = nil
				surface_overlays.Files.Source[name] = nil
			end

			surface_overlays.Errors[name] = tostring(err)
			error(err, 0)
		end

		surface_overlays.Errors[name] = nil

		if kinds_by_name[name].signature ~= previous_signature and RENDER_3D and render.IsInitialized() then
			rebuild.at = system.GetTime() + REBUILD_DELAY
		end
	end
end

function surface_overlays.GetStatus(name)
	return surface_overlays.Errors[name] or surface_overlays.BuildError
end

function surface_overlays.GetNewName(name)
	local base = name:gsub("_?%d+$", "")
	local index = 2

	while kinds_by_name[base .. "_" .. index] do
		index = index + 1
	end

	return base .. "_" .. index
end

function surface_overlays.CreateKind(name, from)
	surface_overlays.UpdateKind(name, table.copy(surface_overlays.Files.Source[from]))
	return name
end

function surface_overlays.ReloadKind(name)
	return surface_overlays.UpdateKind(name, surface_overlays.Files:Read(name))
end

function surface_overlays.SaveKind(name)
	return surface_overlays.Files:Save(name)
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
	int32_t uv_space;
	float uv_scale[2];
	float hold;
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
	local uv_scale = config.UVScale
	layer.hold = -1
	layer.uv_space = uv_scale and 1 or 0
	layer.uv_scale[0], layer.uv_scale[1] = uv_scale and uv_scale[1] or 0, uv_scale and uv_scale[2] or 0

	for i = 1, 4 do
		local param = kind.params[i]
		layer.params[i - 1] = param and (config[param.Name] or param.Default) or 0
	end

	slot_table:Touch(state.slot)
	local handle = setmetatable({state = state, index = index, layer = layer}, handle_meta)
	state.layers[index] = handle
	return handle
end

function handle_meta:IsActive()
	return self.state.layers[self.index] == self
end

function handle_meta:SetIntensity(intensity)
	local layer = self.layer

	if layer.intensity == intensity then return end

	layer.intensity = intensity
	slot_table:Touch(self.state.slot)
end

function handle_meta:SetFade(fade)
	local layer = self.layer

	if fade then
		layer.hold = fade
	elseif layer.hold >= 0 then
		layer.start = surface_overlays.GetTime() - layer.hold * layer.fade_in
		layer.hold = -1
	end

	slot_table:Touch(self.state.slot)
end

function handle_meta:GetFade()
	if not self:IsActive() then return 0 end

	local layer = self.layer

	if layer.hold >= 0 then return layer.hold end

	local age = surface_overlays.GetTime() - layer.start
	local grow = math.clamp(age / math.max(layer.fade_in, 1e-3), 0, 1)
	local outro = layer.duration > 0 and
		1 - math.clamp((age - layer.duration) / math.max(layer.fade_out, 1e-3), 0, 1)
		or
		1
	return grow * outro
end

function handle_meta:SetUVScale(x, y)
	local scale = self.layer.uv_scale

	if scale[0] == x and scale[1] == y then return end

	scale[0], scale[1] = x, y
	slot_table:Touch(self.state.slot)
end

function handle_meta:Remove(fade_out)
	if not self:IsActive() then return end

	self:SetFade()
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
	local noise = slot_table and #state_list > 0 and surface_conditions.GetNoiseTexture()

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

local function get_kind_glsl(kind)
	local declarations = {}

	for i, param in ipairs(kind.params) do
		declarations[i] = string.format(
			"float %s = l.params.%s;",
			surface_overlays.GetParamIdentifier(param.Name),
			("xyzw"):sub(i, i)
		)
	end

	return string.format(
			"void overlay_kind_%s(inout Surface s, inout SurfaceWeather w, OverlayLayer l, OverlayContext c, float age, float t, float grow, float outro, float fade) {\n%s\n#line 1 %d\n%s\n}\n",
			kind.name,
			table.concat(declarations, "\n"),
			kind.index,
			kind.glsl
		),
		string.format(
			"case %d: overlay_kind_%s(s, w, l, layer_context, age, t, grow, outro, fade); break;",
			kind.index,
			kind.name
		)
end

local function get_helpers_glsl()
	return glsl_common.GetNoiseGLSL() .. exposure_compensation.GetGLSL() .. [[
		struct OverlayLayer {]] .. LAYER_FIELDS:gsub("float ([%w_]+)%[4%];", "vec4 %1;"):gsub("float ([%w_]+)%[2%];", "vec2 %1;"):gsub("int32_t", "int") .. [[};

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

		struct OverlayCell {
			vec3 id;
			float edge;
			float nearest;
			vec3 offset;
		};

		OverlayCell overlay_voronoi(vec3 p) {
			vec3 base = floor(p);
			vec3 f = p - base;
			float nearest = 8.0;
			float second = 8.0;
			OverlayCell cell;
			cell.id = vec3(0.0);
			cell.offset = vec3(0.0);

			for (int z = -1; z <= 1; z++) {
				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						vec3 g = vec3(x, y, z);
						uvec3 h = pcg3d(uvec3(ivec3(base + g) + 32768));
						vec3 r = vec3(pcg_unorm(h.x), pcg_unorm(h.y), pcg_unorm(h.z));
						vec3 d = g + r - f;
						float dist = dot(d, d);

						if (dist < nearest) {
							second = nearest;
							nearest = dist;
							cell.id = r;
							cell.offset = d;
						} else if (dist < second) {
							second = dist;
						}
					}
				}
			}

			cell.nearest = sqrt(nearest);
			cell.edge = sqrt(second) - cell.nearest;
			return cell;
		}

		float overlay_fbm(vec3 p, int octaves) {
			float value = 0.0;
			float amplitude = 0.5;

			for (int i = 0; i < octaves; i++) {
				value += amplitude * value_noise3(p);
				p = p * 2.0 + vec3(1.7, 9.2, 3.1);
				amplitude *= 0.5;
			}

			return value;
		}

		vec3 overlay_gradient(vec3 cell, float angle) {
			uvec3 h = pcg3d(uvec3(ivec3(cell) + 32768));
			vec3 g = vec3(pcg_unorm(h.x), pcg_unorm(h.y), pcg_unorm(h.z)) * 2.0 - 1.0;
			vec3 axis = vec3(0.57735);
			float cs = cos(angle);
			float sn = sin(angle);
			return g * cs + cross(axis, g) * sn + axis * (dot(axis, g) * (1.0 - cs));
		}

		vec4 overlay_gradient_noise(vec3 p, float angle) {
			vec3 i = floor(p);
			vec3 f = fract(p);
			vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
			vec3 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
			vec3 ga = overlay_gradient(i, angle);
			vec3 gb = overlay_gradient(i + vec3(1.0, 0.0, 0.0), angle);
			vec3 gc = overlay_gradient(i + vec3(0.0, 1.0, 0.0), angle);
			vec3 gd = overlay_gradient(i + vec3(1.0, 1.0, 0.0), angle);
			vec3 ge = overlay_gradient(i + vec3(0.0, 0.0, 1.0), angle);
			vec3 gf = overlay_gradient(i + vec3(1.0, 0.0, 1.0), angle);
			vec3 gg = overlay_gradient(i + vec3(0.0, 1.0, 1.0), angle);
			vec3 gh = overlay_gradient(i + vec3(1.0, 1.0, 1.0), angle);
			float va = dot(ga, f);
			float vb = dot(gb, f - vec3(1.0, 0.0, 0.0));
			float vc = dot(gc, f - vec3(0.0, 1.0, 0.0));
			float vd = dot(gd, f - vec3(1.0, 1.0, 0.0));
			float ve = dot(ge, f - vec3(0.0, 0.0, 1.0));
			float vf = dot(gf, f - vec3(1.0, 0.0, 1.0));
			float vg = dot(gg, f - vec3(0.0, 1.0, 1.0));
			float vh = dot(gh, f - vec3(1.0, 1.0, 1.0));
			float k1 = vb - va;
			float k2 = vc - va;
			float k3 = ve - va;
			float k4 = va - vb - vc + vd;
			float k5 = va - vc - ve + vg;
			float k6 = va - vb - ve + vf;
			float k7 = -va + vb + vc - vd + ve - vf - vg + vh;
			float value = va + u.x * k1 + u.y * k2 + u.z * k3 + u.x * u.y * k4 + u.y * u.z * k5 + u.z * u.x * k6 + u.x * u.y * u.z * k7;
			vec3 gradient = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.z * (ge - ga) + u.x * u.y * (ga - gb - gc + gd) + u.y * u.z * (ga - gc - ge + gg) + u.z * u.x * (ga - gb - ge + gf) + u.x * u.y * u.z * (-ga + gb + gc - gd + ge - gf - gg + gh) + du * (vec3(k1, k2, k3) + u.yzx * vec3(k4, k5, k6) + u.zxy * vec3(k6, k4, k5) + u.yzx * u.zxy * k7);
			return vec4(gradient, value);
		}

		vec3 overlay_hsv(vec3 c) {
			vec3 rgb = clamp(abs(mod(c.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
			rgb = rgb * rgb * (3.0 - 2.0 * rgb);
			return c.z * mix(vec3(1.0), rgb, c.y);
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
			return exposure_compensation_ev(BLOCK.overlay_exposure_tex, ]] .. surface_overlays.REFERENCE_EV .. [[.0);
		}

		void overlay_cover(inout Surface s, float amount) {
			s.alpha = max(s.alpha, amount);
		}

		void overlay_bump(inout Surface s, float height, float strength) {
			vec3 dpdx = dFdx(s.world_pos);
			vec3 dpdy = dFdy(s.world_pos);
			vec3 r1 = cross(dpdy, s.N);
			vec3 r2 = cross(s.N, dpdx);
			float det = dot(dpdx, r1);
			vec3 grad = sign(det) * (dFdx(height) * r1 + dFdy(height) * r2) * strength;
			s.N = normalize(abs(det) * s.N - grad);
		}

		void overlay_bump_gradient(inout Surface s, OverlayContext c, vec3 local_gradient, float strength) {
			vec3 dpdx = dFdx(s.world_pos);
			vec3 dpdy = dFdy(s.world_pos);
			vec3 r1 = cross(dpdy, s.N);
			vec3 r2 = cross(s.N, dpdx);
			float det = dot(dpdx, r1);
			float dhdx = dot(local_gradient, dFdx(c.P));
			float dhdy = dot(local_gradient, dFdy(c.P));
			vec3 grad = sign(det) * (dhdx * r1 + dhdy * r2) * strength;
			s.N = normalize(abs(det) * s.N - grad);
		}

		void overlay_set_roughness(inout Surface s, float roughness, float amount) {
			s.roughness_alpha = mix(s.roughness_alpha, roughness * roughness, amount);
		}

		void overlay_tilt(inout Surface s, vec3 tilt, float amount) {
			s.N = normalize(mix(s.N, normalize(s.geometric_N + tilt - s.geometric_N * dot(tilt, s.geometric_N)), amount));
		}

	]]
end

local APPLY_LAYER_GLSL = [[
	void overlay_apply_layer(inout Surface s, inout SurfaceWeather w, OverlayLayer l, OverlayContext c, float exposure_gain_ev, vec2 uv) {
		float age = BLOCK.overlay_time - l.start;

		if (age < 0.0) return;

		bool held = l.hold >= 0.0;
		float grow = held ? l.hold : clamp(age / max(l.fade_in, 1e-3), 0.0, 1.0);
		float outro = l.duration > 0.0 && !held ? 1.0 - clamp((age - l.duration) / max(l.fade_out, 1e-3), 0.0, 1.0) : 1.0;
		float fade = smoothstep(0.0, 1.0, grow) * smoothstep(0.0, 1.0, outro) * l.intensity;

		if (fade <= 0.0) return;

		float t = age * l.speed;
		OverlayContext layer_context = c;

		if (l.uv_space != 0) {
			layer_context.P = vec3(uv * l.uv_scale, 0.0);
			layer_context.N = vec3(0.0, 0.0, 1.0);
		}

		vec3 emissive_before = s.emissive;

		switch (l.kind) {
			CASES
			default: break;
		}

		s.emissive = emissive_before + (s.emissive - emissive_before) * ]] .. string.format("%.2f", surface_overlays.EMISSION) .. [[ * exp2(exposure_gain_ev * l.daylight * ]] .. surface_overlays.EXPOSURE_OVERSHOOT .. [[);
	}
]]

function surface_overlays.GetPreviewGLSL(name)
	local kind = kinds_by_name[name]
	local source, case = get_kind_glsl(kind)
	return get_helpers_glsl() .. source .. APPLY_LAYER_GLSL:gsub("CASES", case), kind.index
end

function surface_overlays.ParseError(message)
	local source, line, text = message:match("(%d+):(%d+): error: ([^\n]*)")
	local kind = source and kinds[tonumber(source)]

	if not kind then return message end

	return ("%s line %s: %s"):format(kind.name, line, text)
end

function surface_overlays.GetGLSL(block_name)
	local functions = {}
	local cases = {}

	for _, kind in ipairs(kinds) do
		functions[#functions + 1], cases[#cases + 1] = get_kind_glsl(kind)
	end

	return (
		get_helpers_glsl() .. table.concat(functions, "\n") .. APPLY_LAYER_GLSL:gsub("CASES", table.concat(cases, "\n")) .. [[

		struct OverlaySlot {
			vec3 center;
			float radius;
			OverlayLayer layers[]] .. surface_overlays.MAX_LAYERS .. [[];
		};

		layout(buffer_reference, scalar) readonly buffer SurfaceOverlaySlots { OverlaySlot slots[]; };

		void apply_surface_overlays(inout Surface s, inout SurfaceWeather w, float slot_value, vec3 noise_P, vec3 noise_N, vec2 uv) {
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

				if (l.kind != 0) overlay_apply_layer(s, w, l, c, exposure_gain_ev, uv);
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

		surface_conditions.GetNoiseTexture()
		surface_overlays.Update()
		store.FlushStaged(render.GetCommandBuffer())
	end,
	{priority = 1}
)

return surface_overlays
