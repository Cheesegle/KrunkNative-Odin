#version 450 core
out vec4 frag_color;

in vec2 tex_coord;
in flat int face_idx;
in vec3 world_pos;

uniform float world_uv_scale;

#ifdef BATCHED
in flat int object_idx;

struct Batch_Object {
    mat4 transform;
    vec4 color;
    vec4 emissive;
    vec4 face_scale; // xyz face scale, w texture scale
    vec4 tex_row0;
    vec4 tex_row1;
    ivec4 flags; // x face mask, y bit flags, z float bits of alpha_test
};
layout (std430, binding = 0) readonly buffer Batch_Objects {
    Batch_Object objects[];
};
#else
uniform bool is_ramp;
uniform bool is_ladder;

uniform bool use_face_tex_scaling;
uniform int face_mask;
uniform float texture_scale;
uniform bool unlit;
uniform bool no_fog;
uniform vec3 face_scale;

uniform vec4 color;
uniform vec4 emissive;
uniform float alpha_test;

uniform mat3 tex_transform;
#endif

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

void main() {
#ifdef BATCHED
    // Same values the per-object path uploads as uniforms (map_batch.odin).
    Batch_Object o = objects[object_idx];
    bool m_is_ramp = (o.flags.y & 1) != 0;
    bool m_is_ladder = (o.flags.y & 2) != 0;
    bool m_use_face_tex_scaling = (o.flags.y & 4) != 0;
    bool m_unlit = (o.flags.y & 8) != 0;
    bool m_no_fog = (o.flags.y & 16) != 0;
    int m_face_mask = o.flags.x;
    float m_texture_scale = o.face_scale.w;
    vec3 m_face_scale = o.face_scale.xyz;
    vec4 m_color = o.color;
    vec4 m_emissive = o.emissive;
    float m_alpha_test = intBitsToFloat(o.flags.z);
    mat3 m_tex_transform = mat3(
        vec3(o.tex_row0.x, o.tex_row1.x, 0.0),
        vec3(o.tex_row0.y, o.tex_row1.y, 0.0),
        vec3(o.tex_row0.z, o.tex_row1.z, 1.0));
#else
    bool m_is_ramp = is_ramp;
    bool m_is_ladder = is_ladder;
    bool m_use_face_tex_scaling = use_face_tex_scaling;
    bool m_unlit = unlit;
    bool m_no_fog = no_fog;
    int m_face_mask = face_mask;
    float m_texture_scale = texture_scale;
    vec3 m_face_scale = face_scale;
    vec4 m_color = color;
    vec4 m_emissive = emissive;
    float m_alpha_test = alpha_test;
    mat3 m_tex_transform = tex_transform;
#endif

    if (face_idx < 6 && ((m_face_mask & (1 << face_idx)) == 0)) discard;
    vec2 scaled_tex_coord;

    if (m_use_face_tex_scaling) {
        vec2 scale;

        if (m_is_ramp) {
            switch (face_idx) {
                case 0:
                    scale = vec2(m_face_scale.x, sqrt(m_face_scale.z*m_face_scale.z + m_face_scale.y*m_face_scale.y));
                    break;
                case 1:
                    scale = m_face_scale.xz;
                    break;
                case 2:
                    scale = m_face_scale.zy;
                    break;
                case 3:
                    scale = m_face_scale.xy;
                    break;
            }
        } else if (m_is_ladder) {
            if (face_idx < 2) scale = m_face_scale.xy;
            else if (face_idx < 4) scale = m_face_scale.zy;
            else if (face_idx < 6) scale = m_face_scale.xz;
            else if (face_idx < 8) scale = m_face_scale.xy;
            else if (face_idx < 10) scale = m_face_scale.zy;
            else scale = m_face_scale.xz;
        } else {
            if (face_idx < 2) scale = m_face_scale.xy;
            else if (face_idx < 4) scale = m_face_scale.zy;
            else scale = m_face_scale.xz;
        }

        vec2 repeat_scale = (scale / world_uv_scale) * m_texture_scale;
        scaled_tex_coord = repeat_scale * tex_coord;
        scaled_tex_coord.x += 0.5f - repeat_scale.x * 0.5f;
    } else {
        scaled_tex_coord = tex_coord;
    }

    vec3 t_tex_coord = m_tex_transform * vec3(scaled_tex_coord, 1.0f);
    frag_color = texture(tex, t_tex_coord.xy) * mix(m_color, m_emissive, 0.0f);
    // Cutout foliage stays in the opaque pass, with holes in color and depth.
    if (frag_color.a < m_alpha_test) discard;

    vec3 normal = normalize(cross(dFdx(world_pos), dFdy(world_pos)));
    float light_length = length(uLightDir);
    vec3 light_direction = light_length > 0.0001 ? uLightDir / light_length : vec3(0.0, 1.0, 0.0);
    float diffuse = max(dot(normal, light_direction), 0.0);
    vec3 lighting = uAmbientColor * uAmbientIntensity + uLightColor * (uLightIntensity * diffuse);
    // Three.js applies color management/tone mapping after accumulating light.
    // Keep the native path from saturating every textured face when the live
    // map's ambient and directional intensities sum above one.
    float peak_light = max(max(lighting.r, lighting.g), max(lighting.b, 1.0));
    lighting = (uAmbientColor * uAmbientIntensity * uVisualLighting.x + uLightColor * (uLightIntensity * diffuse * uVisualLighting.y)) / peak_light;
    // The map loader uses white as the neutral/default emissive value. Keep
    // that default neutral; explicit emissive materials need a separate
    // strength flag before they can be added without brightening every mesh.
    vec3 lit_rgb = frag_color.rgb * (m_unlit ? vec3(1.0) : lighting);
    float fog_span = max(0.001, uFogFar - uFogNear);
    float fog_amount = m_no_fog ? 0.0 : clamp((length(world_pos - uCameraPosition) - uFogNear) / fog_span, 0.0, 1.0);
    vec3 rgb = mix(lit_rgb, uFogColor, fog_amount);
    rgb = (rgb * uVisualImage.x - 0.5) * uVisualImage.z + 0.5;
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    rgb = mix(vec3(luma), rgb, uVisualImage.w);
    rgb = pow(clamp(rgb, 0.0, 1.0), vec3(1.0 / max(0.01, uVisualImage.y)));
    frag_color = vec4(rgb, frag_color.a);
}
