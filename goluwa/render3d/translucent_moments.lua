local render3d = import("goluwa/render3d/render3d.lua")
-- what the passes that write and read the translucent moments share: the glsl, the blend states of
-- the attachments and the depth warp, which maps a distance to what the moments are stored in
local translucent_moments = {}

translucent_moments.GLSL = [[
	float moments_warp_depth(float distance, vec2 warp) {
		return clamp(log(max(distance, 1e-4)) * warp.x + warp.y, -1.0, 1.0);
	}

	// the transmittance of everything in front of depth. b0 is the summed
	// absorbance, moments its weighted depth, depth², depth³ and depth⁴. a
	// surface counts a quarter of itself as in front of it, so the summed
	// weights never vanish
	float moments_transmittance(float b0, vec4 moments, float depth) {
		if (b0 < 0.00100050033) return 1.0;

		vec4 b = mix(moments / b0, vec4(0.0, 0.375, 0.0, 0.375), 5e-7);
		float L21D11 = fma(-b.x, b.y, b.z);
		float D11 = fma(-b.x, b.x, b.y);
		float inv_D11 = 1.0 / D11;
		float L21 = L21D11 * inv_D11;
		float D22 = fma(-L21D11, L21, fma(-b.y, b.y, b.w));
		vec3 c = vec3(1.0, depth, depth * depth);
		c.y -= b.x;
		c.z -= b.y + L21 * c.y;
		c.y *= inv_D11;
		c.z /= D22;
		c.y -= L21 * c.z;
		c.x -= dot(c.yz, b.xy);
		float p = c.y / c.z;
		float q = c.x / c.z;
		float r = sqrt(p * p * 0.25 - q);
		vec3 z = vec3(depth, -p * 0.5 - r, -p * 0.5 + r);
		vec3 f = vec3(0.25, z.y < z.x ? 1.0 : 0.0, z.z < z.x ? 1.0 : 0.0);
		float f01 = (f.y - f.x) / (z.y - z.x);
		float f12 = (f.z - f.y) / (z.z - z.y);
		float f012 = (f12 - f01) / (z.z - z.x);
		float p0 = f01 - f012 * z.y;
		float p1 = p0 - f012 * z.x;
		p0 = f.x - p0 * z.x;
		return clamp(exp(-b0 * (p0 + b.x * p1 + b.y * f012)), 0.0, 1.0);
	}
]]

function translucent_moments.WriteDepthWarp(warp)
	local camera = render3d.GetCamera()
	local near = math.clamp(render3d.translucent_depth_near, camera:GetNearZ(), camera:GetFarZ())
	local far = math.max(math.min(render3d.translucent_depth_far, camera:GetFarZ()), near * 1.01)
	local scale = 2 / (math.log(far) - math.log(near))
	warp[0] = scale
	warp[1] = -math.log(near) * scale - 1
end

function translucent_moments.GetTextures()
	local fb = render3d.pipelines.translucent_moments:GetFramebuffer()
	return fb:GetAttachment(1), fb:GetAttachment(2)
end

translucent_moments.ADDITIVE = {
	blend = true,
	src_color_blend_factor = "one",
	dst_color_blend_factor = "one",
	color_blend_op = "add",
	src_alpha_blend_factor = "one",
	dst_alpha_blend_factor = "one",
	alpha_blend_op = "add",
}
translucent_moments.MULTIPLY = {
	blend = true,
	src_color_blend_factor = "zero",
	dst_color_blend_factor = "src_color",
	color_blend_op = "add",
	src_alpha_blend_factor = "zero",
	dst_alpha_blend_factor = "one",
	alpha_blend_op = "add",
}

return translucent_moments
