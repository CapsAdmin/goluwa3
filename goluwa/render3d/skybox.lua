local event = require("event")
local ffi = require("ffi")
local Color = require("structs.color")
local orientation = require("render3d.orientation")
local Matrix44 = require("structs.matrix44")
local Vec3 = require("structs.vec3")
local Ang3 = require("structs.ang3")
local Quat = require("structs.quat")
local Rect = require("structs.rect")
local render = require("render.render")
local render3d = require("render3d.render3d")
local Camera3D = require("render3d.camera3d")
local EasyPipeline = require("render.easy_pipeline")
local skybox = library()
local Texture = require("render.texture")
local Fence = require("render.vulkan.internal.fence")
local USE_TEMPLE = true

function skybox.GetGLSLCode()
	local code = [[const float PI = 3.14159265359;]]

	if USE_TEMPLE then
		return code .. [[
			const int Iterations=14;
			const float detail=.00002;
			const float Scale=1.976;

			vec3 lightdir=normalize(vec3(0.,-0.3,-1.));

			float ot=0.;
			float det=0.;

			float hitfloor;

			float smin( float a, float b, float k )
			{
				float h = clamp( 0.5+0.5*(b-a)/k, 0.0, 1.0 );
				return mix( b, a, h ) - k*h*(1.0-h);
			}

			float de(vec3 pos) {
				hitfloor=0.;
				vec3 p=pos;
				p.xz=abs(.5-mod(pos.xz,1.))+.01;
				float DEfactor=1.;
				ot=1000.;
				for (int i=0; i<Iterations; i++) {
					p = abs(p)-vec3(0.,2.,0.);  
					float r2 = dot(p, p);
					float sc=Scale/clamp(r2,0.4,1.);
					p*=sc; 
					DEfactor*=sc;
					p = p - vec3(0.5,1.,0.5);
				}
				float fl=pos.y-3.013;
				float d=min(fl,length(p)/DEfactor-.0005);
				d=min(d,-pos.y+3.9);
				if (abs(d-fl)<.0001) hitfloor=1.;
				return d;
			}

			vec3 normal(vec3 p) {
				vec3 e = vec3(0.0,det,0.0);
				return normalize(vec3(
						de(p+e.yxx)-de(p-e.yxx),
						de(p+e.xyx)-de(p-e.xyx),
						de(p+e.xxy)-de(p-e.xxy)
						)
					);	
			}

			float shadow(vec3 pos, vec3 sdir) {
				float totalDist =2.0*det, sh=1.;
				for (int steps=0; steps<30; steps++) {
					if (totalDist<1.) {
						vec3 p = pos - totalDist * sdir;
						float dist = de(p)*1.5;
						if (dist < detail)  sh=0.;
						totalDist += max(0.05,dist);
					}
				}
				return max(0.,sh);	
			}

			float calcAO( const vec3 pos, const vec3 nor ) {
				float aodet=detail*80.;
				float totao = 0.0;
				float sca = 10.0;
				for( int aoi=0; aoi<5; aoi++ ) {
					float hr = aodet + aodet*float(aoi*aoi);
					vec3 aopos =  nor * hr + pos;
					float dd = de( aopos );
					totao += -(dd-hr)*sca;
					sca *= 0.75;
				}
				return clamp( 1.0 - 5.0*totao, 0.0, 1.0 );
			}

			float kset(vec3 p) {
				p=abs(.5-fract(p*20.));
				float es, l=es=0.;
				for (int i=0;i<13;i++) {
					float pl=l;
					l=length(p);
					p=abs(p)/dot(p,p)-.5;
					es+=exp(-1./abs(l-pl));
				}
				return es;	
			}

			vec3 light(in vec3 p, in vec3 dir) {
				float hf=hitfloor;
				vec3 n=normal(p);
				float sh=clamp(shadow(p, lightdir)+hf,.4,1.);
				float ao=calcAO(p,n);
				float diff=max(0.,dot(lightdir,-n))*sh*1.3;
				float amb=max(0.2,dot(dir,-n))*.4;
				vec3 r = reflect(lightdir,n);
				float spec=pow(max(0.,dot(dir,-r))*sh,10.)*(.5+ao*.5);
				float k=kset(p)*.18; 
				vec3 col=mix(vec3(k*1.1,k*k*1.3,k*k*k),vec3(k),.45)*2.;
				col=col*ao*(amb*vec3(.9,.85,1.)+diff*vec3(1.,.9,.9))+spec*vec3(1,.9,.5)*.7;	
				return col;
			}

			vec3 raymarch(in vec3 from, in vec3 dir) 
			{
				float t=0.0;
				float cc=cos(t*.03); float ss=sin(t*.03);
				mat2 rot=mat2(cc,ss,-ss,cc);
				float glow,d=1., totdist=glow=0.;
				vec3 p, col=vec3(0.);
				float steps;
				for (int i=0; i<130; i++) {
					if (d>det && totdist<3.5) {
						p=from+totdist*dir;
						d=de(p);
						det=detail*(1.+totdist*55.);
						totdist+=d; 
						glow+=max(0.,.0075-d)*exp(-totdist);
						steps++;
					}
				}
				float l=pow(max(0.,dot(normalize(-dir),normalize(lightdir))),10.);
				vec3 backg=vec3(.8,.85,1.)*.25*(2.-l)+vec3(1.,.9,.65)*l*.4;
				float hf=hitfloor;
				if (d<det) {
					col=light(p-det*dir*1.5, dir); 
					if (hf>0.5) col*=vec3(1.,.85,.8)*.6;
					col*=min(1.2,.5+totdist*totdist*1.5);
					col = mix(col, backg, 1.0-exp(-1.3*pow(totdist,1.3)));
				} else { 
					col=backg;
				}
				col+=glow*vec3(1.,.9,.8)*.34;
				col+=vec3(1,.8,.6)*pow(l,8.)*3;
				col = col*vec3(1.55, 1, 1)*1.8;
				return col; 
			}
		]]
	end

	return code .. [[
		
		// Nishita Sky Model Constants
		const float EARTH_RADIUS = 6371000.0;      // meters
		const float ATMOSPHERE_RADIUS = 6471000.0; // meters (100km atmosphere)
		const float HR = 7994.0;                   // Rayleigh scale height
		const float HM = 1200.0;                   // Mie scale height
		
		// Rayleigh scattering coefficients at sea level
		const vec3 BETA_R = vec3(5.5e-6, 13.0e-6, 22.4e-6);
		// Mie scattering coefficient at sea level
		const float BETA_M = 21e-6;
		
		// Mie scattering phase function asymmetry factor
		const float G = 0.76;
		
		const int NUM_SAMPLES = 16;
		const int NUM_SAMPLES_LIGHT = 8;
		
		// Ray-sphere intersection
		// Returns distance to first intersection, or -1 if no intersection
		vec2 raySphereIntersect(vec3 rayOrigin, vec3 rayDir, float radius) {
			float a = dot(rayDir, rayDir);
			float b = 2.0 * dot(rayDir, rayOrigin);
			float c = dot(rayOrigin, rayOrigin) - radius * radius;
			float d = b * b - 4.0 * a * c;
			if (d < 0.0) return vec2(-1.0);
			d = sqrt(d);
			return vec2(-b - d, -b + d) / (2.0 * a);
		}
		
		// Rayleigh phase function
		float phaseRayleigh(float cosTheta) {
			return 3.0 / (16.0 * PI) * (1.0 + cosTheta * cosTheta);
		}
		
		// Mie phase function (Henyey-Greenstein)
		float phaseMie(float cosTheta) {
			float g2 = G * G;
			float num = (1.0 - g2);
			float denom = pow(1.0 + g2 - 2.0 * G * cosTheta, 1.5);
			return 3.0 / (8.0 * PI) * num / denom;
		}
		
		// Compute atmospheric scattering using Nishita model
		vec3 nishitaSky(vec3 rayDir, vec3 sunDir, vec3 camPos) {
			// Camera position - add world position to earth surface
			// Scale factor: game units to meters (adjust as needed)
			float scale = 1.0;
			vec3 rayOrigin = vec3(0.0, EARTH_RADIUS + 1.0 + camPos.y * scale, 0.0);
			
			// Intersect with atmosphere
			vec2 t = raySphereIntersect(rayOrigin, rayDir, ATMOSPHERE_RADIUS);
			if (t.x > t.y || t.y < 0.0) return vec3(0.0);
			
			float tMax = t.y;
			float tMin = max(t.x, 0.0);
			
			float segmentLength = (tMax - tMin) / float(NUM_SAMPLES);
			float tCurrent = tMin;
			
			vec3 sumR = vec3(0.0);
			vec3 sumM = vec3(0.0);
			float opticalDepthR = 0.0;
			float opticalDepthM = 0.0;
			
			float cosTheta = dot(rayDir, sunDir);
			float phaseR = phaseRayleigh(cosTheta);
			float phaseM = phaseMie(cosTheta);
			
			for (int i = 0; i < NUM_SAMPLES; i++) {
				vec3 samplePos = rayOrigin + rayDir * (tCurrent + segmentLength * 0.5);
				float height = length(samplePos) - EARTH_RADIUS;
				
				// Density at this height
				float densityR = exp(-height / HR) * segmentLength;
				float densityM = exp(-height / HM) * segmentLength;
				
				opticalDepthR += densityR;
				opticalDepthM += densityM;
				
				// Light ray to sun
				vec2 tLight = raySphereIntersect(samplePos, sunDir, ATMOSPHERE_RADIUS);
				float segmentLengthLight = tLight.y / float(NUM_SAMPLES_LIGHT);
				float tCurrentLight = 0.0;
				float opticalDepthLightR = 0.0;
				float opticalDepthLightM = 0.0;
				
				bool hitGround = false;
				for (int j = 0; j < NUM_SAMPLES_LIGHT; j++) {
					vec3 samplePosLight = samplePos + sunDir * (tCurrentLight + segmentLengthLight * 0.5);
					float heightLight = length(samplePosLight) - EARTH_RADIUS;
					
					if (heightLight < 0.0) {
						hitGround = true;
						break;
					}
					
					opticalDepthLightR += exp(-heightLight / HR) * segmentLengthLight;
					opticalDepthLightM += exp(-heightLight / HM) * segmentLengthLight;
					tCurrentLight += segmentLengthLight;
				}
				
				if (!hitGround) {
					vec3 tau = BETA_R * (opticalDepthR + opticalDepthLightR) + 
							   BETA_M * 1.1 * (opticalDepthM + opticalDepthLightM);
					vec3 attenuation = exp(-tau);
					sumR += densityR * attenuation;
					sumM += densityM * attenuation;
				}
				
				tCurrent += segmentLength;
			}
			
			// Sun intensity (22 is a good value for Earth)
			float sunIntensity = 22.0;
			
			return sunIntensity * (sumR * BETA_R * phaseR + sumM * BETA_M * phaseM);
		}
		
		// Render sun disk
		vec3 renderSun(vec3 rayDir, vec3 sunDir, vec3 skyColor) {
			float sunAngle = acos(clamp(dot(rayDir, sunDir), 0.0, 1.0));
			float sunRadius = 0.00935; // Angular radius of sun in radians (~0.53 degrees)
			
			if (sunAngle < sunRadius + 0.00000000001) {
				// Inside sun disk
				float limb = 1.0 - pow(sunAngle / sunRadius, 0.5);
				return vec3(1.0, 0.98, 0.95) * 100.0 * limb;
			} else if (sunAngle < sunRadius * 1.5) {
				// Sun glow/corona
				float glow = 1.0 - (sunAngle - sunRadius) / (sunRadius * 0.5);
				return skyColor + vec3(1.0, 0.9, 0.7) * glow * glow * 10.0;
			}
			
			return skyColor;
		}

		// ============================================
		// Physically-based procedural star field
		// Based on real stellar magnitude distribution and blackbody colors
		// ============================================

		// High-quality hash functions for star placement
		float hash1(vec2 p) {
			vec3 p3 = fract(vec3(p.xyx) * 0.1031);
			p3 += dot(p3, p3.yzx + 33.33);
			return fract((p3.x + p3.y) * p3.z);
		}

		vec2 hash2(vec2 p) {
			vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
			p3 += dot(p3, p3.yzx + 33.33);
			return fract((p3.xx + p3.yz) * p3.zy);
		}

		vec3 hash3(vec2 p) {
			vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
			p3 += dot(p3, p3.yxz + 33.33);
			return fract((p3.xxy + p3.yzz) * p3.zyx);
		}

		// Blackbody radiation color for stellar temperature (Kelvin)
		// Based on Planck's law approximation for visible spectrum
		vec3 blackbodyColor(float temperature) {
			// Normalize temperature to typical star range (2000K - 40000K)
			float t = temperature / 100.0;
			vec3 color;
			
			// Red channel
			if (t <= 66.0) {
				color.r = 1.0;
			} else {
				color.r = 1.29293618606 * pow(t - 60.0, -0.1332047592);
			}
			
			// Green channel
			if (t <= 66.0) {
				color.g = 0.390081578769 * log(t) - 0.631841443788;
			} else {
				color.g = 1.12989086089 * pow(t - 60.0, -0.0755148492);
			}
			
			// Blue channel
			if (t >= 66.0) {
				color.b = 1.0;
			} else if (t <= 19.0) {
				color.b = 0.0;
			} else {
				color.b = 0.543206789110 * log(t - 10.0) - 1.19625408914;
			}
			
			return clamp(color, 0.0, 1.0);
		}

		// Convert direction to equirectangular UV for consistent star grid
		vec2 dirToEquirect(vec3 dir) {
			float phi = atan(dir.z, dir.x); // -PI to PI
			float theta = asin(clamp(dir.y, -1.0, 1.0)); // -PI/2 to PI/2
			return vec2(phi / (2.0 * PI) + 0.5, theta / PI + 0.5);
		}

		// Voronoi-based star placement for natural random distribution
		float voronoiStar(vec2 uv, float scale, out vec2 starCenter, out float starSeed) {
			vec2 cell = floor(uv * scale);
			vec2 frac = fract(uv * scale);
			
			float minDist = 1.0;
			starSeed = 0.0;
			starCenter = vec2(0.0);
			
			for (int y = -1; y <= 1; y++) {
				for (int x = -1; x <= 1; x++) {
					vec2 neighbor = vec2(float(x), float(y));
					vec2 point = hash2(cell + neighbor);
					vec2 diff = neighbor + point - frac;
					float dist = length(diff);
					
					if (dist < minDist) {
						minDist = dist;
						starCenter = cell + neighbor + point;
						starSeed = hash1(cell + neighbor);
					}
				}
			}
			
			return minDist;
		}

		// Stellar magnitude distribution following power law
		// Brighter stars are exponentially rarer
		float magnitudeToIntensity(float magnitude) {
			// Pogson's equation: each magnitude is 2.512x dimmer
			// magnitude 0 = brightest visible stars, magnitude 6 = dimmest naked eye
			return pow(2.512, -magnitude);
		}

		// Sample stellar temperature based on spectral class distribution
		// O,B,A,F,G,K,M types with realistic probabilities
		float sampleStellarTemperature(float seed) {
			// Most stars are K and M type (cooler, redder)
			// Fewer are hot O and B type
			if (seed < 0.0001) return 30000.0 + seed * 100000.0; // O-type (very rare, blue)
			if (seed < 0.001) return 10000.0 + seed * 10000.0;   // B-type (rare, blue-white)
			if (seed < 0.01) return 7500.0 + seed * 2500.0;      // A-type (white)
			if (seed < 0.05) return 6000.0 + seed * 1500.0;      // F-type (yellow-white)
			if (seed < 0.15) return 5200.0 + seed * 800.0;       // G-type (yellow, like Sun)
			if (seed < 0.40) return 3700.0 + seed * 1500.0;      // K-type (orange)
			return 2400.0 + seed * 1300.0;                        // M-type (most common, red)
		}

		// Rotate direction around Y axis (celestial pole)
		// Earth completes one rotation per 24 hours, so stars appear to move opposite to sun
		vec3 rotateStarField(vec3 dir, vec3 sunDir) {
			// Get sun's azimuth angle (horizontal rotation)
			float sunAzimuth = atan(sunDir.z, sunDir.x);
			
			// Stars rotate opposite to sun - when sun moves east, stars appear to move west
			// The sun completes 360° in 24h, so this gives correct apparent stellar motion
			float starRotation = -sunAzimuth;
			
			// Rotate around Y axis (assuming Y is up/celestial north)
			float c = cos(starRotation);
			float s = sin(starRotation);
			return vec3(
				dir.x * c - dir.z * s,
				dir.y,
				dir.x * s + dir.z * c
			);
		}

		// Milky Way approximation using noise
		float milkyWayDensity(vec3 dir) {
			// Galactic plane is roughly along the ecliptic, tilted ~60° from celestial equator
			// Simplified: brightest along a great circle
			vec3 galacticNorth = normalize(vec3(0.0, 0.4, 0.9));
			float galacticLat = abs(dot(dir, galacticNorth));
			
			// Density falls off from galactic plane
			float planeDensity = exp(-galacticLat * galacticLat * 8.0);
			
			// Add some structure with noise
			vec2 uv = dirToEquirect(dir);
			float noise1 = hash1(uv * 50.0);
			float noise2 = hash1(uv * 100.0);
			float structure = 0.5 + 0.3 * noise1 + 0.2 * noise2;
			
			return planeDensity * structure;
		}

		vec3 get_stars(vec3 dir, vec3 sunDir) {
			dir = normalize(dir);
			
			// Rotate star field based on sun position (Earth's rotation)
			dir = rotateStarField(dir, sunDir);
			
			vec2 uv = dirToEquirect(dir);
			
			vec3 starColor = vec3(0.0);
			
			// Multiple layers of stars at different scales for depth
			// Layer 1: Bright stars (sparse, large)
			{
				vec2 center;
				float seed;
				float dist = voronoiStar(uv, 100.0, center, seed);
				
				if (seed > 0.92) { // Only ~8% of cells have bright stars
					float magnitude = mix(-1.0, 2.0, pow(seed, 4.0));
					float intensity = magnitudeToIntensity(magnitude);
					float temperature = sampleStellarTemperature(hash1(center));
					vec3 color = blackbodyColor(temperature);
					
					// Star size based on brightness
					float starRadius = 0.015 * sqrt(intensity);
					float star = smoothstep(starRadius, starRadius * 0.1, dist);
					
					// Add subtle glow for bright stars
					float glow = exp(-dist * dist * 500.0) * intensity * 0.3;
					
					starColor += color * (star * intensity * 3.0 + glow);
				}
			}
			
			// Layer 2: Medium stars
			{
				vec2 center;
				float seed;
				float dist = voronoiStar(uv, 300.0, center, seed);
				
				if (seed > 0.75) {
					float magnitude = mix(2.0, 4.0, seed);
					float intensity = magnitudeToIntensity(magnitude);
					float temperature = sampleStellarTemperature(hash1(center + vec2(1.0)));
					vec3 color = blackbodyColor(temperature);
					
					float starRadius = 0.008 * sqrt(intensity);
					float star = smoothstep(starRadius, starRadius * 0.05, dist);
					
					starColor += color * star * intensity * 2.0;
				}
			}
			
			// Layer 3: Dim background stars (dense)
			{
				vec2 center;
				float seed;
				float dist = voronoiStar(uv, 800.0, center, seed);
				
				if (seed > 0.5) {
					float magnitude = mix(4.0, 6.5, seed);
					float intensity = magnitudeToIntensity(magnitude);
					float temperature = sampleStellarTemperature(hash1(center + vec2(2.0)));
					vec3 color = blackbodyColor(temperature);
					
					float starRadius = 0.004;
					float star = smoothstep(starRadius, 0.0, dist);
					
					starColor += color * star * intensity * 1.5;
				}
			}
			
			// Layer 4: Very faint stars / star dust
			{
				vec2 center;
				float seed;
				float dist = voronoiStar(uv, 2000.0, center, seed);
				
				float intensity = magnitudeToIntensity(6.0) * seed;
				float temperature = sampleStellarTemperature(hash1(center + vec2(3.0)));
				vec3 color = blackbodyColor(temperature);
				
				float star = smoothstep(0.003, 0.0, dist);
				starColor += color * star * intensity;
			}
			
			// Add Milky Way glow
			float milkyWay = milkyWayDensity(dir);
			vec3 milkyWayColor = vec3(0.8, 0.85, 1.0) * 0.015 * milkyWay;
			
			// Boost star density in Milky Way region
			starColor *= 1.0 + milkyWay * 0.5;
			
			return starColor + milkyWayColor;
		}
	]]
