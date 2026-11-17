extends SceneTree

func _initialize() -> void:
	call_deferred("run_checks")

func run_checks() -> void:
	var map = preload("res://village.tscn").instantiate()
	root.add_child(map)
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or args.size() > 2:
		push_error("Expected a test snapshot path and optional Office layout path")
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
	if args.size() == 2 and not await check_office(map, args[1]):
		quit(1)
		return
	quit()

func check_office(map, path: String) -> bool:
	map.show_voxel(true)
	map.load_office(path)
	var office = map.office_view
	if office == null or map.voxel_map.visible or map.village_actions.visible:
		push_error("The Office layout did not open from the existing Village")
		return false
	office.set_physics_process(false)
	for index in range(90):
		await physics_frame
		office.walk(Vector2(0, -1), 0.0, 1.0 / 60.0)
	if not (-1.32 < office.walker.position.z and office.walker.position.z < -0.85):
		push_error("The Office walker did not stop at the scanned table")
		return false
	office.walk(Vector2.ZERO, 1.0, 0.15)
	if office.walker.rotation.y < 0.2:
		push_error("The Office walker did not turn")
		return false
	map.close_office()
	if map.office_view != null or not map.voxel_map.visible or not map.village_actions.visible or map.bots[0].name != "Prøvebot":
		push_error("Closing Office lost the Village mode or snapshot")
		return false
	map.load_office(OS.get_cmdline_user_args()[0])
	if map.office_view != null or not map.voxel_map.visible:
		push_error("An incompatible layout replaced the Village")
		return false
	print("FadedAI Godot: Office import, walk, collision, turn, and return passed")
	return true
