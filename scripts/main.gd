extends Node2D
## Sokoban TD: push tower blocks to shape the enemy path, then survive the wave.

const Data = preload("res://scripts/data.gd")

const TILE := 48.0
const W := 16
const H := 11
const GRID_OFS := Vector2(16, 56)
const PANEL_X := 800.0
const SCREEN := Vector2(1060, 600)
const NONE := Vector2i(-99, -99)
const DIRS: Array[Vector2i] = [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]
const ATTACK_TYPES := ["bolt", "cannon", "frost", "tesla"]
const START_LIVES := 20

enum Phase { TITLE, BUILD, WAVE, REWARD, GAMEOVER, VICTORY }

var phase: int = Phase.TITLE
var level_idx := 0
var wave_idx := 0
var lives := START_LIVES
var kills := 0

# Board
var tiles: Array = []
var spawns: Array[Vector2i] = []
var goal := Vector2i.ZERO
var docks: Array[Vector2i] = []
var deadlocks: Array[Vector2i] = []
var dist: Dictionary = {}
var player := Vector2i.ZERO
var player_draw := Vector2.ZERO
var player_facing := Vector2i.RIGHT
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
var level_done := false
var dmg_mult := {}
var rate_mult := 1.0
var range_bonus := 0.0

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
	reset_run()
	phase = Phase.TITLE


# ---------------------------------------------------------------- run / level flow

func reset_run() -> void:
	lives = START_LIVES
	kills = 0
	dmg_mult = {"bolt": 1.0, "cannon": 1.0, "frost": 1.0, "tesla": 1.0, "stone": 0.0}
	rate_mult = 1.0
	range_bonus = 0.0
	speed = 1.0
	carried = ["bolt"]
	load_level(0)


func load_level(i: int) -> void:
	level_idx = i
	wave_idx = 0
	level_done = false
	var lv: Dictionary = Data.LEVELS[i]
	tiles = []
	spawns.clear()
	docks.clear()
	for y in H:
		var row: Array = []
		var line: String = lv.map[y]
		for x in W:
			var ch := line[x]
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
					docks.append(c)
					ch = "."
			row.append(ch)
		tiles.append(row)
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
	for type in carried:
		place_new_block(type)
	player_draw = cell_center(player)
	enter_build()
	show_banner("Level %d: %s" % [i + 1, lv.name])


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
	var d := wi
	for i in li:
		d += Data.LEVELS[i].waves
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
	if wi == Data.LEVELS[li].waves - 1:
		q.append({"type": "brute", "scale": hp_scale * 3.0, "boss": true})
	return q


func wave_cleared() -> void:
	wave_idx += 1
	projectiles.clear()
	if wave_idx >= Data.LEVELS[level_idx].waves:
		if level_idx >= Data.LEVELS.size() - 1:
			phase = Phase.VICTORY
			return
		level_done = true
	roll_rewards()
	phase = Phase.REWARD


func roll_rewards() -> void:
	var block_pool := ["bolt", "cannon", "frost", "tesla", "stone"]
	block_pool.shuffle()
	var others := []
	for ty in ATTACK_TYPES:
		if has_type(ty):
			others.append({"kind": "dmg", "type": ty})
	others.append({"kind": "rate"})
	others.append({"kind": "range"})
	if lives < START_LIVES:
		others.append({"kind": "heal"})
	others.shuffle()
	rewards = [{"kind": "block", "type": block_pool[0]}]
	if randf() < 0.5:
		rewards.append({"kind": "block", "type": block_pool[1]})
	else:
		rewards.append(others.pop_back())
	rewards.append(others.pop_back())
	rewards.shuffle()


func choose_reward(i: int) -> void:
	if i < 0 or i >= rewards.size():
		return
	var r: Dictionary = rewards[i]
	var bonus := []
	match r.kind:
		"block":
			var n := 2 if r.type == "stone" else 1
			for k in n:
				if level_done:
					bonus.append(r.type)
				elif place_new_block(r.type):
					blocks[-1].pop = 1.0
				else:
					flash("No room to place the new block!")
		"dmg":
			dmg_mult[r.type] += 0.3
		"rate":
			rate_mult *= 1.15
		"range":
			range_bonus += 0.4
		"heal":
			lives = mini(lives + 5, 30)
	if level_done:
		carried = []
		for b in blocks:
			carried.append(b.type)
		carried.append_array(bonus)
		load_level(level_idx + 1)
	else:
		enter_build()


