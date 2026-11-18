extends SceneTree
## Export authored transforms without starting a world, PTY, or scene script.
func _initialize() -> void:
	var source := "res://worlds/bistro/world.tscn"
	var scene := load(source) as PackedScene
	assert(scene != null)
	var state := scene.get_state()
	var nodes: Dictionary = {}
	for i in state.get_node_count():
		var properties: Dictionary = {}
		for j in state.get_node_property_count(i):
			properties[str(state.get_node_property_name(i, j))] = state.get_node_property_value(i, j)
		var parent: Transform3D = nodes.get(str(state.get_node_path(i, true)), {}).get("pose", Transform3D.IDENTITY)
		properties.pose = parent * properties.get("transform", Transform3D(Basis.IDENTITY, properties.get("position", Vector3.ZERO)))
		nodes[str(state.get_node_path(i))] = properties
	var destinations: Array = []
	for path: String in nodes:
		var properties: Dictionary = nodes[path]
		if not properties.has("canvas"): continue
		var pose: Transform3D = properties.pose
		var camera: Dictionary = nodes[path.path_join("ViewPose")]
		assert(camera.get("keep_aspect", 1) == 0)
		var camera_pose: Transform3D = camera.pose
		# BistroBaked.gd reorients all destinations to the authored surface normal.
		var normal := pose.basis.z.normalized()
		var distance := maxf(absf((camera_pose.origin - pose.origin).dot(normal)), 0.1)
		camera_pose = Transform3D(Basis.IDENTITY, pose.origin + normal * distance).looking_at(pose.origin, pose.basis.y.normalized())
		var canvas: Vector2 = properties.canvas
		destinations.append({"name": properties.get("surface_id", path.get_file()), "order": properties.get("visit_order", 0),
			"canvas": [canvas.x * pose.basis.x.length(), canvas.y * pose.basis.y.length()],
			"position": vec(pose.origin), "rotation": quat(pose.basis.orthonormalized().get_rotation_quaternion()),
			"surface_lift": float(properties.get("surface_lift", 0.06)) * pose.basis.z.length(),
			"camera_position": vec(camera_pose.origin), "camera_rotation": quat(camera_pose.basis.get_rotation_quaternion()), "fov": camera.get("fov", 75.0)})
	destinations.sort_custom(func(a, b): return a.order < b.order)
	var output := OS.get_cmdline_user_args()[0]
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	FileAccess.open(output, FileAccess.WRITE).store_string(JSON.stringify({"schema": 1,
		"source": {"name": source, "format": "godot-tscn-scene-state", "sha256": FileAccess.get_sha256(source)},
		"destinations": destinations}, "  ") + "\n")
	print("Exported Bistro destinations: ", destinations.size())
	quit()

func vec(v: Vector3) -> Array: return [v.x, v.y, v.z]
func quat(q: Quaternion) -> Array: return [q.x, q.y, q.z, q.w]
