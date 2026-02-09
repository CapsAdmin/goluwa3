local Texture = require("render.texture")
return function(options)
	options = options or {}
	local width = options.width or 256
	local height = options.height or 256
	local light_x = options.light_x or -1
	local light_y = options.light_y or -1
	local light_z = options.light_z or 1
	local frame_outer = options.frame_outer or 0.005
	local frame_inner = options.frame_inner or 0.02
	local bevel = options.bevel or 0.015
	local corner_radius = options.corner_radius or 0.03
	local profile_strength = options.profile_strength or 1.5
	local long_curve = options.long_curve or 0.4
	local specular_power = options.specular_power or 80.0
	local specular_strength = options.specular_strength or 0.8
	local ambient = options.ambient or 0.2
	local base_color_r = options.base_color.r or 0.6
	local base_color_g = options.base_color.g or 0.63
	local base_color_b = options.base_color.b or 0.65
	local tex = Texture.New(
		{
			width = width,
			height = height,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	)

	local function f(v)
		return tostring(v)
	end

	tex:Shade(
		[[
	float frameOuter = ]] .. f(frame_outer) .. [[;
	float frameInner = ]] .. f(frame_inner) .. [[;
	float bevel = ]] .. f(bevel) .. [[;
	float cornerRadius = ]] .. f(corner_radius) .. [[;

	vec2 p = uv - vec2(0.5);
	vec2 halfSize = vec2(0.5 - cornerRadius);
	vec2 d = abs(p) - halfSize;
	float sdRect = length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - cornerRadius;
	float dEdge = -sdRect;

	float outerMask = smoothstep(frameOuter - bevel, frameOuter, dEdge);
	float innerMask = 1.0 - smoothstep(frameInner - bevel, frameInner, dEdge);
	float frameMask = outerMask * innerMask;

	// SDF gradient for cross-bar bevel direction
	vec2 grad;
	if (d.x > 0.0 && d.y > 0.0) {
		grad = normalize(d) * sign(p);
	} else if (d.x > d.y) {
		grad = vec2(sign(p.x), 0.0);
	} else {
		grad = vec2(0.0, sign(p.y));
	}
	grad = -grad;

	// bevel profile (cross section)
	float frameMid = (frameOuter + frameInner) * 0.5;
	float frameHalf = (frameInner - frameOuter) * 0.5;
	float t = clamp((dEdge - frameMid) / frameHalf, -1.0, 1.0);
	float profileSlope = -t * ]] .. f(profile_strength) .. [[;

	// longitudinal curvature
	vec2 tangent = vec2(-grad.y, grad.x);
	float alongBar = dot(p, tangent);
	float longCurve = alongBar * ]] .. f(long_curve) .. [[;

	vec3 N = normalize(vec3(
		grad * profileSlope + tangent * longCurve,
		1.0
	));

	vec3 L = normalize(vec3(]] .. f(light_x) .. [[, ]] .. f(light_y) .. [[, ]] .. f(light_z) .. [[));
	vec3 V = vec3(0.0, 0.0, 1.0);
	vec3 H = normalize(L + V);

	float NdotL = max(dot(N, L), 0.0);
	float NdotH = max(dot(N, H), 0.0);
	float spec = pow(NdotH, ]] .. f(specular_power) .. [[);

	vec3 baseColor = vec3(]] .. f(base_color_r) .. [[, ]] .. f(base_color_g) .. [[, ]] .. f(base_color_b) .. [[);
	float ambient = ]] .. f(ambient) .. [[;
	vec3 color = baseColor * (ambient + (1.0 - ambient) * NdotL) + vec3(0.9, 0.9, 0.95) * spec * ]] .. f(specular_strength) .. [[;

	return vec4(color, frameMask);
]]
	)
	-- nine patch derived from frame parameters
	local outer_px = math.ceil(frame_outer * width)
	local inner_px = math.ceil(frame_inner * width) - 2
	local corner_px = math.ceil(corner_radius * width)
	local patch_border = math.max(inner_px, corner_px) + 2 -- +2 for safety margin
	tex.nine_patch = {
		x_stretch = {
			{patch_border, width - patch_border},
		},
		y_stretch = {
			{patch_border, height - patch_border},
		},
		x_content = {
			{inner_px, width - inner_px},
		},
		y_content = {
			{inner_px, height - inner_px},
		},
	}
	return tex
end
