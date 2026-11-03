extends SceneTree
## Rule checks for pushing, locking, path sealing, undo, combos, tower spawns and rewards.
## godot --headless --path . -s tests/logic.gd

const Data = preload("res://scripts/data.gd")

var main
var failures := 0


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)


func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		failures += 1


func put(type: String, c: Vector2i) -> Dictionary:
	main.add_block(type, c)
	return main.blocks[-1]


func key(k: int, echo := false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	ev.pressed = true
	ev.echo = echo
	main._unhandled_input(ev)


func release(k: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = k
	main._unhandled_input(ev)


func frames(seconds: float) -> void:
	for i in int(seconds * 60):
		main.update_game(1.0 / 60.0, 1.0 / 60.0)



func _process(_delta: float) -> bool:
	# ---- level 1: The Corridor (S at 0,2 - T at 18,2 - A at 21,2)
	main.reset_run()
	var T := Vector2i(18, 2)
	check(main.W == 22 and main.H == 5, "level 1 is 22x5")
	check(main.tower_spawns == [T], "level 1 has one tower spawn")
	check(main.player == Vector2i(17, 2), "player starts beside the tower spawn")
	check(main.blocks.size() == 1 and main.blocks[0].cell != T, "starting block leaves the spawn free")
	check(main.next_spawn == T, "free spawn is the next drop point")

	# reward drop lands on the spawn and steps the player off it
	main.player = T
	main.drop_reward_block("cannon")
	check(main.blocks[-1].cell == T and main.player != T, "reward tower drops on the spawn")
	check(main.next_spawn == main.NONE, "covered spawn is not suggested")
	main.roll_rewards()
	check(main.rewards == [{"kind": "heal"}], "all spawns covered -> repair only")

	# push the tower off the spawn and it becomes available again
	main.player = Vector2i(17, 2)
	main.try_move(Vector2i.RIGHT)
	check(main.blocks[-1].cell == Vector2i(19, 2) and main.next_spawn == T, "clearing the spawn re-enables it")
	main.undo()
	check(main.blocks[-1].cell == T and main.player == Vector2i(17, 2), "undo restores")

	# corner lock at the top-left corner
	main.blocks.clear()
	var b := put("bolt", Vector2i(2, 1))
	main.player = Vector2i(3, 1)
	check(not b.locked, "block against a wall is not locked")
	main.try_move(Vector2i.LEFT)
	check(b.cell == Vector2i(1, 1) and b.locked, "block in corner is locked")

	# sealing the corridor must be refused
	main.blocks.clear()
	put("stone", Vector2i(10, 1))
	put("stone", Vector2i(10, 3))
	var g := put("stone", Vector2i(9, 2))
	main.player = Vector2i(8, 2)
	main.try_move(Vector2i.RIGHT)
	check(g.cell == Vector2i(9, 2), "cannot seal enemy path")

	# no pushing during a wave
	main.blocks.clear()
	var w := put("bolt", Vector2i(5, 2))
	main.player = Vector2i(4, 2)
	main.phase = main.Phase.WAVE
	main.try_move(Vector2i.RIGHT)
	check(w.cell == Vector2i(5, 2), "no pushing during wave")
	main.phase = main.Phase.BUILD

	# combos
	var tz := put("tesla", Vector2i(5, 1))
	check(w.stats.dmg == 15.0 and tz.stats.chain == 4, "bolt+tesla Charged Bolts combo")
	put("stone", Vector2i(5, 3))
	check(is_equal_approx(w.stats.range, 3.3), "stone Bulwark adds range")

	# upgrade blocks boost every tower touching them, whatever its kind
	var cn := put("cannon", Vector2i(7, 2))
	var amp := put("amp", Vector2i(6, 2))
	check(is_equal_approx(w.stats.dmg, 19.5) and is_equal_approx(cn.stats.dmg, 28.6), "Amplifier boosts a bolt and a cannon")
	check(amp.stats.notes == ["Boosting 2 towers"], "Amplifier shows how many towers it boosts")
	put("lens", Vector2i(4, 1))
	check(is_equal_approx(tz.stats.range, 3.15), "Lens adds range")
	main.blocks.pop_back()
	main.blocks.pop_back()
	main.blocks.pop_back()
	main.on_board_changed()

	# ---- level 2: two tower spawns take turns
	main.carried = ["bolt"]
	main.load_level(1)
	var t1 := Vector2i(6, 2)
	var t2 := Vector2i(17, 2)
	check(main.tower_spawns == [t1, t2], "level 2 has two tower spawns")
	main.drop_reward_block("frost")
	main.drop_reward_block("tesla")
	check(main.blocks[-2].cell == t1 and main.blocks[-1].cell == t2, "rewards alternate between spawns")
	check(main.next_spawn == main.NONE, "both covered -> nothing suggested")
	main.blocks[-2].cell = t1 + Vector2i.UP  # clear spawn 1, turn is back on spawn 1
	main.on_board_changed()
	check(main.next_spawn == t1, "turn returns to the first spawn")
	main.blocks[-2].cell = t1
	main.blocks[-1].cell = t2 + Vector2i.UP  # cover spawn 1, clear spawn 2
	main.on_board_changed()
	check(main.next_spawn == t2, "covered spawn is skipped for the next one")

	# both tower choices on a reward screen land on the same spot
	main.blocks[-1].cell = t2
	main.blocks[-2].cell = t1 + Vector2i.UP
	main.on_board_changed()
	var target: Vector2i = main.next_spawn
	main.rewards = [{"kind": "block", "type": "bolt"}, {"kind": "block", "type": "cannon"}, {"kind": "heal"}]
	main.choose_reward(1)
	check(main.blocks[-1].type == "cannon" and main.blocks[-1].cell == target, "chosen tower lands on the announced spawn")

	# hiding the reward screen
	main.roll_rewards()
	main.phase = main.Phase.REWARD
	key(KEY_H)
	check(main.rewards_hidden, "H hides the reward screen")
	var n: int = main.blocks.size()
	key(KEY_1)
	check(main.phase == main.Phase.REWARD and main.blocks.size() == n, "can't pick while hidden")
	key(KEY_H)
	check(not main.rewards_hidden, "H shows it again")
	key(KEY_1)
	check(main.phase == main.Phase.BUILD, "picking works once shown")

	# carried blocks never make a tower spawn unusable
	main.carried = ["bolt", "cannon", "frost", "tesla", "stone", "bolt"]
	main.load_level(1)
	check(main.blocks.size() == 6 and main.tower_spawns.all(main.spawn_usable), "carried blocks keep spawns usable")

	# ---- level 3 loads and has a valid path
	main.load_level(2)
	check(main.W == 22 and main.H == 10 and main.dist.has(main.spawns[0]), "level 3 loads with a path")
	check(main.tower_spawns == [Vector2i(14, 5)], "level 3 tower spawn")

	# ---- level select: each level is its own run, winning goes back to the menu
	check(Data.LEVELS.all(func(lv): return lv.waves >= 20), "levels are 20+ waves")
	main.to_menu()
	check(main.phase == main.Phase.TITLE, "game opens on the level select")
	key(KEY_DOWN)
	check(main.select_idx == 1 and main.level_idx == 1 and main.phase == main.Phase.TITLE, "arrows pick a level")
	key(KEY_ENTER)
	check(main.phase == main.Phase.BUILD and main.level_idx == 1 and main.blocks.size() == 1, "ENTER starts that level fresh")
	main.wave_idx = main.levels[1].waves - 1
	main.wave_cleared()
	check(main.phase == main.Phase.VICTORY and main.level_idx == 1, "last wave wins without moving to the next level")
	key(KEY_ENTER)
	check(main.phase == main.Phase.TITLE and main.select_idx == 1, "winning returns to the level select")
	key(KEY_3)
	check(main.phase == main.Phase.BUILD and main.level_idx == 2, "number keys start a level directly")
	key(KEY_ESCAPE)
	check(main.phase == main.Phase.TITLE, "Esc leaves a level")

	# ---- movement: taps queue up, holding never does
	main.reset_run()
	key(KEY_UP)
	for i in 5:
		key(KEY_UP, true)
	check(main.move_queue.size() == 1, "OS key repeat does not fill the buffer")
	release(KEY_UP)
	check(main.held_key == 0, "releasing stops the hold")
	for i in 8:
		key(KEY_DOWN)
		release(KEY_DOWN)
	check(main.move_queue.size() == main.MOVE_BUFFER, "taps queue up to the buffer size")
	frames(1.0)
	check(main.move_queue.is_empty(), "queued taps play out")
	key(KEY_LEFT)
	frames(0.6)
	check(main.move_queue.is_empty(), "holding keeps the buffer empty")
	release(KEY_LEFT)
	frames(0.1)
	var stop: Vector2i = main.player
	frames(0.5)
	check(main.player == stop, "player stops once the key is let go")

	# ---- holes (The Pits: a 2-wide chasm in columns 8-9, open only along row 7)
	main.load_level(3)
	check(main.tile_at(Vector2i(8, 1)) == "O" and not main.dist.has(Vector2i(8, 2)), "enemies route around holes")
	main.blocks.clear()
	put("bolt", Vector2i(6, 1))
	main.player = Vector2i(7, 2)
	main.try_move(Vector2i.RIGHT)
	check(main.player == Vector2i(7, 2), "the player can't walk into a hole")
	main.player = Vector2i(5, 1)
	main.try_move(Vector2i.RIGHT)
	main.try_move(Vector2i.RIGHT)
	check(main.tile_at(Vector2i(8, 1)) == "." and main.blocks.is_empty() and main.player == Vector2i(7, 1),
		"a pushed block falls in and fills the hole")
	check(main.filled.get(Vector2i(8, 1)) == "bolt" and main.dist.has(Vector2i(8, 1)), "the filled hole is floor now")
	main.try_move(Vector2i.RIGHT)
	check(main.player == Vector2i(8, 1), "the player can walk over a filled hole")
	main.undo()
	check(main.tile_at(Vector2i(8, 1)) == "O" and main.blocks.size() == 1 and main.blocks[0].cell == Vector2i(7, 1),
		"undo brings the hole and the block back")

	print("FAILURES: %d" % failures)
	return true
