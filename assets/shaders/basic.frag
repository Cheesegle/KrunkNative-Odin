#version 450 core
out vec4 frag_color;

in vec2 tex_coord;
in flat int face_idx;
in vec3 world_pos;

uniform bool is_ramp;
uniform bool is_ladder;

uniform bool use_face_tex_scaling;
uniform int face_mask;
uniform float texture_scale;
uniform bool unlit;
uniform bool no_fog;
uniform float world_uv_scale;
uniform vec3 face_scale;

uniform vec4 color;
uniform vec4 emissive;
uniform float alpha_test;

uniform mat3 tex_transform;
uniform sampler2D tex;
uniform vec3 uAmbientColor;
uniform float uAmbientIntensity;
uniform vec3 uLightColor;
uniform float uLightIntensity;
uniform vec3 uLightDir;
uniform vec3 uFogColor;
uniform float uFogNear;
uniform float uFogFar;
uniform vec3 uCameraPosition;
uniform vec4 uVisualImage; // brightness, gamma, contrast, saturation
uniform vec2 uVisualLighting; // ambient and sunlight multipliers

// Krunker "Lighting": 0 Low (unlit), 1 Normal (Lambert), 2 High (Phong),
// 3 Physical (standard, roughness 1, metalness 0). See shadows.odin.
uniform int uLightingMode;
// Krunker "Shadows": the sun's orthographic shadow map.
uniform bool uShadowEnabled;
uniform bool receive_shadow;
uniform mat4 uShadowMatrix; // world -> shadow map uv (xy) and depth (z)
uniform sampler2DShadow uShadowMap;
uniform bool uShadowSoft; // PCFShadowMap; otherwise BasicShadowMap
uniform float uShadowTexel; // shadow.radius (1) / mapSize
uniform float uShadowBias;
uniform float uShadowNormalBias;
// Map POINT/SPOT/DIRECTIONAL_LIGHT objects (High and Physical).
#define MAX_MAP_LIGHTS 16
uniform int uMapLightCount;
uniform vec4 uMapLightPosition[MAX_MAP_LIGHTS]; // xyz, kind (0 point, 1 spot, 2 directional)
uniform vec4 uMapLightColor[MAX_MAP_LIGHTS]; // rgb * intensity, distance
uniform vec4 uMapLightDirection[MAX_MAP_LIGHTS]; // spot axis or direction to light, decay
uniform vec2 uMapLightCone[MAX_MAP_LIGHTS]; // cos(angle), cos(angle * (1 - penumbra))

// three.js interleavedGradientNoise and vogelDiskSample, as used by its
// PCFShadowFilter.
float interleaved_gradient_noise(vec2 position) {
    return fract(52.9829189 * fract(dot(position, vec2(0.06711056, 0.00583715))));
}

vec2 vogel_disk_sample(int index, int count, float phi) {
    float r = sqrt((float(index) + 0.5) / float(count));
    float theta = float(index) * 2.399963229728653 + phi;
    return vec2(cos(theta), sin(theta)) * r;
}

float sun_shadow(vec3 normal) {
    vec4 coord = uShadowMatrix * vec4(world_pos + normal * uShadowNormalBias, 1.0);
    vec3 shadow_coord = coord.xyz / coord.w;
    shadow_coord.z += uShadowBias;
    // Outside the shadow camera's frustum is lit.
    if (shadow_coord.x < 0.0 || shadow_coord.x > 1.0 || shadow_coord.y < 0.0 || shadow_coord.y > 1.0 || shadow_coord.z > 1.0) return 1.0;
    if (!uShadowSoft) return texture(uShadowMap, shadow_coord);
    float phi = interleaved_gradient_noise(gl_FragCoord.xy) * 6.28318530718;
    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        vec2 offset = vogel_disk_sample(i, 5, phi) * uShadowTexel;
        sum += texture(uShadowMap, vec3(shadow_coord.xy + offset, shadow_coord.z));
    }
    return sum * 0.2;
}

vec3 f_schlick(vec3 f0, float dot_vh) {
    float fresnel = exp2((-5.55473 * dot_vh - 6.98316) * dot_vh);
    return f0 * (1.0 - fresnel) + fresnel;
}

// Specular BRDF times pi (three.js scales Krunker's light intensities by pi,
// which cancels the 1/pi in each BRDF and in BRDF_Lambert).
vec3 specular_brdf(vec3 light_dir, vec3 view_dir, vec3 normal, float dot_nl) {
    vec3 half_dir = normalize(light_dir + view_dir);
    float dot_nh = clamp(dot(normal, half_dir), 0.0, 1.0);
    float dot_vh = clamp(dot(view_dir, half_dir), 0.0, 1.0);
    if (uLightingMode == 2) {
        // BRDF_BlinnPhong: specular 0x111111, shininess 30.
        return f_schlick(vec3(17.0 / 255.0), dot_vh) * (0.25 * (30.0 * 0.5 + 1.0) * pow(dot_nh, 30.0));
    }
    // BRDF_GGX with roughness 1 (alpha 1): D = 1/pi, V = 0.5 / (NdotL + NdotV).
    float dot_nv = clamp(dot(normal, view_dir), 0.0, 1.0);
    return f_schlick(vec3(0.04), dot_vh) * (0.5 / max(dot_nl + dot_nv, 1e-6));
}