end

function skybox.GetGLSLMainCode(dir_var, sun_dir_var, cam_pos_var, stars_texture_index_var)
	if USE_TEMPLE then
		return [[
			{
				vec3 dir = normalize(]] .. dir_var .. [[);
				float y = -0.22;
				vec3 from = vec3(0.0, 3.04 + y * 0.1, -2.0);
				sky_color_output = raymarch(from, dir);
			}
		]]
	end

	return [[
		{
			vec3 dir = normalize(]] .. dir_var .. [[);
			vec3 sunDir = normalize(]] .. sun_dir_var .. [[);
			
			// Compute Nishita sky
			vec3 skyColor = nishitaSky(dir, sunDir, ]] .. cam_pos_var .. [[);
			
			// Add sun disk
			skyColor = renderSun(dir, sunDir, skyColor);
			
			// Compute sky brightness for blending with space texture
			// Use sun elevation to determine day/night
			float sunElevation = sunDir.y;
			
			// Sky brightness based on sun elevation
			// At sunset (elevation ~0), start transitioning
			// Below horizon, night time
			float dayFactor = smoothstep(-0.2, 0.1, sunElevation);
			
			// Also consider the actual sky luminance for the blend
			float skyLuminance = dot(skyColor, vec3(0.2126, 0.7152, 0.0722));
			float skyBrightness = clamp(skyLuminance * 0.5, 0.0, 1.0);
			
			// Combine day factor and sky brightness
			float blendFactor = max(dayFactor, skyBrightness);
			
			// Sample space/stars texture
			vec3 spaceColor = vec3(0.0);
			if (]] .. stars_texture_index_var .. [[ != -1) {
				float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
				float v = asin(dir.y) / PI + 0.5;
				spaceColor = texture(TEXTURE(]] .. stars_texture_index_var .. [[), vec2(u, -v)).rgb;
				spaceColor = pow(spaceColor, vec3(10.0));
				spaceColor *= 0.5;
			} else {
				spaceColor = get_stars(dir, sunDir);
			}
			
			// Blend: show stars when sky is dark, hide them during day
			sky_color_output = mix(spaceColor, skyColor, blendFactor);
		}
	]]
