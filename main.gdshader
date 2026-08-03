shader_type canvas_item;

// Uniforms allow you to tweak the effect in the Inspector
uniform float dash_length : hint_range(0.01, 1.0) = 0.1;
uniform float gap_length : hint_range(0.01, 1.0) = 0.1;
uniform float speed : hint_range(-10.0, 10.0) = 1.0;
uniform vec4 ant_color : source_color = vec4(1, 1, 1, 1);

void fragment() {
    // UV.x goes from 0.0 (start of line) to 1.0 (end of line)
    // We multiply by a large number to get repeating segments along the line
    float scale = 10.0; 
    
    // Calculate the total length of one dash+gap cycle
    float cycle = dash_length + gap_length;
    
    // Create a scrolling coordinate system
    // We multiply UV.x by scale to fit more dashes, then add TIME * speed to animate
    float scroll = fract((UV.x * scale) + (TIME * speed));
    
    // Determine if we are in a 'dash' or a 'gap'
    // If the scrolled position is less than the dash ratio, it's visible
    float dash_ratio = dash_length / cycle;
    float mask = step(scroll, dash_ratio);
    
    // Apply the mask to the alpha channel
    // If mask is 0.0, we discard the pixel (make it transparent)
    if (mask < 0.5) {
        discard;
    }
    
    // Set the final color
    COLOR = ant_color;
}