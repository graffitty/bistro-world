extends SceneTree
## Imports GLB directly, avoiding project editor plugins and their scene switching.
var textures := {}
var folder: String

func _initialize() -> void:
	run.call_deferred()

func texture(path: String) -> Texture2D:
	if textures.has(path): return textures[path]
	var image := Image.load_from_file(folder.path_join(path))
	assert(image != null, "Cannot load " + path)
	image.generate_mipmaps()
	if path.ends_with(".png"):
		assert(image.compress(Image.COMPRESS_S3TC) == OK, "Texture compression failed: " + path)
	var result := ImageTexture.create_from_image(image)
	textures[path] = result
	return result

func own(node: Node, scene: Node) -> void:
	for child in node.get_children():
		child.owner = scene
		own(child, scene)

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var preset := args[0] if args.size() else "preview"
	folder = "res://worlds/bistro/generated/" + preset
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("manifest.json")))
	manifest["denoise"] = JSON.parse_string(FileAccess.get_file_as_string("res://worlds/bistro/.build/" + preset + "/denoise-state.json"))
	for chunk in manifest.chunks:
		assert(manifest.denoise.has(chunk.name), "Missing denoise result")
		assert(FileAccess.get_sha256(folder.path_join(chunk.lightmap)) == manifest.denoise[chunk.name].output_sha256, "Stale denoised lightmap")
	manifest["godot"] = Engine.get_version_info().string
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(folder.path_join("geometry.glb"), state)
	assert(error == OK, "GLB import failed")
	var scene := document.generate_scene(state)
	assert(scene != null)
	scene.name = "Scenery"
	var maps := {}
	for chunk in manifest.chunks: maps[chunk.name] = chunk.lightmap
	var shader := load("res://worlds/bistro/tools/baked_light.gdshader")
	var surface_count := 0
	for mesh in scene.find_children("*", "MeshInstance3D", true, false):
		assert(maps.has(str(mesh.name)), "Unknown chunk " + str(mesh.name))
		var lightmap := texture(maps[str(mesh.name)])
		for i in mesh.mesh.get_surface_count():
			var arrays: Array = mesh.mesh.surface_get_arrays(i)
			assert(arrays[Mesh.ARRAY_TEX_UV2] != null and arrays[Mesh.ARRAY_TEX_UV2].size() == arrays[Mesh.ARRAY_VERTEX].size(), "Missing lightmap UV")
			var original: Material = mesh.mesh.surface_get_material(i)
			assert(manifest.materials.has(original.resource_name), "Unknown material " + original.resource_name)
			var record: Dictionary = manifest.materials[original.resource_name]
			var material := ShaderMaterial.new()
			material.shader = shader
			material.resource_name = original.resource_name
			material.set_shader_parameter("lightmap_texture", lightmap)
			material.set_shader_parameter("emission_strength", record.emission_strength)
			material.set_shader_parameter("base_color", Color(record.color[0],record.color[1],record.color[2],record.color[3]))
			for pair in [["base_texture","albedo"], ["emission_texture","emission"]]:
				if not str(record[pair[0]]).is_empty():
					material.set_shader_parameter(pair[1] + "_texture", texture(record[pair[0]]))
					material.set_shader_parameter("has_" + pair[1], true)
			mesh.set_surface_override_material(i, material)
			surface_count += 1
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	own(scene, scene)
	var packed := PackedScene.new()
	assert(packed.pack(scene) == OK)
	assert(ResourceSaver.save(packed, folder.path_join("scenery.scn"), ResourceSaver.FLAG_COMPRESS) == OK)
	# Keep the source graph intact. tools/link_destinations.gd then adds the
	# destinations' line-of-sight edges and curved routes to this copy.
	var graph: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://worlds/bistro/navgraph.json"))
	FileAccess.open(folder.path_join("navgraph.json"), FileAccess.WRITE).store_string(JSON.stringify(graph) + "\n")
	FileAccess.open(folder.path_join("manifest.json"), FileAccess.WRITE).store_string(JSON.stringify(manifest,"  ")+"\n")
	print("BAKED_SCENE_READY chunks=",maps.size()," surfaces=",surface_count," textures=",textures.size()," folder=",folder)
	scene.free()
	quit()