void main() {
    if (face_idx < 6 && ((face_mask & (1 << face_idx)) == 0)) discard;
    vec2 scaled_tex_coord;

    if (use_face_tex_scaling) {
        vec2 scale;

        if (is_ramp) {
            switch (face_idx) {
                case 0:
                    scale = vec2(face_scale.x, sqrt(face_scale.z*face_scale.z + face_scale.y*face_scale.y));
                    break;
                case 1:
                    scale = face_scale.xz;
                    break;
                case 2:
                    scale = face_scale.zy;
                    break;
                case 3:
                    scale = face_scale.xy;
                    break;
            }
        } else if (is_ladder) {
            if (face_idx < 2) scale = face_scale.xy;
            else if (face_idx < 4) scale = face_scale.zy;
            else if (face_idx < 6) scale = face_scale.xz;
            else if (face_idx < 8) scale = face_scale.xy;
            else if (face_idx < 10) scale = face_scale.zy;
            else scale = face_scale.xz;
        } else {
            if (face_idx < 2) scale = face_scale.xy;
            else if (face_idx < 4) scale = face_scale.zy;
            else scale = face_scale.xz;
        }

        vec2 repeat_scale = (scale / world_uv_scale) * texture_scale;
        scaled_tex_coord = repeat_scale * tex_coord;
        scaled_tex_coord.x += 0.5f - repeat_scale.x * 0.5f;
    } else {
        scaled_tex_coord = tex_coord;
    }

    vec3 t_tex_coord = tex_transform * vec3(scaled_tex_coord, 1.0f);
    frag_color = texture(tex, t_tex_coord.xy) * mix(color, emissive, 0.0f);
    // Cutout foliage stays in the opaque pass, with holes in color and depth.
    if (frag_color.a < alpha_test) discard;
#ifdef SHADOW_DEPTH_PASS
    return;
#endif

    vec3 normal = normalize(cross(dFdx(world_pos), dFdy(world_pos)));
    float light_length = length(uLightDir);
    vec3 light_direction = light_length > 0.0001 ? uLightDir / light_length : vec3(0.0, 1.0, 0.0);
    float diffuse = max(dot(normal, light_direction), 0.0);
    float sun_diffuse = diffuse;
    if (uShadowEnabled && receive_shadow && diffuse > 0.0) diffuse *= sun_shadow(normal);
    vec3 lighting = uAmbientColor * uAmbientIntensity + uLightColor * (uLightIntensity * diffuse);
    vec3 extra_diffuse = vec3(0.0);
    vec3 specular = vec3(0.0);
    bool shaded = !unlit && uLightingMode != 0;
    if (shaded && uLightingMode >= 2) {
        vec3 view_dir = normalize(uCameraPosition - world_pos);
        specular = uLightColor * (uLightIntensity * diffuse) * specular_brdf(light_direction, view_dir, normal, sun_diffuse);
        for (int i = 0; i < uMapLightCount; i++) {
            vec3 to_light;
            float attenuation = 1.0;
            int kind = int(uMapLightPosition[i].w);
            if (kind == 2) {
                to_light = uMapLightDirection[i].xyz;
            } else {
                vec3 delta = uMapLightPosition[i].xyz - world_pos;
                float distance = length(delta);
                to_light = delta / max(distance, 1e-4);
                // three.js getDistanceAttenuation.
                attenuation = 1.0 / max(pow(distance, uMapLightDirection[i].w), 0.01);
                float cutoff = uMapLightColor[i].w;
                if (cutoff > 0.0) {
                    float ratio = distance / cutoff;
                    float falloff = clamp(1.0 - ratio * ratio * ratio * ratio, 0.0, 1.0);
                    attenuation *= falloff * falloff;
                }
                if (kind == 1) attenuation *= smoothstep(uMapLightCone[i].x, uMapLightCone[i].y, dot(to_light, -uMapLightDirection[i].xyz));
            }
            float dot_nl = max(dot(normal, to_light), 0.0);
            vec3 irradiance = uMapLightColor[i].rgb * (attenuation * dot_nl);
            extra_diffuse += irradiance;
            specular += irradiance * specular_brdf(to_light, view_dir, normal, dot_nl);
        }
        lighting += extra_diffuse;
    }
    // Three.js applies color management/tone mapping after accumulating light.
    // Keep the native path from saturating every textured face when the live
    // map's ambient and directional intensities sum above one.
    float peak_light = max(max(lighting.r, lighting.g), max(lighting.b, 1.0));
    lighting = (uAmbientColor * uAmbientIntensity * uVisualLighting.x + uLightColor * (uLightIntensity * diffuse * uVisualLighting.y)) / peak_light;
    if (shaded && uLightingMode >= 2) {
        lighting += extra_diffuse * (uVisualLighting.y / peak_light);
        specular *= uVisualLighting.y / peak_light;
    }
    // The map loader uses white as the neutral/default emissive value. Keep
    // that default neutral; explicit emissive materials need a separate
    // strength flag before they can be added without brightening every mesh.
    vec3 lit_rgb = frag_color.rgb * (shaded ? lighting : vec3(1.0)) + specular;
    float fog_span = max(0.001, uFogFar - uFogNear);
    float fog_amount = no_fog ? 0.0 : clamp((length(world_pos - uCameraPosition) - uFogNear) / fog_span, 0.0, 1.0);
    vec3 rgb = mix(lit_rgb, uFogColor, fog_amount);
    rgb = (rgb * uVisualImage.x - 0.5) * uVisualImage.z + 0.5;
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    rgb = mix(vec3(luma), rgb, uVisualImage.w);
    rgb = pow(clamp(rgb, 0.0, 1.0), vec3(1.0 / max(0.01, uVisualImage.y)));
    frag_color = vec4(rgb, frag_color.a);
}
