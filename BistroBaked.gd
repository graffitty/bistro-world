extends "res://scenes/TerminalWorld3D.gd"
## Bistro: editable terminal destinations over the baked Cycles scenery.
## Static Cycles lighting is already in the shader's linear output.
## Outdoor visibility is graded separately from the already-lit cafe interior.
@export_dir var asset_directory: String
@export_range(0.0, 1.0) var terminal_backdrop_alpha := 0.0
@export_file("*.json") var navigation_graph := ""
@export_range(0.0, 1.0) var exterior_shadow_fill := 0.012
@export_range(0.0, 1.0) var interior_shadow_fill := 0.018
@export_range(0.0, 8.0) var exterior_baked_light_gain := 0.65
@export_range(0.0, 8.0) var interior_baked_light_gain := 0.5

var _source_screen_names: Array = []

func _init() -> void:
	super()
	settings_script = preload("res://scenes/WorldSettings.gd")
	use_navgraph = true
	# Every world starts from the same shared effect defaults.
	default_config = "res://presets/flat.conf"

func configure_terminal(user: TerminalConfig) -> TerminalConfig:
	var inherited: TerminalConfig = user.copy()
	inherited.background.alpha = terminal_backdrop_alpha
	return super.configure_terminal(inherited)

## Settings come from [worlds.bistro] in client.toml.
func read_settings(user: TerminalConfig) -> RefCounted:
	return preload("res://graffitty/world_config.gd").load_settings(settings_script, user, PackedStringArray(["bistro"]))

func _ready() -> void:
	super._ready()
	cam.far = 20000.0
	if ink_cam != null: ink_cam.far = cam.far

func _configure_scenery_antialiasing(viewport: SubViewport, _compositor: Viewport) -> void:
	# Configure before the viewport enters the tree, avoiding a second set of
	# render targets and shader variants when AA changes during startup.
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.use_taa = true

func _configure_ink_antialiasing(viewport: SubViewport) -> void:
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED

func _load_world() -> Dictionary:
	world_dir = asset_directory
	_adopt_surfaces(get_node("Surfaces"))
	authored_surface_count = surfaces.size()
	var source_graph = _read_json(world_dir.path_join("navgraph.json"))
	_source_screen_names = source_graph.get("walls", [])
	_load_navgraph()
	_front_facing_destinations()
	var light := _read_json(world_dir.path_join("lighting.json"))
	wall_shade = float(light.get("terminal_shade", 0.0))
	return light

func _load_navgraph() -> void:
	var scenery_directory := world_dir
	if not navigation_graph.is_empty():
		world_dir = navigation_graph.get_base_dir()
	super._load_navgraph()
	world_dir = scenery_directory

func _front_facing_destinations() -> void:
	for surface in surfaces:
		var normal: Vector3 = surface.global_basis.z.normalized()
		var distance: float = maxf(absf((surface.eye - surface.global_position).dot(normal)), 0.1)
		var view: Camera3D = surface.view_pose
		view.global_position = surface.global_position + normal * distance
		view.look_at(surface.global_position, surface.global_basis.y.normalized())
		var index: int = nav_node_for_surface.get(surface.id, -1)
		if index >= 0: nav_nodes[index] = surface.eye
	# Route endpoints now land on the front-facing views, not the old oblique poses.
	if not _navigation_graph.reweight(nav_nodes):
		push_error("Navigation positions do not match the loaded graph")

func _navigation_route(prev: int, idx: int) -> PackedVector3Array:
	# The two outdoor cafe views share an open approach. A saved graph overview
	# can sit well outside the authored eye: routing back through that eye makes
	# the camera double back. Prefer the actual displayed endpoints when clear.
	if prev >= 0 and idx >= 0 and prev < surfaces.size() and idx < surfaces.size():
		var pair := [surfaces[prev].id, surfaces[idx].id]
		if pair.has("cafe-awning") and pair.has("terrace-tables"):
			var target := _camera_base_frame(surfaces[idx].eye, surfaces[idx].forward, surfaces[idx].up, surfaces[idx].half_x)
			if _floating(): target = _camera_fx_frame(target)
			var origin: Vector3 = camera_motion.frame.transform.origin
			var destination: Vector3 = target.transform.origin
			if _outdoor_route_is_clear(origin,destination):
				navigation_route_kind = "direct-clear"
				navigation_allows_wall_crossing = false
				_flight_endpoints = Vector2i(-1,-1)
				fly_path = PackedVector3Array()
				return fly_path
	return super._navigation_route(prev,idx)