func has_type(ty: String) -> bool:
	for b in blocks:
		if b.type == ty:
			return true
	return false


# ---------------------------------------------------------------- board helpers

func tile_at(c: Vector2i) -> String:
	if c.x < 0 or c.y < 0 or c.x >= W or c.y >= H:
		return "#"
	return tiles[c.y][c.x]


func is_wall(c: Vector2i) -> bool:
	return tile_at(c) == "#"


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
	return GRID_OFS + (Vector2(c) + Vector2(0.5, 0.5)) * TILE


func cell_rect(c: Vector2i) -> Rect2:
	return Rect2(GRID_OFS + Vector2(c) * TILE, Vector2(TILE, TILE))


func world_to_cell(p: Vector2) -> Vector2i:
	var g := (p - GRID_OFS) / TILE
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


func place_new_block(type: String) -> bool:
	var candidates: Array = docks.duplicate()
	candidates.append_array(walk_bfs(player, NONE))
	for c in candidates:
		if can_place(c):
			blocks.append({
				"type": type, "cell": c, "draw": cell_center(c), "cd": 0.0,
				"stats": {}, "locked": false, "pulse": 0.0, "pop": 0.0,
			})
			on_board_changed()
			return true
	return false


func on_board_changed() -> void:
	dist = path_field(NONE, NONE)
	compute_stats()
	for b in blocks:
		b.locked = is_locked(b.cell)


# ---------------------------------------------------------------- stats & combos

func combo_key(a: String, b: String) -> String:
	return a + "+" + b if a < b else b + "+" + a


func combo_info(a: String, b: String) -> Dictionary:
	if a == "stone" and b == "stone":
		return {}
	if a == "stone" or b == "stone":
		return {"name": "Bulwark", "desc": "tower +0.5 range"}
	return Data.COMBOS[combo_key(a, b)]


func apply_combo(ty: String, other: String, s: Dictionary) -> void:
	if ty == "stone":
		return
	if other == "stone":
		s.range += 0.5
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
			"dmg": def.dmg * dmg_mult[b.type],
			"rate": def.rate * rate_mult,
			"range": def.range + (range_bonus if b.type != "stone" else 0.0),
			"splash": def.get("splash", 0.0),
			"chain": def.get("chain", 0),
			"slow": def.get("slow", 0.0),
			"shatter": false,
			"notes": [],
		}
		if b.type != "stone" and tile_at(b.cell) == "*":
			s.dmg *= 1.5
			s.range += 0.5
			s.notes.append("Power tile: +50% dmg, +0.5 range")
		for dir in DIRS:
			var j := block_index(b.cell + dir)
			if j < 0:
				continue
			var other: String = blocks[j].type
			var info := combo_info(b.type, other)
			if info.is_empty() or b.type == "stone":
				continue
			apply_combo(b.type, other, s)
			s.notes.append("%s: %s" % [info.name, info.desc])
		b.stats = s


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		var k: int = event.keycode
		match phase:
			Phase.TITLE:
				if not event.echo and k in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
					reset_run()
			Phase.GAMEOVER, Phase.VICTORY:
				if not event.echo and k in [KEY_ENTER, KEY_KP_ENTER, KEY_R]:
					reset_run()
			Phase.REWARD:
				if k >= KEY_1 and k <= KEY_3:
					choose_reward(k - KEY_1)
			Phase.BUILD, Phase.WAVE:
				var dir := key_dir(k)
				if dir != Vector2i.ZERO:
					try_move(dir)
				elif k == KEY_Z and phase == Phase.BUILD:
					undo()
				elif not event.echo and k in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER] and phase == Phase.BUILD:
					start_wave()
				elif not event.echo and k == KEY_F:
					speed = 1.0 if speed >= 3.0 else speed + 1.0
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var m := get_local_mouse_position()
		match phase:
			Phase.REWARD:
				for i in rewards.size():
					if card_rect(i).has_point(m):
						choose_reward(i)
						return
			Phase.TITLE, Phase.GAMEOVER, Phase.VICTORY:
				reset_run()


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
	elif tile_at(beyond) == "*" and b.type != "stone":
		flash("Power tile! +50% damage and +0.5 range.")


