local Texture = require("render.texture")
local tex
return function()
	if tex then return tex end

	local size = 64
	tex = Texture.New(
		{
			width = size,
			height = size,
			format = "r32g32b32a32_sfloat",
			sampler = {
				min_filter = "nearest",
				mag_filter = "nearest",
				wrap_s = "repeat",
				wrap_t = "repeat",
			},
		}
	)
	tex:Shade(
		[[
				return vec4(B(uv*1000.2), B(uv*300.4), 1, 1);
			]],
		{
			header = [[
					// https://www.shadertoy.com/view/tllcR2
					// no sell :-)

					float hash12(vec2 p)
					{
						vec3 p3  = fract(vec3(p.xyx) * .1031);
						p3 += dot(p3, p3.yzx + 33.33);
						return fract((p3.x + p3.y) * p3.z);
					}

					#define hash(p)  fract(sin(dot(p, vec2(11.9898, 78.233))) * 43758.5453) // iq suggestion, for Windows
					float B(vec2 U) {
						float v = 0.;
						for (int k=0; k<9; k++)
							v += hash12( U + vec2(k%3-1,k/3-1) ); 
						return .9 *( 1.125*hash12(U)- v/8.) + .5; // 
					}
				]],
		}
	)
end
