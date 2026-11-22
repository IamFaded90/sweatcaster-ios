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
	if not check_passages_and_markers(map):
		quit(1)
		return
	map.load_snapshot(args[0])
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

func solid_at(landscape: Node3D, point: Vector3) -> bool:
	for rock: MeshInstance3D in landscape.get_children():
		if rock.get_aabb().has_point(point - rock.position):
			return true
	return false

func check_passages_and_markers(map) -> bool:
	var voxel = map.voxel_map
	if voxel.passages.size() < 2:
		push_error("Expected visible cliff passages in the default terrain")
		return false
	for cell: Vector2i in voxel.passages:
		var limits: Vector2 = voxel.passages[cell]
		var top: Vector3 = map.Terrain.voxel_surface(cell, map.tiles[cell])
		var middle := Vector3(top.x, (limits.x + limits.y) * 0.5, top.z)
		var mouth := middle + Vector3.RIGHT * 0.49
		for rock: MeshInstance3D in voxel.landscape.get_children():
			var local_mouth := mouth - rock.position
			if rock.get_aabb().intersects_segment(local_mouth, local_mouth + voxel.camera.global_transform.basis.z * 35.0) != null:
				push_error("The default camera cannot see the cave entrance")
				return false
		for step in [0.7, 0.4, 0.0, -0.6, -1.25]:
			if solid_at(voxel.landscape, middle + Vector3.RIGHT * step):
				push_error("The bank or rock blocks passage into the cliff")
				return false
		for boundary in [Vector3(top.x, limits.x - 0.02, top.z), Vector3(top.x, limits.y + 0.02, top.z),
				middle + Vector3.BACK * 0.42, middle + Vector3.LEFT * 1.45]:
			if not solid_at(voxel.landscape, boundary):
				push_error("Cave is missing a floor, roof, wall or closed end")
				return false
	for zone in map.PLACES:
		var crowd: Array[Dictionary] = []
		for index in 10:
			crowd.append({"zone": zone, "id": str(index)})
		voxel.rebuild_bots(map.PLACES, crowd)
		if voxel.markers.get_child_count() != map.PLACES.size() + crowd.size():
			push_error("A marker is missing from a crowded room")
			return false
		var footprints: Array[Rect2] = []
		for marker: MeshInstance3D in voxel.markers.get_children():
			var size := marker.mesh.get_aabb().size
			var base := marker.position - Vector3.UP * (size.y * 0.5)
			var footprint := Rect2(base.x - size.x * 0.5, base.z - size.z * 0.5, size.x, size.z)
			for other in footprints:
				if footprint.intersects(other):
					push_error("Two village markers overlap")
					return false
			footprints.append(footprint)
			for corner in [footprint.position, footprint.end]:
				var floor_point := Vector3(corner.x, base.y, corner.y)
				if not solid_at(voxel.landscape, floor_point - Vector3.UP * 0.01) \
					or solid_at(voxel.landscape, floor_point + Vector3.UP * 0.01):
					push_error("A building or resident is floating or buried")
					return false
	print("FadedAI Godot: %d visible caves, floors and roofs, six buildings and six crowds of ten grounded residents passed" % voxel.passages.size())
	return true

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
