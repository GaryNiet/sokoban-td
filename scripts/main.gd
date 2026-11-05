extends Node2D
## Sokoban TD: push tower blocks to shape the enemy path, then survive the wave.

const Data = preload("res://scripts/data.gd")
const BoardDraw = preload("res://scripts/board_draw.gd")

const TILE := 48.0  # board units per cell; the game logic works on this flat grid
const TILT := 0.72  # the camera leans towards the player: rows are squashed to this, columns stay put
const WALL_H := 20.0  # heights are in screen pixels (before board_scale)
const EDGE_WALL_H := 6.0  # the wall along the front edge stays low so it doesn't hide the board
const BOARD_AREA := Rect2(16, 56, 992, 648)
const PANEL_X := 1024.0
const SCREEN := Vector2(1280, 720)
const NONE := Vector2i(-99, -99)
const DIRS: Array[Vector2i] = [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
const ATTACK_TYPES := ["bolt", "cannon", "frost", "tesla"]
const UPGRADE_TYPES := ["amp", "clock", "lens"]
const START_LIVES := 20
const MOVE_BUFFER := 5  # most taps that can queue up ahead of the player
const HOLD_DELAY := 0.2  # seconds a direction key is held before the player keeps walking

enum Phase { TITLE, BUILD, WAVE, REWARD, GAMEOVER, VICTORY }

var phase: int = Phase.TITLE
var levels: Array = Data.LEVELS
var custom := false
var select_idx := 0  # level highlighted on the level select
var level_idx := 0
var wave_idx := 0
var lives := START_LIVES
var kills := 0

# Board (logic runs in board space: TILE-sized cells from (0, 0); drawing scales it to fit)
var W := 16
var H := 11
var board_pos := BOARD_AREA.position
var board_scale := 1.0
var board_rect := Rect2()  # screen area the board covers
var filled := {}  # filled hole cell -> type of the block that fell in
var tiles: Array = []
var spawns: Array[Vector2i] = []
var goal := Vector2i.ZERO
var tower_spawns: Array[Vector2i] = []
var spawn_turn := 0  # index of the tower spawn whose turn it is
var next_spawn := NONE  # where the next reward tower drops, NONE if every spawn is covered
var deadlocks: Array[Vector2i] = []
var dist: Dictionary = {}
var player := Vector2i.ZERO
var player_draw := Vector2.ZERO
var player_facing := Vector2i.RIGHT
var move_queue: Array[Vector2i] = []  # tapped moves, played one tile at a time
var held_key := 0  # direction key being held, 0 if none
var held_t := 0.0
var blocks: Array = []
var undo_stack: Array = []

# Combat
var enemies: Array = []
var pending_enemies: Array = []
var projectiles: Array = []
var effects: Array = []
var spawn_queue: Array = []
var next_wave: Array = []
var spawn_timer := 0.0
var spawn_rr := 0
var enemy_id := 0
var speed := 1.0

# Run progression
var carried: Array = []
var rewards: Array = []
var rewards_hidden := false
var dmg_mult := {}  # per tower type; only the sim and editor tests raise these

# UI
var message := ""
var message_t := 0.0
var banner := ""
var banner_t := 0.0
var hover := NONE
var t := 0.0
var font: Font


func _ready() -> void:
	font = ThemeDB.fallback_font
	custom = not Data.custom_level.is_empty()
	levels = [Data.custom_level] if custom else Data.LEVELS
	if custom:
		reset_run()
	else:
		to_menu()


# ---------------------------------------------------------------- run / level flow

## Back to the level select, with the highlighted level shown behind it.
func to_menu() -> void:
	select_idx = clampi(select_idx, 0, levels.size() - 1)
	reset_run(select_idx)
	phase = Phase.TITLE


func select_level(i: int) -> void:
	select_idx = posmod(i, levels.size())
	to_menu()


## Each level is its own run: fresh lives, upgrades and a single starting tower.
func reset_run(i := 0) -> void:
	lives = START_LIVES
	kills = 0
	dmg_mult = {"bolt": 1.0, "cannon": 1.0, "frost": 1.0, "tesla": 1.0, "stone": 0.0}
	speed = 1.0
	carried = ["bolt"]
	load_level(i)


func load_level(i: int) -> void:
	level_idx = i
	wave_idx = 0
	var lv: Dictionary = levels[i]
	H = lv.map.size()
	W = 0
	for line in lv.map:
		W = maxi(W, line.length())
	layout_board()
	tiles = []
	filled.clear()
	spawns.clear()
	tower_spawns.clear()
	spawn_turn = 0
	player = NONE
	for y in H:
		var row: Array = []
		var line: String = lv.map[y]
		for x in W:
			var ch := Data.internal_tile(line[x]) if x < line.length() else "#"
			var c := Vector2i(x, y)
			match ch:
				"S":
					spawns.append(c)
				"G":
					goal = c
				"P":
					player = c
					ch = "."
				"D":
					tower_spawns.append(c)
					ch = "."
			row.append(ch)
		tiles.append(row)
	if player == NONE:
		player = default_player_start()
	deadlocks.clear()
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			if tile_at(c) in [".", "*"] and is_locked(c):
				deadlocks.append(c)
	blocks = []
	enemies.clear()
	pending_enemies.clear()
	projectiles.clear()
	effects.clear()
	spawn_queue.clear()
	# the first block starts on the first tower spawn; the rest cluster around it
	for k in carried.size():
		if k == 0 and find_next_spawn() >= 0:
			drop_reward_block(carried[k])
		else:
			place_carried_block(carried[k])
	player_draw = cell_center(player)
	clear_moves()
	enter_build()
	show_banner("Level %d: %s" % [i + 1, lv.name])


func layout_board() -> void:
	var size := Vector2(W * TILE, H * TILE * TILT + WALL_H)
	board_scale = minf(1.4, minf(BOARD_AREA.size.x / size.x, BOARD_AREA.size.y / size.y))
	var top_left := BOARD_AREA.position + (BOARD_AREA.size - size * board_scale) / 2.0
	board_rect = Rect2(top_left, size * board_scale)
	board_pos = top_left + Vector2(0, WALL_H) * board_scale


## Next to the first tower spawn (left side first), so the opening push is obvious.
func default_player_start() -> Vector2i:
	var anchor: Vector2i = tower_spawns[0] if not tower_spawns.is_empty() else goal
	var seen := {anchor: true}
	var q: Array[Vector2i] = [anchor]
	var head := 0
	while head < q.size():
		var c := q[head]
		head += 1
		if tile_at(c) == "." and not c in tower_spawns:
			return c
		for dir in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var n: Vector2i = c + dir
			if not seen.has(n) and not is_wall(n):
				seen[n] = true
				q.append(n)
	return anchor


func enter_build() -> void:
	phase = Phase.BUILD
	undo_stack.clear()
	next_wave = generate_wave(level_idx, wave_idx)
	on_board_changed()


func start_wave() -> void:
	spawn_queue = next_wave.duplicate()
	spawn_timer = 0.3
	spawn_rr = 0
	undo_stack.clear()
	for b in blocks:
		b.cd = 0.0
	on_board_changed()
	phase = Phase.WAVE


func generate_wave(li: int, wi: int) -> Array:
	var d: int = wi + int(levels[li].get("difficulty", 0))
	var hp_scale := 1.0 + 0.2 * d + 0.012 * d * d
	var count := 5 + int(d * 1.6)
	var pool := ["grunt"]
	var weights := [4.0]
	if d >= 1:
		pool.append("runner")
		weights.append(3.0)
	if d >= 2:
		pool.append("brute")
		weights.append(1.3)
	if d >= 4:
		pool.append("splitter")
		weights.append(2.0)
	var total := 0.0
	for w in weights:
		total += w
	var q := []
	for i in count:
		var roll := randf() * total
		var type: String = pool[0]
		for k in pool.size():
			roll -= weights[k]
			if roll <= 0.0:
				type = pool[k]
				break
		q.append({"type": type, "scale": hp_scale, "boss": false})
	if wi == levels[li].waves - 1:
		q.append({"type": "brute", "scale": hp_scale * 3.0, "boss": true})
	return q


func wave_cleared() -> void:
	wave_idx += 1
	projectiles.clear()
	if wave_idx >= levels[level_idx].waves:
		phase = Phase.VICTORY
		return
	roll_rewards()
	phase = Phase.REWARD


func roll_rewards() -> void:
	rewards_hidden = false
	# every block needs a free tower spawn to drop on; with none left the only choice is a repair
	if next_spawn == NONE:
		rewards = [{"kind": "heal"}]
		return
	var towers := ATTACK_TYPES + ["stone"]
	towers.shuffle()
	var ups := UPGRADE_TYPES.duplicate()
	ups.shuffle()
	rewards = [{"kind": "block", "type": towers[0]}, {"kind": "block", "type": ups[0]}]
	if lives < START_LIVES and randf() < 0.35:
		rewards.append({"kind": "heal"})
	elif randf() < 0.5:
		rewards.append({"kind": "block", "type": towers[1]})
	else:
		rewards.append({"kind": "block", "type": ups[1]})
	rewards.shuffle()


func choose_reward(i: int) -> void:
	if i < 0 or i >= rewards.size():
		return
	var r: Dictionary = rewards[i]
	match r.kind:
		"block":
			drop_reward_block(r.type)
		"heal":
			lives = mini(lives + 5, 30)
	enter_build()


func is_tower(ty: String) -> bool:
	return ty in ATTACK_TYPES


# ---------------------------------------------------------------- board helpers

func tile_at(c: Vector2i) -> String:
	if c.x < 0 or c.y < 0 or c.x >= W or c.y >= H:
		return "#"
	return tiles[c.y][c.x]


## Nobody walks here: walls, and holes until a block fills them.
func is_wall(c: Vector2i) -> bool:
	return tile_at(c) in ["#", "O"]


## Walls, spawns and the core can never hold a block.
func is_hard(c: Vector2i) -> bool:
	return tile_at(c) in ["#", "S", "G"]


## A block on this cell can never be pushed again (wall-corner deadlock).
func is_locked(c: Vector2i) -> bool:
	var horiz_stuck := is_hard(c + Vector2i.LEFT) or is_hard(c + Vector2i.RIGHT)
	var vert_stuck := is_hard(c + Vector2i.UP) or is_hard(c + Vector2i.DOWN)
	return horiz_stuck and vert_stuck


func block_index(c: Vector2i) -> int:
	for i in blocks.size():
		if blocks[i].cell == c:
			return i
	return -1


func cell_center(c: Vector2i) -> Vector2:
	return (Vector2(c) + Vector2(0.5, 0.5)) * TILE


func cell_rect(c: Vector2i) -> Rect2:
	return Rect2(Vector2(c) * TILE, Vector2(TILE, TILE))


## Board point at height `h` -> view pixels (before board_pos / board_scale).
func project(p: Vector2, h := 0.0) -> Vector2:
	return Vector2(p.x, p.y * TILT - h)


func unproject(q: Vector2) -> Vector2:
	return Vector2(q.x, q.y / TILT)


## Draws flat board-space shapes onto the ground (or a surface `h` pixels up).
func ground_xf(h := 0.0) -> Transform2D:
	return Transform2D(Vector2(board_scale, 0), Vector2(0, TILT * board_scale),
		board_pos + Vector2(0, -h * board_scale))


## Draws in view pixels, for things with height.
func screen_xf() -> Transform2D:
	return Transform2D(Vector2(board_scale, 0), Vector2(0, board_scale), board_pos)


func to_screen(p: Vector2, h := 0.0) -> Vector2:
	return board_pos + project(p, h) * board_scale


func board_screen_rect() -> Rect2:
	return board_rect


func world_to_cell(p: Vector2) -> Vector2i:
	var g := p / TILE
	var c := Vector2i(floori(g.x), floori(g.y))
	if c.x < 0 or c.y < 0 or c.x >= W or c.y >= H:
		return NONE
	return c


## BFS distance-to-core over cells enemies can walk. `extra` is treated as an
## additional block, `ignore` as a block that has been moved away.
func path_field(extra: Vector2i, ignore: Vector2i) -> Dictionary:
	var d := {goal: 0}
	var q: Array[Vector2i] = [goal]
	var head := 0
	while head < q.size():
		var c := q[head]
		head += 1
		for dir in DIRS:
			var n := c + dir
			if d.has(n) or is_wall(n) or n == extra:
				continue
			if n != ignore and block_index(n) >= 0:
				continue
			d[n] = d[c] + 1
			q.append(n)
	return d


## Cells the player can walk to from `from`, in BFS order.
func walk_bfs(from: Vector2i, extra: Vector2i) -> Array:
	var seen := {from: true}
	var order: Array = [from]
	var head := 0
	while head < order.size():
		var c: Vector2i = order[head]
		head += 1
		for dir in DIRS:
			var n := c + dir
			if seen.has(n) or is_wall(n) or n == extra or block_index(n) >= 0:
				continue
			seen[n] = true
			order.append(n)
	return order


func next_cell(c: Vector2i) -> Vector2i:
	var best := c
	var bd: int = dist.get(c, 1 << 20)
	for dir in DIRS:
		var n := c + dir
		if dist.has(n) and dist[n] < bd:
			bd = dist[n]
			best = n
	return best


func path_points(from: Vector2i) -> Array:
	var pts := [from]
	var c := from
	for i in 400:
		if c == goal:
			break
		var n := next_cell(c)
		if n == c:
			break
		pts.append(n)
		c = n
	return pts


func can_place(c: Vector2i) -> bool:
	if tile_at(c) != "." or c == player or block_index(c) >= 0:
		return false
	var d := path_field(c, NONE)
	for s in spawns:
		if not d.has(s):
			return false
	# never wall the player into a pocket
	return walk_bfs(player, c).has(goal)


func add_block(type: String, c: Vector2i) -> void:
	blocks.append({
		"type": type, "cell": c, "draw": cell_center(c), "cd": 0.0,
		"stats": {}, "locked": false, "pulse": 0.0, "pop": 0.0,
	})
	on_board_changed()


## Blocks brought from the previous level start clustered around the first tower spawn,
## never on a spawn and never where they'd stop a tower from dropping on one.
func place_carried_block(type: String) -> bool:
	var anchor: Vector2i = tower_spawns[0] if not tower_spawns.is_empty() else player
	var fallback := NONE
	for c in walk_bfs(anchor, NONE):
		if c in tower_spawns or not can_place(c):
			continue
		if fallback == NONE:
			fallback = c
		add_block(type, c)
		if tower_spawns.all(spawn_usable):
			return true
		blocks.pop_back()
	if fallback != NONE:
		add_block(type, fallback)
		return true
	on_board_changed()
	return false


## A tower could drop on this spawn without sealing the enemy path.
func spawn_usable(c: Vector2i) -> bool:
	var d := path_field(c, NONE)
	return spawns.all(func(s): return d.has(s))


## The tower spawn whose turn it is, skipping covered ones (or ones that would seal the path).
func find_next_spawn() -> int:
	for k in tower_spawns.size():
		var i := (spawn_turn + k) % tower_spawns.size()
		var c := tower_spawns[i]
		if block_index(c) < 0 and spawn_usable(c):
			return i
	return -1


func drop_reward_block(type: String) -> void:
	var i := find_next_spawn()
	if i < 0:
		flash("Every tower spawn is covered!")
		return
	var c := tower_spawns[i]
	if player == c:
		# step the player off the spawn so the tower has room
		for n in walk_bfs(player, NONE):
			if n != c:
				player = n
				break
	add_block(type, c)
	blocks[-1].pop = 1.0
	spawn_turn = (i + 1) % tower_spawns.size()
	on_board_changed()


func on_board_changed() -> void:
	dist = path_field(NONE, NONE)
	compute_stats()
	for b in blocks:
		b.locked = is_locked(b.cell)
	var i := find_next_spawn()
	next_spawn = tower_spawns[i] if i >= 0 else NONE


# ---------------------------------------------------------------- stats & combos

func combo_key(a: String, b: String) -> String:
	return a + "+" + b if a < b else b + "+" + a


func combo_info(a: String, b: String) -> Dictionary:
	if is_tower(a) and is_tower(b):
		return Data.COMBOS[combo_key(a, b)]
	if not is_tower(a) and not is_tower(b):
		return {}
	var helper := b if is_tower(a) else a
	if helper == "stone":
		return {"name": "Bulwark", "desc": "tower +0.5 range"}
	return {"name": Data.TOWERS[helper].name, "desc": Data.TOWERS[helper].boost}


func apply_combo(ty: String, other: String, s: Dictionary) -> void:
	if not is_tower(ty):
		return
	match other:
		"stone":
			s.range += 0.5
			return
		"amp":
			s.dmg *= 1.3
			return
		"clock":
			s.rate *= 1.25
			return
		"lens":
			s.range += 0.75
			return
	match combo_key(ty, other):
		"bolt+bolt":
			s.rate *= 1.35
		"cannon+cannon":
			s.splash *= 1.5
		"frost+frost":
			s.slow = maxf(s.slow, 0.6)
		"tesla+tesla":
			s.chain += 2
		"bolt+cannon":
			s.dmg *= 1.25
		"bolt+frost":
			if ty == "bolt":
				s.range += 0.6
			else:
				s.dmg *= 2.0
		"bolt+tesla":
			if ty == "bolt":
				s.dmg *= 1.5
			else:
				s.chain += 1
		"cannon+frost":
			if ty == "cannon":
				s.shatter = true
			else:
				s.slow += 0.1
		"cannon+tesla":
			if ty == "cannon":
				s.splash *= 1.3
			else:
				s.dmg *= 1.25
		"frost+tesla":
			if ty == "tesla":
				s.dmg *= 1.4
			else:
				s.range += 0.5


func compute_stats() -> void:
	for b in blocks:
		var def: Dictionary = Data.TOWERS[b.type]
		var s := {
			"dmg": def.dmg * dmg_mult.get(b.type, 1.0),
			"rate": def.rate,
			"range": def.range,
			"splash": def.get("splash", 0.0),
			"chain": def.get("chain", 0),
			"slow": def.get("slow", 0.0),
			"shatter": false,
			"notes": [],
		}
		if is_tower(b.type) and tile_at(b.cell) == "*":
			s.dmg *= 1.5
			s.range += 0.5
			s.notes.append("Power tile: +50% dmg, +0.5 range")
		var boosted := 0
		for dir in DIRS:
			var j := block_index(b.cell + dir)
			if j < 0:
				continue
			var other: String = blocks[j].type
			var info := combo_info(b.type, other)
			if info.is_empty():
				continue
			if is_tower(b.type):
				apply_combo(b.type, other, s)
				s.notes.append("%s: %s" % [info.name, info.desc])
			else:
				boosted += 1
		if b.type in UPGRADE_TYPES:
			s.notes.append("Boosting %d tower%s" % [boosted, "" if boosted == 1 else "s"])
		b.stats = s


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		var k: int = event.keycode
		if k == KEY_ESCAPE and custom:
			open_editor()
			return
		if k == KEY_ESCAPE and not event.echo and phase in [Phase.BUILD, Phase.WAVE, Phase.REWARD]:
			to_menu()
			return
		match phase:
			Phase.TITLE:
				if not event.echo and k in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
					reset_run(select_idx)
				elif k in [KEY_UP, KEY_W, KEY_LEFT, KEY_A]:
					select_level(select_idx - 1)
				elif k in [KEY_DOWN, KEY_S, KEY_RIGHT, KEY_D]:
					select_level(select_idx + 1)
				elif not event.echo and k >= KEY_1 and k < KEY_1 + mini(levels.size(), 9):
					select_level(k - KEY_1)
					reset_run(select_idx)
				elif k == KEY_E:
					open_editor()
			Phase.GAMEOVER, Phase.VICTORY:
				if event.echo:
					return
				if k == KEY_E:
					open_editor()
				elif custom:
					if k in [KEY_ENTER, KEY_KP_ENTER, KEY_R]:
						reset_run()
				elif k == KEY_R and phase == Phase.GAMEOVER:
					reset_run(level_idx)
				elif k in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_ESCAPE, KEY_R]:
					to_menu()
			Phase.REWARD:
				if not event.echo and k in [KEY_H, KEY_TAB]:
					rewards_hidden = not rewards_hidden
				elif not rewards_hidden and k >= KEY_1 and k < KEY_1 + rewards.size():
					choose_reward(k - KEY_1)
			Phase.BUILD, Phase.WAVE:
				var dir := key_dir(k)
				if dir != Vector2i.ZERO:
					# OS key repeat is ignored: holding is handled in update_moves()
					if not event.echo:
						held_key = k
						held_t = 0.0
						if move_queue.size() < MOVE_BUFFER:
							move_queue.append(dir)
				elif k == KEY_Z and phase == Phase.BUILD:
					clear_moves()
					undo()
				elif not event.echo and k in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER] and phase == Phase.BUILD:
					start_wave()
				elif not event.echo and k == KEY_F:
					speed = 1.0 if speed >= 3.0 else speed + 1.0
	elif event is InputEventKey and event.keycode == held_key:
		held_key = 0
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var m := get_local_mouse_position()
		match phase:
			Phase.REWARD:
				if rewards_hidden:
					if hidden_bar_rect().has_point(m):
						rewards_hidden = false
					return
				if hide_button_rect().has_point(m):
					rewards_hidden = true
					return
				for i in rewards.size():
					if card_rect(i).has_point(m):
						choose_reward(i)
						return
			Phase.TITLE:
				var i := level_at(m)
				if i >= 0:
					select_idx = i
					reset_run(i)
			Phase.GAMEOVER, Phase.VICTORY:
				if custom:
					reset_run()
				else:
					to_menu()
	elif event is InputEventMouseMotion and phase == Phase.TITLE:
		var i := level_at(get_local_mouse_position())
		if i >= 0 and i != select_idx:
			select_level(i)


