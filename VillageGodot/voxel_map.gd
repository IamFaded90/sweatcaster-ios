extends SubViewportContainer

const Terrain = preload("res://terrain.gd")
var world_view: SubViewport
var planet: Node3D
var camera: Camera3D
var markers: Node3D
var landscape: Node3D
var surfaces: Dictionary
var passages: Dictionary

func build(tiles: Dictionary, places: Dictionary, bots: Array[Dictionary]) -> void:
	stretch = true
	world_view = SubViewport.new()
	world_view.own_world_3d = true
	world_view.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(world_view)
	planet = Node3D.new()
	world_view.add_child(planet)
	surfaces = tiles
	passages = Terrain.cave_passages(tiles, places)
	landscape = Node3D.new()
	planet.add_child(landscape)
	for slot: Vector2i in tiles:
		var value: Vector2i = tiles[slot]
		var top := Terrain.voxel_surface(slot, value)
		var entrance := slot if passages.has(slot) else slot + Vector2i.RIGHT
		if passages.has(entrance):
			build_passage(top, Terrain.COLORS[value.x], passages[entrance], entrance != slot)
		else:
			add_rock(Vector3(1, top.y, 1), Vector3(top.x, top.y * 0.5, top.z), Terrain.COLORS[value.x])
	var sunlight := DirectionalLight3D.new()
	sunlight.rotation_degrees = Vector3(-46, -35, 0)
	sunlight.shadow_enabled = true
	planet.add_child(sunlight)
	var light := WorldEnvironment.new()
	light.environment = Environment.new()
	light.environment.background_mode = Environment.BG_COLOR
	light.environment.background_color = Color("#192220")
	light.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	light.environment.ambient_light_color = Color("#ccd4bf")
	light.environment.ambient_light_energy = 0.8
	planet.add_child(light)
	camera = Camera3D.new()
	camera.position = Vector3(0, 1, 0) + Terrain.VOXEL_CAMERA_OFFSET
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	planet.add_child(camera)
	camera.look_at(Vector3(0, 1, 0))
	camera.current = true
	rebuild_bots(places, bots)

func add_rock(dimensions: Vector3, at: Vector3, color: Color) -> void:
	var piece := cube(dimensions, color)
	piece.position = at
	landscape.add_child(piece)

func build_passage(top: Vector3, color: Color, opening: Vector2, closed_end: bool) -> void:
	var floor_y := opening.x
	var roof_y := opening.y
	var height := roof_y - floor_y
	var middle := (roof_y + floor_y) * 0.5
	var stone := Color("#6b6759")
	add_rock(Vector3(1, floor_y, 1), Vector3(top.x, floor_y * 0.5, top.z), stone)
	add_rock(Vector3(1, top.y - roof_y, 1), Vector3(top.x, (roof_y + top.y) * 0.5, top.z), color)
	for side in [-1.0, 1.0]:
		# Open the near corner of the mouth towards the isometric camera.
		var length := 0.52 if side > 0 and not closed_end else 1.0
		add_rock(Vector3(length, height, 0.16), Vector3(top.x - (1.0 - length) * 0.5, middle, top.z + 0.42 * side), stone)
	if closed_end:
		add_rock(Vector3(0.15, height, 0.68), Vector3(top.x - 0.425, middle, top.z), Color("#363b37"))

func set_zoom(value: float) -> void:
	if camera != null:
		camera.size = 24.0 / clampf(value, 1, 2.2)

func rebuild_bots(places: Dictionary, bots: Array[Dictionary]) -> void:
	if markers != null:
		markers.hide()
		markers.queue_free()
	markers = Node3D.new()
	planet.add_child(markers)
	var occupied := {}
	for id in places:
		var cell: Vector2i = places[id].cell
		var building := cube(Vector3(0.92, 1.1, 0.92), Color("#e1cd9f"))
		building.position = Terrain.voxel_surface(cell, surfaces[cell]) + Vector3.UP * 0.55
		markers.add_child(building)
		occupied[cell] = 4
	for index in bots.size():
		var cell: Vector2i = places[bots[index].zone].cell
		var standing := standing_cell(cell, occupied)
		var used: int = occupied.get(standing, 0)
		var bot := cube(Vector3(0.34, 0.63, 0.34), Color("#6ddcbb"))
		var corner := Vector3(-0.22 if used % 2 == 0 else 0.22, 0.315, 0.22 if used < 2 else -0.22)
		bot.position = Terrain.voxel_surface(standing, surfaces[standing]) + corner
		markers.add_child(bot)
		occupied[standing] = used + 1

func standing_cell(home: Vector2i, occupied: Dictionary) -> Vector2i:
	var front := Vector2(home) + Vector2(0, 0.85)
	var nearest := home
	var distance := INF
	for cell: Vector2i in surfaces:
		if surfaces[cell].x == Terrain.WATER or occupied.get(cell, 0) >= 4:
			continue
		var next_distance := Vector2(cell).distance_squared_to(front)
		if next_distance < distance:
			distance = next_distance
			nearest = cell
	return nearest

func cube(dimensions: Vector3, color: Color) -> MeshInstance3D:
	var block := BoxMesh.new()
	block.size = dimensions
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	block.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = block
	return instance