end

skybox.inv_projection_view = skybox.inv_projection_view or Matrix44()
local SIZE = 512

function skybox.CreatePipeline(color_format, samples)
	local attachments = {}
	local num_attachments = type(color_format) == "table" and #color_format or 1

	for i = 1, num_attachments do
		table.insert(attachments, {blend = false, color_write_mask = {"r", "g", "b", "a"}})
	end

	return EasyPipeline.New(
		{
			color_format = color_format,
			samples = samples or "1",
			vertex = {
				push_constants = {
					{
						name = "vertex",
						block = {
							{
								"inv_projection_view",
								"mat4",
								function(constants)
									skybox.inv_projection_view:CopyToFloatPointer(constants.inv_projection_view)
								end,
							},
						},
					},
				},
				custom_declarations = [[
					layout(location = 0) out vec3 out_direction;
				]],
				shader = [[
					vec2 positions[3] = vec2[](
						vec2(-1.0, -1.0),
						vec2( 3.0, -1.0),
						vec2(-1.0,  3.0)
					);

					void main() {
						vec2 pos = positions[gl_VertexIndex];
						gl_Position = vec4(pos, 1.0, 1.0);
						
						vec4 world_pos = pc.vertex.inv_projection_view * vec4(pos, 1.0, 1.0);
						out_direction = world_pos.xyz / world_pos.w;
					}
				]],
			},
			fragment = {
				push_constants = {
					{
						name = "fragment",
						block = {
							{
								"stars_texture_index",
								"int",
								function(constants, pipeline)
									return pipeline:GetTextureIndex(skybox.stars_texture)
								end,
							},
							{
								"sun_direction",
								"vec4",
								function(constants)
									local lights = render3d.GetLights()
									local sun = lights[1]

									if not sun then return end

									sun:GetRotation():GetBackward():CopyToFloatPointer(constants.sun_direction)
								end,
							},
							{
								"camera_position",
								"vec4",
								function(constants)
									(render3d.camera:GetPosition()):CopyToFloatPointer(constants.camera_position)
								end,
							},
							{
								"envmap_rendering",
								"int",
								function(constants)
									constants.envmap_rendering = skybox.envmap_rendering and 1 or 0
								end,
							},
						},
					},
				},
				custom_declarations = [[
					layout(location = 0) in vec3 in_direction;
					]] .. (
						num_attachments > 1 and
						[[
						layout(location = 0) out vec4 out_albedo;
						layout(location = 1) out vec4 out_normal;
						layout(location = 2) out vec4 out_metallic_roughness_ao;
						layout(location = 3) out vec4 out_emissive;
					]] or
						[[
						layout(location = 0) out vec4 out_color;
					]]
					) .. [[
					]] .. skybox.GetGLSLCode() .. [[
				]],
				shader = [[
					void main() {
						vec3 sky_color_output;
						]] .. skybox.GetGLSLMainCode(
						"in_direction",
						"pc.fragment.sun_direction.xyz",
						"pc.fragment.camera_position.xyz",
						"pc.fragment.stars_texture_index"
					) .. [[
						vec3 color = sky_color_output;
						
						]] .. (
						num_attachments > 1 and
						[[
							out_albedo = vec4(color, 1.0);
							out_normal = vec4(0.0, 0.0, 0.0, 0.0);
							out_metallic_roughness_ao = vec4(0.0, 1.0, 1.0, 1.0);
							out_emissive = vec4(0.0, 0.0, 0.0, 1.0);
						]] or
						[[
							out_color = vec4(color, 1.0);
						]]
					) .. [[
					}
				]],
			},
			color_blend = {
				attachments = attachments,
			},
			rasterizer = {
				cull_mode = "none",
				front_face = orientation.FRONT_FACE,
			},
			depth_stencil = {
				depth_test = false,
				depth_write = false,
			},
		}
	)
