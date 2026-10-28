extends SceneTree
## Renders a few game states to PNGs. Needs a display:
## xvfb-run godot --path . -s tests/shots.gd -- <out_dir>

var main
var out := "user://"
var step := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		out = args[0]
	main = load("res://main.tscn").instantiate()
	root.add_child(main)


func snap(name: String) -> void:
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))


func _process(_delta: float) -> bool:
	step += 1
	match step:
		5:
			snap("1_title")
			main.reset_run()
			main.banner_t = 0.0
		10:
			snap("2_level1_build")
			main.start_wave()
			for i in 60 * 6:
				main.update_game(1.0 / 60.0, 1.0 / 60.0)
		15:
			snap("3_level1_wave")
			main.carried = ["bolt", "cannon", "frost"]
			main.load_level(1)
			main.banner_t = 0.0
			main.drop_reward_block("tesla")
			main.phase = main.Phase.REWARD
			main.rewards = [{"kind": "block", "type": "bolt"}, {"kind": "block", "type": "frost"}, {"kind": "rate"}]
		20:
			snap("4_level2_reward")
			main.rewards_hidden = true
		25:
			snap("5_level2_reward_hidden")
			main.carried = ["bolt", "cannon", "frost", "tesla"]
			main.load_level(2)
			main.banner_t = 0.0
		30:
			snap("6_level3")
			return true
	return false
