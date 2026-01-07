return [[
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
