extends SceneTree
## Connects every terminal destination to each graph node it can see.
##
##     godot --headless --path . --script worlds/bistro/tools/link_destinations.gd -- preview
##
## The merged graph predates the baked geometry; edges that now pass through
## it are dropped first, so no route or curve is fitted around a blocked leg.
##
## The merged graph reached each destination through one approach node, so
## every flight detoured through that node and often doubled back. Castle
## Castle's destinations are ordinary visibility-graph members; this gives
## Bistro's destinations the same line-of-sight edges, checked against the
## imported triangle geometry with a camera clearance tube.
##
## A route that still turns corners (over a roof, through a doorway) becomes a
## smooth curve in camera_routes.json. Candidates, each checked against the
## geometry: a B-spline of the graph route with its interior raised until
## clear, as the hand-authored terrace crossing does; a crane arc rising over
## the roofs between the two views; and the graph's own legs with each corner
## rounded by the widest tangent-continuous fillet that clears; and one or two
## wide rounded turns at nodes that see both views or each other. A flight has a
## fixed duration, so its peak turn rate grows with length times peak
## curvature; the candidate with the least is kept. A pair keeps its graph
## route only when no candidate clears.
const CLEARANCE := 0.2
const LIFTS := [0.0, 1.0, 2.0, 3.0, 4.0, 6.0, 8.0]
const FILLETS := [0.95, 0.8, 0.65, 0.5, 0.35, 0.25, 0.15, 0.08]
const ARCHES := [4.0, 6.0, 8.0]
## The street is a set built to be seen from the ground: above the facades the
## camera looks into unroofed building shells. No curve climbs past this.
const MAX_RISE := 8.0
const LEANS := [0.0, 0.1, 0.25, 0.4]
const SPACING := 1.5
const DOGLEG_ATTEMPTS := 6000
const DOGLEG_KEEP := 80
const MAX_DETOUR := 1.5
const MAX_LENGTHENING := 1.3