end

function skybox.Initialize()
	if skybox.output_texture then return end

	-- Create environment cubemap
	skybox.output_texture = skybox.output_texture or
		Texture.New(
			{
				width = SIZE,
				height = SIZE,
				format = "b10g11r11_ufloat_pack32",
				mip_map_levels = "auto",
				image = {
					array_layers = 6,
					flags = {"cube_compatible"},
					usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"},
				},
				view = {
					view_type = "cube",
					layer_count = 6,
				},
			}
		)
	skybox.source_texture = skybox.source_texture or
		Texture.New(
			{
				width = SIZE,
				height = SIZE,
				format = "b10g11r11_ufloat_pack32",
				mip_map_levels = "auto",
				image = {
					array_layers = 6,
					flags = {"cube_compatible"},
					usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"},
				},
				view = {
					view_type = "cube",
					layer_count = 6,
				},
			}
		)

	if not skybox.mip_face_views then
		skybox.mip_face_views = {}
		local num_mips = skybox.output_texture.mip_map_levels

		for m = 0, num_mips - 1 do
			skybox.mip_face_views[m] = {}

			for i = 0, 5 do
				skybox.mip_face_views[m][i] = skybox.output_texture:GetImage():CreateView(
					{
						view_type = "2d",
						base_array_layer = i,
						layer_count = 1,
						base_mip_level = m,
						level_count = 1,
					}
				)
			end
		end
	end

	if not skybox.source_face_views then
		skybox.source_face_views = {}

		for i = 0, 5 do
			skybox.source_face_views[i] = skybox.source_texture:GetImage():CreateView(
				{
					view_type = "2d",
					base_array_layer = i,
					layer_count = 1,
					base_mip_level = 0,
					level_count = 1,
				}
			)
		end
	end

	skybox.pipeline = skybox.CreatePipeline(render3d.fill_config.color_format, "1")
	skybox.cubemap_pipeline = skybox.CreatePipeline("b10g11r11_ufloat_pack32", "1")
	skybox.prefilter_pipeline = EasyPipeline.New(
		{
			color_format = "b10g11r11_ufloat_pack32",
			samples = "1",
			vertex = {
				push_constants = {
					{
						name = "vertex",
						block = {
							{
								"inv_projection_view",
								"mat4",
								function(constants)
									skybox.inv_projection_view:CopyToFloatPointer(constants.inv_projection_view)
								end,
							},
						},
					},
				},
				custom_declarations = [[
					layout(location = 0) out vec3 out_direction;
				]],
				shader = [[
					vec2 positions[3] = vec2[](
						vec2(-1.0, -1.0),
						vec2( 3.0, -1.0),
						vec2(-1.0,  3.0)
					);

					void main() {
						vec2 pos = positions[gl_VertexIndex];
						gl_Position = vec4(pos, 1.0, 1.0);
						
						vec4 world_pos = pc.vertex.inv_projection_view * vec4(pos, 1.0, 1.0);
						out_direction = world_pos.xyz / world_pos.w;
					}
				]],
			},
			fragment = {
				push_constants = {
					{
						name = "fragment",
						block = {
							{
								"roughness",
								"float",
								function(constants)
									return skybox.current_roughness or 0
								end,
							},
							{
								"input_texture_index",
								"int",
								function(constants, pipeline)
									return pipeline:GetTextureIndex(skybox.source_texture)
								end,
							},
						},
					},
				},
				custom_declarations = [[
					layout(location = 0) in vec3 in_direction;
					layout(location = 0) out vec4 out_color;

					const float PI = 3.14159265359;

					float D_GGX(float NoH, float roughness) {
						float a = roughness * roughness;
						float a2 = a * a;
						float NoH2 = NoH * NoH;
						float denom = (NoH2 * (a2 - 1.0) + 1.0);
						return a2 / (PI * denom * denom);
					}

					float RadicalInverse_Vdc(uint bits) {
						bits = (bits << 16u) | (bits >> 16u);
						bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
						bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
						bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
						bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
						return float(bits) * 2.3283064365386963e-10;
					}

					vec2 Hammersley(uint i, uint N) {
						return vec2(float(i)/float(N), RadicalInverse_Vdc(i));
					}

					vec3 ImportanceSampleGGX(vec2 Xi, vec3 N, float roughness) {
						float a = roughness*roughness;
						float phi = 2.0 * PI * Xi.x;
						float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (a*a - 1.0) * Xi.y));
						float sinTheta = sqrt(1.0 - cosTheta*cosTheta);
						
						vec3 H;
						H.x = cos(phi) * sinTheta;
						H.y = sin(phi) * sinTheta;
						H.z = cosTheta;
						
						vec3 up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
						vec3 tangent = normalize(cross(up, N));
						vec3 bitangent = cross(N, tangent);
						
						vec3 sampleVec = tangent * H.x + bitangent * H.y + N * H.z;
						return normalize(sampleVec);
					}
				]],
				shader = [[
					void main() {
						vec3 N = normalize(in_direction);
						vec3 R = N;
						vec3 V = R;

						const uint SAMPLE_COUNT = 1024u;
						float totalWeight = 0.0;
						vec3 prefilteredColor = vec3(0.0);
						float roughness = pc.fragment.roughness;

						for(uint i = 0u; i < SAMPLE_COUNT; ++i) {
							vec2 Xi = Hammersley(i, SAMPLE_COUNT);
							vec3 H  = ImportanceSampleGGX(Xi, N, roughness);
							vec3 L  = normalize(2.0 * dot(V, H) * H - V);

							float NoL = max(dot(N, L), 0.0);
							if(NoL > 0.0) {
								float NoH = max(dot(N, H), 0.0);
								float VoH = max(dot(V, H), 0.0);
								float D = D_GGX(NoH, roughness);
								float pdf = (D * NoH / (4.0 * VoH)) + 0.0001;

								float resolution = 512.0; // SIZE
								float saSample = 1.0 / (float(SAMPLE_COUNT) * pdf + 0.0001);
								float saTexel  = 4.0 * PI / (6.0 * resolution * resolution);

								float lod = roughness == 0.0 ? 0.0 : 0.5 * log2(saSample / saTexel);

								prefilteredColor += textureLod(CUBEMAP(pc.fragment.input_texture_index), L, lod).rgb * NoL;
								totalWeight      += NoL;
							}
						}
						out_color = vec4(prefilteredColor / totalWeight, 1.0);
					}
				]],
			},
			rasterizer = {
				cull_mode = "none",
			},
			depth_stencil = {
				depth_test = false,
				depth_write = false,
			},
		}
	)
	render3d.SetEnvironmentTexture(skybox.output_texture)