func open_editor() -> void:
	get_tree().change_scene_to_file("res://editor.tscn")


func clear_moves() -> void:
	move_queue.clear()
	held_key = 0


## Taps queue up and play out one tile at a time. A held key never queues: once the player
## has finished sliding into a tile it takes one more step, so letting go stops right away.
func update_moves(real_dt: float) -> void:
	if phase not in [Phase.BUILD, Phase.WAVE]:
		clear_moves()
		return
	if held_key != 0:
		held_t += real_dt
	if player_draw.distance_to(cell_center(player)) > 1.0:
		return
	if not move_queue.is_empty():
		try_move(move_queue.pop_front())
	elif held_key != 0 and held_t >= HOLD_DELAY:
		try_move(key_dir(held_key))


func key_dir(k: int) -> Vector2i:
	match k:
		KEY_UP, KEY_W:
			return Vector2i.UP
		KEY_DOWN, KEY_S:
			return Vector2i.DOWN
		KEY_LEFT, KEY_A:
			return Vector2i.LEFT
		KEY_RIGHT, KEY_D:
			return Vector2i.RIGHT
	return Vector2i.ZERO


func try_move(dir: Vector2i) -> void:
	player_facing = dir
	var target := player + dir
	if is_wall(target):
		return
	var bi := block_index(target)
	if bi < 0:
		player = target
		return
	if phase != Phase.BUILD:
		flash("Can't push blocks while enemies are on the field!")
		return
	var beyond := target + dir
	if is_hard(beyond) or block_index(beyond) >= 0:
		return
	if tile_at(beyond) == "O":
		fill_hole(bi, beyond)
		player = target
		return
	var d := path_field(beyond, target)
	for s in spawns:
		if not d.has(s):
			flash("Blocked! Enemies must always have a path to the core.")
			return
	push_undo()
	blocks[bi].cell = beyond
	player = target
	on_board_changed()
	var b: Dictionary = blocks[bi]
	if b.locked:
		flash("%s is wedged in a corner - it can never move again." % Data.TOWERS[b.type].name)
	elif tile_at(beyond) == "*" and is_tower(b.type):
		flash("Power tile! +50% damage and +0.5 range.")


