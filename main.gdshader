shader_type canvas_item;

// Uniforms allow you to tweak the effect in the Inspector
// total_length should be updated by script whenever the Line2D changes.
// UV.x is a fraction (0..1) along the line, so we multiply by total_length
// to get a true pixel distance along the line. This keeps dash sizes fixed
// regardless of how long the line grows.
uniform float total_length : hint_range(0.0, 10000.0) = 100.0;
uniform float dash_px : hint_range(1.0, 100.0) = 10.0;
uniform float gap_px : hint_range(1.0, 100.0) = 10.0;
uniform float speed : hint_range(-10.0, 10.0) = 1.0;
uniform vec4 ant_color : source_color = vec4(1, 1, 1, 1);

void fragment() {
    // Convert UV fraction to pixel distance along the line
    float distance_along = UV.x * total_length;
    
    // Total length of one dash+gap cycle in pixels
    float cycle_px = dash_px + gap_px;
    
    // Create a scrolling coordinate system in pixel space
    // (distance / cycle) gives which cycle we're in; TIME * speed animates it
    float pos = fract(distance_along / cycle_px + (TIME * speed));
    
    // Determine if we are in a 'dash' or a 'gap'
    float dash_ratio = dash_px / cycle_px;
    float mask = step(pos, dash_ratio);
    
    // Apply the mask to the alpha channel
    if (mask < 0.5) {
        discard;
    }
    
    // Set the final color
    COLOR = ant_color;
}