func _initialize() -> void: run.call_deferred()

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var folder := "res://worlds/bistro/generated".path_join(args[0] if not args.is_empty() else "preview")
	var scenery: Node3D = (load(folder.path_join("scenery.scn")) as PackedScene).instantiate()
	root.add_child(scenery)
	for mesh in scenery.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh != null: mesh.create_trimesh_collision()
	await physics_frame
	await physics_frame
	var space := root.get_world_3d().direct_space_state
	var path := folder.path_join("navgraph.json")
	var graph: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var nodes: Array[Vector3] = []
	for n in graph.nodes: nodes.append(Vector3(n[0], n[1], n[2]))
	var open_edges: Array = []
	for e in graph.edges:
		var a := nodes[int(e[0])]
		var b := nodes[int(e[1])]
		if a.distance_to(b) < 0.001 or space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b)).is_empty():
			open_edges.append(e)
	print("BLOCKED_EDGES removed=", graph.edges.size() - open_edges.size(), " of ", graph.edges.size())
	graph.edges = open_edges
	var linked := {}
	for e in graph.edges:
		linked[Vector2i(int(e[0]), int(e[1]))] = true
		linked[Vector2i(int(e[1]), int(e[0]))] = true
	var added := 0
	for destination in graph.walls.size():
		var eye := nodes[destination]
		for other in nodes.size():
			if other == destination or linked.has(Vector2i(destination, other)): continue
			var distance := eye.distance_to(nodes[other])
			if distance < 0.001 or not clear(space, eye, nodes[other]): continue
			graph.edges.append([destination, other, distance])
			linked[Vector2i(destination, other)] = true
			linked[Vector2i(other, destination)] = true
			added += 1
	FileAccess.open(path, FileAccess.WRITE).store_string(JSON.stringify(graph) + "\n")
	print("DESTINATION_LINKS added=", added, " graph=", path)
	var adjacency: Array = []
	adjacency.resize(nodes.size())
	for i in nodes.size(): adjacency[i] = []
	for e in graph.edges:
		adjacency[int(e[0])].append([int(e[1]), float(e[2])])
		adjacency[int(e[1])].append([int(e[0]), float(e[2])])
	var navigation: RefCounted = ClassDB.instantiate("SceneNavigationGraph")
	navigation.replace(adjacency)
	var neighbours: Array = []
	for i in nodes.size(): neighbours.append(adjacency[i].map(func(edge): return edge[0]))
	var routes: Array = []
	for a in graph.walls.size():
		for b in range(a + 1, graph.walls.size()):
			var polygon: Array[Vector3] = []
			var nodes_on_route: PackedInt32Array = navigation.route(a, b)
			if nodes_on_route.is_empty():
				push_error("%s -> %s is disconnected" % [graph.walls[a], graph.walls[b]])
				quit(1)
				return
			for node in nodes_on_route:
				if polygon.is_empty() or polygon[-1].distance_to(nodes[node]) > 0.001: polygon.append(nodes[node])
			if polygon.size() < 3: continue
			var label := "%s -> %s" % [graph.walls[a], graph.walls[b]]
			var candidates := {"spline": smooth_route(space, polygon), "arch": arch_route(space, polygon[0], polygon[-1]), "fillet": filleted_route(space, polygon),
					"dogleg": dogleg_route(space, nodes, neighbours, a, b, polygon)}
			var kind := ""
			for name in candidates:
				if candidates[name].is_empty() or not emitted_clear(space, candidates[name]): continue
				if kind.is_empty() or bend(candidates[name]) < bend(candidates[kind]): kind = name
			if kind.is_empty():
				print("GRAPH_ROUTE ", label, " (no clear curve)")
				continue
			var curve: Array[Vector3] = candidates[kind]
			var points: Array = []
			for p in curve.slice(1, curve.size() - 1): points.append([p.x, p.y, p.z])
			routes.append({"from": graph.walls[a], "to": graph.walls[b], "bidirectional": true, "points": points})
			print("CURVED_ROUTE ", label, " ", kind, " samples=", points.size(), " bend=%.1f" % bend(curve))
	var routes_path := folder.path_join("camera_routes.json")
	FileAccess.open(routes_path, FileAccess.WRITE).store_string(JSON.stringify({"routes": routes}, "  ") + "\n")
	print("CURVED_ROUTES ", routes.size(), " file=", routes_path)
	scenery.free()
	quit()

## A clamped uniform cubic B-spline of the route, resampled by arc length;
## empty when no lift of its interior clears the geometry.
static func smooth_route(space: PhysicsDirectSpaceState3D, polygon: Array[Vector3]) -> Array[Vector3]:
	for lift in LIFTS:
		var control: Array[Vector3] = [polygon[0], polygon[0], polygon[0]]
		for i in range(1, polygon.size() - 1): control.append(polygon[i] + Vector3.UP * lift)
		control.append_array([polygon[-1], polygon[-1], polygon[-1]])
		var dense: Array[Vector3] = []
		for span in control.size() - 3:
			for k in 32:
				dense.append(b_spline(control[span], control[span + 1], control[span + 2], control[span + 3], k / 32.0))
		dense.append(polygon[-1])
		var curve := resample(dense)
		var ok := true
		for i in curve.size() - 1:
			if not clear(space, curve[i], curve[i + 1]):
				ok = false
				break
		if ok: return curve
	return []

