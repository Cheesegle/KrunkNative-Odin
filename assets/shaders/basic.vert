#version 450 core
// BATCHED (injected by shader_compile) draws many static map objects in one
// call. Each vertex keeps its object's model-space position and original UV;
// the per-object values come from an SSBO instead of uniforms. All arithmetic
// below is shared, so both variants produce bit-identical results.
layout (location = 0) in vec3 v_pos;
layout (location = 1) in vec2 v_tex_coord;

out vec2 tex_coord;
out flat int face_idx;
out vec3 world_pos;

uniform mat4 camera_world_inverse;
uniform mat4 camera_projection;

invariant gl_Position;

#ifdef BATCHED
layout (location = 2) in uint v_face_idx;
layout (location = 3) in uint v_object;
out flat int object_idx;

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
uniform mat4 transform;
#endif

void main() {
    tex_coord = v_tex_coord;
#ifdef BATCHED
    mat4 m_transform = objects[v_object].transform;
#else
    mat4 m_transform = transform;
#endif
    world_pos = vec3(m_transform * vec4(v_pos, 1.0));

#ifdef BATCHED
    // Computed on the CPU with the per-object rule below.
    face_idx = int(v_face_idx);
    object_idx = int(v_object);
#else
    if (is_ramp) {
        if (gl_VertexID < 4) face_idx = 0;
        else if (gl_VertexID < 8) face_idx = 1;
        else if (gl_VertexID - 8 < 6) face_idx = 2;
        else face_idx = 3;
    } else {
		// Cube geometry uses four unique indexed vertices per face.
		face_idx = gl_VertexID / 4;
    }
#endif

    gl_Position = camera_projection * camera_world_inverse * vec4(world_pos, 1.0f);
}
