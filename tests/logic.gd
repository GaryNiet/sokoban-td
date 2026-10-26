extends SceneTree
## Rule checks for pushing, locking, path sealing, undo and combos.
## godot --headless --path . -s tests/logic.gd

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
	var b := {"type": type, "cell": c, "draw": main.cell_center(c), "cd": 0.0, "stats": {},
		"locked": false, "pulse": 0.0, "pop": 0.0}
	main.blocks.append(b)
	main.on_board_changed()
	return b


func _process(_delta: float) -> bool:
	main.reset_run()
	main.blocks.clear()
	# Level 1: push a block right
	main.player = Vector2i(2, 5)
	var b := put("bolt", Vector2i(3, 5))
	main.try_move(Vector2i.RIGHT)
	check(b.cell == Vector2i(4, 5) and main.player == Vector2i(3, 5), "push moves block and player")
	main.undo()
	check(b.cell == Vector2i(3, 5) and main.player == Vector2i(2, 5), "undo restores")

	# push into bottom-left corner (1,9) -> locked, on power tile
	b.cell = Vector2i(1, 8)
	main.player = Vector2i(1, 7)
	main.on_board_changed()
	check(not b.locked, "block against wall is not locked")
	main.try_move(Vector2i.DOWN)
	check(b.cell == Vector2i(1, 9) and b.locked, "block in corner is locked")
	check(b.stats.dmg > 10.0, "power tile boosts damage")

	# sealing the single gap at (7,5) must be refused
	main.blocks.clear()
	var g := put("stone", Vector2i(6, 5))
	main.player = Vector2i(5, 5)
	main.on_board_changed()
	main.try_move(Vector2i.RIGHT)
	check(g.cell == Vector2i(6, 5), "cannot seal enemy path")

	# no pushing during a wave
	main.blocks.clear()
	var w := put("bolt", Vector2i(3, 5))
	main.player = Vector2i(2, 5)
	main.on_board_changed()
	main.phase = main.Phase.WAVE
	main.try_move(Vector2i.RIGHT)
	check(w.cell == Vector2i(3, 5) and main.player == Vector2i(2, 5), "no pushing during wave")
	main.phase = main.Phase.BUILD

	# combos
	var t := put("tesla", Vector2i(3, 4))
	check(w.stats.dmg == 15.0 and t.stats.chain == 4, "bolt+tesla Charged Bolts combo")
	put("stone", Vector2i(3, 6))
	check(is_equal_approx(w.stats.range, 3.3), "stone Bulwark adds range")

	print("FAILURES: %d" % failures)
	return true
