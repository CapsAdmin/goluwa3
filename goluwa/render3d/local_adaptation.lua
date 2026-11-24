local pvars = import("goluwa/cli/pvars.lua")
local local_adaptation = {}
local_adaptation.GRID_X = 64
local_adaptation.GRID_Y = 36
local_adaptation.GRID_Z = 48
local_adaptation.MIDDLE_GREY = 0.18
pvars.StartGroup("Post", "Local adaptation", {store = false, prefix = "local_"})
local shadows = pvars.Setup2{
	key = "r_local_shadows",
	default = 0,
	help = "exposes regions darker than middle grey for their surroundings, before the tonemapper: 1 brings a region's average all the way up to middle grey, negative darkens it further. Detail inside the region stays, the regions are separated at edges so there are no halos",
}
local highlights = pvars.Setup2{
	key = "r_local_highlights",
	default = 0,
	help = "exposes regions brighter than middle grey for their surroundings, before the tonemapper: 1 brings a region's average all the way down to middle grey, negative brightens it further",
}
local detail = pvars.Setup2{
	key = "r_local_detail",
	default = 1,
	help = "the contrast of detail inside a region against the region's average, in stops: 1 keeps it, above 1 adds local contrast (clarity), below 1 flattens it",
}
local white_balance = pvars.Setup2{
	key = "r_local_white_balance",
	default = 0,
	help = "removes this share of each region's colour cast, judged against similar brightness around it, like an eye adapting to the light around what it looks at. 1 makes every region's average neutral: a warm valley turns neutral and a grey object in it turns cool",
}
pvars.EndGroup()

function local_adaptation.IsEnabled()
	return shadows:Get() ~= 0 or
		highlights:Get() ~= 0 or
		detail:Get() ~= 1 or
		white_balance:Get() ~= 0
end

local_adaptation.block = {
	{"local_adaptation", "int"},
	{"local_shadows", "float"},
	{"local_highlights", "float"},
	{"local_detail", "float"},
	{"local_white_balance", "float"},
}

function local_adaptation.WriteBlock(block, enabled)
	block.local_adaptation = enabled and 1 or 0
	block.local_shadows = shadows:Get()
	block.local_highlights = highlights:Get()
	block.local_detail = detail:Get()
	block.local_white_balance = white_balance:Get()
end

function local_adaptation.GetGridGLSL()
	return (
		[[
		#define LOCAL_GRID_X %d
		#define LOCAL_GRID_Y %d
		#define LOCAL_GRID_Z %d
		#define LOCAL_LOG_MIN -12.0
		#define LOCAL_LOG_MAX 20.0
		const mat3 LOCAL_RGB_TO_CONES = mat3(0.4490254, 0.0535360, 0.0196255, 0.5219146, 0.9241808, 0.0804399, 0.0290600, 0.0222832, 0.8999346);
		const mat3 LOCAL_CONES_TO_RGB = mat3(2.3893876, -0.1374524, -0.0398210, -1.3455482, 1.1617806, -0.0745014, -0.0438394, -0.0243282, 1.1143224);

		float local_log_level(vec3 exposed) {
			return clamp(log2(max(luminance(exposed), 1e-6) / %.7g), LOCAL_LOG_MIN, LOCAL_LOG_MAX);
		}

		vec2 local_chroma(vec3 rgb) {
			vec3 cones = log2(max(LOCAL_RGB_TO_CONES * rgb, vec3(1e-6)));
			return vec2(cones.x - cones.y, cones.z - 0.5 * (cones.x + cones.y));
		}

		int local_bin(float l) {
			return min(int((l - LOCAL_LOG_MIN) / (LOCAL_LOG_MAX - LOCAL_LOG_MIN) * float(LOCAL_GRID_Z)), LOCAL_GRID_Z - 1);
		}
	]]
	):format(
		local_adaptation.GRID_X,
		local_adaptation.GRID_Y,
		local_adaptation.GRID_Z,
		local_adaptation.MIDDLE_GREY
	)
end

function local_adaptation.GetApplyGLSL(block_name, binding)
	return local_adaptation.GetGridGLSL() .. (
			[[
		layout(set = 0, binding = %d) uniform sampler2D local_grid_tex;

		vec4 local_region(vec2 uv, float l, vec2 chroma) {
			float z = clamp((l - LOCAL_LOG_MIN) / (LOCAL_LOG_MAX - LOCAL_LOG_MIN) * float(LOCAL_GRID_Z) - 0.5, 0.0, float(LOCAL_GRID_Z - 1));
			int z0 = int(z);
			int z1 = min(z0 + 1, LOCAL_GRID_Z - 1);
			vec2 xy = clamp(uv * vec2(LOCAL_GRID_X, LOCAL_GRID_Y), vec2(0.5), vec2(LOCAL_GRID_X, LOCAL_GRID_Y) - 0.5);
			vec2 size = vec2(LOCAL_GRID_X * LOCAL_GRID_Z, LOCAL_GRID_Y);
			vec4 cell = mix(texture(local_grid_tex, (xy + vec2(z0 * LOCAL_GRID_X, 0.0)) / size), texture(local_grid_tex, (xy + vec2(z1 * LOCAL_GRID_X, 0.0)) / size), z - float(z0));
			return vec4(cell.xyz + vec3(l, chroma), cell.w + 1.0);
		}

		vec3 apply_local_adaptation(vec3 col, vec2 uv, float exposure) {
			float l = local_log_level(col * exposure);
			vec2 chroma = local_chroma(col);
			vec4 region = local_region(uv, l, chroma);
			vec3 mean = region.xyz / region.w;

			if (BLOCK.local_white_balance != 0.0) {
				vec2 shift = -BLOCK.local_white_balance * mean.yz;
				vec3 adapted = max(LOCAL_CONES_TO_RGB * ((LOCAL_RGB_TO_CONES * col) * exp2(vec3(0.5 * shift.x, -0.5 * shift.x, shift.y))), vec3(0.0));
				col = adapted * (luminance(col) / max(luminance(adapted), 1e-9));
			}

			float stops = -mean.x * (mean.x < 0.0 ? BLOCK.local_shadows : BLOCK.local_highlights) + (l - mean.x) * (BLOCK.local_detail - 1.0);
			return col * exp2(stops);
		}
	]]
		):format(binding):gsub("BLOCK", block_name)
end

return local_adaptation
