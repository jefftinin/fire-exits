class_name LineUtils
extends Object

## Recomputes a Line2D's arc length and sets the "total_length" shader
## parameter so dash sizes stay fixed in pixels regardless of line length
## (prevents the UV-based "pulsing" artifact).
static func update_total_length(line: Line2D) -> void:
	var len := 0.0
	var pts := line.points
	for i in range(1, pts.size()):
		len += pts[i - 1].distance_to(pts[i])
	var mat := line.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("total_length", len)