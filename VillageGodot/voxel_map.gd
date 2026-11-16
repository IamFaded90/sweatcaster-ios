extends SubViewportContainer

const Terrain = preload("res://terrain.gd")
var world_view: SubViewport
var planet: Node3D
var camera: Camera3D
var markers: Node3D

func build(tiles: Dictionary, places: Dictionary, bots: Array[Dictionary]) -> void:
	stretch = true
	world_view = SubViewport.new()
	world_view.own_world_3d = true
	world_view.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(world_view)
	planet = Node3D.new()
	world_view.add_child(planet)
	# Add a single block-cap and one extruded column per cell. No per-frame mesh rebuilding.
	for slot: Vector2i in tiles:
		var value: Vector2i = tiles[slot]
		var tile_height := 0.4 * value.y + 0.15
		var block := cube(Vector3(1, tile_height, 1), Terrain.COLORS[value.x])
		block.position = Vector3(slot.x + slot.y * 0.39, tile_height / 2.0, slot.y)
		planet.add_child(block)
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
	camera.position = Vector3(17, 18, 22)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	planet.add_child(camera)
	camera.look_at(Vector3(0, 1, 0))
	camera.current = true
	rebuild_bots(places, bots)

func set_zoom(value: float) -> void:
	if camera != null:
		camera.size = 24.0 / clampf(value, 1, 2.2)

func rebuild_bots(places: Dictionary, bots: Array[Dictionary]) -> void:
	if markers != null:
		markers.queue_free()
	markers = Node3D.new()
	planet.add_child(markers)
	for id in places:
		var cell: Vector2i = places[id].cell
		var building := cube(Vector3(1.2, 1.1, 1.2), Color("#e1cd9f"))
		building.position = Vector3(cell.x + cell.y * 0.39, 2.25, cell.y)
		markers.add_child(building)
	for index in bots.size():
		var cell: Vector2i = places[bots[index].zone].cell
		var bot := cube(Vector3(0.34, 0.63, 0.34), Color("#6ddcbb"))
		bot.position = Vector3(cell.x + cell.y * 0.39 + index * 0.12, 2.0, cell.y + 0.85)
		markers.add_child(bot)

func cube(dimensions: Vector3, color: Color) -> MeshInstance3D:
	var block := BoxMesh.new()
	block.size = dimensions
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	block.material = material
	var instance := MeshInstance3D.new()
	instance.mesh = block
	return instance