## The graph legs with each corner replaced by a quadratic fillet. A leg is
## shared by at most two corners, so each takes at most half of a shared leg.
## Fillets stay inside the corner's triangle and are checked like graph edges.
static func filleted_route(space: PhysicsDirectSpaceState3D, polygon: Array[Vector3]) -> Array[Vector3]:
	var last := polygon.size() - 1
	var dense: Array[Vector3] = [polygon[0]]
	for i in range(1, last):
		var before := polygon[i] - polygon[i - 1]
		var after := polygon[i + 1] - polygon[i]
		var reach := minf(before.length() * (1.0 if i == 1 else 0.5), after.length() * (1.0 if i + 1 == last else 0.5))
		var arc: Array[Vector3] = [polygon[i]]
		for fraction in FILLETS:
			var entry: Vector3 = polygon[i] - before.normalized() * reach * fraction
			var exit: Vector3 = polygon[i] + after.normalized() * reach * fraction
			var candidate: Array[Vector3] = []
			for k in 17:
				var t := k / 16.0
				candidate.append(entry.lerp(polygon[i], t).lerp(polygon[i].lerp(exit, t), t))
			var ok := true
			for k in 16:
				if not space.intersect_ray(PhysicsRayQueryParameters3D.create(candidate[k], candidate[k + 1])).is_empty():
					ok = false
					break
			if ok:
				arc = candidate
				break
		# Resampling would cut an unrounded corner without checking it.
		if arc.size() == 1: return []
		dense.append_array(arc)
	dense.append(polygon[last])
	# Emit exactly the checked legs and arcs: resampled chords would cut inside
	# the corners, and these legs can pass within centimetres of geometry.
	var points: Array[Vector3] = [dense[0]]
	for p in dense.slice(1):
		if p.distance_to(points[-1]) > 0.05: points.append(p)
	if points[-1] != polygon[last]: points[-1] = polygon[last]
	return points

## The shortest graph route is not the smoothest: it may thread an alley in
## many short legs where one or two wide turns in the open also connect the
## views. Ranks every one- and two-corner route by its unrounded corners, then
## rounds and checks the most promising that are not much longer than the
## shortest route, and keeps the least bend.
static func dogleg_route(space: PhysicsDirectSpaceState3D, nodes: Array[Vector3], neighbours: Array, a: int, b: int, shortest: Array[Vector3]) -> Array[Vector3]:
	# A wide turn must not buy its smoothness with distance: the flight's
	# duration is fixed, so a long way round is flown proportionally faster.
	var limit := 0.0
	for i in shortest.size() - 1: limit += shortest[i].distance_to(shortest[i + 1])
	limit = maxf(limit * MAX_LENGTHENING, nodes[a].distance_to(nodes[b]) * MAX_DETOUR)
	var ceiling: float = maxf(nodes[a].y, nodes[b].y) + MAX_RISE
	var ranked: Array = []
	var near_b := {}
	for corner in neighbours[b]:
		if nodes[corner].y <= ceiling: near_b[corner] = true
	for first in neighbours[a]:
		if nodes[first].y > ceiling: continue
		if near_b.has(first): ranked.append([corner_bend([nodes[a], nodes[first], nodes[b]]), [first]])
		for second in neighbours[first]:
			if second != a and near_b.has(second):
				ranked.append([corner_bend([nodes[a], nodes[first], nodes[second], nodes[b]]), [first, second]])
	ranked.sort_custom(func(x, y): return x[0] < y[0])
	var best: Array[Vector3] = []
	var found := 0
	for entry in ranked.slice(0, DOGLEG_ATTEMPTS):
		var legs: Array[Vector3] = [nodes[a]]
		for corner in entry[1]: legs.append(nodes[corner])
		legs.append(nodes[b])
		var length := 0.0
		for i in legs.size() - 1: length += legs[i].distance_to(legs[i + 1])
		if length > limit: continue
		var curve := filleted_route(space, legs)
		# A fillet too small to keep its samples apart is still a sharp corner.
		if curve.size() < 17 * entry[1].size(): continue
		var ok := true
		for i in curve.size() - 1:
			if not clear(space, curve[i], curve[i + 1]):
				ok = false
				break
		if not ok: continue
		if best.is_empty() or bend(curve) < bend(best): best = curve
		found += 1
		if found >= DOGLEG_KEEP: break
	return best

