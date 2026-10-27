extends Node2D
## Level editor: paint a map, check it is playable, save/load it as JSON and playtest it.

const Data = preload("res://scripts/data.gd")
const BoardDraw = preload("res://scripts/board_draw.gd")

const TILE := 48.0
const W := 16
const H := 11
const GRID_OFS := Vector2(16, 56)
const PANEL_X := 800.0
const SCREEN := Vector2(1060, 600)
const NONE := Vector2i(-99, -99)
const DIRS: Array[Vector2i] = [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
const SAVE_DIR := "user://levels"
const TOOLS := [
	{"ch": "#", "name": "Wall", "color": Color("4a5070")},
	{"ch": ".", "name": "Floor", "color": Color("202436")},
	{"ch": "S", "name": "Enemy gate", "color": Color("e05555")},
	{"ch": "G", "name": "Core", "color": Color("4fd1c5")},
	{"ch": "P", "name": "Player start", "color": Color("3fbf7f")},
	{"ch": "D", "name": "Block dock", "color": Color("9aa0bc")},
	{"ch": "*", "name": "Power tile", "color": Color("f2c94c")},
]

var map: Array = []
var level_name := "My Level"
var waves := 5
var difficulty := 0
var tool := 0
var painting := 0  # 0 idle, 1 paint, 2 erase
var undo_stack: Array = []
var hover := NONE
var errors: Array = []
var warnings: Array = []
var paths: Array = []
var deadlocks: Array[Vector2i] = []
var load_sources: Array = []
var message := ""
var message_t := 0.0
var t := 0.0
var font: Font

var name_edit: LineEdit
var load_menu: OptionButton


func _ready() -> void:
	font = ThemeDB.fallback_font
	build_ui()
	if Data.editor_level.is_empty():
		new_level()
	else:
		set_level(Data.editor_level)
	refresh_load_menu()


# ---------------------------------------------------------------- UI setup

func build_ui() -> void:
	var x := PANEL_X + 12
	name_edit = LineEdit.new()
	name_edit.position = Vector2(x, 62)
	name_edit.size = Vector2(236, 30)
	name_edit.max_length = 24
	name_edit.text_changed.connect(func(s: String): level_name = s)
	add_child(name_edit)
	button("-", Rect2(x + 150, 102, 28, 24), func(): waves = maxi(1, waves - 1))
	button("+", Rect2(x + 208, 102, 28, 24), func(): waves = mini(12, waves + 1))
	button("-", Rect2(x + 150, 130, 28, 24), func(): difficulty = maxi(0, difficulty - 1))
	button("+", Rect2(x + 208, 130, 28, 24), func(): difficulty = mini(15, difficulty + 1))
	button("Playtest  [P]", Rect2(x, 404, 116, 30), playtest)
	button("Save", Rect2(x + 120, 404, 116, 30), save_level)
	load_menu = OptionButton.new()
	load_menu.position = Vector2(x, 440)
	load_menu.size = Vector2(170, 30)
	load_menu.fit_to_longest_item = false
	add_child(load_menu)
	button("Load", Rect2(x + 176, 440, 60, 30), load_selected)
	button("New", Rect2(x, 476, 116, 30), func():
		push_undo()
		new_level())
	button("Copy as code", Rect2(x + 120, 476, 116, 30), copy_as_code)
	button("Back to game  [Esc]", Rect2(x, 512, 236, 30), back_to_game)


func button(label: String, r: Rect2, cb: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.position = r.position
	b.size = r.size
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	add_child(b)
	return b


func tool_rect(i: int) -> Rect2:
	return Rect2(PANEL_X + 12 + (i % 2) * 120, 186 + (i / 2) * 28, 116, 24)


# ---------------------------------------------------------------- level data

func new_level() -> void:
	var rows := []
	for y in H:
		var row := ""
		for x in W:
			row += "#" if x == 0 or y == 0 or x == W - 1 or y == H - 1 else "."
		rows.append(row)
	rows[3] = "#..D...........#"
	rows[5] = "S..P...........G"
	rows[7] = "#..D...........#"
	set_level({"name": "My Level", "waves": 5, "difficulty": 0, "map": rows})


func set_level(lv: Dictionary) -> void:
	map = []
	for line in lv.map:
		var row := []
		for x in W:
			row.append(line[x])
		map.append(row)
	level_name = lv.get("name", "My Level")
	waves = int(lv.get("waves", 5))
	difficulty = int(lv.get("difficulty", 0))
	if name_edit:
		name_edit.text = level_name
	validate()


func to_level() -> Dictionary:
	var rows := []
	for row in map:
		rows.append("".join(row))
	var nm := level_name.strip_edges()
	return {
		"name": nm if nm != "" else "Untitled",
		"waves": waves,
		"difficulty": difficulty,
		"tip": "A custom level.",
		"map": rows,
	}


## Returns an error string, or "" if `lv` is a well-formed level dictionary.
static func check_shape(lv) -> String:
	if not lv is Dictionary or not lv.has("map") or not lv.map is Array:
		return "not a level file"
	if lv.map.size() != H:
		return "map must have %d rows" % H
	for line in lv.map:
		if not line is String or line.length() != W:
			return "every row must be %d characters" % W
		for ch in line:
			if not ch in "#.SGPD*":
				return "unknown tile '%s'" % ch
	return ""


# ---------------------------------------------------------------- validation

func at(c: Vector2i) -> String:
	if c.x < 0 or c.y < 0 or c.x >= W or c.y >= H:
		return "#"
	return map[c.y][c.x]


func is_hard(c: Vector2i) -> bool:
	return at(c) in ["#", "S", "G"]


func validate() -> void:
	errors.clear()
	warnings.clear()
	paths.clear()
	deadlocks.clear()
	var spawns: Array[Vector2i] = []
	var goals: Array[Vector2i] = []
	var players: Array[Vector2i] = []
	var docks := 0
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			match at(c):
				"S":
					spawns.append(c)
				"G":
					goals.append(c)
				"P":
					players.append(c)
				"D":
					docks += 1
			if at(c) in [".", "D", "*", "P"]:
				var horiz := is_hard(c + Vector2i.LEFT) or is_hard(c + Vector2i.RIGHT)
				var vert := is_hard(c + Vector2i.UP) or is_hard(c + Vector2i.DOWN)
				if horiz and vert:
					deadlocks.append(c)
	if goals.is_empty():
		errors.append("Place a core (G).")
	if spawns.is_empty():
		errors.append("Place at least one enemy gate (S).")
	if players.is_empty():
		errors.append("Place the player start (P).")
	if docks == 0:
		warnings.append("No docks: starting blocks go next to the player.")
	if goals.is_empty():
		return
	var dist := {goals[0]: 0}
	var q: Array[Vector2i] = [goals[0]]
	var head := 0
	while head < q.size():
		var c := q[head]
		head += 1
		for dir in DIRS:
			var n := c + dir
			if not dist.has(n) and at(n) != "#":
				dist[n] = dist[c] + 1
				q.append(n)
	for s in spawns:
		if not dist.has(s):
			errors.append("Gate at %d,%d can't reach the core." % [s.x, s.y])
			continue
		# follow the same steepest-descent rule enemies use in the game
		var pts := [s]
		var c := s
		while c != goals[0]:
			var best := c
			for dir in DIRS:
				if dist.has(c + dir) and dist[c + dir] < dist[best]:
					best = c + dir
			c = best
			pts.append(c)
		paths.append(pts)
	if not players.is_empty() and not dist.has(players[0]):
		errors.append("The player start can't reach the core.")


# ---------------------------------------------------------------- editing

func paint(c: Vector2i, ch: String) -> void:
	if c == NONE or at(c) == ch:
		return
	if ch in ["G", "P"]:
		# only one core and one player start: move the existing one
		for y in H:
			for x in W:
				if map[y][x] == ch:
					map[y][x] = "."
	map[c.y][c.x] = ch
	validate()


func push_undo() -> void:
	var snap := []
	for row in map:
		snap.append(row.duplicate())
	undo_stack.append(snap)
	if undo_stack.size() > 200:
		undo_stack.pop_front()


func undo() -> void:
	if undo_stack.is_empty():
		flash("Nothing to undo.")
		return
	map = undo_stack.pop_back()
	validate()


func world_to_cell(p: Vector2) -> Vector2i:
	var g := (p - GRID_OFS) / TILE
	var c := Vector2i(floori(g.x), floori(g.y))
	if c.x < 0 or c.y < 0 or c.x >= W or c.y >= H:
		return NONE
	return c


func flash(s: String) -> void:
	message = s
	message_t = 3.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var m := get_local_mouse_position()
		if not event.pressed:
			painting = 0
			return
		for i in TOOLS.size():
			if tool_rect(i).has_point(m):
				tool = i
				return
		var c := world_to_cell(m)
		if c == NONE:
			return
		get_viewport().gui_release_focus()
		if event.button_index == MOUSE_BUTTON_LEFT:
			painting = 1
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			painting = 2
		else:
			return
		push_undo()
		paint(c, TOOLS[tool].ch if painting == 1 else ".")
	elif event is InputEventMouseMotion and painting != 0:
		paint(world_to_cell(get_local_mouse_position()), TOOLS[tool].ch if painting == 1 else ".")
	elif event is InputEventKey and event.pressed:
		var k: int = event.keycode
		if k >= KEY_1 and k < KEY_1 + TOOLS.size():
			tool = k - KEY_1
		elif k == KEY_Z and event.ctrl_pressed:
			undo()
		elif k == KEY_P and not event.echo:
			playtest()
		elif k == KEY_ESCAPE:
			back_to_game()


# ---------------------------------------------------------------- actions

func playtest() -> void:
	if not errors.is_empty():
		flash("Fix the problems listed on the right first.")
		return
	Data.custom_level = to_level()
	Data.editor_level = Data.custom_level
	get_tree().change_scene_to_file("res://main.tscn")


func back_to_game() -> void:
	Data.custom_level = {}
	Data.editor_level = to_level()
	get_tree().change_scene_to_file("res://main.tscn")


func file_name_for(nm: String) -> String:
	var out := ""
	for ch in nm.to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	return out.strip_edges() if out != "" else "untitled"


func save_level() -> String:
	var lv := to_level()
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var path := SAVE_DIR.path_join(file_name_for(lv.name) + ".json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		flash("Couldn't save: %s" % error_string(FileAccess.get_open_error()))
		return ""
	f.store_string(JSON.stringify(lv, "\t"))
	f.close()
	refresh_load_menu()
	for i in load_sources.size():
		if load_sources[i].get("path", "") == path:
			load_menu.select(i)
	flash("Saved to %s" % ProjectSettings.globalize_path(path))
	return path


func refresh_load_menu() -> void:
	load_sources.clear()
	load_menu.clear()
	for i in Data.LEVELS.size():
		load_sources.append({"builtin": i})
		load_menu.add_item("Built-in: " + Data.LEVELS[i].name)
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return
	var files := dir.get_files()
	files.sort()
	for f in files:
		if f.ends_with(".json"):
			load_sources.append({"path": SAVE_DIR.path_join(f)})
			load_menu.add_item(f.get_basename())


func load_selected() -> void:
	var i := load_menu.selected
	if i < 0 or i >= load_sources.size():
		return
	var src: Dictionary = load_sources[i]
	var lv
	if src.has("builtin"):
		lv = Data.LEVELS[src.builtin].duplicate(true)
	else:
		lv = JSON.parse_string(FileAccess.get_file_as_string(src.path))
	var problem := check_shape(lv)
	if problem != "":
		flash("Can't load: " + problem)
		return
	push_undo()
	set_level(lv)
	flash("Loaded " + lv.name)


func copy_as_code() -> void:
	var lv := to_level()
	var s := "\t{\n\t\t\"name\": \"%s\",\n\t\t\"waves\": %d,\n" % [lv.name.c_escape(), lv.waves]
	if difficulty > 0:
		s += "\t\t\"difficulty\": %d,\n" % difficulty
	s += "\t\t\"tip\": \"%s\",\n\t\t\"map\": [\n" % lv.tip
	for row in lv.map:
		s += "\t\t\t\"%s\",\n" % row
	s += "\t\t],\n\t},\n"
	DisplayServer.clipboard_set(s)
	print(s)
	flash("Copied - paste it into LEVELS in scripts/data.gd.")


# ---------------------------------------------------------------- drawing

func _process(delta: float) -> void:
	t += delta
	message_t -= delta
	hover = world_to_cell(get_local_mouse_position())
	queue_redraw()


func cell_rect(c: Vector2i) -> Rect2:
	return Rect2(GRID_OFS + Vector2(c) * TILE, Vector2(TILE, TILE))


func text(s: String, pos: Vector2, size := 16, col := Color.WHITE, width := -1.0,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string(font, pos, s, align, width, size, col)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color("141621"))
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			var ch: String = map[y][x]
			var r := cell_rect(c)
			BoardDraw.draw_tile(self, r, ch, (x + y) % 2 == 0, t)
			match ch:
				"P":
					draw_circle(r.get_center(), 13.0, Color("3fbf7f"))
					draw_circle(r.get_center() + Vector2(-5, -2), 3.0, Color.WHITE)
					draw_circle(r.get_center() + Vector2(5, -2), 3.0, Color.WHITE)
				"D":
					draw_rect(r.grow(-8), Color("9aa0bc"), false, 1.5)
					draw_rect(r.grow(-14), Color(0.6, 0.63, 0.74, 0.25))
	for c in deadlocks:
		BoardDraw.draw_corner_mark(self, cell_rect(c), is_hard(c + Vector2i.LEFT), is_hard(c + Vector2i.UP))
	for pts in paths:
		var line := PackedVector2Array()
		for c in pts:
			line.append(cell_rect(c).get_center())
		if line.size() >= 2:
			draw_polyline(line, Color(1, 0.4, 0.4, 0.35), 3.0)
	if hover != NONE:
		var col: Color = TOOLS[tool].color
		draw_rect(cell_rect(hover), Color(col, 0.25))
		draw_rect(cell_rect(hover), col.lightened(0.3), false, 2.0)

	text("LEVEL EDITOR  ·  %s" % to_level().name.to_upper(), Vector2(18, 36), 20, Color("e8e8f0"))
	var hint := "LMB paint  ·  RMB erase  ·  Ctrl+Z undo  ·  1-7 tools"
	if message_t > 0.0:
		text(message, Vector2(300, 36), 15, Color(1, 0.85, 0.4, clampf(message_t, 0.0, 1.0)), 484, HORIZONTAL_ALIGNMENT_RIGHT)
	else:
		text(hint, Vector2(300, 36), 14, Color("9aa0bc"), 484, HORIZONTAL_ALIGNMENT_RIGHT)

	var x := PANEL_X
	draw_rect(Rect2(x - 4, 0, SCREEN.x - x + 4, SCREEN.y), Color("181a28"))
	draw_line(Vector2(x - 4, 0), Vector2(x - 4, SCREEN.y), Color("2b2f45"), 2.0)
	text("LEVEL EDITOR", Vector2(x + 12, 36), 24, Color("f2c94c"))
	text("Name", Vector2(x + 12, 56), 13, Color("6c7290"))
	text("Waves", Vector2(x + 12, 119), 15, Color("9aa0bc"))
	text(str(waves), Vector2(x + 178, 119), 16, Color.WHITE, 30, HORIZONTAL_ALIGNMENT_CENTER)
	text("Difficulty", Vector2(x + 12, 147), 15, Color("9aa0bc"))
	text(str(difficulty), Vector2(x + 178, 147), 16, Color.WHITE, 30, HORIZONTAL_ALIGNMENT_CENTER)
	text("TILES", Vector2(x + 12, 178), 13, Color("6c7290"))
	for i in TOOLS.size():
		var r := tool_rect(i)
		var sel := i == tool
		draw_rect(r, Color("2a2e48") if sel else Color("1e2134"))
		if sel:
			draw_rect(r, Color("f2c94c"), false, 1.5)
		draw_rect(Rect2(r.position + Vector2(5, 5), Vector2(14, 14)), TOOLS[i].color)
		text("%d %s" % [i + 1, TOOLS[i].name], r.position + Vector2(24, 17), 13, Color.WHITE if sel else Color("b8bdd6"))

	var y := 316.0
	if errors.is_empty():
		text("Ready to play", Vector2(x + 12, y), 14, Color("6be675"))
		y += 18
	for e in errors.slice(0, 4):
		draw_multiline_string(font, Vector2(x + 12, y), "x " + e, HORIZONTAL_ALIGNMENT_LEFT, 236, 13, 2, Color("e07070"))
		y += 18
	for w in warnings:
		draw_multiline_string(font, Vector2(x + 12, y), "! " + w, HORIZONTAL_ALIGNMENT_LEFT, 236, 12, 2, Color("e0c070"))
		y += 30
	text("Corner brackets: a block pushed there is stuck.", Vector2(x + 12, 570), 11, Color("6c7290"), 236)
