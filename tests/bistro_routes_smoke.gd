extends SceneTree
const Motion := preload("res://scenes/CameraMotion.gd")
var failed := false
func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-bistro-route-test-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	_run.call_deferred()
func expect(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	failed = failed or not ok
func frame_at(point: Vector3) -> Dictionary:
	return Motion.pose(point, Vector3.FORWARD, Vector3.UP, Vector4(-.5, -.3, 1, .6))

class Bistro extends "res://worlds/bistro/BistroBaked.gd":
	var clear := true
	func _outdoor_route_is_clear(_origin: Vector3, _destination: Vector3) -> bool:
		return clear
	func _floating() -> bool:
		return false
	func _camera_base_frame(eye: Vector3, forward: Vector3, up: Vector3, _half_x: float) -> Dictionary:
		return Motion.pose(eye,forward,up,Vector4(-.5,-.3,1,.6))

func _run() -> void:
	var previous_orphans := Node.get_orphan_node_ids()
	var world := Bistro.new()
	world.nav_nodes = PackedVector3Array([Vector3(0,0,10),Vector3(20,0,10),Vector3(40,0,10),Vector3(10,5,10)])
	world._navigation_graph.replace([[[3,12.0]],[[3,12.0]],[[3,32.0]],[[0,12.0],[1,12.0],[2,32.0]]])
	for i in 3:
		var surface := TerminalSurface3D.new()
		surface.surface_id = ["cafe-awning","terrace-tables","dining-room"][i]
		surface.position = Vector3(i*20,0,0)
		(Engine.get_main_loop() as SceneTree).root.add_child(surface)
		world.surfaces.append(surface)
		world.nav_node_for_surface[surface.id] = i
	world.camera_motion.reset(frame_at(Vector3(-5,0,10)))
	expect(world._navigation_route(0,1).is_empty() and world.navigation_route_kind == "direct-clear", "A panned outdoor departure uses a clear direct path")
	expect(not world.navigation_allows_wall_crossing, "Direct outdoor flight never bypasses collision policy")
	world.clear = false
	expect(not world._navigation_route(0,1).is_empty() and world.navigation_route_kind == "graph", "An obstruction retains graph routing")
	world.clear = true
	expect(not world._navigation_route(0,2).is_empty() and world.navigation_route_kind == "graph", "The indoor route keeps the doorway navigation graph")
	for surface in world.surfaces: surface.free()
	world.surfaces.clear()
	world.free()
	_authored_reversal()
	for id in Node.get_orphan_node_ids():
		if id in previous_orphans or not is_instance_id_valid(id): continue
		var node := instance_from_id(id) as Node
		if node != null and node.get_parent() == null: node.free()
	_finish.call_deferred()

func _authored_reversal() -> void:
	var world := Bistro.new()
	world.nav_node_for_surface = {"cafe-terrace": 0, "square-reverse": 1}
	world.nav_nodes = PackedVector3Array([Vector3(-8,2.2,3), Vector3(27,2.3,24)])
	var forward: Dictionary = world._authored_navigation_route(0, 1)
	var backward: Dictionary = world._authored_navigation_route(1, 0)
	var reversed: PackedVector3Array = forward.points.duplicate()
	reversed.reverse()
	expect(forward.points.size() == 23 and backward.points.size() == 23, "Bistro retains its existing sampled curve")
	var same: bool = reversed.size() == backward.points.size()
	for i in reversed.size():
		same = same and reversed[i].is_equal_approx(backward.points[i])
	expect(same, "Bistro reverse has the same geometry")
	expect(not forward.allow_wall_crossing, "Bistro's authored route grants no wall-crossing exception")
	world.free()

func _finish() -> void:
	await process_frame
	quit(1 if failed else 0)