## The block drops into the hole and is gone; the hole becomes floor. Filling only ever
## opens the map, so it can't seal the enemy path.
func fill_hole(bi: int, c: Vector2i) -> void:
	push_undo()
	var b: Dictionary = blocks[bi]
	blocks.remove_at(bi)
	tiles[c.y][c.x] = "."
	filled[c] = b.type
	var col: Color = Data.TOWERS[b.type].color
	effects.append({"kind": "pop", "pos": cell_center(c), "r": TILE * 0.4, "t": 0.0, "dur": 0.5, "color": col})
	on_board_changed()
	flash("%s fell in and filled the hole." % Data.TOWERS[b.type].name)


func push_undo() -> void:
	var saved := []
	for b in blocks:
		saved.append(b.duplicate())
	undo_stack.append({"player": player, "blocks": saved, "tiles": tiles.duplicate(true), "filled": filled.duplicate()})


func undo() -> void:
	if undo_stack.is_empty():
		flash("Nothing to undo this build phase.")
		return
	var s: Dictionary = undo_stack.pop_back()
	player = s.player
	blocks = s.blocks
	tiles = s.tiles
	filled = s.filled
	on_board_changed()


func flash(text: String) -> void:
	message = text
	message_t = 3.0


func show_banner(text: String) -> void:
	banner = text
	banner_t = 2.5