func _outdoor_route_is_clear(origin: Vector3, destination: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	for offset in [Vector3.ZERO, Vector3.UP * .15, Vector3.DOWN * .15, Vector3.RIGHT * .15, Vector3.LEFT * .15, Vector3.FORWARD * .15, Vector3.BACK * .15]:
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(origin + offset,destination + offset)).is_empty():
			return false
	return true

func _authored_navigation_route(from_node: int, to_node: int) -> Dictionary:
	var terrace: int = nav_node_for_surface.get("cafe-terrace", -1)
	var square: int = nav_node_for_surface.get("square-reverse", -1)
	# This open-air crossing used a vertical graph leg beside the terrace.
	# Its tight corner made the interpolator backtrack before crossing the
	# square. A broad, clearance-checked arc starts moving across immediately.
	# The shared router handles departures, reversal and graph fallback.
	var crossing := terrace >= 0 and square >= 0 and ((from_node == terrace and to_node == square) or (from_node == square and to_node == terrace))
	if crossing:
		var a: Vector3 = nav_nodes[terrace]
		var b: Vector3 = nav_nodes[square]
		var p := a.lerp(b, .25) + Vector3.UP * 4.0
		var q := a.lerp(b, .65) + Vector3.UP * 4.0
		var points := PackedVector3Array()
		for i in range(1, 24):
			var t := float(i) / 24.0 if from_node == terrace else 1.0 - float(i) / 24.0
			var u := 1.0 - t
			points.append(a * u*u*u + 3.0*p*u*u*t + 3.0*q*u*t*t + b*t*t*t)
		return {"points": points, "allow_wall_crossing": false}
	return super._authored_navigation_route(from_node, to_node)

func _build_world() -> void:
	_hide_placeholder_screens(get_node("Scenery"))
	_build_walls()
	for mesh in get_node("Scenery").find_children("*", "MeshInstance3D", true, false):
		var fill: float = interior_shadow_fill if str(mesh.name) == "Cafe" else exterior_shadow_fill
		for i in mesh.mesh.get_surface_count():
			var material: Material = mesh.get_active_material(i)
			if material is ShaderMaterial:
				material.set_shader_parameter("shadow_fill", fill)
				material.set_shader_parameter("visible_emission_scale", 0.1)
				material.set_shader_parameter("baked_light_gain", interior_baked_light_gain if str(mesh.name) == "Cafe" else exterior_baked_light_gain)

func _build_environment(_light: Dictionary) -> void:
	get_viewport().transparent_bg = false
	get_window().set_flag(Window.FLAG_TRANSPARENT, false)
	fx_env = Environment.new()
	fx_env.background_mode = Environment.BG_COLOR
	fx_env.background_color = Color("080d18")
	# Baked/unshaded radiance uses unit exposure. The physical sky default
	# (30,000 nits) otherwise overflows filmic tone mapping and blooms gaps.
	fx_env.background_intensity = 1.0
	fx_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	fx_env.glow_enabled = true
	fx_env.glow_intensity = 0.12
	fx_attr = CameraAttributesPhysical.new()
	fx_attr.exposure_aperture = F_APERTURE
	fx_attr.exposure_shutter_speed = F_SHUTTER
	fx_attr.exposure_sensitivity = F_ISO
	fx_attr.exposure_multiplier = F_APERTURE * F_APERTURE * F_SHUTTER * (100.0 / F_ISO) * 1.2
	tonemap_exposure = 1.0
	var environment := WorldEnvironment.new()
	environment.environment = fx_env
	environment.camera_attributes = fx_attr
	add_child(environment)

func _hide_placeholder_screens(node: Node) -> void:
	# The scenery's named black screen meshes would occlude the live terminals.
	if node is MeshInstance3D and (nav_node_for_surface.has(str(node.name)) or str(node.name) in _source_screen_names):
		node.hide()
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children(): _hide_placeholder_screens(child)
