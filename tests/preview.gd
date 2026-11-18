extends SceneTree
## Run with -- --tabs=9 --shell=/bin/sh. Screenshots go to res://.cache/bistro/preview.
## The cafe doorway is the three navigation nodes starting here.
const DOORWAY_START := 1190
var failures := 0
var output := "res://.cache/bistro/preview"
func _initialize(): run.call_deferred()
func check(ok: bool, message: String):
	if not ok:
		failures += 1
		push_error(message)
func run():
	OS.set_environment("XDG_CONFIG_HOME", "/tmp/graffitty-bistro-preview")
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280,800)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var host = load("res://scenes/TerminalHost.gd").new()
	viewport.add_child(host)
	if not host.switch_world("res://worlds/bistro"):
		quit(1)
		return
	var w = host.world
	check(w.get_node("Scenery").find_children("*", "Light3D", true, false).is_empty(), "No runtime lights")
	for mesh in w.get_node("Scenery").find_children("*", "MeshInstance3D", true, false):
		for i in mesh.mesh.get_surface_count():
			check(mesh.get_active_material(i) is ShaderMaterial, "Baked material on every surface")
	check(not w.fx_env.sdfgi_enabled, "No runtime global illumination")
	await create_timer(1).timeout
	for mesh in w.get_node("Scenery").find_children("*","MeshInstance3D",true,false):
		if mesh.is_visible_in_tree() and mesh.mesh != null: mesh.create_trimesh_collision()
	await physics_frame
	await physics_frame
	var space = w.get_world_3d().direct_space_state
	# tools/link_destinations.gd: destination links and curved routes use the
	# runtime eyes and clear the imported triangles.
	var graph = JSON.parse_string(FileAccess.get_file_as_string(w.navigation_graph))
	var destinations: int = graph.walls.size()
	for e in graph.edges:
		if int(e[0]) >= destinations and int(e[1]) >= destinations: continue
		var a: Vector3 = w.nav_nodes[int(e[0])]
		var b: Vector3 = w.nav_nodes[int(e[1])]
		if a.distance_to(b) < .001: continue
		var hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b))
		check(hit.is_empty(), "Destination link %s-%s clear: %s" % [e[0], e[1], hit])
	check(not w.authored_routes.is_empty(), "Generated curved routes loaded")
	for pair in w.authored_routes:
		var points := PackedVector3Array([w.nav_nodes[pair.x]])
		points.append_array(w.authored_routes[pair].points)
		points.append(w.nav_nodes[pair.y])
		for step in points.size() - 1:
			var hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(points[step], points[step + 1]))
			check(hit.is_empty(), "Curved route %s segment %d clear: %s" % [pair, step, hit])
	check(w.fx_env.background_intensity == 1.0, "Baked sky uses unit intensity")
	for i in 2:
		var hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(w.nav_nodes[DOORWAY_START+i],w.nav_nodes[DOORWAY_START+i+1]))
		check(hit.is_empty(), "Doorway segment "+str(i)+" clear: "+str(hit))
	check(w.authored_surface_count == 9, "Nine authored destinations")
	DirAccess.make_dir_recursive_absolute(output)
	for i in w.authored_surface_count:
		var s = w.surfaces[i]
		var frame = s.uv_basis()
		for uv in [Vector2.ZERO,Vector2(0,1),Vector2(1,0),Vector2.ONE,Vector2(.5,.5)]:
			var hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(s.eye,frame.origin+frame.du*uv.x+frame.dv*uv.y))
			check(hit.is_empty(), "Unobstructed terminal: "+s.id+" "+str(uv))
		var route = w._route(0,w._nav_node_for(s))
		check(not route.is_empty(), "Connected route to "+s.id)
		for step in range(route.size()-1):
			var a = w.nav_nodes[route[step]]
			var b = w.nav_nodes[route[step+1]]
			if a.distance_to(b) < .001: continue
			var hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(a,b))
			check(hit.is_empty(), "Clear route to "+s.id+" segment "+str(step)+": "+str(hit))
		w._goto(i,true)
		if DisplayServer.get_name() != "headless":
			await create_timer(.4).timeout
			RenderingServer.force_draw()
			viewport.get_texture().get_image().save_png(output+"/"+s.id+".png")
	if DisplayServer.get_name() != "headless":
		w.set_process(false)
		w.scenery_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var review_camera := Camera3D.new()
		review_camera.attributes = w.fx_attr
		review_camera.near = .05
		review_camera.far = 2000.0
		review_camera.fov = 65
		w.scenery_vp.add_child(review_camera)
		review_camera.make_current()
		for view in [["facade",Vector3(-15,6.5,-8),Vector3(0,3,-1)],["entrance",Vector3(-6,2.5,1),Vector3(3,2.5,-3)],["threshold",Vector3(-2.7,2.5,-.7),Vector3(8,2.5,-5)],["inside-out",Vector3(2,2.5,-3),Vector3(-6,2.5,1)]]:
			review_camera.global_position = view[1]
			review_camera.look_at(view[2])
			await create_timer(.3).timeout
			RenderingServer.force_draw()
			RenderingServer.force_draw()
			w.scenery_vp.get_texture().get_image().save_png(output+"/"+view[0]+".png")
	print("BISTRO ","PASS" if failures == 0 else "FAIL", " failures=",failures)
	host.free()
	viewport.free()
	await process_frame
	quit(0 if failures == 0 else 1)
