local T = import("test/environment.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local Material = import("goluwa/render3d/material.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Color = import("goluwa/structs/color.lua")
local decode_pass = {
	name = "gbuffer_decode_test",
	ComputePass = true,
	ColorFormat = {{"r32g32b32a32_sfloat", {"decoded", "rgba"}}},
	FramebufferSize = {x = 9, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 1, z = 1},
	storage_images = {{binding_index = 0, dst_stage = "compute"}},
	uniform_buffers = {
		{
			name = "decode_data",
			binding_index = 1,
			block = {gbuffer_layout.block},
			write = function(self, block)
				return gbuffer_layout.WriteBlock(self, block)
			end,
		},
	},
	custom_declarations = [[
		layout(set = 0, binding = 0, rgba32f) uniform writeonly image2D out_decoded;
	]],
	shader = gbuffer_layout.GetDecodeGLSL("decode_data") .. [[
		void main() {
			int x = int(gl_GlobalInvocationID.x);
			vec2 uv = vec2(0.5);
			ivec2 pixel = textureSize(TEXTURE(decode_data.depth_tex), 0) / 2;
			vec4 value = vec4(0.0);

			if (x == 0) value = vec4(gbuffer_albedo(uv), gbuffer_alpha(uv));
			if (x == 1) value = vec4(gbuffer_normal(uv), gbuffer_specular(uv) * 0.04);
			if (x == 2) value = vec4(gbuffer_metallic(uv), gbuffer_roughness(uv), gbuffer_ao(uv), gbuffer_transmission(uv));
			if (x == 3) value = vec4(gbuffer_transmission_color(uv), gbuffer_transmission_scattering(uv));
			if (x == 4) value = vec4(gbuffer_normal(pixel), gbuffer_specular(pixel) * 0.04);
			if (x == 5) value = vec4(gbuffer_clearcoat(uv), gbuffer_clearcoat_roughness(uv), gbuffer_clearcoat_rain(uv), 0.0);
			if (x == 6) value = vec4(gbuffer_clearcoat_normal(uv), 0.0);

			if (x == 7) value = vec4(gbuffer_secondary_specular(uv), gbuffer_secondary_specular_roughness(uv), gbuffer_sheen(uv), gbuffer_sheen_roughness(uv));
			if (x == 8) value = vec4(gbuffer_specular_tint(uv), 0.0, 0.0, 0.0);

			if (x < 9) imageStore(out_decoded, ivec2(x, 0), value);
		}
	]],
}

local function decode(draw, material)
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			decode_pass,
			import("goluwa/render3d/passes/blit.lua"),
		},
	}
	local camera = render3d.GetCamera()
	camera:SetFOV(math.rad(90))
	camera:SetNearZ(0.1)
	camera:SetFarZ(100)
	camera:SetPosition(Vec3(0, 0, 0))
	camera:SetRotation(Quat():Identity())
	local polygon3d = Polygon3D.New()
	shapes.BuildCube(polygon3d, 1)
	polygon3d:BuildBoundingBox()
	polygon3d:Upload()
	local entity = Entity.New{Name = "gbuffer_encoding_cube"}
	entity:AddComponent("transform")
	entity.transform:SetPosition(Vec3(0, 0, -4))
	entity:AddComponent("visual")
	local primitive = Entity.New{Name = "gbuffer_encoding_cube_primitive", Parent = entity}
	primitive:AddComponent("transform")
	local visual_primitive = primitive:AddComponent("visual_primitive")
	visual_primitive:SetPolygon3D(polygon3d)
	visual_primitive:SetMaterial(material)
	entity.visual:BuildAABB()
	local ok, err = pcall(draw)
	local downloaded = ok and
		render3d.pipelines.gbuffer_decode_test:GetFramebuffer(1):GetAttachment(1):Download()
	entity:Remove()
	polygon3d:Remove()
	render3d.Initialize{
		passes = {
			import("goluwa/render3d/passes/gbuffer.lua"),
			import("goluwa/render3d/passes/blit.lua"),
		},
	}

	if not ok then error(err, 0) end

	local texels = {}

	for x = 0, 8 do
		texels[x] = {downloaded:GetPixelFloat(x, 0)}
	end

	return texels
end

T.Test3D("Graphics render3d gbuffer decodes what the gbuffer pass encoded", function(draw)
	local texels = decode(
		draw,
		Material.New{
			ColorMultiplier = Color(0.5, 0.25, 0.75, 1),
			MetallicMultiplier = 0.25,
			SpecularMultiplier = 1.5,
			DiffuseTransmission = 0.5,
			TransmissionColor = Color(1, 0.6, 0.2, 1),
			TransmissionScattering = 0.4,
			Clearcoat = 0.7,
			ClearcoatRoughness = 0.3,
			SecondarySpecular = 0.6,
			SecondarySpecularRoughness = 0.5,
			Sheen = 0.4,
			SheenRoughness = 0.8,
			SpecularTint = 0.8,
		}
	)
	local albedo, normal, mra, transmission, by_pixel = texels[0], texels[1], texels[2], texels[3], texels[4]
	T(albedo[1])["~"](0.5, 0.02)
	T(albedo[2])["~"](0.25, 0.02)
	T(albedo[3])["~"](0.75, 0.02)
	T(normal[1])["~"](0, 0.01)
	T(normal[2])["~"](0, 0.01)
	T(normal[3])["~"](1, 0.01)
	T(normal[4])["~"](0.06, 0.001)
	T(mra[1])["~"](0.25, 0.01)
	T(mra[4])["~"](0.5, 0.01)
	local lum = 0.2126 + 0.7152 * 0.6 + 0.0722 * 0.2
	T(transmission[1])["~"](1 / lum, 0.07)
	T(transmission[2])["~"](0.6 / lum, 0.07)
	T(transmission[3])["~"](0.2 / lum, 0.07)
	T(transmission[4])["~"](0.4, 0.01)

	local coat, coat_normal = texels[5], texels[6]
	T(coat[1])["~"](0.7, 0.01)
	T(coat[2])["~"](0.09, 0.005)
	T(coat[3])["~"](0, 0.01)
	T(coat_normal[1])["~"](0, 0.01)
	T(coat_normal[2])["~"](0, 0.01)
	T(coat_normal[3])["~"](1, 0.01)

	local lobe, tint = texels[7], texels[8]
	T(lobe[1])["~"](0.6, 0.01)
	T(lobe[2])["~"](0.25, 0.005)
	T(lobe[3])["~"](0.4, 0.01)
	T(lobe[4])["~"](0.8, 0.01)
	T(tint[1])["~"](0.8, 0.01)

	for i = 1, 4 do
		T(by_pixel[i])["~"](normal[i], 1e-4)
	end
end)

T.Test("Graphics render3d gbuffer packs every field into its own slot", function()
	local slots = {}
	T(#gbuffer_layout.targets)["<="](8)

	for _, field in ipairs(gbuffer_layout.fields) do
		T(field.target ~= nil)["=="](true)

		for i = 1, #field.swizzle do
			local slot = field.target.texture .. "." .. field.swizzle:sub(i, i) .. "." .. tostring(field.nibble or "")
			T(slots[slot])["=="](nil)
			slots[slot] = field.name
		end
	end
end)
