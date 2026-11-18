extends SceneTree
## Pack Bistro's runtime files into bistro.pck and bistro.json.
## Run through pipeline.py (`python3 pipeline.py pack`); the output directory
## follows `--`. The baked scenery holds its meshes and textures, so the source
## archive, pipeline tools, bake intermediates and tests are never packed.
const WORLD := "res://worlds/bistro"
const FILES := [
	"BistroBaked.gd", "plugin.json", "lighting.json", "navgraph.json",
	"tools/baked_light.gdshader", "world.tscn",
	"generated/preview/scenery.scn", "generated/preview/navgraph.json",
	"generated/preview/camera_routes.json",
]

var packer := PCKPacker.new()
var packed := { }
var resource_uids := { }
var failed := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("Pass the output directory after --")
		quit(1)
		return
	var out: String = args[0]
	if not FileAccess.file_exists(WORLD + "/generated/preview/scenery.scn"):
		push_error("Run `pipeline.py all` before packing")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(out)
	check(packer.pck_start(out.path_join("bistro.pck")))
	for name in FILES:
		add_file(WORLD + "/" + name)
	check(packer.flush())
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(WORLD + "/plugin.json"))
	manifest["resource_uids"] = resource_uids
	var file := FileAccess.open(out.path_join("bistro.json"), FileAccess.WRITE)
	if file == null:
		check(FileAccess.get_open_error())
	else:
		file.store_string(JSON.stringify(manifest, "\t") + "\n")
		file.close()
	print("[pack] bistro: %d files" % packed.size())
	quit(1 if failed else 0)


func check(error: Error) -> void:
	if error != OK:
		push_error("Pack operation failed: %s" % error_string(error))
		failed = true


func add_file(path: String) -> void:
	if packed.has(path):
		return
	if not FileAccess.file_exists(path):
		push_error("Missing runtime file: " + path)
		failed = true
		return
	packed[path] = true
	check(packer.add_file(path, path))


func add_tree(path: String) -> void:
	if FileAccess.file_exists(path.path_join(".gdignore")):
		return
	for name in DirAccess.get_directories_at(path):
		if not name.begins_with("."):
			add_tree(path.path_join(name))
	for name in DirAccess.get_files_at(path):
		var file := path.path_join(name)
		if name.ends_with(".uid"):
			continue
		if name.ends_with(".import"):
			# Ship the remap and its imported GPU resources, not the source PNG/glTF/EXR.
			add_file(file)
			var cfg := ConfigFile.new()
			check(cfg.load(file))
			var uid := str(cfg.get_value("remap", "uid", ""))
			if not uid.is_empty():
				resource_uids[uid] = file.trim_suffix(".import")
			for dest in cfg.get_value("deps", "dest_files", PackedStringArray()):
				add_file(dest)
		elif not FileAccess.file_exists(file + ".import"):
			add_file(file)
