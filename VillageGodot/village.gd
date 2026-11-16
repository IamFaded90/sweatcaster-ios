extends Node2D

const Terrain = preload("res://terrain.gd")
const VoxelMap = preload("res://voxel_map.gd")
const RADIUS := 18.0
const MAP_CENTER := Vector2(480, 320)
const BOT_COLORS := [
	Color("#96e6b3"), Color("#bba2f3"), Color("#8ed9f2"), Color("#f4c975"),
	Color("#ec9f9f"), Color("#c9e387"), Color("#f5b5e3"), Color("#b0bccf")
]
const PLACES := {
	"research": {"cell": Vector2i(-1, -4), "title": "Værksted"},
	"video": {"cell": Vector2i(4, -2), "title": "Video"},
	"cafe": {"cell": Vector2i(-5, 2), "title": "Café"},
	"sleep": {"cell": Vector2i(-1, 5), "title": "Sovekrog"},
	"office": {"cell": Vector2i.ZERO, "title": "Kontor"},
	"cemetery": {"cell": Vector2i(4, 2), "title": "Kirkegård"}
}

var tiles: Dictionary
var bots: Array[Dictionary] = []
var selected := ""
var zoom := 1.0
var voxel := false
var status: Label
var details: Label
var voxel_map: SubViewportContainer

func _ready() -> void:
	tiles = Terrain.fields(2026)
	bots = [
		{"id": "sample-a", "name": "Adam", "zone": "research", "activity": "Arbejder", "mood": 0.74},
		{"id": "sample-b", "name": "Eva", "zone": "video", "activity": "Klar", "mood": 0.82}
	]
	make_controls()
	status.text = "Eksempeldata · Adam og Eva"
	var args := OS.get_cmdline_user_args()
	var flag := args.find("--snapshot")
	if flag >= 0 and flag + 1 < args.size():
		load_snapshot(args[flag + 1])
	queue_redraw()

func make_controls() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var controls := VBoxContainer.new()
	controls.position = Vector2(18, 14)
	layer.add_child(controls)
	var actions := HBoxContainer.new()
	controls.add_child(actions)
	var load_button := Button.new()
	load_button.text = "Åbn landsbykort fra FadedAI"
	actions.add_child(load_button)
	var picker := FileDialog.new()
	picker.title = "Vælg landsbykort"
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.filters = PackedStringArray(["*.json ; Landsbykort"])
	layer.add_child(picker)
	load_button.pressed.connect(func() -> void: picker.popup_centered_ratio(0.65))
	picker.file_selected.connect(load_snapshot)
	var toggle := CheckButton.new()
	toggle.text = "3D-voxel"
	actions.add_child(toggle)
	toggle.toggled.connect(show_voxel)
	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(132, 44)
	slider.min_value = 1
	slider.max_value = 2.2
	slider.step = 0.05
	slider.value = 1
	slider.tooltip_text = "Zoom"
	actions.add_child(slider)
	slider.value_changed.connect(set_zoom)
	status = Label.new()
	controls.add_child(status)
	details = Label.new()
	details.position = Vector2(18, 583)
	layer.add_child(details)
	details.text = "Klik på en bygning eller bot"

func set_zoom(value: float) -> void:
	zoom = clampf(value, 1, 2.2)
	if voxel_map != null:
		voxel_map.set_zoom(zoom)
	queue_redraw()

func show_voxel(enabled: bool) -> void:
	voxel = enabled
	if enabled and voxel_map == null:
		voxel_map = VoxelMap.new()
		voxel_map.position = Vector2(100, 90)
		voxel_map.size = Vector2(760, 475)
		add_child(voxel_map)
		voxel_map.build(tiles, PLACES, bots)
		voxel_map.set_zoom(zoom)
	if voxel_map != null:
		voxel_map.visible = enabled
	queue_redraw()

func load_snapshot(path: String) -> void:
	var source := FileAccess.open(path, FileAccess.READ)
	if source == null or source.get_length() > 65536:
		status.text = "Landsbykortet kunne ikke åbnes"
		return
	var data: Variant = JSON.parse_string(source.get_as_text())
	if not data is Dictionary or data.get("version") != 1 or not data.get("bots") is Array:
		status.text = "Filen har ikke det forventede landsbyformat"
		return
	var parsed: Array[Dictionary] = []
	var seen := {}
	for row in data.bots.slice(0, 10):
		if not row is Dictionary or not row.get("id") is String or not row.get("name") is String:
			continue
		if not PLACES.has(row.get("zone", "")) or seen.has(row.id):
			continue
		seen[row.id] = true
		parsed.append(row)
	bots = parsed
	selected = ""
	status.text = "Fra FadedAI · %d bots" % bots.size()
	details.text = "Klik på en bygning eller bot"
	if voxel_map != null:
		voxel_map.rebuild_bots(PLACES, bots)
	queue_redraw()

func place_point(id: String) -> Vector2:
	return Terrain.center(PLACES[id].cell, RADIUS)

func bot_point(index: int) -> Vector2:
	var bot := bots[index]
	var origin := place_point(bot.zone) + Vector2(-12 + index * 9, 23)
	var destination: String = bot.get("destination", "")
	var progress: float = clampf(float(bot.get("progress", 0.0)), 0, 1)
	if PLACES.has(destination):
		if progress < 0.5:
			return origin.lerp(Vector2.ZERO, 2.0 * progress)
		return Vector2.ZERO.lerp(place_point(destination) + Vector2(0, 23), progress * 2.0 - 1.0)
	return origin

func _draw() -> void:
	if voxel:
		return
	draw_set_transform(MAP_CENTER, 0, Vector2.ONE * zoom)
	for cell in tiles:
		var color: Color = Terrain.COLORS[tiles[cell].x]
		var points := Terrain.polygon(cell, RADIUS, 0.8)
		var shadow := PackedVector2Array()
		for point in points:
			shadow.append(point + Vector2(2, 4))
		draw_colored_polygon(shadow, Color("#343a31"))
		draw_colored_polygon(points, color)
	var font := ThemeDB.fallback_font
	for id in PLACES:
		var center := place_point(id)
		var rect := Rect2(center - Vector2(29, 16), Vector2(58, 32))
		draw_rect(Rect2(rect.position + Vector2(4, 4), rect.size), Color("#363831"))
		draw_rect(rect, Color("#e2d5b7") if selected == id else Color("#f4ead2"))
		draw_string(font, center + Vector2(-27, 4), PLACES[id].title, HORIZONTAL_ALIGNMENT_CENTER, 54, 12, Color("#292d2a"))
	for index in bots.size():
		var point := bot_point(index)
		draw_circle(point + Vector2(2, 4), 8.0, Color("#333d32"))
		draw_circle(point, 8.0, BOT_COLORS[index % BOT_COLORS.size()])
		draw_string(font, point + Vector2(-28, 21), bots[index].name.left(14), HORIZONTAL_ALIGNMENT_CENTER, 56, 12, Color("#242a22"))

func _unhandled_input(event: InputEvent) -> void:
	if voxel or not event is InputEventMouseButton or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var target := (get_local_mouse_position() - MAP_CENTER) / zoom
	for index in range(bots.size() - 1, -1, -1):
		if target.distance_to(bot_point(index)) < 22:
			var bot := bots[index]
			selected = str(bot.id)
			details.text = "%s · %s · Humør %.0f %%" % [bot.name, bot.get("activity", "Klar"), float(bot.get("mood", 0)) * 100]
			queue_redraw()
			return
	for id in PLACES:
		if target.distance_to(place_point(id)) < 29:
			selected = id
			details.text = PLACES[id].title
			queue_redraw()
			return
