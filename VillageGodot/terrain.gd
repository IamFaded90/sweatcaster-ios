extends RefCounted

# Voxelcraft separates large land masses, small details and a narrow river contour.
# Here Godot generates those layers with a fixed seed, so both maps share their terrain.
const RADIUS := 8
const WATER := 0
const GRASS := 1
const ROCK := 2
const SAND := 3
const COLORS := [Color("#54828d"), Color("#b5bc87"), Color("#727978"), Color("#e1cb92")]
const AXIAL_DIRECTIONS := [
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)
]

static func fields(seed_value: int) -> Dictionary:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.11
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	var tiles := {}
	for r in range(-RADIUS, RADIUS + 1):
		for q in range(-RADIUS, RADIUS + 1):
			var radius: int = maxi(absi(q), maxi(absi(r), absi(q + r)))
			if radius > RADIUS:
				continue
			var ground := noise.get_noise_2d(q, r) * 0.7 + noise.get_noise_2d(q * 2.7 + 26, r * 2.7) * 0.3
			var river := absf(noise.get_noise_2d(q * 0.74 + 40, r * 0.74))
			var height := clampi(int((ground + 0.55) * 6.0), 1, 4)
			var kind := GRASS
			if radius == RADIUS and ground < 0.12:
				kind = SAND
			if ground > 0.18:
				kind = ROCK
			if river < 0.055 and radius >= 3:
				kind = WATER
				height = 0
			tiles[Vector2i(q, r)] = Vector2i(kind, height)
	return tiles

static func center(cell: Vector2i, size: float) -> Vector2:
	# Axial coordinates and six neighbors follow the layout used by HexEngine.
	return Vector2(sqrt(3.0) * (cell.x + cell.y * 0.5), 1.5 * cell.y) * size

static func polygon(cell: Vector2i, size: float, inset: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for edge in range(6):
		var angle := PI / 6.0 + edge * TAU / 6.0
		points.append(center(cell, size) + Vector2(cos(angle), sin(angle)) * (size - inset))
	return points
