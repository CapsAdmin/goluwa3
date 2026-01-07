return [[
// Atmosphere rendering based on:
// "A Scalable and Production Ready Sky and Atmosphere Rendering Technique"
// Sébastien Hillaire, Epic Games (Eurographics 2020)

// Planet parameters
const float R_GROUND = 6360000.0;  // Earth ground radius in meters
const float R_TOP = 6460000.0;     // Atmosphere top radius
const float PI = 3.14159265359;

// Scattering coefficients (Table 1 from paper)
const vec3 RAYLEIGH_SCATTERING = vec3(5.802, 13.558, 33.1) * 1e-6;
const vec3 MIE_SCATTERING = vec3(3.996) * 1e-6;
const vec3 MIE_ABSORPTION = vec3(4.40) * 1e-6;
const vec3 OZONE_ABSORPTION = vec3(0.650, 1.881, 0.085) * 1e-6;

// Density scale heights
const float H_RAYLEIGH = 8000.0;   // 8km
const float H_MIE = 1200.0;        // 1.2km

// Mie phase function asymmetry parameter
const float MIE_G = 0.8;

// Ground albedo
const float GROUND_ALBEDO = 0.3;

// Number of samples for ray marching
const int PRIMARY_STEPS = 32;
const int LIGHT_STEPS = 8;

// Density distributions (Section 4)
float rayleighDensity(float h) {
    return exp(-h / H_RAYLEIGH);
}

float mieDensity(float h) {
    return exp(-h / H_MIE);
}

float ozoneDensity(float h) {
    // Tent function centered at 25km, width 30km
    return max(0.0, 1.0 - abs(h - 25000.0) / 15000.0);
}

// Phase functions (Section 4)
float rayleighPhase(float cosTheta) {
    return (3.0 / (16.0 * PI)) * (1.0 + cosTheta * cosTheta);
}

// Cornette-Shanks phase function for Mie scattering
float miePhase(float cosTheta, float g) {
    float g2 = g * g;
    float num = 3.0 * (1.0 - g2) * (1.0 + cosTheta * cosTheta);
    float denom = (8.0 * PI) * (2.0 + g2) * pow(1.0 + g2 - 2.0 * g * cosTheta, 1.5);
    return num / denom;
}

// Ray-sphere intersection
// Returns distance to intersection, or -1 if no intersection
vec2 raySphereIntersect(vec3 ro, vec3 rd, float radius) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - radius * radius;
    float d = b * b - c;
    if (d < 0.0) return vec2(-1.0);
    d = sqrt(d);
    return vec2(-b - d, -b + d);
}

// Get altitude from position (assumes planet centered at origin)
float getAltitude(vec3 pos) {
    return length(pos) - R_GROUND;
}

// Compute optical depth (transmittance integral) along a ray
vec3 computeOpticalDepth(vec3 rayOrigin, vec3 rayDir, float rayLength, int steps) {
    float stepSize = rayLength / float(steps);
    vec3 opticalDepth = vec3(0.0);
    
    for (int i = 0; i < steps; i++) {
        float t = (float(i) + 0.5) * stepSize;
        vec3 pos = rayOrigin + rayDir * t;
        float h = getAltitude(pos);
        
        if (h < 0.0) break; // Below ground
        
        // Accumulate optical depth for each medium type
        float densityR = rayleighDensity(h);
        float densityM = mieDensity(h);
        float densityO = ozoneDensity(h);
        
        vec3 localExtinction = 
            RAYLEIGH_SCATTERING * densityR +
            (MIE_SCATTERING + MIE_ABSORPTION) * densityM +
            OZONE_ABSORPTION * densityO;
        
        opticalDepth += localExtinction * stepSize;
    }
    
    return opticalDepth;
}

// Compute transmittance between two points (Equation 2)
vec3 transmittance(vec3 pa, vec3 pb) {
    vec3 dir = normalize(pb - pa);
    float dist = length(pb - pa);
    vec3 opticalDepth = computeOpticalDepth(pa, dir, dist, LIGHT_STEPS);
    return exp(-opticalDepth);
}

// Compute transmittance from a point to the sun (atmosphere boundary)
vec3 transmittanceToSun(vec3 pos, vec3 sunDir) {
    vec2 atmoHit = raySphereIntersect(pos, sunDir, R_TOP);
    if (atmoHit.y < 0.0) return vec3(1.0);
    
    float dist = atmoHit.y;
    return exp(-computeOpticalDepth(pos, sunDir, dist, LIGHT_STEPS));
}

// Multiple scattering approximation (Section 5.5)
// This is the key contribution of the paper - O(1) multiple scattering
vec3 computeMultipleScattering(vec3 pos, vec3 sunDir, vec3 sunIlluminance) {
    float h = getAltitude(pos);
    if (h < 0.0 || h > R_TOP - R_GROUND) return vec3(0.0);
    
    // Simplified multiple scattering contribution
    // In production, this would be a LUT lookup (Section 5.5.2)
    // Here we compute an approximation inline
    
    float densityR = rayleighDensity(h);
    float densityM = mieDensity(h);
    
    vec3 scattering = RAYLEIGH_SCATTERING * densityR + MIE_SCATTERING * densityM;
    
    // Second order scattering approximation (Equation 5-6)
    // Isotropic phase for multiple scattering
    float pu = 1.0 / (4.0 * PI);
    
    // Transmittance to sun for this position
    vec3 T_sun = transmittanceToSun(pos, sunDir);
    
    // Approximate L2ndorder (simplified - in production use proper integration)
    vec3 L2nd = scattering * T_sun * pu;
    
    // Transfer function fms approximation (Equation 7-8)
    // This represents energy transfer from surrounding medium
    float fms = 0.0;
    float totalScattering = dot(scattering, vec3(1.0/3.0));
    
    // Simplified fms based on local scattering (proper version integrates over sphere)
    fms = min(0.9, totalScattering * H_RAYLEIGH * 0.5);
    
    // Infinite series sum (Equation 9)
    float Fms = 1.0 / (1.0 - fms);
    
    // Final multiple scattering contribution (Equation 10)
    vec3 Psi_ms = L2nd * Fms;
    
    return Psi_ms * sunIlluminance;
}

// Main atmosphere rendering function
vec3 get_atmosphere(vec3 dir, vec3 sunDir, vec3 camPos) {
    // Sun illuminance (can be parameterized)
    vec3 sunIlluminance = vec3(7); 
    
    // Camera position relative to planet center
    // camPos is in world units (meters), with Y as up
    // Place camera on planet surface + camPos.y altitude
    // If camPos is (0,0,0), we're at ground level
    float altitude = max(camPos.y, 1.0); // At least 1m above ground
    vec3 rayOrigin = vec3(camPos.x, R_GROUND + altitude, camPos.z);
    vec3 rayDir = normalize(dir);
    
    // Find atmosphere intersection
    vec2 atmoHit = raySphereIntersect(rayOrigin, rayDir, R_TOP);
    vec2 groundHit = raySphereIntersect(rayOrigin, rayDir, R_GROUND);
    
    if (atmoHit.y < 0.0) {
        // Ray doesn't hit atmosphere
        return vec3(0.0);
    }
    
    // Determine ray start and end
    float tStart = max(0.0, atmoHit.x);
    float tEnd = atmoHit.y;
    
    // Check for ground intersection
    bool hitGround = false;
    if (groundHit.x > 0.0) {
        tEnd = groundHit.x;
        hitGround = true;
    }
    
    float rayLength = tEnd - tStart;
    float stepSize = rayLength / float(PRIMARY_STEPS);
    
    // Accumulated values
    vec3 inScattering = vec3(0.0);
    vec3 transmittanceAccum = vec3(1.0);
    
    // Phase function evaluation
    float cosTheta = dot(rayDir, sunDir);
    float phaseR = rayleighPhase(cosTheta);
    float phaseM = miePhase(cosTheta, MIE_G);
    
    // Ray march through atmosphere (Equation 1)
    for (int i = 0; i < PRIMARY_STEPS; i++) {
        float t = tStart + (float(i) + 0.5) * stepSize;
        vec3 pos = rayOrigin + rayDir * t;
        float h = getAltitude(pos);
        
        if (h < 0.0) break;
        
        // Local medium properties
        float densityR = rayleighDensity(h);
        float densityM = mieDensity(h);
        float densityO = ozoneDensity(h);
        
        vec3 scatteringR = RAYLEIGH_SCATTERING * densityR;
        vec3 scatteringM = MIE_SCATTERING * densityM;
        vec3 extinction = scatteringR + 
                          (MIE_SCATTERING + MIE_ABSORPTION) * densityM +
                          OZONE_ABSORPTION * densityO;
        
        // Transmittance for this step
        vec3 stepTransmittance = exp(-extinction * stepSize);
        
        // Shadow term: transmittance from sample to sun (Equation 4)
        vec3 T_sun = transmittanceToSun(pos, sunDir);
        
        // Check if sun is visible (planet shadow)
        vec2 planetShadow = raySphereIntersect(pos, sunDir, R_GROUND);
        float visibility = (planetShadow.x > 0.0) ? 0.0 : 1.0;
        
        // Single scattering contribution (Equation 3)
        vec3 S = visibility * T_sun;
        vec3 scatteringSingle = 
            scatteringR * phaseR * S +
            scatteringM * phaseM * S;
        
        // Multiple scattering contribution (Equation 11)
        vec3 scatteringMulti = computeMultipleScattering(pos, sunDir, sunIlluminance);
        
        // Total scattering (Equation 11)
        vec3 totalScattering = (scatteringSingle + scatteringMulti) * sunIlluminance;
        
        // Integrate in-scattering with transmittance
        // Using the improved integration formula for better energy conservation
        vec3 scatteringIntegral = (totalScattering - totalScattering * stepTransmittance) / 
                                   max(extinction, vec3(1e-10));
        
        inScattering += transmittanceAccum * scatteringIntegral;
        transmittanceAccum *= stepTransmittance;
    }
    
    // Add ground contribution if we hit it
    if (hitGround) {
        vec3 groundPos = rayOrigin + rayDir * tEnd;
        vec3 groundNormal = normalize(groundPos);
        float NdotL = max(0.0, dot(groundNormal, sunDir));
        
        // Check if ground point is in shadow
        vec2 groundShadow = raySphereIntersect(groundPos + groundNormal * 0.001, sunDir, R_GROUND);
        if (groundShadow.x < 0.0) {
            vec3 T_ground = transmittanceToSun(groundPos, sunDir);
            vec3 groundColor = vec3(GROUND_ALBEDO / PI) * NdotL * T_ground * sunIlluminance;
            inScattering += transmittanceAccum * groundColor;
        }
    }
    
    // Add sun disk
    float sunAngularRadius = 0.00935; // ~0.5 degrees
    if (cosTheta > cos(sunAngularRadius) && !hitGround) {
        vec3 sunTransmittance = transmittanceToSun(rayOrigin, sunDir);
        inScattering += sunTransmittance * sunIlluminance * 100.0;
    }
    
    return inScattering;
}]]
