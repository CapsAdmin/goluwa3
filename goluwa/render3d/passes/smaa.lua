local Vec2 = require("structs.vec2")
local system = require("system")
local render3d = require("render3d.render3d")
return {
	{
		name = "smaa_edge",
		color_format = {{"r8g8_unorm", {"color", "rg"}}},
		fragment = {
			push_constants = {
				{
					name = "smaa",
					block = {
						{
							"tex",
							"int",
							function(self, block, key)
								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
							end,
						},
					},
				},
			},
			shader = [[
			#define SMAA_THRESHOLD 0.1
			#define SMAA_LOCAL_CONTRAST_ADAPTATION_FACTOR 2.0
			
			void main() {
				vec2 texcoord = in_uv;
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(pc.smaa.tex), 0));
				
				// Calculate lumas (using BT.709 weights like reference):
				vec3 weights = vec3(0.2126, 0.7152, 0.0722);
				float L = dot(texture(TEXTURE(pc.smaa.tex), texcoord).rgb, weights);
				
				float Lleft = dot(texture(TEXTURE(pc.smaa.tex), texcoord + vec2(-texel.x, 0.0)).rgb, weights);
				float Ltop = dot(texture(TEXTURE(pc.smaa.tex), texcoord + vec2(0.0, -texel.y)).rgb, weights);
				
				// We do the usual threshold:
				vec4 delta;
				delta.xy = abs(L - vec2(Lleft, Ltop));
				vec2 edges = step(SMAA_THRESHOLD, delta.xy);
				
				// Then discard if there is no edge:
				if (dot(edges, vec2(1.0, 1.0)) == 0.0)
					discard;
				
				// Calculate right and bottom deltas:
				float Lright = dot(texture(TEXTURE(pc.smaa.tex), texcoord + vec2(texel.x, 0.0)).rgb, weights);
				float Lbottom = dot(texture(TEXTURE(pc.smaa.tex), texcoord + vec2(0.0, texel.y)).rgb, weights);
				delta.zw = abs(L - vec2(Lright, Lbottom));
				
				// Calculate the maximum delta in the direct neighborhood:
				vec2 maxDelta = max(delta.xy, delta.zw);
				
				// Calculate left-left and top-top deltas:
				float Lleftleft = dot(texture(TEXTURE(pc.smaa.tex), texcoord + vec2(-2.0 * texel.x, 0.0)).rgb, weights);
				float Ltoptop = dot(texture(TEXTURE(pc.smaa.tex), texcoord + vec2(0.0, -2.0 * texel.y)).rgb, weights);
				delta.zw = abs(vec2(Lleft, Ltop) - vec2(Lleftleft, Ltoptop));
				
				// Calculate the final maximum delta:
				maxDelta = max(maxDelta.xy, delta.zw);
				float finalDelta = max(maxDelta.x, maxDelta.y);
				
				// Local contrast adaptation:
				edges.xy *= step(finalDelta, SMAA_LOCAL_CONTRAST_ADAPTATION_FACTOR * delta.xy);
				
				set_color(edges);
			}
		]],
		},
	},
	{
		name = "smaa_weight",
		color_format = {{"r8g8b8a8_unorm", {"color", "rgba"}}},
		fragment = {
			push_constants = {
				{
					name = "smaa",
					block = {
						{
							"edges_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.smaa_edge:GetFramebuffer():GetAttachment(1))
							end,
						},
						{
							"area_tex",
							"int",
							function()
								local tex = require("render.textures.smaa_area_tex")
								return function(self, block, key)
									block[key] = self:GetTextureIndex(tex)
								end
							end,
						},
						{
							"search_tex",
							"int",
							function()
								local tex = require("render.textures.smaa_search_tex")
								return function(self, block, key)
									block[key] = self:GetTextureIndex(tex)
								end
							end,
						},
					},
				},
			},
			shader = [[
			#define SMAA_MAX_SEARCH_STEPS 16
			#define SMAA_AREATEX_MAX_DISTANCE 16.0
			#define SMAA_AREATEX_PIXEL_SIZE (1.0 / vec2(160.0, 560.0))
			#define SMAA_AREATEX_SUBTEX_SIZE (1.0 / 7.0)
			#define SMAA_SEARCHTEX_SIZE vec2(66.0, 33.0)
			#define SMAA_SEARCHTEX_PACKED_SIZE vec2(64.0, 16.0)

			float SMAASearchLength(vec2 e, float offset) {
				// The texture is flipped vertically, with left and right cases taking half
				// of the space horizontally:
				vec2 scale = SMAA_SEARCHTEX_SIZE * vec2(0.5, -1.0);
				vec2 bias = SMAA_SEARCHTEX_SIZE * vec2(offset, 1.0);
				
				// Scale and bias to access texel centers:
				scale += vec2(-1.0, 1.0);
				bias += vec2(0.5, -0.5);
				
				// Convert from pixel coordinates to texcoords:
				scale *= 1.0 / SMAA_SEARCHTEX_PACKED_SIZE;
				bias *= 1.0 / SMAA_SEARCHTEX_PACKED_SIZE;
				
				return textureLod(TEXTURE(pc.smaa.search_tex), e * scale + bias, 0.0).r;
			}

			float SMAASearchXLeft(vec2 texcoord, float end) {
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(pc.smaa.edges_tex), 0));
				// @PSEUDO_GATHER4
				// This texcoord has been offset by (-0.25, -0.125) to sample between edges
				vec2 e = vec2(0.0, 1.0);
				while (texcoord.x > end && 
				       e.g > 0.8281 && // Is there some edge not activated?
				       e.r == 0.0) { // Or is there a crossing edge that breaks the line?
					e = textureLod(TEXTURE(pc.smaa.edges_tex), texcoord, 0.0).rg;
					texcoord.x -= 2.0 * texel.x;
				}
				float offset = -(255.0 / 127.0) * SMAASearchLength(e, 0.0) + 3.25;
				return texcoord.x + offset * texel.x;
			}

			float SMAASearchXRight(vec2 texcoord, float end) {
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(pc.smaa.edges_tex), 0));
				vec2 e = vec2(0.0, 1.0);
				while (texcoord.x < end && 
				       e.g > 0.8281 && 
				       e.r == 0.0) {
					e = textureLod(TEXTURE(pc.smaa.edges_tex), texcoord, 0.0).rg;
					texcoord.x += 2.0 * texel.x;
				}
				float offset = -(255.0 / 127.0) * SMAASearchLength(e, 0.5) + 3.25;
				return texcoord.x - offset * texel.x;
			}

			float SMAASearchYUp(vec2 texcoord, float end) {
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(pc.smaa.edges_tex), 0));
				vec2 e = vec2(1.0, 0.0);
				while (texcoord.y > end && 
				       e.r > 0.8281 && 
				       e.g == 0.0) {
					e = textureLod(TEXTURE(pc.smaa.edges_tex), texcoord, 0.0).rg;
					texcoord.y -= 2.0 * texel.y;
				}
				float offset = -(255.0 / 127.0) * SMAASearchLength(e.gr, 0.0) + 3.25;
				return texcoord.y + offset * texel.y;
			}

			float SMAASearchYDown(vec2 texcoord, float end) {
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(pc.smaa.edges_tex), 0));
				vec2 e = vec2(1.0, 0.0);
				while (texcoord.y < end && 
				       e.r > 0.8281 && 
				       e.g == 0.0) {
					e = textureLod(TEXTURE(pc.smaa.edges_tex), texcoord, 0.0).rg;
					texcoord.y += 2.0 * texel.y;
				}
				float offset = -(255.0 / 127.0) * SMAASearchLength(e.gr, 0.5) + 3.25;
				return texcoord.y - offset * texel.y;
			}

			vec2 SMAAArea(vec2 dist, float e1, float e2, float offset) {
				// Rounding prevents precision errors of bilinear filtering:
				vec2 texcoord = SMAA_AREATEX_MAX_DISTANCE * round(4.0 * vec2(e1, e2)) + dist;
				
				// We do a scale and bias for mapping to texel space:
				texcoord = SMAA_AREATEX_PIXEL_SIZE * (texcoord + 0.5);
				
				// Move to proper place, according to the subpixel offset:
				texcoord.y = SMAA_AREATEX_SUBTEX_SIZE * offset + texcoord.y;
				
				return textureLod(TEXTURE(pc.smaa.area_tex), texcoord, 0.0).rg;
			}

			void main() {
				vec2 texcoord = in_uv;
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(pc.smaa.edges_tex), 0));
				vec2 pixcoord = texcoord / texel; // Convert to pixel coordinates
				
				// Pre-calculate offsets (normally done in vertex shader):
				// offset[0] = texcoord.xyxy + texel.xyxy * vec4(-0.25, -0.125, 1.25, -0.125)
				// offset[1] = texcoord.xyxy + texel.xyxy * vec4(-0.125, -0.25, -0.125, 1.25)
				// offset[2] = vec4(-2, 2, -2, 2) * SMAA_MAX_SEARCH_STEPS * texel.xxyy + vec4(offset[0].xz, offset[1].yw)
				vec4 offset0 = texcoord.xyxy + texel.xyxy * vec4(-0.25, -0.125, 1.25, -0.125);
				vec4 offset1 = texcoord.xyxy + texel.xyxy * vec4(-0.125, -0.25, -0.125, 1.25);
				vec4 offset2 = vec4(-2.0, 2.0, -2.0, 2.0) * float(SMAA_MAX_SEARCH_STEPS) * texel.xxyy + vec4(offset0.xz, offset1.yw);
				
				vec4 weights = vec4(0.0);
				vec2 e = textureLod(TEXTURE(pc.smaa.edges_tex), texcoord, 0.0).rg;
				
				if (e.g > 0.0) { // Edge at north (horizontal edge)
					vec2 d;
					
					// Find the distance to the left:
					vec3 coords;
					coords.x = SMAASearchXLeft(offset0.xy, offset2.x);
					coords.y = offset1.y; // texcoord.y - 0.25 * texel.y
					d.x = coords.x;
					
					// Fetch the left crossing edges:
					float e1 = textureLod(TEXTURE(pc.smaa.edges_tex), coords.xy, 0.0).r;
					
					// Find the distance to the right:
					coords.z = SMAASearchXRight(offset0.zw, offset2.y);
					d.y = coords.z;
					
					// We want the distances to be in pixel units:
					d = abs(round(d / texel.x - pixcoord.x));
					
					// SMAAArea below needs a sqrt, as the areas texture is compressed quadratically:
					vec2 sqrt_d = sqrt(d);
					
					// Fetch the right crossing edges:
					float e2 = textureLod(TEXTURE(pc.smaa.edges_tex), vec2(coords.z + texel.x, coords.y), 0.0).r;
					
					// Ok, we know how this pattern looks like, now it is time for getting the actual area:
					weights.rg = SMAAArea(sqrt_d, e1, e2, 0.0);
				}

				if (e.r > 0.0) { // Edge at west (vertical edge)
					vec2 d;
					
					// Find the distance to the top:
					vec3 coords;
					coords.y = SMAASearchYUp(offset1.xy, offset2.z);
					coords.x = offset0.x; // texcoord.x - 0.25 * texel.x
					d.x = coords.y;
					
					// Fetch the top crossing edges:
					float e1 = textureLod(TEXTURE(pc.smaa.edges_tex), coords.xy, 0.0).g;
					
					// Find the distance to the bottom:
					coords.z = SMAASearchYDown(offset1.zw, offset2.w);
					d.y = coords.z;
					
					// We want the distances to be in pixel units:
					d = abs(round(d / texel.y - pixcoord.y));
					
					// SMAAArea below needs a sqrt, as the areas texture is compressed quadratically:
					vec2 sqrt_d = sqrt(d);
					
					// Fetch the bottom crossing edges:
					float e2 = textureLod(TEXTURE(pc.smaa.edges_tex), vec2(coords.x, coords.z + texel.y), 0.0).g;
					
					// Get the area for this direction:
					weights.ba = SMAAArea(sqrt_d, e1, e2, 0.0);
				}

				set_color(weights);
			}
		]],
		},
	},
	{
		name = "smaa_blend",
		color_format = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			push_constants = {
				{
					name = "smaa",
					block = {
						{
							"color_tex",
							"int",
							function(self, block, key)
								local current_idx = system.GetFrameNumber() % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(current_idx):GetAttachment(1))
							end,
						},
						{
							"weight_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.smaa_weight:GetFramebuffer():GetAttachment(1))
							end,
						},
					},
				},
			},
			shader = [[
			void main() {
				vec2 texcoord = in_uv;
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(pc.smaa.color_tex), 0));
				
				// Offset for fetching neighbor blend weights:
				// offset.xy = texcoord + vec2(texel.x, 0)  -> Right
				// offset.zw = texcoord + vec2(0, texel.y)  -> Top (in UV, top is +Y)
				vec4 offset = vec4(texcoord + vec2(texel.x, 0.0), texcoord + vec2(0.0, texel.y));
				
				// Fetch the blending weights for current pixel:
				vec4 a;
				a.x = texture(TEXTURE(pc.smaa.weight_tex), offset.xy).a; // Right
				a.y = texture(TEXTURE(pc.smaa.weight_tex), offset.zw).g; // Top
				a.wz = texture(TEXTURE(pc.smaa.weight_tex), texcoord).xz; // Bottom / Left

				// Is there any blending weight with a value greater than 0.0?
				if (dot(a, vec4(1.0, 1.0, 1.0, 1.0)) < 1e-5) {
					set_color(textureLod(TEXTURE(pc.smaa.color_tex), texcoord, 0.0));
					return;
				}
				
				bool h = max(a.x, a.z) > max(a.y, a.w); // max(horizontal) > max(vertical)
				
				// Calculate the blending offsets:
				vec4 blendingOffset = vec4(0.0, a.y, 0.0, a.w);
				vec2 blendingWeight = a.yw;
				if (h) {
					blendingOffset = vec4(a.x, 0.0, a.z, 0.0);
					blendingWeight = a.xz;
				}
				blendingWeight /= dot(blendingWeight, vec2(1.0, 1.0));
				
				// Calculate the texture coordinates:
				vec4 blendingCoord = blendingOffset * vec4(texel, -texel) + texcoord.xyxy;
				
				// We exploit bilinear filtering to mix current pixel with the chosen neighbor:
				vec4 color = blendingWeight.x * textureLod(TEXTURE(pc.smaa.color_tex), blendingCoord.xy, 0.0);
				color += blendingWeight.y * textureLod(TEXTURE(pc.smaa.color_tex), blendingCoord.zw, 0.0);
				
				set_color(color);
			}
		]],
		},
	},
	{
		name = "smaa_resolve",
		color_format = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		framebuffer_count = 2,
		post_draw = function()
			local cam = render3d.GetCamera()
			local s = 0.1
			local offsets = {Vec2(s, -s), Vec2(-s, s)}
			cam:SetJitter(offsets[(system.GetFrameNumber() % 2) + 1])
		end,
		fragment = {
			uniform_buffers = {
				{
					name = "smaa_data",
					binding_index = 2,
					block = {
						render3d.camera_block,
						{
							"current_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.smaa_blend:GetFramebuffer():GetAttachment(1))
							end,
						},
						{
							"history_tex",
							"int",
							function(self, block, key)
								local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
								block[key] = self:GetTextureIndex(render3d.pipelines.smaa_resolve:GetFramebuffer(prev_idx):GetAttachment(1))
							end,
						},
						{
							"depth_tex",
							"int",
							function(self, block, key)
								block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer().depth_texture)
							end,
						},
						{
							"prev_view",
							"mat4",
							function(self, block, key)
								render3d.prev_view_matrix:CopyToFloatPointer(block[key])
							end,
						},
						{
							"prev_projection",
							"mat4",
							function(self, block, key)
								render3d.prev_projection_matrix:CopyToFloatPointer(block[key])
							end,
						},
					},
				},
			},
			shader = [[
			void main() {
				vec2 uv = in_uv;
				float depth = texture(TEXTURE(smaa_data.depth_tex), uv).r;
				
				// Reprojection
				vec4 clip_pos = vec4(uv * 2.0 - 1.0, depth, 1.0);
				vec4 view_pos = smaa_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				vec3 world_pos = (smaa_data.inv_view * view_pos).xyz;
				
				vec4 prev_view_pos = smaa_data.prev_view * vec4(world_pos, 1.0);
				vec4 prev_clip = smaa_data.prev_projection * prev_view_pos;
				prev_clip /= prev_clip.w;
				vec2 prev_uv = prev_clip.xy * 0.5 + 0.5;
				
				vec4 current = texture(TEXTURE(smaa_data.current_tex), uv);
				
				if (prev_uv.x < 0.0 || prev_uv.x > 1.0 || prev_uv.y < 0.0 || prev_uv.y > 1.0) {
					set_color(current);
					return;
				}
				
				vec4 history = texture(TEXTURE(smaa_data.history_tex), prev_uv);
				
				// Neighborhood clamping
				vec2 texel = 1.0 / vec2(textureSize(TEXTURE(smaa_data.current_tex), 0));
				
				// Edge artifact fix: check if we are too close to the edge
				if (prev_uv.x < texel.x || prev_uv.x > 1.0 - texel.x || prev_uv.y < texel.y || prev_uv.y > 1.0 - texel.y) {
					set_color(current);
					return;
				}

				vec4 m1 = vec4(0.0);
				vec4 m2 = vec4(0.0);
				for(int x = -1; x <= 1; x++) {
					for(int y = -1; y <= 1; y++) {
						vec4 c = texture(TEXTURE(smaa_data.current_tex), uv + vec2(x,y)*texel);
						m1 += c;
						m2 += c*c;
					}
				}
				vec4 mu = m1 / 9.0;
				vec4 sigma = sqrt(max(vec4(0.0), (m2 / 9.0) - mu*mu));
				vec4 min_c = mu - 2.0 * sigma;
				vec4 max_c = mu + 2.0 * sigma;
				history = clamp(history, min_c, max_c);
				
				set_color(mix(current, history, 0.85));
			}
		]],
		},
	},
}
