local Texture = require("render.texture")
return function(core_thickness, glow_radius, glow_intensity)
	local height = core_thickness + (glow_radius * 2)
	local width = 256
	local glow_line = Texture.New(
		{
			width = width,
			height = height,
			format = "r8g8b8a8_unorm",
			mip_map_levels = 1,
			anisotropy = 0,
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
			},
		}
	)
	local shader_code = string.format(
		[[
        float core_thickness_px = %d.0;
        float glow_radius_px = %d.0;
        float glow_intensity = %f;
        float height_px = %d.0;
        float width_px = %d.0;
        
        // Get pixel position from UV
        float y_px = uv.y * height_px;
        float x_px = uv.x * width_px;
        float center_y_px = height_px * 0.5;
        
        // Distance from center line (vertical)
        float dist_from_center_y = abs(y_px - center_y_px);
        float half_core = core_thickness_px * 0.5;
        
        // Core line alpha (sharp, bright center)
        float core_alpha = 0.0;
        if (dist_from_center_y <= half_core) {
            core_alpha = 1.0;
        }
        
        // Glow alpha (soft falloff)
        float glow_alpha = 0.0;
        if (dist_from_center_y > half_core) {
            float glow_dist = dist_from_center_y - half_core;
            glow_alpha = (1.0 - clamp(glow_dist / glow_radius_px, 0.0, 1.0)) * glow_intensity;
        }
        
        // Combine core and glow
        float alpha_y = max(core_alpha, glow_alpha);
        
        // Horizontal fade at edges
        float dist_from_left = x_px;
        float dist_from_right = width_px - x_px;
        float dist_from_edge = min(dist_from_left, dist_from_right);
        float alpha_x = clamp(dist_from_edge / glow_radius_px, 0.0, 1.0);
        
        float alpha = alpha_y * alpha_x * pow(sin(uv.x * 3.14159265359), 1.5);
        
        return vec4(1.0, 1.0, 1.0, alpha);
    ]],
		core_thickness,
		glow_radius,
		glow_intensity,
		height,
		width
	)
	glow_line:Shade(shader_code)
	return glow_line
end