end

event.AddListener("Render3DInitialized", "skybox", function()
	skybox.Initialize()
end)

function skybox.UpdateEnvironmentTexture()
	if not skybox.pipeline or not skybox.output_texture then return end

	if not skybox.update_cmd then
		skybox.update_cmd = render.GetCommandPool():AllocateCommandBuffer()
	end

	local cmd = skybox.update_cmd
	cmd:Reset()
	cmd:Begin()
	-- Transition source cubemap mip 0 to color_attachment_optimal
	cmd:PipelineBarrier(
		{
			srcStage = "top_of_pipe",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = skybox.source_texture:GetImage(),
					oldLayout = "undefined",
					newLayout = "color_attachment_optimal",
					srcAccessMask = "none",
					dstAccessMask = "color_attachment_write",
					base_mip_level = 0,
					level_count = 1,
					layer_count = 6,
				},
			},
		}
	)

	if not skybox.temp_camera then
		skybox.temp_camera = Camera3D.New()
		skybox.temp_camera:SetFOV(math.rad(90))
		skybox.temp_camera:SetViewport(Rect(0, 0, SIZE, SIZE))
		skybox.temp_camera:SetNearZ(0.1)
		skybox.temp_camera:SetFarZ(100)
	end

	local temp_camera = skybox.temp_camera
	local old_camera = render3d.camera
	render3d.camera = temp_camera
	skybox.envmap_rendering = true
	local face_angles = {
		Deg3(0, -90 + 180, 0), -- +X
		Deg3(0, 90 + 180, 0), -- -X
		Deg3(90, 0 + 180, 0), -- +Y
		Deg3(-90, 0 + 180, 0), -- -Y
		Deg3(0, 0 + 180, 0), -- +Z
		Deg3(0, 180 + 180, 0), -- -Z
	}

	for i = 0, 5 do
		temp_camera:SetAngles(face_angles[i + 1])
		-- Calculate inverse projection-view matrix
		local proj = temp_camera:BuildProjectionMatrix()
		local view = temp_camera:BuildViewMatrix():Copy()
		view.m30, view.m31, view.m32 = 0, 0, 0
		local proj_view = view * proj
		proj_view:GetInverse(skybox.inv_projection_view)
		cmd:BeginRendering(
			{
				color_image_view = skybox.source_face_views[i],
				w = SIZE,
				h = SIZE,
				clear_color = {0, 0, 0, 1},
			}
		)
		cmd:SetViewport(0, 0, SIZE, SIZE)
		cmd:SetScissor(0, 0, SIZE, SIZE)
		cmd:SetCullMode("none")
		-- Use fixed frame index 1 to avoid descriptor set conflicts with main render loop
		skybox.cubemap_pipeline:Bind(cmd, 1)
		skybox.cubemap_pipeline:UploadConstants(cmd)
		cmd:Draw(3, 1, 0, 0)
		cmd:EndRendering()
	end

	-- Generate mipmaps for source texture
	skybox.source_texture:GenerateMipmaps("color_attachment_optimal", cmd)
	local num_mips = skybox.output_texture.mip_map_levels
	-- Transition output cubemap to color_attachment_optimal
	cmd:PipelineBarrier(
		{
			srcStage = "top_of_pipe",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = skybox.output_texture:GetImage(),
					oldLayout = "undefined",
					newLayout = "color_attachment_optimal",
					srcAccessMask = "none",
					dstAccessMask = "color_attachment_write",
					base_mip_level = 0,
					level_count = num_mips,
					layer_count = 6,
				},
			},
		}
	)

	for m = 0, num_mips - 1 do
		local perceptual_roughness = m / (num_mips - 1)
		skybox.current_roughness = perceptual_roughness
		local mip_size = math.max(1, math.floor(SIZE / (2 ^ m)))

		for i = 0, 5 do
			temp_camera:SetAngles(face_angles[i + 1])
			local proj = temp_camera:BuildProjectionMatrix()
			local view = temp_camera:BuildViewMatrix():Copy()
			view.m30, view.m31, view.m32 = 0, 0, 0
			local proj_view = view * proj
			proj_view:GetInverse(skybox.inv_projection_view)
			cmd:BeginRendering(
				{
					color_image_view = skybox.mip_face_views[m][i],
					w = mip_size,
					h = mip_size,
					clear_color = {0, 0, 0, 1},
				}
			)
			cmd:SetViewport(0, 0, mip_size, mip_size)
			cmd:SetScissor(0, 0, mip_size, mip_size)
			cmd:SetCullMode("none")
			skybox.prefilter_pipeline:Bind(cmd, 1)
			skybox.prefilter_pipeline:UploadConstants(cmd)
			cmd:Draw(3, 1, 0, 0)
			cmd:EndRendering()
		end

		-- Transition this mip to shader_read_only_optimal
		cmd:PipelineBarrier(
			{
				srcStage = "color_attachment_output",
				dstStage = "fragment_shader",
				imageBarriers = {
					{
						image = skybox.output_texture:GetImage(),
						oldLayout = "color_attachment_optimal",
						newLayout = "shader_read_only_optimal",
						srcAccessMask = "color_attachment_write",
						dstAccessMask = "shader_read",
						base_mip_level = m,
						level_count = 1,
						layer_count = 6,
					},
				},
			}
		)
	end

	cmd:End()

	if not skybox.temp_fence then
		skybox.temp_fence = Fence.New(render.GetDevice())
	end

	render.GetQueue():SubmitAndWait(render.GetDevice(), cmd, skybox.temp_fence)
	render.GetDevice():WaitIdle()
	render3d.camera = old_camera
	skybox.envmap_rendering = false
end

event.AddListener("PreFrame", "skybox_update", function()
	skybox.UpdateEnvironmentTexture()
end)

function skybox.SetStarsTexture(texture)
	skybox.stars_texture = texture
end

function skybox.GetOutputCubemapTexture()
	return skybox.output_texture
end

if HOTRELOAD then skybox.Initialize() end

if HOTRELOAD then dofile("goluwa/render3d/render3d.lua") end

return skybox
