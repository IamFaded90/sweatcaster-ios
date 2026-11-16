extends SceneTree

func _initialize() -> void:
	call_deferred("run_checks")

func run_checks() -> void:
	var map = preload("res://village.tscn").instantiate()
	root.add_child(map)
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("Expected a test snapshot path")
		quit(1)
		return
	map.load_snapshot(args[0])
	map.show_voxel(true)
	map.set_zoom(4.0)
	if map.tiles.size() != 217 or map.bots.size() != 1 or map.bots[0].name != "Prøvebot" \
		or map.zoom != 2.2 or map.voxel_map.markers.get_child_count() != 7:
		push_error("FadedAI snapshot, hex grid or 3D navigation failed")
		quit(1)
		return
	map.show_voxel(false)
	if map.voxel_map.visible:
		push_error("Could not leave 3D view")
		quit(1)
		return
	print("FadedAI Godot: snapshot, hex grid, voxel scene and zoom passed")
	quit()
