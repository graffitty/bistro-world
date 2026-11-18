shader_type spatial;
render_mode unshaded, cull_disabled;
// Blender diffuse bake excludes albedo. glTF TEXCOORD_1 becomes Godot UV2.
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D emission_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D lightmap_texture : filter_linear_mipmap, repeat_disable;
uniform vec4 base_color : source_color = vec4(1.0);
uniform bool has_albedo = false;
uniform bool has_emission = false;
uniform float emission_strength = 0.0;
// Display-only night grading: reveal unlit surfaces without lifting black albedo
// or increasing already-lit fixtures. These defaults also apply after re-export.
uniform float shadow_fill : hint_range(0.0, 0.5) = 0.012;
uniform float shadow_rolloff = 0.25;
uniform float baked_light_gain = 1.0;
uniform float visible_emission_scale : hint_range(0.0, 1.0) = 0.1;
void fragment() {
    vec4 base = has_albedo ? texture(albedo_texture, UV) : base_color;
    if (base.a < 0.5) { discard; }
    // Denoising can undershoot zero. Negative HDR radiance creates NaNs
    // in tone mapping/glow; clamp before display grading.
    vec3 lighting = max(texture(lightmap_texture, UV2).rgb, vec3(0.0)) * baked_light_gain;
    float luminance = dot(lighting, vec3(0.2126, 0.7152, 0.0722));
    lighting += vec3(0.45, 0.65, 1.0) * shadow_fill * exp(-luminance / shadow_rolloff);
    vec3 emitted = has_emission ? texture(emission_texture, UV).rgb * emission_strength * visible_emission_scale : vec3(0.0);
    ALBEDO = base.rgb * lighting + emitted;
}
