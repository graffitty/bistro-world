extends SceneTree
## Optional installed-world integration: no shells or live application changes.
const TerminalConfig := preload("res://graffitty/terminal_config.gd")
const Effects := preload("res://scenes/Effects.gd")
const Kit := preload("res://scenes/TerminalWorld3D.gd")
var failed := false

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	failed = failed or not ok

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-world-settings-smoke-%d" % OS.get_process_id())
	OS.set_environment("XDG_CONFIG_HOME", isolated)
	var user := TerminalConfig.new()
	user.font_size = 23
	for entry in [
		["bistro", "res://worlds/bistro/BistroBaked.gd", "res://worlds/bistro"]]:
		var script = load(entry[1])
		if script == null or not script.can_instantiate():
			check(false, entry[0] + " compiles")
			continue
		var world = script.new()
		check(world is Kit, entry[0] + " uses complete shared world kit")
		if not entry[2].is_empty(): world.asset_directory = entry[2]
		var config = world.configure_terminal(user)
		check(config.font_size == 23 and user.font_size == 23, entry[0] + " preserves user font")
		check(world.settings.validate().is_empty(), entry[0] + " defaults validate")
		check(world.default_config == "res://presets/flat.conf", entry[0] + " uses the shared default preset")
		check(world.use_navgraph and world.terminal_space_scene != null, entry[0] + " retains navigation and presenter")
		var effects := Effects.new()
		check(effects.load_config(world.default_config), entry[0] + " preset loads")
		config.apply_effects(effects)
		world.configure_effects(effects)
		check(effects.scene.tab_switch.effect == "push_pull", entry[0] + " defaults to tab zoom")
		check(effects.scene.session_switch.effect == "fly_away_and_in", entry[0] + " defaults to two-way session flight")
		check(effects.scene.session_switch.fly_ratio_sparse == 0.5 and effects.scene.session_switch.fly_ratio_dense == 0.1 and effects.scene.session_switch.fly_dense_count == 1200, entry[0] + " defaults to 50 percent sparse, 10 percent dense at 1200 characters")
		check(world.render_scale == 1.0, entry[0] + " keeps full render scale")
		check(world.motion_render_scale == 1.0, entry[0] + " keeps full resolution while moving")
		var mild := Effects.new()
		mild.load_config("res://presets/flat.conf")
		for state in ["idle", "typing"]:
			for key in mild.states[state]:
				check(effects.states[state][key] == mild.states[state][key], entry[0] + " matches Flat World state: " + state + "." + key)
		for group in ["camera", "lighting", "sheet", "typing"]:
			for key in mild.scene[group]:
				check(effects.scene[group][key] == mild.scene[group][key], entry[0] + " matches Flat World effect: " + group + "." + key)
		check(is_equal_approx(config.background.alpha, 0.0), entry[0] + " keeps background alpha")
		# Each world names its own table: imported worlds by asset directory.
		var id: String = world.asset_directory.get_file()
		var config_path := preload("res://config/UserConfig.gd").config_path()
		DirAccess.make_dir_recursive_absolute(config_path.get_base_dir())
		var file := FileAccess.open(config_path, FileAccess.WRITE)
		file.store_string('[worlds."%s"]\nsheet.padding = 39\nterminal.font_size = 28\nsession_switch.fly_ratio_sparse = 0.7\nsession_switch.fly_ratio_dense = 0.2\nsession_switch.fly_dense_count = 600\n' % id)
		file.close()
		var configured = world.configure_terminal(user)
		check(configured.font_size == 28 and world.terminal_padding == 39, entry[0] + " loads its client.toml world table")
		world.configure_effects(effects)
		check(effects.scene.session_switch.fly_ratio_sparse == 0.7 and effects.scene.session_switch.fly_ratio_dense == 0.2 and effects.scene.session_switch.fly_dense_count == 600, entry[0] + " applies session ratios from its world config")
		effects.set_option("scene.session_switch", "fly_ratio_dense", 0.3)
		check(effects.scene.session_switch.fly_ratio_dense == 0.3, entry[0] + " allows explicit effects overrides after world config")
		DirAccess.remove_absolute(config_path)
		world.free()
	# Constructor-created controls are not yet parented before _ready().
	for id in Node.get_orphan_node_ids():
		if not is_instance_id_valid(id): continue
		var node := instance_from_id(id) as Node
		if node != null and node.get_parent() == null and node != root: node.free()
	quit(1 if failed else 0)