func push_undo() -> void:
	var cells := []
	for b in blocks:
		cells.append(b.cell)
	undo_stack.append({"player": player, "cells": cells})


func undo() -> void:
	if undo_stack.is_empty():
		flash("Nothing to undo this build phase.")
		return
	var s: Dictionary = undo_stack.pop_back()
	player = s.player
	for i in blocks.size():
		blocks[i].cell = s.cells[i]
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
	hover = world_to_cell(get_local_mouse_position())
	update_game(delta * (speed if phase == Phase.WAVE else 1.0), delta)
	queue_redraw()


func update_game(dt: float, real_dt: float) -> void:
	message_t -= real_dt
	banner_t -= real_dt
	player_draw = player_draw.move_toward(cell_center(player), real_dt * TILE * 14.0)
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
		if b.type == "stone":
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
	draw_board()
	draw_path_preview()
	draw_ranges()
	draw_blocks()
	draw_combo_links()
	draw_player()
	draw_enemies()
	draw_projectiles()
	draw_effects()
	draw_top_bar()
	draw_panel()
	if banner_t > 0.0 and phase in [Phase.BUILD, Phase.WAVE]:
		var a := clampf(banner_t, 0.0, 1.0)
		var board_w := W * TILE
		draw_rect(Rect2(GRID_OFS + Vector2(0, H * TILE * 0.5 - 34), Vector2(board_w, 60)), Color(0, 0, 0, 0.55 * a))
		text(banner, GRID_OFS + Vector2(0, H * TILE * 0.5 + 6), 30, Color(1, 1, 1, a), board_w, HORIZONTAL_ALIGNMENT_CENTER)
	match phase:
		Phase.TITLE:
			draw_title()
		Phase.REWARD:
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
			var r := cell_rect(c)
			var ch: String = tiles[y][x]
			if ch == "#":
				draw_rect(r, Color("2b2f45"))
				draw_rect(Rect2(r.position, Vector2(TILE, 5)), Color("3a3f5c"))
				continue
			draw_rect(r, Color("1c1f2e") if (x + y) % 2 == 0 else Color("202436"))
			var cc := cell_center(c)
			match ch:
				"*":
					draw_rect(r.grow(-3), Color(1, 0.8, 0.3, 0.10 + 0.06 * sin(t * 3.0)))
					draw_rect(r.grow(-3), Color("f2c94c"), false, 2.0)
					draw_star(cc, 8.0, Color(0.95, 0.79, 0.3, 0.8))
				"S":
					for i in 3:
						var k := fmod(t * 0.8 + i / 3.0, 1.0)
						draw_arc(cc, 4.0 + k * 18.0, 0, TAU, 24, Color(1, 0.35, 0.35, 1.0 - k), 2.0)
					draw_circle(cc, 6.0, Color("e05555"))
				"G":
					var s := 15.0 + sin(t * 2.5) * 2.0
					draw_colored_polygon(PackedVector2Array([cc + Vector2(0, -s), cc + Vector2(s * 0.75, 0),
						cc + Vector2(0, s), cc + Vector2(-s * 0.75, 0)]), Color("4fd1c5"))
					draw_circle(cc, 4.0, Color.WHITE)
	# corner brackets mark "premium" cells: a block pushed there is stuck forever
	for c in deadlocks:
		if block_index(c) >= 0:
			continue
		var r := cell_rect(c).grow(-6)
		var col := Color(1, 1, 1, 0.13)
		var corner := Vector2(
			r.position.x if is_hard(c + Vector2i.LEFT) else r.end.x,
			r.position.y if is_hard(c + Vector2i.UP) else r.end.y)
		var sx := 1.0 if corner.x == r.position.x else -1.0
		var sy := 1.0 if corner.y == r.position.y else -1.0
		draw_line(corner, corner + Vector2(10 * sx, 0), col, 2.0)
		draw_line(corner, corner + Vector2(0, 10 * sy), col, 2.0)


func draw_star(c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI / 2 + i * PI / 5
		pts.append(c + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.45))
	draw_colored_polygon(pts, col)


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
		if b.type == "stone" or b.stats.is_empty():
			continue
		if not show_all and b.cell != hover:
			continue
		var col: Color = Data.TOWERS[b.type].color
		var r: float = b.stats.range * TILE
		draw_circle(b.draw, r, Color(col, 0.07))
		draw_arc(b.draw, r, 0, TAU, 48, Color(col, 0.6), 1.5)