## Length times the sharpest corner (angle over the room to round it): the
## bend a route's fillets can reach at best, without casting a ray.
static func corner_bend(legs: Array[Vector3]) -> float:
	var length := 0.0
	var peak := 0.0
	var last := legs.size() - 1
	for i in last: length += legs[i].distance_to(legs[i + 1])
	for i in range(1, last):
		var before := legs[i] - legs[i - 1]
		var after := legs[i + 1] - legs[i]
		var reach := minf(before.length() * (1.0 if i == 1 else 0.5), after.length() * (1.0 if i + 1 == last else 0.5))
		if reach < 0.001: return INF
		peak = maxf(peak, before.angle_to(after) / reach)
	return length * peak

## A cubic Bezier from one view up over the roofs and down onto the other.
## Lean 0 climbs straight above each view; a larger lean starts across at once,
## which also clears a view that has a canopy or an awning overhead. The clear
## arc with the least bend is kept.
static func arch_route(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> Array[Vector3]:
	var best: Array[Vector3] = []
	for height in ARCHES:
		var top: float = maxf(a.y, b.y) + height
		for lean in LEANS:
			var rise: Vector3 = a.lerp(b, lean)
			var fall: Vector3 = b.lerp(a, lean)
			rise.y = top
			fall.y = top
			var dense: Array[Vector3] = []
			for k in 129:
				var t := k / 128.0
				var u := 1.0 - t
				dense.append(a * u * u * u + rise * 3.0 * u * u * t + fall * 3.0 * u * t * t + b * t * t * t)
			var curve := resample(dense)
			var ok := true
			for i in curve.size() - 1:
				if not clear(space, curve[i], curve[i + 1]):
					ok = false
					break
			if ok and (best.is_empty() or bend(curve) < bend(best)): best = curve
	return best

## Every segment the camera is actually given, as tests/preview.gd checks it.
static func emitted_clear(space: PhysicsDirectSpaceState3D, curve: Array[Vector3]) -> bool:
	for i in curve.size() - 1:
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(curve[i], curve[i + 1])).is_empty(): return false
	return true

## Length times peak curvature: at a fixed flight duration, the peak turn rate.
static func bend(curve: Array[Vector3]) -> float:
	var length := 0.0
	var peak := 0.0
	for i in curve.size() - 1:
		length += curve[i].distance_to(curve[i + 1])
		if i == 0: continue
		var before := curve[i] - curve[i - 1]
		var after := curve[i + 1] - curve[i]
		peak = maxf(peak, before.angle_to(after) / maxf((before.length() + after.length()) * 0.5, 0.001))
	return length * peak

static func b_spline(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return (p0 * u * u * u + p1 * (3.0 * t * t * t - 6.0 * t * t + 4.0) + p2 * (-3.0 * t * t * t + 3.0 * t * t + 3.0 * t + 1.0) + p3 * t * t * t) / 6.0

static func resample(dense: Array[Vector3]) -> Array[Vector3]:
	var lengths: Array[float] = [0.0]
	for i in range(1, dense.size()): lengths.append(lengths[-1] + dense[i].distance_to(dense[i - 1]))
	var count := clampi(ceili(lengths[-1] / SPACING), 8, 64)
	var out: Array[Vector3] = [dense[0]]
	var j := 1
	for k in range(1, count):
		var target := lengths[-1] * k / count
		while lengths[j] < target: j += 1
		var f := (target - lengths[j - 1]) / maxf(lengths[j] - lengths[j - 1], 0.00001)
		out.append(dense[j - 1].lerp(dense[j], f))
	out.append(dense[-1])
	return out

static func clear(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	for offset in [Vector3.ZERO, Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		var o: Vector3 = offset * CLEARANCE
		var query := PhysicsRayQueryParameters3D.create(a + o, b + o)
		query.hit_back_faces = true
		query.hit_from_inside = true
		if not space.intersect_ray(query).is_empty(): return false
	return true
