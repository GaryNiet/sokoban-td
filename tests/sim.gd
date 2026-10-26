extends SceneTree
## Headless smoke test: plays a whole run with no pushing, always taking the first reward.
## godot --headless --path . -s tests/sim.gd [-- --strong]

var main
var frames := 0


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)


func _process(_delta: float) -> bool:
	main.reset_run()
	if "--strong" in OS.get_cmdline_user_args():
		for ty in main.dmg_mult:
			main.dmg_mult[ty] = 6.0
	var Phase = main.Phase
	var guard := 0
	while main.phase != Phase.GAMEOVER and main.phase != Phase.VICTORY and guard < 200:
		guard += 1
		if main.phase == Phase.BUILD:
			main.start_wave()
		elif main.phase == Phase.REWARD:
			main.choose_reward(0)
		var steps := 0
		while main.phase == Phase.WAVE and steps < 60 * 600:
			main.update_game(1.0 / 60.0, 1.0 / 60.0)
			steps += 1
		print("level %d wave %d lives %d blocks %d kills %d phase %d" % [main.level_idx + 1, main.wave_idx,
			main.lives, main.blocks.size(), main.kills, main.phase])
	print("RESULT phase=%d" % main.phase)
	return true