func draw_blocks() -> void:
	for b in blocks:
		var col: Color = Data.TOWERS[b.type].color
		var c: Vector2 = b.draw
		var half: float = TILE * 0.42 * (1.0 + b.pop * 0.35)
		var rect := Rect2(c - Vector2(half, half), Vector2(half, half) * 2.0)
		draw_rect(Rect2(rect.position + Vector2(2, 4), rect.size), Color(0, 0, 0, 0.35))
		draw_rect(rect, col.darkened(0.55))
		draw_rect(rect.grow(-3), col.darkened(0.25))
		draw_rect(Rect2(rect.position + Vector2(3, 3), Vector2(rect.size.x - 6, 4)), col.lightened(0.15))
		draw_icon(b.type, c, col)
		if b.pulse > 0.0:
			draw_rect(rect.grow(2), Color(1, 1, 1, b.pulse * 0.5), false, 2.0)
		if b.locked:
			draw_lock(rect.end - Vector2(8, 8))


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
			var mid: Vector2 = (a.draw + b.draw) * 0.5
			var col: Color = Data.TOWERS[a.type].color.lerp(Data.TOWERS[b.type].color, 0.5).lightened(0.3)
			var s := 6.0 + sin(t * 5.0) * 1.0
			draw_colored_polygon(PackedVector2Array([mid + Vector2(0, -s), mid + Vector2(s, 0),
				mid + Vector2(0, s), mid + Vector2(-s, 0)]), col)
			draw_circle(mid, 2.0, Color.WHITE)


func draw_player() -> void:
	var c := player_draw
	var f := Vector2(player_facing)
	var side := Vector2(-f.y, f.x)
	draw_circle(c + Vector2(0, 5), 13.0, Color(0, 0, 0, 0.35))
	draw_circle(c, 13.0, Color("3fbf7f"))
	draw_circle(c, 13.0, Color("2a8c5b"), false, 2.0)
	for sgn in [-1.0, 1.0]:
		var eye: Vector2 = c + f * 5.0 + side * 5.0 * sgn
		draw_circle(eye, 3.5, Color.WHITE)
		draw_circle(eye + f * 1.5, 1.8, Color("1a1a1a"))


func draw_enemies() -> void:
	for e in enemies:
		var col: Color = Color.WHITE if e.flash > 0.0 else e.color
		var r: float = e.size * TILE
		var p: Vector2 = e.pos
		draw_circle(p + Vector2(0, 4), r, Color(0, 0, 0, 0.3))
		match e.type:
			"grunt", "splitling":
				draw_circle(p, r, col)
			"runner":
				var h: Vector2 = e.heading
				var sd := Vector2(-h.y, h.x)
				draw_colored_polygon(PackedVector2Array([p + h * r * 1.3, p - h * r + sd * r, p - h * r - sd * r]), col)
			"brute":
				draw_rect(Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0), col)
				draw_rect(Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0), col.darkened(0.4), false, 3.0)
			"splitter":
				draw_colored_polygon(PackedVector2Array([p + Vector2(0, -r * 1.2), p + Vector2(r, 0),
					p + Vector2(0, r * 1.2), p + Vector2(-r, 0)]), col)
				draw_line(p + Vector2(0, -r), p + Vector2(0, r), col.darkened(0.4), 2.0)
		if e.boss:
			draw_arc(p, r + 5.0, 0, TAU, 24, Color("f2c94c"), 2.5)
		if e.slow_t > 0.0:
			draw_arc(p, r + 2.0, 0, TAU, 20, Color(0.55, 0.9, 1.0, 0.9), 2.0)
		if e.hp < e.max_hp:
			var w := maxf(r * 2.0, 18.0)
			var bar := Rect2(p + Vector2(-w / 2, -r - 9), Vector2(w, 4))
			draw_rect(bar, Color(0, 0, 0, 0.7))
			draw_rect(Rect2(bar.position, Vector2(w * maxf(e.hp / e.max_hp, 0.0), 4)), Color("6be675"))


