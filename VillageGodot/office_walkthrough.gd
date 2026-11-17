extends SubViewportContainer

const PLAYER_RADIUS := 0.22
const WALK_SPEED := 2.0
const TURN_SPEED := 1.8

var walker: CharacterBody3D
var room_bounds: Rect2

static func parse_layout(data: Variant) -> Dictionary:
	if not data is Dictionary or data.get("format") != "fadedai-office" or data.get("version") != 1:
		return {}
	var items: Variant = data.get("items")
	if not items is Array or items.is_empty() or items.size() > 150:
		return {}
	var bounds := Rect2()
	var has_wall := false
	for item in items:
		if not item is Dictionary or not item.get("wall") is bool or not item.get("bot") is bool:
			return {}
		if not item.get("title") is String or (item.wall and item.bot):
			return {}
		if not dimension(item.get("width"), 0.04, 60.0) or not dimension(item.get("depth"), 0.04, 60.0) \
				or not dimension(item.get("height"), 0.04, 12.0) or not dimension(item.get("angle"), -TAU, TAU) \
				or not dimension(item.get("x"), -181.0, 181.0) or not dimension(item.get("z"), -181.0, 181.0):
			return {}
		if item.wall:
			var sine := absf(sin(item.angle))
			var cosine := absf(cos(item.angle))
			var span := Vector2(cosine * item.width + sine * item.depth, sine * item.width + cosine * item.depth)
			var extent := Rect2(Vector2(item.x, item.z) - span / 2.0, span)
			bounds = bounds.merge(extent) if has_wall else extent
			has_wall = true
	if not has_wall:
		return {}
	var walkable := bounds.grow(-PLAYER_RADIUS)
	if walkable.size.x <= 0.0 or walkable.size.y <= 0.0:
		return {}
	for ix in [0.5, 0.25, 0.75, 0.1, 0.9]:
		for iz in [0.5, 0.25, 0.75, 0.1, 0.9]:
			var point := walkable.position + Vector2(ix, iz) * walkable.size
			if clear_at(point, items):
				return {"bounds": bounds, "spawn": point, "items": items}
	return {}

static func dimension(value: Variant, minimum: float, maximum: float) -> bool:
	return (value is float or value is int) and is_finite(value) and value >= minimum and value <= maximum

static func clear_at(point: Vector2, items: Array) -> bool:
	for item in items:
		if item.bot:
			continue
		var local := (point - Vector2(item.x, item.z)).rotated(-item.angle).abs()
		if local.x < item.width / 2.0 + PLAYER_RADIUS and local.y < item.depth / 2.0 + PLAYER_RADIUS:
			return false
	return true

func build(layout: Dictionary) -> void:
	stretch = true
	room_bounds = layout.bounds
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(viewport)
	var world := Node3D.new()
	viewport.add_child(world)
	var light := WorldEnvironment.new()
	light.environment = Environment.new()
	light.environment.background_mode = Environment.BG_COLOR
	light.environment.background_color = Color("#263233")
	light.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	light.environment.ambient_light_color = Color("#e0dfcf")
	light.environment.ambient_light_energy = 0.52
	world.add_child(light)
	var daylight := DirectionalLight3D.new()
	daylight.rotation_degrees = Vector3(-54, -24, 0)
	daylight.light_energy = 0.9
	daylight.shadow_enabled = true
	world.add_child(daylight)
	var center := room_bounds.get_center()
	var floor := cube(Vector3(room_bounds.size.x, 0.08, room_bounds.size.y), Color("#75624d"))
	floor.position = Vector3(center.x, -0.04, center.y)
	world.add_child(floor)
	for item in layout.items:
		add_item(world, item)
	var spawn: Vector2 = layout.spawn
	walker = CharacterBody3D.new()
	walker.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	walker.position = Vector3(spawn.x, 0.75, spawn.y)
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = PLAYER_RADIUS
	capsule.height = 1.5
	collision.shape = capsule
	walker.add_child(collision)
	var camera := Camera3D.new()
	camera.position.y = 0.78
	camera.current = true
	walker.add_child(camera)
	world.add_child(walker)

func add_item(world: Node3D, item: Dictionary) -> void:
	var size_meters := Vector3(item.width, item.height, item.depth)
	var color := Color("#e2dbcc") if item.wall else Color("#559a96")
	if item.bot:
		color = Color("#6ddcbb")
	var mesh := cube(size_meters, color)
	mesh.position = Vector3(item.x, item.height / 2.0, item.z)
	mesh.rotation.y = -item.angle
	world.add_child(mesh)
	if item.bot:
		var label := Label3D.new()
		label.text = item.title.left(60)
		label.position.y = item.height / 2.0 + 0.2
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.pixel_size = 0.005
		mesh.add_child(label)
	else:
		mesh.create_trimesh_collision()

func cube(size_meters: Vector3, color: Color) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size_meters
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	box.material = material
	var node := MeshInstance3D.new()
	node.mesh = box
	return node

func _physics_process(delta: float) -> void:
	if walker == null or not is_visible_in_tree():
		return
	var side := int(Input.is_physical_key_pressed(KEY_D)) - int(Input.is_physical_key_pressed(KEY_A))
	var forward := int(Input.is_physical_key_pressed(KEY_S)) - int(Input.is_physical_key_pressed(KEY_W))
	var turn := int(Input.is_physical_key_pressed(KEY_LEFT)) - int(Input.is_physical_key_pressed(KEY_RIGHT))
	walk(Vector2(side, forward), turn, delta)

func walk(direction: Vector2, turn: float, delta: float) -> void:
	walker.rotate_y(turn * TURN_SPEED * delta)
	var step := direction.limit_length(1.0) * WALK_SPEED
	walker.velocity = walker.basis * Vector3(step.x, 0.0, step.y)
	walker.move_and_slide()
	var bounds := room_bounds.grow(-PLAYER_RADIUS)
	walker.position.x = clampf(walker.position.x, bounds.position.x, bounds.end.x)
	walker.position.z = clampf(walker.position.z, bounds.position.y, bounds.end.y)
