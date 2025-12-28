local Vec3 = require("structs.vec3")
local shaders = {
	shaders = {
		vertexlitgeneric = {
			["environment map"] = {
				envmapfresnel = {
					type = "float",
					friendly = "Fresnel",
					description = "like $fresnelreflection. requires phong.",
				},
			},
			wrinkle = {
				compress = {
					type = "texture",
					friendly = "Compress",
					description = "compression wrinklemap",
				},
				bumpcompress = {
					type = "texture",
					friendly = "BumpCompress",
					description = "compression bump map",
				},
				bumpstretch = {
					type = "texture",
					friendly = "BumpStretch",
					description = "expansion bump map",
				},
				stretch = {
					type = "texture",
					friendly = "Stretch",
					description = "expansion wrinklemap",
				},
			},
			["sheen map"] = {
				sheenmapmaskoffsetx = {
					type = "float",
					description = "X Offset of the mask relative to model space coords of target",
					default = 0,
					friendly = "MaskOffsetX",
				},
				sheenindex = {
					type = "integer",
					description = "Index of the Effect Type (Color Additive, Override etc...)",
					default = 0,
					friendly = "Index",
				},
				sheenmaptint = {
					type = "color",
					description = "sheenmap tint",
					friendly = "Tint",
				},
				sheenmapmaskoffsety = {
					type = "float",
					description = "Y Offset of the mask relative to model space coords of target",
					default = 0,
					friendly = "MaskOffsetY",
				},
				sheenpassenabled = {
					type = "bool",
					description = "Enables weapon sheen render in a second pass",
					default = false,
					friendly = "Enable",
				},
				sheenmapmask = {
					type = "texture",
					description = "sheenmap mask",
					friendly = "Mask",
				},
				sheenmapmaskscalex = {
					type = "float",
					description = "X Scale the size of the map mask to the size of the target",
					default = 1,
					friendly = "MaskScaleX",
				},
				sheenmapmaskscaley = {
					type = "float",
					description = "Y Scale the size of the map mask to the size of the target",
					default = 1,
					friendly = "MaskScaleY",
				},
				sheenmap = {
					type = "texture",
					description = "sheenmap",
				},
				sheenmapmaskframe = {
					type = "integer",
					description = "",
					default = 0,
					friendly = "MaskFrame",
					linked = "sheenmap",
				},
				sheenmapmaskdirection = {
					type = "integer",
					description = "The direction the sheen should move (length direction of weapon) XYZ, 0,1,2",
					default = 0,
					friendly = "Direction",
				},
			},
			["rim lighting"] = {
				rimlightboost = {
					type = "float",
					friendly = "Boost",
					default = 0,
					description = "Boost for rim lights",
				},
				rimmask = {
					type = "bool",
					friendly = "ExponentAlphaMask",
					default = false,
					description = "Indicates whether or not to use alpha channel of exponent texture to mask the rim term",
				},
				rimlight = {
					type = "bool",
					default = false,
					description = "enables rim lighting",
					friendly = "Enable",
				},
				rimlightexponent = {
					type = "float",
					friendly = "Exponent",
					default = 0,
					description = "Exponent for rim lights",
				},
			},
			phong = {
				albedo = {
					type = "texture",
					friendly = "Albedo",
					description = "albedo (Base texture with no baked lighting)",
				},
				basemapalphaphongmask = {
					type = "bool",
					friendly = "BaseMapAlphaPhongMask",
					default = false,
					description = "indicates that there is no normal map and that the phong mask is in base alpha",
				},
				invertphongmask = {
					type = "bool",
					friendly = "InvertPhongMask",
					default = false,
					description = "invert the phong mask (0=full phong, 1=no phong)",
				},
				phongexponenttexture = {
					type = "texture",
					friendly = "Exponent",
					description = "Phong Exponent map",
				},
				phongwarptexture = {
					type = "texture",
					friendly = "Warp",
					description = "warp the specular term",
				},
			},
			flesh = {
				fleshcubetexture = {
					type = "texture",
					friendly = "CubeTexture",
					description = "Flesh cubemap texture",
				},
				flesheffectcenterradius3 = {
					type = "vec4",
					friendly = "EffectCenterRadius3",
					default = "[ 0 0 0 0 ]",
					description = "Flesh effect center and radius",
				},
				fleshglossbrightness = {
					type = "float",
					friendly = "GlossBrightness",
					default = 0,
					description = "Flesh gloss brightness",
				},
				fleshsubsurfacetint = {
					type = "color",
					friendly = "SubsurfaceTint",
					default = Vec3(1, 1, 1),
					description = "Subsurface Color",
				},
				fleshbordersoftness = {
					type = "float",
					friendly = "BorderSoftness",
					default = 0,
					description = "Flesh border softness (> 0.0 && <= 0.5)",
				},
				fleshdebugforcefleshon = {
					type = "bool",
					friendly = "DebugForceFleshOn",
					default = false,
					description = "Flesh Debug full flesh",
				},
				fleshbordertexture1d = {
					type = "texture",
					friendly = "BorderTexture1D",
					description = "Flesh border 1D texture",
				},
				flesheffectcenterradius1 = {
					type = "vec4",
					friendly = "EffectCenterRadius1",
					default = "[ 0 0 0 0 ]",
					description = "Flesh effect center and radius",
				},
				flesheffectcenterradius4 = {
					type = "vec4",
					friendly = "EffectCenterRadius4",
					default = "[ 0 0 0 0 ]",
					description = "Flesh effect center and radius",
				},
				fleshinteriorenabled = {
					friendly = "InteriorEnabled",
					type = "bool",
					description = "Enable Flesh interior blend pass",
					default = false,
				},
				fleshbordernoisescale = {
					type = "float",
					friendly = "BorderNoiseScale",
					default = 0,
					description = "Flesh Noise UV scalar for border",
				},
				fleshsubsurfacetexture = {
					type = "texture",
					friendly = "SubsurfaceTexture",
					description = "Flesh subsurface texture",
				},
				fleshglobalopacity = {
					type = "float",
					friendly = "GlobalOpacity",
					default = 0,
					description = "Flesh global opacity",
				},
				fleshinteriortexture = {
					type = "texture",
					friendly = "Texture",
					description = "Flesh color texture",
				},
				fleshborderwidth = {
					type = "float",
					friendly = "BorderWidth",
					default = 0,
					description = "Flesh border",
				},
				fleshbordertint = {
					type = "color",
					friendly = "BorderTint",
					default = Vec3(1, 1, 1),
					description = "Flesh border Color",
				},
				fleshscrollspeed = {
					type = "float",
					friendly = "ScrollSpeed",
					default = 0,
					description = "Flesh scroll speed",
				},
				flesheffectcenterradius2 = {
					type = "vec4",
					friendly = "EffectCenterRadius2",
					default = "[ 0 0 0 0 ]",
					description = "Flesh effect center and radius",
				},
				fleshinteriornoisetexture = {
					type = "texture",
					friendly = "NoiseTexture",
					description = "Flesh noise texture",
				},
				fleshnormaltexture = {
					type = "texture",
					friendly = "NormalTexture",
					description = "Flesh normal texture",
				},
			},
			["self illumination"] = {
				selfillumfresnel = {
					type = "bool",
					friendly = "Fresnel",
					default = false,
					description = "Self illum fresnel",
				},
				selfillum_envmapmask_alpha = {
					type = "float",
					friendly = "EnvMapMaskAlpha",
					default = 0,
					description = "defines that self illum value comes from env map mask alpha",
				},
				selfillumfresnelminmaxexp = {
					type = "vec4",
					friendly = "FresnelMinMaxExp",
					default = "[ 0 0 0 0 ]",
					description = "Self illum fresnel min, max, exp",
				},
				selfillum = {
					is_flag = true,
					type = "integer",
					default = false,
					description = "flag",
				},
				selfillummask = {
					type = "texture",
					friendly = "Mask",
					description = "If we bind a texture here, it overrides base alpha (if any) for self illum",
				},
				selfillumtint = {
					type = "color",
					friendly = "Tint",
					default = Vec3(1, 1, 1),
					description = "Self-illumination tint",
				},
			},
			generic = {
				color2 = {
					type = "color",
					friendly = "Color2",
					default = Vec3(1, 1, 1),
					description = "color2",
				},
				opaquetexture = {
					is_flag = true,
					type = "integer",
					friendly = "OpaqueTexture",
					default = false,
					description = "flag",
				},
				noalphamod = {
					is_flag = true,
					type = "integer",
					friendly = "NoAlphaMod",
					default = false,
					description = "flag",
				},
				znearer = {
					is_flag = true,
					type = "integer",
					friendly = "Znearer",
					default = false,
					description = "flag",
				},
				additive = {
					is_flag = true,
					type = "integer",
					friendly = "Additive",
					default = false,
					description = "flag",
				},
				nocull = {
					is_flag = true,
					type = "integer",
					friendly = "NoCull",
					default = false,
					description = "flag",
				},
				ignore_alpha_modulation = {
					is_flag = true,
					type = "integer",
					friendly = "IgnoreAlphaModulation",
					default = false,
					description = "flag",
				},
				color = {
					type = "color",
					friendly = "Color",
					default = Vec3(1, 1, 1),
					description = "color",
				},
				no_draw = {
					is_flag = true,
					type = "integer",
					friendly = "NoDraw",
					default = false,
					description = "flag",
				},
				suppress_decals = {
					is_flag = true,
					type = "integer",
					friendly = "SuppressDecals",
					default = false,
					description = "flag",
				},
				lightwarptexture = {
					type = "texture",
					friendly = "LightWarpTexture",
					description = "1D ramp texture for tinting scalar diffuse term",
				},
				use_in_fillrate_mode = {
					is_flag = true,
					type = "integer",
					friendly = "UseInFillrateMode",
					default = false,
					description = "flag",
				},
				halflambert = {
					is_flag = true,
					type = "bool",
					friendly = "HalfLambert",
					default = false,
					description = "flag",
				},
				ambientonly = {
					type = "bool",
					friendly = "AmbientOnly",
					default = false,
					description = "Control drawing of non-ambient light ()",
				},
				ignorez = {
					is_flag = true,
					type = "integer",
					friendly = "Ignorez",
					default = false,
					description = "flag",
				},
				nofog = {
					is_flag = true,
					type = "integer",
					friendly = "Nofog",
					default = false,
					description = "flag",
				},
				nolod = {
					type = "bool",
					default = false,
					description = "flag",
					friendly = "NoLod",
				},
				decal = {
					is_flag = true,
					type = "integer",
					friendly = "Decal",
					default = false,
					description = "flag",
				},
				allowalphatocoverage = {
					is_flag = true,
					type = "integer",
					friendly = "AllowAlphaToCoverage",
					default = false,
					description = "flag",
				},
				model = {
					is_flag = true,
					type = "integer",
					friendly = "Model",
					default = false,
					description = "flag",
				},
				multipass = {
					is_flag = true,
					type = "integer",
					friendly = "Multipass",
					default = false,
					description = "flag",
				},
				debug = {
					is_flag = true,
					type = "integer",
					friendly = "Debug",
					default = false,
					description = "flag",
				},
				wireframe = {
					is_flag = true,
					type = "integer",
					friendly = "Wireframe",
					default = false,
					description = "flag",
				},
				translucent = {
					is_flag = true,
					type = "integer",
					friendly = "Translucent",
					default = false,
					description = "flag",
				},
				flat = {
					is_flag = true,
					type = "integer",
					friendly = "Flat",
					default = false,
					description = "flag",
				},
				allowdiffusemodulation = {
					type = "bool",
					default = true,
					friendly = "AllowDiffuseModulation",
					description = "Prevents the material from being tinted.",
				},
			},
			["bump map"] = {
				bumpmap = {
					type = "texture",
					friendly = "BumpMap",
					description = "bump map",
					default = "null-bumpmap",
				},
				bumpframe = {
					type = "integer",
					friendly = "Frame",
					default = 0,
					description = "The frame to start an animated bump map on.",
					linked = "bumpmap",
				},
				bumptransform = {
					type = "matrix",
					friendly = "Transform",
					description = "Transforms the bump map texture.",
				},
				nodiffusebumplighting = {
					type = "bool",
					friendly = "NoDiffuseLighting",
					default = false,
					description = "Stops the bump map affecting the lighting of the material's albedo, which help combat overdraw. Does not affect the specular map.",
				},
			},
			seamless = {
				seamless_scale = {
					type = "float",
					friendly = "Scale",
					default = 0,
					description = "the scale for the seamless mapping. # of repetions of texture per inch.",
				},
				seamless_detail = {
					type = "bool",
					friendly = "Detail",
					default = false,
					description = "where to apply seamless mapping to the detail texture.",
				},
				seamless_base = {
					type = "bool",
					friendly = "Base",
					default = false,
					description = "whether to apply seamless mapping to the base texture. requires a smooth model.",
				},
			},
			cloak = {
				cloakpassenabled = {
					friendly = "Enable",
					type = "bool",
					description = "Enables cloak render in a second pass",
					default = false,
				},
				cloakfactor = {
					friendly = "Factor",
					type = "float",
					description = "",
					default = 0,
				},
				cloakcolortint = {
					friendly = "ColorTint",
					type = "color",
					description = "Cloak color tint",
					default = Vec3(1, 1, 1),
				},
				refractamount = {
					type = "float",
					friendly = "RefractAmount",
					default = 0.5,
					description = "How strong the refraction effect should be when the material is partially cloaked (default = 2).",
				},
			},
			blend = {
				blendtintbybasealpha = {
					type = "bool",
					friendly = "TintByBaseAlpha",
					default = false,
					description = "Use the base alpha to blend in the $color modulation",
				},
				blendtintcoloroverbase = {
					friendly = "TintColorOverBase",
					type = "float",
					description = "blend between tint acting as a multiplication versus a replace",
					default = 0,
				},
			},
			detail = {
				detail = {
					type = "texture",
					description = "detail texture",
				},
				detailtint = {
					type = "color",
					friendly = "Tint",
					default = Vec3(1, 1, 1),
					description = "detail texture tint",
				},
			},
			["emissive blend"] = {
				emissiveblendstrength = {
					type = "float",
					friendly = "Strength",
					default = 0,
					description = "Emissive blend strength",
				},
				emissiveblendbasetexture = {
					type = "texture",
					friendly = "BaseTexture",
					description = "self-illumination map",
				},
				emissiveblendenabled = {
					friendly = "Enabled",
					type = "bool",
					description = "Enable emissive blend pass",
					default = false,
				},
				emissiveblendtexture = {
					type = "texture",
					friendly = "Texture",
					description = "self-illumination map",
				},
				emissiveblendflowtexture = {
					type = "texture",
					friendly = "FlowTexture",
					description = "flow map",
				},
				emissiveblendtint = {
					type = "color",
					friendly = "Tint",
					default = Vec3(1, 1, 1),
					description = "Self-illumination tint",
				},
				emissiveblendscrollVec3 = {
					type = "vec2",
					friendly = "ScrollVec3",
					description = "Emissive scroll vec",
					default = Vec3(0, 0),
				},
			},
		},
	},
	base = {
		["base texture"] = {
			basetexture = {
				type = "texture",
				description = "Base Texture with lighting built in",
				default = "models/debug/debugwhite",
			},
			basetexturetransform = {
				type = "matrix",
				friendly = "Transform",
				description = "Base Texture Texcoord Transform",
			},
			frame = {
				type = "integer",
				friendly = "Frame",
				default = 0,
				description = "Base Texture Animation Frame",
				linked = "basetexture",
			},
		},
		detail = {
			detail = {
				type = "texture",
				friendly = "Texture",
				description = "detail texture",
			},
			detailblendfactor = {
				type = "float",
				friendly = "BlendFactor",
				default = 1,
				description = "blend amount for detail texture.",
			},
			detailframe = {
				type = "integer",
				friendly = "Frame",
				default = 0,
				description = "frame number for $detail",
				linked = "detail",
			},
			detailblendmode = {
				recompute = true,
				type = "integer",
				friendly = "BlendMode",
				default = 0,
				description = "mode for combining detail texture with base." .. [[
0 = original mode
1 = ADDITIVE base.rgb+detail.rgb*fblend
2 = alpha blend detail over base
3 = straight fade between base and detail.
4 = use base alpha for blend over detail
5 = add detail color post lighting
6 = TCOMBINE_RGB_ADDITIVE_SELFILLUM_THRESHOLD_FADE 6
7 = use alpha channel of base to select between mod2x channels in r+a of detail
8 = multiply
9 = use alpha channel of detail to mask base
10 = use detail to modulate lighting as an ssbump
11 = detail is an ssbump but use it as an albedo. shader does the magic here - no user needs to specify mode 11
12 = there is no detail texture
]],
			},
			detailscale = {
				type = "float",
				friendly = "SimpleScale",
				default = 1,
				description = "scale of the detail texture",
			},
			detailtexturetransform = {
				type = "matrix",
				friendly = "Transform",
				description = "$detail texcoord transform",
			},
		},
		["depth blend"] = {
			depthblendscale = {
				friendly = "Scale",
				type = "float",
				description = "Amplify or reduce DEPTHBLEND fading. Lower values make harder edges.",
				default = 50,
			},
			depthblend = {
				type = "float",
				description = "fade at intersection boundaries",
				default = 0,
				friendly = "Blend",
			},
		},
		generic = {
			separatedetailuvs = {
				type = "bool",
				friendly = "SeparateDetailUv",
				default = false,
				description = "Use texcoord1 for detail texture",
			},
			alpha = {
				type = "float",
				friendly = "Alpha",
				default = 1,
				description = "alpha",
			},
		},
		srgb = {
			linearwrite = {
				type = "bool",
				friendly = "LinearWrite",
				default = false,
				description = "Disables SRGB conversion of shader results.",
			},
			srgbtint = {
				type = "color",
				friendly = "Tint",
				default = Vec3(1, 1, 1),
				description = "tint value to be applied when running on new-style srgb parts",
			},
		},
		phong = {
			phongtint = {
				type = "color",
				friendly = "Tint",
				description = "Phong tint for local specular lights",
			},
			phongfresnelranges = {
				type = "vec3",
				friendly = "FresnelRanges",
				description = "Parameters for remapping fresnel output",
				default = Vec3(0.05, 0.5, 1),
			},
			phongalbedotint = {
				type = "bool",
				friendly = "AlbedoTint",
				default = false,
				description = "Apply tint by albedo (controlled by spec exponent texture",
			},
			phongexponent = {
				type = "float",
				friendly = "Exponent",
				default = 5,
				description = "Phong exponent for local specular lights",
			},
			phong = {
				type = "bool",
				default = false,
				friendly = "Enable",
				description = "enables phong lighting",
			},
			phongboost = {
				type = "float",
				friendly = "Boost",
				default = 1,
				description = "Phong overbrightening factor (specular mask channel should be authored to account for this)",
			},
		},
		flashlight = {
			flashlighttexture = {
				type = "texture",
				friendly = "Texture",
				description = "flashlight spotlight shape texture",
			},
			flashlightnolambert = {
				type = "bool",
				friendly = "NoLambert",
				default = false,
				description = "Flashlight pass sets N.L=1.0",
			},
			flashlighttextureframe = {
				type = "integer",
				friendly = "Frame",
				default = 0,
				description = "Animation Frame for $flashlight",
				linked = "flashlighttexture",
			},
			receiveflashlight = {
				type = "bool",
				friendly = "ReceiveFlashlight",
				default = false,
				description = "Forces this material to receive flashlights.",
			},
		},
		["alpha test"] = {
			alphatest = {
				is_flag = true,
				type = "integer",
				friendly = "AlphaTest",
				default = false,
				description = "flag",
			},
			alphatestreference = {
				recompute = true,
				type = "float",
				friendly = "Reference",
				default = 0.7,
				description = "",
			},
		},
		["environment map"] = {
			envmapmasktransform = {
				type = "matrix",
				friendly = "MaskTransform",
				description = "$envmapmask texcoord transform",
			},
			envmapsaturation = {
				type = "float",
				friendly = "Saturation",
				default = 1,
				description = "saturation 0 == greyscale 1 == normal",
			},
			envmapcontrast = {
				type = "float",
				friendly = "Contrast",
				default = 0,
				description = "contrast 0 == normal 1 == color*color",
			},
			envmapmask = {
				type = "texture",
				friendly = "Mask",
				description = "envmap mask",
			},
			envmapmaskframe = {
				type = "integer",
				friendly = "MaskFrame",
				default = 0,
				description = "Frame of the animated mask.",
				linked = "envmapmask",
			},
			envmapcameraspace = {
				is_flag = true,
				type = "integer",
				friendly = "CameraSpace",
				default = false,
				description = "flag",
			},
			envmap = {
				type = "texture",
				friendly = "Envmap",
				description = "envmap. won't work if hdr is enabled",
				default = "",
				partial_hdr = true,
			},
			envmapframe = {
				type = "integer",
				friendly = "Frame",
				default = 0,
				description = "envmap frame number",
				linked = "envmap",
			},
			envmapmode = {
				is_flag = true,
				type = "integer",
				friendly = "Mode",
				default = false,
				description = "flag",
			},
			envmaptint = {
				type = "color",
				friendly = "Tint",
				default = Vec3(1, 1, 1),
				description = "envmap tint",
			},
			envmapsphere = {
				is_flag = true,
				type = "integer",
				friendly = "Sphere",
				default = false,
				description = "flag",
			},
			normalmapalphaenvmapmask = {
				is_flag = true,
				type = "integer",
				friendly = "NormalmapAlphaMask",
				default = false,
				description = "flag",
			},
			basealphaenvmapmask = {
				is_flag = true,
				type = "integer",
				friendly = "BaseAlphaMask",
				default = false,
				description = "flag",
			},
		},
		vertex = {
			vertexalpha = {
				is_flag = true,
				type = "bool",
				friendly = "Alpha",
				default = false,
				description = "flag",
			},
			vertexcolor = {
				is_flag = true,
				type = "bool",
				friendly = "Color",
				default = false,
				description = "flag",
			},
		},
	},
}
local tbl = {}

for category_name, category in pairs(shaders.shaders.vertexlitgeneric) do
	for k, v in pairs(category) do
		v.category = category_name
		tbl[k] = v
	end
end

for category_name, category in pairs(shaders.base) do
	for k, v in pairs(category) do
		v.category = category_name
		tbl[k] = v
	end
end

local vlg = {}

function vlg.GetPropertyInfo(str)
	return tbl[str]
end

return vlg