func draw_projectiles() -> void:
	for p in projectiles:
		if p.kind == "bolt":
			var dir: Vector2 = (p.dest - p.pos).normalized()
			draw_line(p.pos - dir * 8.0, p.pos, Color("fff1a8"), 3.0)
		else:
			draw_circle(p.pos, 5.0, Color("3a2a1a"))
			draw_circle(p.pos, 3.0, Color("eb8a3c"))


func draw_effects() -> void:
	for fx in effects:
		var k: float = fx.t / fx.dur
		match fx.kind:
			"ring":
				var col: Color = fx.color
				draw_arc(fx.pos, fx.r * (0.3 + 0.7 * k), 0, TAU, 40, Color(col, 0.8 * (1.0 - k)), 3.0)
			"boom":
				draw_circle(fx.pos, fx.r * (0.5 + 0.5 * k), Color(1, 0.6, 0.2, 0.55 * (1.0 - k)))
			"zap":
				var pts := PackedVector2Array()
				for i in fx.pts.size():
					var q: Vector2 = fx.pts[i]
					if i > 0:
						var prev: Vector2 = fx.pts[i - 1]
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
	var lv: Dictionary = Data.LEVELS[level_idx]
	text("LEVEL %d  ·  %s" % [level_idx + 1, lv.name.to_upper()], Vector2(18, 36), 20, Color("e8e8f0"))
	var hint := ""
	match phase:
		Phase.BUILD:
			hint = "BUILD - push blocks, SPACE to send the wave"
		Phase.WAVE:
			hint = "WAVE IN PROGRESS - blocks are frozen   (F: speed x%d)" % int(speed)
	if message_t > 0.0:
		text(message, Vector2(300, 36), 16, Color(1, 0.85, 0.4, clampf(message_t, 0.0, 1.0)), 484, HORIZONTAL_ALIGNMENT_RIGHT)
	else:
		text(hint, Vector2(300, 36), 15, Color("9aa0bc"), 484, HORIZONTAL_ALIGNMENT_RIGHT)