# ---------------------------------------------------------------- simulation

func _process(delta: float) -> void:
	t += delta
	hover = world_to_cell(unproject((get_local_mouse_position() - board_pos) / board_scale))
	update_game(delta * (speed if phase == Phase.WAVE else 1.0), delta)
	queue_redraw()


func update_game(dt: float, real_dt: float) -> void:
	message_t -= real_dt
	banner_t -= real_dt
	player_draw = player_draw.move_toward(cell_center(player), real_dt * TILE * 14.0)
	update_moves(real_dt)
	for b in blocks:
		b.draw = b.draw.move_toward(cell_center(b.cell), real_dt * TILE * 14.0)
		b.pop = maxf(0.0, b.pop - real_dt * 2.5)
		b.pulse = maxf(0.0, b.pulse - real_dt * 4.0)
	for fx in effects:
		fx.t += dt
	effects = effects.filter(func(fx): return fx.t < fx.dur)
	if phase != Phase.WAVE:
		return

	spawn_timer -= dt
	if spawn_timer <= 0.0 and not spawn_queue.is_empty():
		var info: Dictionary = spawn_queue.pop_front()
		var s: Vector2i = spawns[spawn_rr % spawns.size()]
		spawn_rr += 1
		var e := make_enemy(info.type, s, info.scale)
		if info.boss:
			e.boss = true
			e.size *= 1.5
			e.speed *= 0.8
		enemies.append(e)
		spawn_timer = Data.ENEMIES[info.type].gap

	for e in enemies:
		if e.dead:
			continue
		e.flash -= dt
		if e.slow_t > 0.0:
			e.slow_t -= dt
			if e.slow_t <= 0.0:
				e.slow_amt = 0.0
		move_enemy(e, dt)

	update_towers(dt)
	update_projectiles(dt)

	enemies = enemies.filter(func(e): return not e.dead)
	enemies.append_array(pending_enemies)
	pending_enemies.clear()

	if lives <= 0:
		lives = 0
		phase = Phase.GAMEOVER
	elif spawn_queue.is_empty() and enemies.is_empty():
		wave_cleared()


func make_enemy(type: String, cell: Vector2i, scale: float) -> Dictionary:
	var def: Dictionary = Data.ENEMIES[type]
	enemy_id += 1
	return {
		"id": enemy_id, "type": type, "pos": cell_center(cell), "cell": cell, "next": cell,
		"hp": def.hp * scale, "max_hp": def.hp * scale, "scale": scale,
		"speed": def.speed, "armor": def.armor, "size": def.size, "color": def.color,
		"slow_t": 0.0, "slow_amt": 0.0, "flash": 0.0, "dead": false, "boss": false,
		"heading": Vector2.RIGHT,
	}


func move_enemy(e: Dictionary, dt: float) -> void:
	var remaining: float = e.speed * TILE * (1.0 - e.slow_amt) * dt
	for guard in 8:
		if remaining <= 0.0:
			return
		var tgt := cell_center(e.next)
		var to: Vector2 = tgt - e.pos
		var l := to.length()
		if l > remaining:
			e.heading = to / l
			e.pos += e.heading * remaining
			return
		e.pos = tgt
		remaining -= l
		e.cell = e.next
		if e.cell == goal:
			e.dead = true
			lives -= 3 if e.boss else 1
			effects.append({"kind": "leak", "pos": cell_center(goal), "t": 0.0, "dur": 0.5})
			return
		e.next = next_cell(e.cell)
		if e.next == e.cell:
			return


func remaining_path(e: Dictionary) -> float:
	return dist.get(e.next, 999) + e.pos.distance_to(cell_center(e.next)) / TILE


func pick_target(c: Vector2, r: float):
	var best = null
	var best_rem := INF
	for e in enemies:
		if e.dead or e.pos.distance_to(c) > r + e.size * TILE:
			continue
		var rem := remaining_path(e)
		if rem < best_rem:
			best_rem = rem
			best = e
	return best


func update_towers(dt: float) -> void:
	for b in blocks:
		if not is_tower(b.type):
			continue
		b.cd -= dt
		if b.cd > 0.0:
			continue
		var st: Dictionary = b.stats
		var c := cell_center(b.cell)
		var r: float = st.range * TILE
		if b.type == "frost":
			var hit := false
			for e in enemies:
				if not e.dead and e.pos.distance_to(c) <= r + e.size * TILE:
					hurt(e, st.dmg)
					e.slow_t = 1.6
					e.slow_amt = maxf(e.slow_amt, minf(st.slow, 0.8))
					hit = true
			if hit:
				b.cd = 1.0 / st.rate
				b.pulse = 1.0
				effects.append({"kind": "ring", "pos": c, "r": r, "t": 0.0, "dur": 0.45, "color": Data.TOWERS.frost.color})
			continue
		var target = pick_target(c, r)
		if target == null:
			continue
		b.cd = 1.0 / st.rate
		b.pulse = 1.0
		match b.type:
			"bolt":
				projectiles.append({"kind": "bolt", "pos": c, "dest": target.pos, "target": target,
					"dmg": st.dmg, "speed": TILE * 13.0, "done": false})
			"cannon":
				projectiles.append({"kind": "shell", "pos": c, "dest": target.pos, "target": target,
					"dmg": st.dmg, "speed": TILE * 7.0, "splash": st.splash * TILE,
					"shatter": st.shatter, "done": false})
			"tesla":
				chain_lightning(c, target, st)


func chain_lightning(from: Vector2, first: Dictionary, st: Dictionary) -> void:
	var pts: Array = [from]
	var hit_ids := []
	var cur = first
	var dmg: float = st.dmg
	for i in st.chain:
		if cur == null:
			break
		hit_ids.append(cur.id)
		pts.append(cur.pos)
		hurt(cur, dmg)
		dmg *= 0.85
		var nxt = null
		var best := 1.8 * TILE
		for e in enemies:
			if e.dead or e.id in hit_ids:
				continue
			var d: float = cur.pos.distance_to(e.pos)
			if d < best:
				best = d
				nxt = e
		cur = nxt
	effects.append({"kind": "zap", "pts": pts, "t": 0.0, "dur": 0.2})


func update_projectiles(dt: float) -> void:
	for p in projectiles:
		var tgt = p.target
		if tgt != null and not tgt.dead:
			p.dest = tgt.pos
		var to: Vector2 = p.dest - p.pos
		var step: float = p.speed * dt
		if to.length() > step:
			p.pos += to.normalized() * step
			continue
		p.pos = p.dest
		p.done = true
		if p.kind == "bolt":
			if tgt != null and not tgt.dead:
				hurt(tgt, p.dmg)
		else:
			for e in enemies:
				if not e.dead and e.pos.distance_to(p.pos) <= p.splash + e.size * TILE:
					var dm: float = p.dmg
					if p.shatter and e.slow_t > 0.0:
						dm *= 2.0
					hurt(e, dm)
			effects.append({"kind": "boom", "pos": p.pos, "r": p.splash, "t": 0.0, "dur": 0.3})
	projectiles = projectiles.filter(func(p): return not p.done)


