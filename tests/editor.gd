extends SceneTree
## Level editor checks: validation, undo, save/load round trip, and playing a custom level.
## godot --headless --path . -s tests/editor.gd

const Data = preload("res://scripts/data.gd")

var ed
var failures := 0


func _initialize() -> void:
	Data.editor_level = {}
	ed = load("res://editor.tscn").instantiate()
	root.add_child(ed)


func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		failures += 1


func _process(_delta: float) -> bool:
	check(ed.errors.is_empty(), "new level is playable")
	for lv in Data.LEVELS:
		check(ed.check_shape(lv) == "", "built-in '%s' passes shape check" % lv.name)

	# sealing the gate makes it invalid, undo fixes it
	ed.push_undo()
	for y in range(1, 10):
		ed.paint(Vector2i(8, y), "#")
	check(ed.errors.size() >= 1 and "can't reach" in ed.errors[0], "sealed map reports unreachable gate")
	ed.undo()
	check(ed.errors.is_empty(), "undo restores a playable map")

	# only one core: placing another moves it
	ed.paint(Vector2i(14, 2), "G")
	var cores := 0
	for row in ed.map:
		cores += row.count("G")
	check(cores == 1 and ed.at(Vector2i(14, 2)) == "G", "core is unique")

	# save / load round trip
	ed.level_name = "Test Level 42"
	ed.waves = 2
	ed.difficulty = 3
	var path: String = ed.save_level()
	var back = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(ed.check_shape(back) == "" and back.map == ed.to_level().map and int(back.waves) == 2,
		"saved JSON round-trips")
	var idx := -1
	for i in ed.load_sources.size():
		if ed.load_sources[i].get("path", "") == path:
			idx = i
	check(idx >= 0, "saved level shows in load menu")
	ed.new_level()
	ed.load_menu.select(idx)
	ed.load_selected()
	check(ed.level_name == "Test Level 42" and ed.difficulty == 3, "load restores level settings")
	check(ed.check_shape({"map": ["###"]}) != "", "malformed level rejected")
	DirAccess.remove_absolute(path)

	# play the custom level to the end
	Data.custom_level = ed.to_level()
	var main = load("res://main.tscn").instantiate()
	root.add_child(main)
	check(main.custom and main.levels.size() == 1 and main.phase == main.Phase.BUILD, "game starts in playtest mode")
	for ty in main.dmg_mult:
		main.dmg_mult[ty] = 8.0
	var guard := 0
	while main.phase not in [main.Phase.GAMEOVER, main.Phase.VICTORY] and guard < 50:
		guard += 1
		if main.phase == main.Phase.BUILD:
			main.start_wave()
		elif main.phase == main.Phase.REWARD:
			main.choose_reward(0)
		for i in 60 * 300:
			if main.phase != main.Phase.WAVE:
				break
			main.update_game(1.0 / 60.0, 1.0 / 60.0)
	check(main.phase == main.Phase.VICTORY, "custom level can be finished")
	check(main.next_wave.size() > 0, "waves generated")
	Data.custom_level = {}

	print("FAILURES: %d" % failures)
	return true
