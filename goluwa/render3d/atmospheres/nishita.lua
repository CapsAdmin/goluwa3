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
        vec3 rayOrigin = vec3(0.0, EARTH_RADIUS + 1.75 + camPos.y, 0.0);
        
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

    vec3 get_atmosphere(vec3 dir, vec3 sunDir, vec3 camPos) {
        vec3 col = nishitaSky(dir, sunDir, camPos);
        
        // Add sun disk
        col = renderSun(dir, sunDir, col);

        return col;
    }
]]
