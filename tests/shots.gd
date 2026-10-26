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
			for ty in ["bolt", "frost", "cannon", "tesla", "bolt", "stone"]:
				main.place_new_block(ty)
			main.player = Vector2i(4, 5)
			main.on_board_changed()
		30:
			main.banner_t = 0.0
			snap("2_build")
			main.start_wave()
			main.banner_t = 0.0
			for i in 60 * 5:
				main.update_game(1.0 / 60.0, 1.0 / 60.0)
		40:
			snap("3_wave")
			main.phase = main.Phase.REWARD
			main.roll_rewards()
		50:
			snap("4_reward")
			main.carried = ["bolt", "cannon", "frost", "tesla"]
			main.load_level(2)
			main.banner_t = 0.0
		60:
			snap("5_level3")
			return true
	return false