func hurt(e: Dictionary, amount: float) -> void:
	if e.dead:
		return
	e.hp -= maxf(amount - e.armor, amount * 0.25)
	e.flash = 0.08
	if e.hp > 0.0:
		return
	e.dead = true
	kills += 1
	effects.append({"kind": "pop", "pos": e.pos, "r": e.size * TILE, "t": 0.0, "dur": 0.35, "color": e.color})
	if e.type == "splitter":
		for i in 2:
			var s := make_enemy("splitling", e.cell, e.scale)
			s.pos = e.pos + Vector2(randf_range(-7, 7), randf_range(-7, 7))
			s.next = e.next
			pending_enemies.append(s)


# ---------------------------------------------------------------- drawing

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color("141621"))
	# flat things on the ground, then everything with height sorted back to front
	draw_set_transform_matrix(ground_xf())
	draw_board()
	draw_tower_spawns()
	draw_path_preview()
	draw_ranges()
	draw_shadows()
	draw_effects(true)
	draw_set_transform_matrix(screen_xf())
	draw_world()
	draw_combo_links()
	draw_projectiles()
	draw_effects(false)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	draw_top_bar()
	draw_panel()
	if banner_t > 0.0 and phase in [Phase.BUILD, Phase.WAVE]:
		var a := clampf(banner_t, 0.0, 1.0)
		var br := board_screen_rect()
		var mid := br.get_center().y
		draw_rect(Rect2(br.position.x, mid - 34, br.size.x, 60), Color(0, 0, 0, 0.55 * a))
		text(banner, Vector2(br.position.x, mid + 6), 30, Color(1, 1, 1, a), br.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	match phase:
		Phase.TITLE:
			draw_title()
		Phase.REWARD:
			if rewards_hidden:
				draw_hidden_rewards_bar()
			else:
				draw_rewards()
		Phase.GAMEOVER:
			draw_end_screen("THE CORE HAS FALLEN", Color("e05555"))
		Phase.VICTORY:
			draw_end_screen("VICTORY!", Color("f2c94c"))


func text(s: String, pos: Vector2, size := 16, col := Color.WHITE, width := -1.0,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string(font, pos, s, align, width, size, col)


func draw_board() -> void:
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			BoardDraw.draw_tile(self, cell_rect(c), tiles[y][x], (x + y) % 2 == 0, t, tile_at(c + Vector2i.UP) == "O")
	# a filled hole shows the top of the block that fell in, flush with the floor
	for c in filled:
		var col: Color = Data.TOWERS[filled[c]].color
		draw_rect(cell_rect(c).grow(-3), col.darkened(0.6))
		draw_rect(cell_rect(c).grow(-3), col.darkened(0.35), false, 2.0)
	# corner brackets mark "premium" cells: a block pushed there is stuck forever
	for c in deadlocks:
		if block_index(c) < 0:
			BoardDraw.draw_corner_mark(self, cell_rect(c), is_hard(c + Vector2i.LEFT), is_hard(c + Vector2i.UP))
	if hover != NONE and phase in [Phase.BUILD, Phase.WAVE] and not is_wall(hover):
		draw_rect(cell_rect(hover).grow(-2), Color(1, 1, 1, 0.22), false, 2.0)


func draw_tower_spawns() -> void:
	for c in tower_spawns:
		var r := cell_rect(c).grow(-5)
		var cc := r.get_center()
		var col := Color(0.55, 0.85, 0.65, 0.45)
		if c == next_spawn and phase != Phase.TITLE:
			var a := 0.5 + 0.5 * sin(t * 4.0)
			draw_rect(r, Color(1, 0.8, 0.3, 0.12 + 0.12 * a))
			col = Color(1, 0.82, 0.35, 0.6 + 0.4 * a)
		draw_rect(r, col, false, 2.0)
		draw_line(cc + Vector2(-7, 0), cc + Vector2(7, 0), col, 2.0)
		draw_line(cc + Vector2(0, -7), cc + Vector2(0, 7), col, 2.0)


func draw_path_preview() -> void:
	if phase == Phase.TITLE:
		return
	var alpha := 0.55 if phase == Phase.BUILD else 0.18
	for s in spawns:
		var cells := path_points(s)
		if cells.size() < 2:
			continue
		var pts := PackedVector2Array()
		for c in cells:
			pts.append(cell_center(c))
		draw_polyline(pts, Color(1, 0.4, 0.4, alpha * 0.45), 3.0)
		var k := fmod(t * 2.0, 1.0)
		for i in pts.size() - 1:
			draw_circle(pts[i].lerp(pts[i + 1], k), 2.5, Color(1, 0.5, 0.5, alpha))


func draw_ranges() -> void:
	var show_all := Input.is_key_pressed(KEY_SHIFT)
	for b in blocks:
		if not is_tower(b.type) or b.stats.is_empty():
			continue
		if not show_all and b.cell != hover:
			continue
		var col: Color = Data.TOWERS[b.type].color
		var r: float = b.stats.range * TILE
		draw_circle(b.draw, r, Color(col, 0.07))
		draw_arc(b.draw, r, 0, TAU, 48, Color(col, 0.6), 1.5)


func draw_shadows() -> void:
	draw_circle(player_draw + Vector2(0, 4), 12.0, Color(0, 0, 0, 0.35))
	for e in enemies:
		draw_circle(e.pos + Vector2(0, 3), e.size * TILE * 0.9, Color(0, 0, 0, 0.3))


func wall_height(c: Vector2i) -> float:
	if c.x >= W or c.y >= H or tile_at(c) != "#":
		return 0.0
	return EDGE_WALL_H if c.y == H - 1 else WALL_H


func block_height(type: String) -> float:
	if is_tower(type):
		return 18.0
	return 14.0 if type == "stone" else 10.0


## A box standing on board point `c`, `e` from its centre to each side, `h` pixels tall.
## The camera only tilts forward, so just the top and the front (+y) face show.
func draw_prism(c: Vector2, e: float, h: float, top: Color, front: Color, show_front := true) -> void:
	var tl := project(c + Vector2(-e, -e), h)
	var br := project(c + Vector2(e, e))
	var front_top := project(c + Vector2(-e, e), h)
	if show_front:
		draw_rect(Rect2(front_top, br - front_top), front)
	draw_rect(Rect2(tl, front_top + Vector2(2 * e, 0) - tl), top)
	draw_line(front_top, front_top + Vector2(2 * e, 0), top.lightened(0.2), 1.5)


## Walls, blocks, the player and enemies, painted back to front.
func draw_world() -> void:
	var items := []
	for y in H:
		for x in W:
			if tiles[y][x] == "#":
				items.append([(y + 0.5) * TILE, 0, Vector2i(x, y)])
	for b in blocks:
		items.append([b.draw.y, 1, b])
	items.append([player_draw.y, 2, null])
	for e in enemies:
		items.append([e.pos.y, 3, e])
	items.sort_custom(func(a, b): return a[0] < b[0])
	for it in items:
		match it[1]:
			0:
				draw_wall(it[2])
			1:
				draw_block(it[2])
			2:
				draw_player()
			3:
				draw_enemy(it[2])


func draw_wall(c: Vector2i) -> void:
	var h := wall_height(c)
	draw_prism(cell_center(c), TILE * 0.5, h, Color("3d4260"), Color("262a3d"), wall_height(c + Vector2i.DOWN) < h)


func draw_block(b: Dictionary) -> void:
	var col: Color = Data.TOWERS[b.type].color
	var c: Vector2 = b.draw
	var e: float = TILE * 0.4 * (1.0 + b.pop * 0.25)
	var h: float = block_height(b.type) * (1.0 + b.pop * 0.5)
	draw_prism(c, e, h, col.darkened(0.15), col.darkened(0.5))
	# the icon is painted onto the top face
	draw_set_transform_matrix(ground_xf(h))
	draw_icon(b.type, c, col)
	if b.pulse > 0.0:
		draw_rect(Rect2(c - Vector2(e, e), Vector2(e, e) * 2.0).grow(2), Color(1, 1, 1, b.pulse * 0.5), false, 2.0)
	draw_set_transform_matrix(screen_xf())
	if b.locked:
		draw_lock(project(c + Vector2(e, e) * 0.55, h))


func draw_icon(type: String, c: Vector2, col: Color) -> void:
	var ink := col.lightened(0.65)
	var dark := col.darkened(0.7)
	match type:
		"bolt":
			draw_colored_polygon(PackedVector2Array([c + Vector2(0, -12), c + Vector2(9, 8),
				c + Vector2(0, 3), c + Vector2(-9, 8)]), dark)
		"cannon":
			draw_rect(Rect2(c + Vector2(-3, -14), Vector2(6, 10)), dark)
			draw_circle(c + Vector2(0, 2), 9.0, dark)
			draw_circle(c + Vector2(0, 2), 4.0, col.darkened(0.25))
		"frost":
			for i in 3:
				var d := Vector2.from_angle(i * PI / 3.0) * 12.0
				draw_line(c - d, c + d, ink, 3.0)
			draw_circle(c, 3.5, Color.WHITE)
		"tesla":
			draw_polyline(PackedVector2Array([c + Vector2(4, -13), c + Vector2(-5, -1), c + Vector2(4, 1),
				c + Vector2(-4, 13)]), ink, 3.0)
		"stone":
			var l := col.darkened(0.6)
			draw_line(c + Vector2(-15, -5), c + Vector2(15, -5), l, 2.0)
			draw_line(c + Vector2(-15, 6), c + Vector2(15, 6), l, 2.0)
			draw_line(c + Vector2(-3, -15), c + Vector2(-3, -5), l, 2.0)
			draw_line(c + Vector2(6, -5), c + Vector2(6, 6), l, 2.0)
			draw_line(c + Vector2(-6, 6), c + Vector2(-6, 15), l, 2.0)
		"amp":
			for k in 2:
				var o := Vector2(0, 7 - k * 10)
				draw_polyline(PackedVector2Array([c + o + Vector2(-10, 5), c + o + Vector2(0, -5),
					c + o + Vector2(10, 5)]), ink, 3.5)
		"clock":
			draw_arc(c, 11.0, 0, TAU, 24, dark, 3.0)
			draw_line(c, c + Vector2(0, -8), ink, 3.0)
			draw_line(c, c + Vector2(6, 3), ink, 3.0)
		"lens":
			draw_arc(c + Vector2(-3, -3), 9.0, 0, TAU, 24, ink, 3.0)
			draw_circle(c + Vector2(-3, -3), 6.5, Color(1, 1, 1, 0.25))
			draw_line(c + Vector2(4, 4), c + Vector2(12, 12), dark, 4.0)


func draw_lock(p: Vector2) -> void:
	draw_circle(p, 8.0, Color(0, 0, 0, 0.6))
	draw_arc(p + Vector2(0, -1), 3.0, PI, TAU, 8, Color("f2c94c"), 1.5)
	draw_rect(Rect2(p + Vector2(-4, -1), Vector2(8, 6)), Color("f2c94c"))


func draw_combo_links() -> void:
	for i in blocks.size():
		for j in range(i + 1, blocks.size()):
			var a: Dictionary = blocks[i]
			var b: Dictionary = blocks[j]
			var d: Vector2i = a.cell - b.cell
			if absi(d.x) + absi(d.y) != 1 or combo_info(a.type, b.type).is_empty():
				continue
			if a.type == "stone" and b.type == "stone":
				continue
			var mid: Vector2 = project((a.draw + b.draw) * 0.5, minf(block_height(a.type), block_height(b.type)))
			var col: Color = Data.TOWERS[a.type].color.lerp(Data.TOWERS[b.type].color, 0.5).lightened(0.3)
			var s := 6.0 + sin(t * 5.0) * 1.0
			draw_colored_polygon(PackedVector2Array([mid + Vector2(0, -s), mid + Vector2(s, 0),
				mid + Vector2(0, s), mid + Vector2(-s, 0)]), col)
			draw_circle(mid, 2.0, Color.WHITE)


func draw_player() -> void:
	var c := player_draw
	draw_circle(project(c, 8.0), 12.0, Color("2a8c5b"))
	draw_circle(project(c, 15.0), 12.0, Color("3fbf7f"))
	draw_circle(project(c, 15.0), 12.0, Color("2a8c5b"), false, 2.0)
	var f := Vector2(player_facing)
	if project(f).y < 0.0:
		return  # facing away from the camera: we see the back of the head
	var side := Vector2(-f.y, f.x)
	for sgn in [-1.0, 1.0]:
		var eye: Vector2 = c + f * 6.0 + side * 5.0 * sgn
		draw_circle(project(eye, 17.0), 3.5, Color.WHITE)
		draw_circle(project(eye + f * 1.5, 17.0), 1.8, Color("1a1a1a"))


func draw_enemy(e: Dictionary) -> void:
	var col: Color = Color.WHITE if e.flash > 0.0 else e.color
	var r: float = e.size * TILE
	var p: Vector2 = e.pos
	var body := project(p, r)
	match e.type:
		"grunt", "splitling":
			draw_circle(body, r, col.darkened(0.3))
			draw_circle(body + Vector2(0, -2), r * 0.85, col)
		"runner":
			var hd: Vector2 = e.heading
			var sd := Vector2(-hd.y, hd.x)
			draw_colored_polygon(PackedVector2Array([project(p + hd * r * 1.3, r), project(p - hd * r + sd * r, r),
				project(p - hd * r - sd * r, r)]), col)
		"brute":
			draw_prism(p, r * 0.85, r * 1.8, col, col.darkened(0.4))
			body = project(p, r * 0.9)
		"splitter":
			var s := r * 1.2
			draw_colored_polygon(PackedVector2Array([body + Vector2(0, -s), body + Vector2(r, 0),
				body + Vector2(0, s), body + Vector2(-r, 0)]), col)
			draw_line(body + Vector2(0, -s), body + Vector2(0, s), col.darkened(0.4), 2.0)
	if e.boss:
		draw_arc(body, r + 5.0, 0, TAU, 24, Color("f2c94c"), 2.5)
	if e.slow_t > 0.0:
		draw_arc(body, r + 2.0, 0, TAU, 20, Color(0.55, 0.9, 1.0, 0.9), 2.0)
	if e.hp < e.max_hp:
		var w := maxf(r * 2.0, 18.0)
		var top := project(p, r * 2.0 + 10.0)
		var bar := Rect2(top + Vector2(-w / 2, 0), Vector2(w, 4))
		draw_rect(bar, Color(0, 0, 0, 0.7))
		draw_rect(Rect2(bar.position, Vector2(w * maxf(e.hp / e.max_hp, 0.0), 4)), Color("6be675"))


func draw_projectiles() -> void:
	for p in projectiles:
		if p.kind == "bolt":
			var dir: Vector2 = (p.dest - p.pos).normalized()
			draw_line(project(p.pos - dir * 8.0, 18.0), project(p.pos, 18.0), Color("fff1a8"), 3.0)
		else:
			draw_circle(project(p.pos, 20.0), 5.0, Color("3a2a1a"))
			draw_circle(project(p.pos, 20.0), 3.0, Color("eb8a3c"))


## `ground`: the flat effects (rings, blasts) drawn on the floor; otherwise the ones in the air.
func draw_effects(ground: bool) -> void:
	for fx in effects:
		var k: float = fx.t / fx.dur
		if (fx.kind == "zap") == ground:
			continue
		match fx.kind:
			"ring":
				var col: Color = fx.color
				draw_arc(fx.pos, fx.r * (0.3 + 0.7 * k), 0, TAU, 40, Color(col, 0.8 * (1.0 - k)), 3.0)
			"boom":
				draw_circle(fx.pos, fx.r * (0.5 + 0.5 * k), Color(1, 0.6, 0.2, 0.55 * (1.0 - k)))
			"zap":
				var pts := PackedVector2Array()
				for i in fx.pts.size():
					var q := project(fx.pts[i], 14.0)
					if i > 0:
						var prev := project(fx.pts[i - 1], 14.0)
						var m := (prev + q) * 0.5 + Vector2(randf_range(-6, 6), randf_range(-6, 6))
						pts.append(m)
					pts.append(q)
				if pts.size() >= 2:
					draw_polyline(pts, Color(0.85, 0.7, 1.0, 1.0 - k), 3.0)
					draw_polyline(pts, Color(1, 1, 1, 1.0 - k), 1.0)
			"pop":
				var col: Color = fx.color
				draw_arc(fx.pos, fx.r * (1.0 + k * 1.2), 0, TAU, 20, Color(col, 1.0 - k), 2.0)
			"leak":
				draw_rect(cell_rect(goal).grow(4.0 + k * 10.0), Color(1, 0.2, 0.2, 0.7 * (1.0 - k)), false, 3.0)


func draw_top_bar() -> void:
	var lv: Dictionary = levels[level_idx]
	var title := "PLAYTEST  ·  %s" % lv.name.to_upper() if custom else "LEVEL %d  ·  %s" % [level_idx + 1, lv.name.to_upper()]
	text(title, Vector2(18, 36), 20, Color("e8e8f0"))
	var hint := ""
	match phase:
		Phase.BUILD:
			hint = "BUILD - push blocks, SPACE to send the wave"
		Phase.WAVE:
			hint = "WAVE IN PROGRESS - blocks are frozen   (F: speed x%d)" % int(speed)
	if phase == Phase.BUILD:
		hint = ("Esc: back to editor" if custom else "Esc: level select") + "  ·  " + hint
	if message_t > 0.0:
		text(message, Vector2(300, 36), 16, Color(1, 0.85, 0.4, clampf(message_t, 0.0, 1.0)), PANEL_X - 316, HORIZONTAL_ALIGNMENT_RIGHT)
	else:
		text(hint, Vector2(300, 36), 15, Color("9aa0bc"), PANEL_X - 316, HORIZONTAL_ALIGNMENT_RIGHT)


func draw_panel() -> void:
	var x := PANEL_X
	draw_rect(Rect2(x - 4, 0, SCREEN.x - x + 4, SCREEN.y), Color("181a28"))
	draw_line(Vector2(x - 4, 0), Vector2(x - 4, SCREEN.y), Color("2b2f45"), 2.0)
	text("SOKOBAN TD", Vector2(x + 12, 36), 24, Color("f2c94c"))
	var y := 70.0
	var lv: Dictionary = levels[level_idx]
	text("Lives", Vector2(x + 12, y), 15, Color("9aa0bc"))
	text(str(lives), Vector2(x + 70, y), 18, Color("e05555") if lives <= 5 else Color.WHITE)
	text("Wave", Vector2(x + 130, y), 15, Color("9aa0bc"))
	text("%d / %d" % [mini(wave_idx + 1, lv.waves), lv.waves], Vector2(x + 180, y), 18)
	y += 22
	text("Kills %d   Path %d tiles" % [kills, dist.get(spawns[0], 0) if not spawns.is_empty() else 0],
		Vector2(x + 12, y), 14, Color("9aa0bc"))
	if not tower_spawns.is_empty():
		y += 20
		if next_spawn != NONE:
			text("Next tower drops on the glowing spawn", Vector2(x + 12, y), 12, Color("e0c070"))
		else:
			text("All tower spawns covered: upgrades only", Vector2(x + 12, y), 12, Color("e07070"))

	# next wave preview / live count
	y += 30
	if phase == Phase.BUILD:
		text("NEXT WAVE", Vector2(x + 12, y), 13, Color("6c7290"))
		y += 20
		var counts := {}
		var boss := false
		for q in next_wave:
			if q.boss:
				boss = true
			else:
				counts[q.type] = counts.get(q.type, 0) + 1
		var cx := x + 12
		for ty in counts:
			draw_circle(Vector2(cx + 6, y - 5), 6.0, Data.ENEMIES[ty].color)
			text("%s x%d" % [Data.ENEMIES[ty].name, counts[ty]], Vector2(cx + 16, y), 13)
			cx += 112
			if cx > x + 200:
				cx = x + 12
				y += 18
		if boss:
			if cx != x + 12:
				y += 18
			draw_arc(Vector2(x + 18, y - 5), 7.0, 0, TAU, 16, Color("f2c94c"), 2.0)
			text("BOSS Brute", Vector2(x + 28, y), 13, Color("f2c94c"))
		y += 10
	elif phase == Phase.WAVE:
		text("ENEMIES LEFT  %d" % (enemies.size() + spawn_queue.size()), Vector2(x + 12, y), 13, Color("6c7290"))
		y += 10

	# hover inspector
	y += 16
	draw_line(Vector2(x + 12, y), Vector2(SCREEN.x - 16, y), Color("2b2f45"), 1.0)
	y += 22
	y = draw_inspector(x + 12, y)

	var controls := "Move/push: WASD or arrows\nZ undo  ·  SPACE start wave\nF speed  ·  Shift show ranges\nH hide/show rewards  ·  hover for stats"
	draw_multiline_string(font, Vector2(x + 12, SCREEN.y - 80), controls, HORIZONTAL_ALIGNMENT_LEFT, 236, 12, -1, Color("6c7290"))


func draw_inspector(x: float, y: float) -> float:
	var bi := block_index(hover) if hover != NONE else -1
	if bi >= 0:
		var b: Dictionary = blocks[bi]
		var def: Dictionary = Data.TOWERS[b.type]
		text(def.name, Vector2(x, y), 18, def.color)
		if b.locked:
			text("LOCKED", Vector2(x + 170, y), 12, Color("f2c94c"))
		y += 20
		draw_multiline_string(font, Vector2(x, y), def.desc, HORIZONTAL_ALIGNMENT_LEFT, 230, 12, 2, Color("b8bdd6"))
		y += 34
		var s: Dictionary = b.stats
		if is_tower(b.type):
			var line := "DMG %.0f  RATE %.2f/s  RNG %.1f" % [s.dmg, s.rate, s.range]
			text(line, Vector2(x, y), 13)
			y += 18
			var extra := ""
			if s.splash > 0.0:
				extra = "Splash %.1f" % s.splash
			if s.chain > 0:
				extra = "Chains %d" % s.chain
			if s.slow > 0.0:
				extra = "Slow %d%%" % roundi(minf(s.slow, 0.8) * 100)
			if s.shatter:
				extra += "  Shatter"
			if extra != "":
				text(extra, Vector2(x, y), 13)
				y += 18
		for n in s.notes:
			draw_multiline_string(font, Vector2(x, y), "+ " + n, HORIZONTAL_ALIGNMENT_LEFT, 230, 12, 2, Color("f2c94c"))
			y += 30 if font.get_string_size("+ " + n, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x > 230 else 16
		return y
	if hover != NONE:
		var ch := tile_at(hover)
		var info := ""
		if hover in tower_spawns:
			info = "TOWER SPAWN\nReward towers drop on spawns in turn. A spawn with a block on it is skipped."
		elif ch == "O":
			info = "HOLE\nNobody can cross it. Push a block in to fill it - the block is lost."
		elif ch == "*":
			info = "POWER TILE\nA tower here deals +50% damage and gets +0.5 range."
		elif hover in deadlocks:
			info = "CORNER\nA block pushed here can never be moved again."
		elif ch == "S":
			info = "ENEMY GATE"
		elif ch == "G":
			info = "CORE\nEach enemy that reaches it costs a life (boss: 3)."
		if info != "":
			draw_multiline_string(font, Vector2(x, y), info, HORIZONTAL_ALIGNMENT_LEFT, 230, 13, 4, Color("b8bdd6"))
			return y + 60
	if phase == Phase.BUILD:
		draw_multiline_string(font, Vector2(x, y), levels[level_idx].tip, HORIZONTAL_ALIGNMENT_LEFT,
			230, 13, 4, Color("7f86a6"))
		y += 60
	# block inventory
	var counts := {}
	for b in blocks:
		counts[b.type] = counts.get(b.type, 0) + 1
	text("YOUR BLOCKS", Vector2(x, y), 13, Color("6c7290"))
	y += 20
	for ty in counts:
		draw_rect(Rect2(x, y - 11, 12, 12), Data.TOWERS[ty].color)
		text("%s x%d" % [Data.TOWERS[ty].name, counts[ty]], Vector2(x + 18, y), 13)
		y += 17
	return y


func dim() -> void:
	draw_rect(Rect2(Vector2.ZERO, SCREEN), Color(0.03, 0.03, 0.06, 0.78))


func draw_title() -> void:
	dim()
	text("SOKOBAN TD", Vector2(0, 110), 56, Color("f2c94c"), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	text("push  ·  block  ·  defend", Vector2(0, 146), 18, Color("9aa0bc"), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	var lines := "Your towers are crates. Push them like Sokoban to reshape the enemy path.\n" + \
		"Blocks can't move while enemies are on the field - plan during the build phase.\n" + \
		"Corners are forever. Each cleared wave grants a reward; neighbouring towers combo."
	draw_multiline_string(font, Vector2(SCREEN.x / 2 - 340, 190), lines, HORIZONTAL_ALIGNMENT_CENTER, 680, 15, -1, Color("b8bdd6"))
	text("SELECT A LEVEL", Vector2(0, 286), 16, Color("9aa0bc"), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	for i in levels.size():
		var r := level_rect(i)
		var lv: Dictionary = levels[i]
		var sel := i == select_idx
		draw_rect(r, Color("2a2e48") if sel else Color("1c1f30"))
		draw_rect(r, Color("f2c94c") if sel else Color("3a3f5c"), false, 2.0 if sel else 1.0)
		text(str(i + 1), r.position + Vector2(18, 38), 26, Color("f2c94c") if sel else Color("6a7090"))
		text(lv.name, r.position + Vector2(60, 26), 20, Color.WHITE if sel else Color("d0d4e8"))
		text("%d waves" % lv.waves, r.position + Vector2(r.size.x - 120, 26), 15, Color("9aa0bc"), 104, HORIZONTAL_ALIGNMENT_RIGHT)
		text(lv.get("tip", ""), r.position + Vector2(60, 46), 13, Color("9aa0bc"), r.size.x - 76)
	var a := 0.6 + 0.4 * sin(t * 4.0)
	var foot := level_rect(levels.size() - 1).end.y + 44
	text("Arrows: choose  ·  ENTER or click: play  ·  E: level editor", Vector2(0, foot), 17, Color(1, 1, 1, a),
		SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)


func level_rect(i: int) -> Rect2:
	return Rect2(SCREEN.x / 2 - 300, 300 + i * 66, 600, 56)


func level_at(m: Vector2) -> int:
	for i in levels.size():
		if level_rect(i).has_point(m):
			return i
	return -1


func card_rect(i: int) -> Rect2:
	return Rect2(SCREEN.x / 2 - (rewards.size() * 280 - 30) / 2.0 + i * 280, 200, 250, 240)


func hide_button_rect() -> Rect2:
	return Rect2(SCREEN.x / 2 - 110, 470, 220, 34)


func hidden_bar_rect() -> Rect2:
	return Rect2(SCREEN.x / 2 - 260, SCREEN.y - 58, 520, 42)


func reward_info(r: Dictionary) -> Array:
	match r.kind:
		"block":
			var def: Dictionary = Data.TOWERS[r.type]
			var head := "UPGRADE BLOCK" if r.type in UPGRADE_TYPES else "NEW TOWER" if is_tower(r.type) else "NEW BLOCK"
			return [head, def.name, def.desc, def.color]
		"heal":
			return ["REPAIR", "Patch the Core", "Restore 5 lives.", Color("e05555")]
	return ["", "", "", Color.WHITE]


func draw_rewards() -> void:
	dim()
	draw_spawn_marker()
	var head := "WAVE CLEARED!"
	text(head, Vector2(0, 130), 36, Color("f2c94c"), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	var sub := "Choose a reward"
	if rewards.any(func(r): return r.kind == "block"):
		sub = "Choose a reward - the new block drops on the glowing spawn"
	elif not tower_spawns.is_empty():
		sub = "Every tower spawn is covered - clear one to get blocks again"
	text(sub, Vector2(0, 165), 16, Color("9aa0bc"), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	var m := get_local_mouse_position()
	for i in rewards.size():
		var r := card_rect(i)
		var info := reward_info(rewards[i])
		var col: Color = info[3]
		var hov := r.has_point(m)
		draw_rect(r, Color("232740") if hov else Color("1c1f33"))
		draw_rect(r, col if hov else col.darkened(0.4), false, 3.0)
		text(info[0], r.position + Vector2(0, 30), 13, Color("9aa0bc"), r.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		var icon_c := r.position + Vector2(r.size.x / 2, 82)
		var rew: Dictionary = rewards[i]
		if rew.kind == "block":
			var half := TILE * 0.42
			var rect := Rect2(icon_c - Vector2(half, half), Vector2(half, half) * 2.0)
			draw_rect(rect, col.darkened(0.55))
			draw_rect(rect.grow(-3), col.darkened(0.25))
			draw_icon(rew.type, icon_c, col)
		else:
			draw_circle(icon_c, 20.0, col.darkened(0.3))
			text("+", icon_c + Vector2(-8, 10), 30, Color.WHITE)
		text(info[1], r.position + Vector2(0, 142), 20, col, r.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		draw_multiline_string(font, r.position + Vector2(18, 170), info[2], HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x - 36, 14, 3, Color("d0d4e8"))
		text("[%d]" % (i + 1), r.position + Vector2(0, r.size.y - 14), 14, Color("6c7290"), r.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	var hb := hide_button_rect()
	draw_rect(hb, Color("232740") if hb.has_point(m) else Color("1c1f33"))
	draw_rect(hb, Color("6c7290"), false, 1.5)
	text("Hide to view the field  [H]", hb.position + Vector2(0, 22), 14, Color("b8bdd6"), hb.size.x, HORIZONTAL_ALIGNMENT_CENTER)


func draw_hidden_rewards_bar() -> void:
	draw_spawn_marker()
	var r := hidden_bar_rect()
	var a := 0.75 + 0.25 * sin(t * 4.0)
	draw_rect(r, Color(0.09, 0.1, 0.16, 0.92))
	draw_rect(r, Color(0.95, 0.79, 0.3, a), false, 2.0)
	text("Reward waiting - press H or click here to choose", r.position + Vector2(0, 27), 16,
		Color("f2c94c"), r.size.x, HORIZONTAL_ALIGNMENT_CENTER)


## Points out where a tower reward will land: above the dimmed field, below the reward UI.
func draw_spawn_marker() -> void:
	if next_spawn == NONE or not rewards.any(func(r): return r.kind == "block"):
		return
	var c := cell_center(next_spawn)
	var e := TILE * 0.42
	var pts := PackedVector2Array()
	for d in [Vector2(-e, -e), Vector2(e, -e), Vector2(e, e), Vector2(-e, e), Vector2(-e, -e)]:
		pts.append(to_screen(c + d))
	var k := fmod(t * 1.2, 1.0)
	var ring := PackedVector2Array()
	for d in pts:
		ring.append(to_screen(c) + (d - to_screen(c)) * (1.1 + 0.9 * k))
	draw_polyline(ring, Color(1, 0.82, 0.35, 1.0 - k), 3.0)
	draw_polyline(pts, Color(1, 0.82, 0.35, 0.9), 2.5)


func draw_end_screen(title: String, col: Color) -> void:
	dim()
	text(title, Vector2(0, 280), 48, col, SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	var lv: Dictionary = levels[level_idx]
	var sub := "%s: fell on wave %d of %d  ·  %d enemies destroyed  ·  %d blocks" % [
		lv.name, mini(wave_idx + 1, lv.waves), lv.waves, kills, blocks.size()]
	if phase == Phase.VICTORY:
		sub = "%s beaten with %d lives left  ·  %d enemies destroyed  ·  %d blocks" % [
			lv.name, lives, kills, blocks.size()]
	text(sub, Vector2(0, 330), 16, Color("d0d4e8"), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	var again := "R: retry  ·  E or Esc: back to editor"
	if not custom:
		again = "R: retry  ·  ENTER: level select" if phase == Phase.GAMEOVER else "Press ENTER to return to the level select"
	text(again, Vector2(0, 400), 20, Color(1, 1, 1, 0.6 + 0.4 * sin(t * 4.0)), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
