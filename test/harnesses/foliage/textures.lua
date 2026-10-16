-- draws the textures of the foliage materials into tmp/foliage_tex_*.png: the albedo (cutouts over a checker), the
-- normal map lit from the top left and the roughness (black is smooth): luajit glw --2d --background lua test/harnesses/foliage/textures.lua
local system = import("goluwa/system.lua")
local textures = import("lua/foliage/textures.lua")
local Texture = import("goluwa/render/texture.lua")
local PREVIEW = [[
vec4 shade(vec2 uv, vec3 dir) {
	Surface s = surface_at(uv);
	vec2 cell = floor(uv * SIZE / 16.0);
	vec3 bg = mod(cell.x + cell.y, 2.0) < 1.0 ? vec3(0.25, 0.25, 0.3) : vec3(0.4, 0.4, 0.45);
	bg = pow(bg, vec3(2.2));
	return vec4(mix(bg, s.albedo, s.alpha), 1.0);
}
]]
local NORMAL = [[
vec4 shade(vec2 uv, vec3 dir) {
	// lit from the top left
	float light = clamp(dot(surface_normal(uv), normalize(vec3(-0.5, -0.5, 0.7))), 0.0, 1.0);
	return vec4(vec3(pow(light, 2.2)), 1.0);
}
]]
-- the roughness, black is smooth, over a checker where the cutouts are clear
local ROUGHNESS = [[
vec4 shade(vec2 uv, vec3 dir) {
	Surface s = surface_at(uv);
	vec2 cell = floor(uv * SIZE / 16.0);
	vec3 bg = mod(cell.x + cell.y, 2.0) < 1.0 ? vec3(0.1, 0.0, 0.1) : vec3(0.2, 0.0, 0.2);
	return vec4(mix(bg, vec3(pow(s.roughness, 2.2)), s.alpha), 1.0);
}
]]
-- the textures of the registered materials, ONLY=bark draws the ones whose material name has bark in it
local foliage = import("lua/foliage/foliage.lua")
local only = os.getenv("ONLY")
local names = {}

for name in pairs(foliage.materials) do
	if not only or name:find(only, 1, true) then names[#names + 1] = name end
end

table.sort(names)

for _, name in ipairs(names) do
	for _, view in ipairs{{"albedo", PREVIEW}, {"normal", NORMAL}, {"roughness", ROUGHNESS}} do
		local texture = foliage.materials[name].textures[view[1]]

		if texture then
			local source, resolved = textures.GetSource(texture[1], texture[2])
			local tex = Texture.New{width = resolved.width, height = resolved.height, format = "r8g8b8a8_srgb", mip_map_levels = 1}
			tex:Shade(source .. view[2])
			print(tex:Download():SaveWithoutAlpha("tmp/foliage_tex_" .. name .. "_" .. view[1] .. ".png"))
		end
	end
end

system.ShutDown(0)