func draw_panel() -> void:
	var x := PANEL_X
	draw_rect(Rect2(x - 4, 0, SCREEN.x - x + 4, SCREEN.y), Color("181a28"))
	draw_line(Vector2(x - 4, 0), Vector2(x - 4, SCREEN.y), Color("2b2f45"), 2.0)
	text("SOKOBAN TD", Vector2(x + 12, 36), 24, Color("f2c94c"))
	var y := 70.0
	var lv: Dictionary = Data.LEVELS[level_idx]
	text("Lives", Vector2(x + 12, y), 15, Color("9aa0bc"))
	text(str(lives), Vector2(x + 70, y), 18, Color("e05555") if lives <= 5 else Color.WHITE)
	text("Wave", Vector2(x + 130, y), 15, Color("9aa0bc"))
	text("%d / %d" % [mini(wave_idx + 1, lv.waves), lv.waves], Vector2(x + 180, y), 18)
	y += 22
	text("Kills %d   Path %d tiles" % [kills, dist.get(spawns[0], 0) if not spawns.is_empty() else 0],
		Vector2(x + 12, y), 14, Color("9aa0bc"))

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

	# upgrades summary
	var ups := []
	for ty in ATTACK_TYPES:
		if dmg_mult[ty] > 1.0:
			ups.append("%s +%d%%" % [ty.capitalize(), roundi((dmg_mult[ty] - 1.0) * 100)])
	if rate_mult > 1.0:
		ups.append("Rate +%d%%" % roundi((rate_mult - 1.0) * 100))
	if range_bonus > 0.0:
		ups.append("Range +%.1f" % range_bonus)
	if not ups.is_empty():
		draw_multiline_string(font, Vector2(x + 12, 470), "Upgrades: " + ", ".join(ups),
			HORIZONTAL_ALIGNMENT_LEFT, 230, 12, 3, Color("8fd18f"))

	var controls := "Move/push: WASD or arrows\nZ undo  ·  SPACE start wave\nF speed  ·  Shift show ranges\nHover a block for stats"
	draw_multiline_string(font, Vector2(x + 12, 520), controls, HORIZONTAL_ALIGNMENT_LEFT, 236, 12, -1, Color("6c7290"))


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
		if b.type != "stone":
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
		if ch == "*":
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
		draw_multiline_string(font, Vector2(x, y), Data.LEVELS[level_idx].tip, HORIZONTAL_ALIGNMENT_LEFT,
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
	var cx := SCREEN.x / 2
	text("SOKOBAN TD", Vector2(0, 150), 56, Color("f2c94c"), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	text("push  ·  block  ·  defend", Vector2(0, 186), 18, Color("9aa0bc"), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	var lines := "Your towers are crates. Push them like Sokoban to reshape the enemy path.\n" + \
		"Blocks can't move while enemies are on the field - plan during the build phase.\n" + \
		"Corners are forever: a block pushed into one can never come back out.\n" + \
		"Matching neighbours create combos. Each cleared wave grants a reward.\n" + \
		"Survive 3 levels to win the run."
	draw_multiline_string(font, Vector2(cx - 330, 240), lines, HORIZONTAL_ALIGNMENT_CENTER, 660, 16, -1, Color("d0d4e8"))
	var a := 0.6 + 0.4 * sin(t * 4.0)
	text("Press ENTER to begin", Vector2(0, 420), 22, Color(1, 1, 1, a), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)


func card_rect(i: int) -> Rect2:
	return Rect2(SCREEN.x / 2 - 405 + i * 280, 190, 250, 240)


func reward_info(r: Dictionary) -> Array:
	match r.kind:
		"block":
			var def: Dictionary = Data.TOWERS[r.type]
			var title: String = def.name + (" x2" if r.type == "stone" else "")
			return ["NEW BLOCK", title, def.desc, def.color]
		"dmg":
			var def: Dictionary = Data.TOWERS[r.type]
			return ["UPGRADE", def.name + " +", "All %ss deal +30%% damage." % def.name, def.color]
		"rate":
			return ["UPGRADE", "Overclock", "All towers fire 15% faster.", Color("8fd18f")]
		"range":
			return ["UPGRADE", "Scopes", "All towers gain +0.4 range.", Color("8fd18f")]
		"heal":
			return ["REPAIR", "Patch the Core", "Restore 5 lives.", Color("e05555")]
	return ["", "", "", Color.WHITE]


func draw_rewards() -> void:
	dim()
	var head := "LEVEL CLEARED!" if level_done else "WAVE CLEARED!"
	text(head, Vector2(0, 120), 36, Color("f2c94c"), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	var sub := "Choose a reward - your blocks travel with you to the next level." if level_done else "Choose a reward"
	text(sub, Vector2(0, 155), 16, Color("9aa0bc"), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
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
		if rew.kind == "block" or rew.kind == "dmg":
			var half := TILE * 0.42
			var rect := Rect2(icon_c - Vector2(half, half), Vector2(half, half) * 2.0)
			draw_rect(rect, col.darkened(0.55))
			draw_rect(rect.grow(-3), col.darkened(0.25))
			draw_icon(rew.type, icon_c, col)
			if rew.kind == "dmg":
				text("+", icon_c + Vector2(18, -10), 26, Color("8fd18f"))
		else:
			draw_circle(icon_c, 20.0, col.darkened(0.3))
			text("+", icon_c + Vector2(-8, 10), 30, Color.WHITE)
		text(info[1], r.position + Vector2(0, 142), 20, col, r.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		draw_multiline_string(font, r.position + Vector2(18, 170), info[2], HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x - 36, 14, 3, Color("d0d4e8"))
		text("[%d]" % (i + 1), r.position + Vector2(0, r.size.y - 14), 14, Color("6c7290"), r.size.x, HORIZONTAL_ALIGNMENT_CENTER)


func draw_end_screen(title: String, col: Color) -> void:
	dim()
	text(title, Vector2(0, 220), 48, col, SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	var lv: Dictionary = Data.LEVELS[level_idx]
	var sub := "Reached level %d (%s), wave %d  ·  %d enemies destroyed  ·  %d blocks" % [
		level_idx + 1, lv.name, mini(wave_idx + 1, lv.waves), kills, blocks.size()]
	if phase == Phase.VICTORY:
		sub = "All 3 levels survived with %d lives left  ·  %d enemies destroyed  ·  %d blocks" % [lives, kills, blocks.size()]
	text(sub, Vector2(0, 270), 16, Color("d0d4e8"), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
	text("Press R to start a new run", Vector2(0, 340), 20, Color(1, 1, 1, 0.6 + 0.4 * sin(t * 4.0)), SCREEN.x, HORIZONTAL_ALIGNMENT_CENTER)
