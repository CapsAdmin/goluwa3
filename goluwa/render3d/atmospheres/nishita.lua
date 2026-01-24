return [[
    const float PI = 3.14159265359;
    
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
    
    // Sun intensity (50.0 provides a good HDR range for Earth)
    const float SUN_INTENSITY = 50.0;
    
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
        // Calculate ambient color based on sun elevation
    vec3 getAmbientColor(vec3 sunDir) {
        float sunHeight = sunDir.y;
        
        // Day sky ambient (blue)
        vec3 dayAmbient = vec3(0.4, 0.6, 0.9) * 0.3;
        
        // Sunset/sunrise ambient (warm orange-red)
        vec3 sunsetAmbient = vec3(0.8, 0.4, 0.2) * 0.15;
        
        // Night ambient (very dark blue)
        vec3 nightAmbient = vec3(0.05, 0.08, 0.15) * 0.05;
        
        // Blend between day, sunset, and night based on sun height
        if (sunHeight > 0.0) {
            // Day to sunset transition
            float t = pow(sunHeight, 0.5);
            return mix(sunsetAmbient, dayAmbient, t);
        } else {
            // Sunset to night transition
            float t = clamp(sunHeight + 0.2, 0.0, 1.0) / 0.2;
            return mix(nightAmbient, sunsetAmbient, t);
        }
    }
        // Compute atmospheric scattering using Nishita model
    vec3 nishitaSky(vec3 rayDir, vec3 sunDir, vec3 camPos) {
        vec3 rayOrigin = vec3(0.0, EARTH_RADIUS + 1.75 + camPos.y, 0.0);
        
        // Intersect with atmosphere
        vec2 t = raySphereIntersect(rayOrigin, rayDir, ATMOSPHERE_RADIUS);
        
        // Intersect with earth
        vec2 tEarth = raySphereIntersect(rayOrigin, rayDir, EARTH_RADIUS);

        float tMax = t.y;
        if (tEarth.x > 0.0) {
            tMax = min(tMax, tEarth.x);
        }

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

            // Check if light ray hits Earth
            vec2 tEarthLight = raySphereIntersect(samplePos, sunDir, EARTH_RADIUS);
            if (tEarthLight.x > 0.0) {
                tCurrent += segmentLength;
                continue;
            }

            float segmentLengthLight = tLight.y / float(NUM_SAMPLES_LIGHT);
            float tCurrentLight = 0.0;
            float opticalDepthLightR = 0.0;
            float opticalDepthLightM = 0.0;
            
            for (int j = 0; j < NUM_SAMPLES_LIGHT; j++) {
                vec3 samplePosLight = samplePos + sunDir * (tCurrentLight + segmentLengthLight * 0.5);
                float heightLight = length(samplePosLight) - EARTH_RADIUS;
                
                opticalDepthLightR += exp(-heightLight / HR) * segmentLengthLight;
                opticalDepthLightM += exp(-heightLight / HM) * segmentLengthLight;
                tCurrentLight += segmentLengthLight;
            }
            
            vec3 tau = BETA_R * (opticalDepthR + opticalDepthLightR) + 
                        BETA_M * (opticalDepthM + opticalDepthLightM);
            vec3 attenuation = exp(-tau);
            sumR += densityR * attenuation;
            sumM += densityM * attenuation;
            
            tCurrent += segmentLength;
        }
        
        vec3 scatteredLight = SUN_INTENSITY * (sumR * BETA_R * phaseR + sumM * BETA_M * phaseM);
        vec3 ambientColor = getAmbientColor(sunDir);
        
        return max(scatteredLight, ambientColor*0.1);
    }
    
    // Render sun disk
    vec3 renderSun(vec3 rayDir, vec3 sunDir, vec3 camPos, vec3 skyColor) {
        float cosTheta = dot(rayDir, sunDir);
        float sunAngle = acos(clamp(cosTheta, 0.0, 1.0));
        float sunRadius = 0.012; // Slightly larger for better visibility
        
        // Earth occlusion check
        vec3 rayOrigin = vec3(0.0, EARTH_RADIUS + 1.75 + camPos.y, 0.0);
        vec2 tEarth = raySphereIntersect(rayOrigin, rayDir, EARTH_RADIUS);
        if (tEarth.x > 0.0) return skyColor;

        vec3 sunColor = vec3(0.0);
        if (sunAngle < sunRadius) {
            // Inside sun disk
            float limb = 1.0 - pow(sunAngle / sunRadius, 0.5);
            sunColor += vec3(1.0, 0.98, 0.95) * SUN_INTENSITY * 10.0 * limb;
        } 
        
        // Sun glow/corona
        // Using multiple layers for a more natural glow
        float glare = pow(max(0.0, cosTheta), 10000.0) * 100.0;
        float halo = pow(max(0.0, cosTheta), 500.0) * 5.0;
        float bloom = pow(max(0.0, cosTheta), 10.0) * 0.1;
        
        sunColor += vec3(1.0, 0.95, 0.8) * (glare + halo + bloom) * (SUN_INTENSITY * 0.5);
        
        return max(skyColor + sunColor, vec3(0.0));
    }

    vec3 get_atmosphere(vec3 dir, vec3 sunDir, vec3 camPos) {
        vec3 col = nishitaSky(dir, sunDir, camPos);
        
        // Add sun disk
        col = renderSun(dir, sunDir, camPos, col);

        return col;
    }
]]
