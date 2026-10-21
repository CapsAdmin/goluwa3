local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec4 = import("goluwa/structs/vec4.lua")
local ray = "InvalidateRayMaterial"
return {
	name = "detail",
	category = "Detail",
	block = "own",
	active = function(material)
		return material:GetAlbedo2Texture() ~= nil or
			material:GetNormal2Texture() ~= nil or
			material:GetBlendTexture() ~= nil or
			material:GetDetailTexture() ~= nil or
			material:GetGroundColorTexture() ~= nil or
			material.has_uv_transform
	end,
	params = {
		{
			name = "Albedo2Texture",
			kind = "texture",
			type = "render_texture",
			callback = ray,
			requires = "AlbedoTexture",
		},
		{
			name = "Normal2Texture",
			kind = "texture",
			type = "render_texture",
			requires = "NormalTexture",
		},
		{
			name = "BlendTexture",
			kind = "texture",
			type = "render_texture",
			callback = ray,
			requires = "Albedo2Texture",
		},
		{
			name = "DetailTexture",
			kind = "texture",
			type = "render_texture",
			requires = "AlbedoTexture",
		},
		{
			name = "DetailTiling",
			kind = "vec2",
			default = Vec2(1.0, 1.0),
			requires = "DetailTexture",
		},
		{name = "DetailBumpScale", default = 1.0, requires = "DetailTexture"},
		{name = "DetailBlendAmount", default = 0.0, requires = "DetailTexture"},
		{
			name = "MultiplyAlbedo2",
			default = false,
			callback = "InvalidateFlags",
			requires = "Albedo2Texture",
			block = false,
		},
		{
			name = "BlendTintByBaseAlpha",
			default = false,
			callback = "InvalidateFlags",
			requires = "AlbedoTexture",
			block = false,
		},
		{
			name = "GroundColorTexture",
			kind = "texture",
			type = "render_texture",
			category = "Ground Color",
		},
		{name = "GroundColorBlend", default = 0.0, requires = "GroundColorTexture"},
		{
			name = "GroundColorUV",
			kind = "vec4",
			default = Color(1.0, 0.0, 0.0, 1.0),
			requires = "GroundColorTexture",
		},
		{
			name = "BaseTextureTransformU",
			kind = "vec4",
			default = Vec4(1, 0, 0, 0),
			callback = ray,
			category = "Texture Transforms",
		},
		{
			name = "BaseTextureTransformV",
			kind = "vec4",
			default = Vec4(0, 1, 0, 0),
			callback = ray,
		},
		{
			name = "BumpTransformU",
			kind = "vec4",
			default = Vec4(1, 0, 0, 0),
			callback = ray,
		},
		{
			name = "BumpTransformV",
			kind = "vec4",
			default = Vec4(0, 1, 0, 0),
			callback = ray,
		},
		{
			name = "Texture2TransformU",
			kind = "vec4",
			default = Vec4(1, 0, 0, 0),
			callback = ray,
			requires = "Albedo2Texture",
		},
		{
			name = "Texture2TransformV",
			kind = "vec4",
			default = Vec4(0, 1, 0, 0),
			callback = ray,
			requires = "Albedo2Texture",
		},
	},
}
