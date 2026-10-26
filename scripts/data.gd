extends RefCounted
## Static game data: towers, combos, enemies, upgrades and levels.

const TOWERS := {
	"arrow": {
		"name": "Arrow Tower",
		"color": Color(0.37, 0.82, 0.41),
		"damage": 6.0, "rate": 1.6, "range": 3.0,
		"desc": "Fast single-target shots. Cheap and reliable.",
	},
	"cannon": {
		"name": "Cannon",
		"color": Color(0.95, 0.62, 0.27),
		"damage": 16.0, "rate": 0.55, "range": 2.6, "splash": 1.1,
		"desc": "Slow shells that explode, hitting everything nearby.",
	},
	"frost": {
		"name": "Frost Spire",
		"color": Color(0.44, 0.83, 0.95),
		"damage": 2.0, "rate": 1.0, "range": 2.0, "slow": 0.45, "slow_time": 1.6,
		"desc": "Pulses cold, slowing every enemy in range.",
	},
	"tesla": {
		"name": "Tesla Coil",
		"color": Color(0.69, 0.49, 0.97),
		"damage": 9.0, "rate": 0.8, "range": 2.6, "chains": 3,
		"desc": "Lightning that jumps between enemies and ignores armor.",
	},
}

## Combos trigger when two blocks sit orthogonally side by side.
const COMBOS := [
	{"a": "arrow", "b": "arrow", "name": "Volley",
		"desc": "Arrow + Arrow: both fire 35% faster."},
	{"a": "cannon", "b": "frost", "name": "Shatter",
		"desc": "Cannon + Frost: shells chill and deal +40% to chilled foes. Frost +0.5 range."},
	{"a": "tesla", "b": "frost", "name": "Superconductor",
		"desc": "Tesla + Frost: Tesla chains +2 targets. Frost slow lasts longer."},
	{"a": "tesla", "b": "tesla", "name": "Arc Link",
		"desc": "Tesla + Tesla: both deal +40% damage."},
	{"a": "arrow", "b": "cannon", "name": "Spotter",
		"desc": "Arrow + Cannon: Cannon +1 range, Arrow +2 damage."},
]

const ENEMIES := {
	"grunt": {"name": "Grunt", "hp": 30.0, "speed": 1.6, "armor": 0.0, "leak": 1,
		"radius": 0.27, "slow_resist": 0.0, "color": Color(0.90, 0.33, 0.33)},
	"runner": {"name": "Runner", "hp": 16.0, "speed": 3.0, "armor": 0.0, "leak": 1,
		"radius": 0.22, "slow_resist": 0.0, "color": Color(0.98, 0.85, 0.30)},
	"brute": {"name": "Brute", "hp": 120.0, "speed": 0.85, "armor": 3.0, "leak": 3,
		"radius": 0.36, "slow_resist": 0.4, "color": Color(0.62, 0.30, 0.52)},
	"swarm": {"name": "Swarmling", "hp": 9.0, "speed": 2.2, "armor": 0.0, "leak": 1,
		"radius": 0.14, "slow_resist": 0.0, "color": Color(0.97, 0.52, 0.75)},
}

const UPGRADES := [
	{"id": "arrow_dmg", "name": "Barbed Arrows", "desc": "Arrow Towers deal +35% damage."},
	{"id": "cannon_power", "name": "Black Powder", "desc": "Cannons deal +25% damage with +0.4 splash radius."},
	{"id": "frost_power", "name": "Deep Freeze", "desc": "Frost Spires slow 15% more and deal +3 damage."},
	{"id": "tesla_chain", "name": "Overcharge", "desc": "Tesla Coils chain to +1 target and deal +20% damage."},
	{"id": "range", "name": "Spyglass", "desc": "All towers gain +0.5 range."},
	{"id": "rate", "name": "Clockwork", "desc": "All towers attack 15% faster."},
	{"id": "lives", "name": "Reinforce Core", "desc": "Restore 6 core HP."},
]

## Map legend: # wall, . floor, * premium floor, S enemy spawn, G core, P player start.
## Waves are lists of groups: [enemy type, count, seconds between spawns].
const LEVELS := [
	{
		"name": "The Yard",
		"map": [
			"####################",
			"#...#*........#....#",
			"#...#.........#....#",
			"#...#.........#....#",
			"#.......###........#",
			"S.......#*.........#",
			"#...P...#..........G",
			"#.......#*.........#",
			"#.......###........#",
			"#...#.........#....#",
			"#...#.........#....#",
			"#...#.........#....#",
			"#...#........*#....#",
			"####################",
		],
		"waves": [
			[["grunt", 6, 1.2]],
			[["grunt", 6, 1.0], ["runner", 4, 0.7]],
			[["swarm", 12, 0.35], ["grunt", 6, 0.9]],
			[["brute", 2, 2.5], ["grunt", 8, 0.8], ["runner", 6, 0.5]],
		],
	},
	{
		"name": "Switchback",
		"map": [
			"####################",
			"S.....#*.....*#....#",
			"#.....#.......#....#",
			"#.....#.......#....#",
			"#.....#...#...#....#",
			"#.....#...#...#....#",
			"#.........#........#",
			"#.........#........#",
			"#.....#...#...#....#",
			"#.....#...#...#....#",
			"#..P..#.......#....#",
			"#.....#.......#....#",
			"#.....#*.....*#...G#",
			"####################",
		],
		"waves": [
			[["grunt", 10, 0.8], ["runner", 6, 0.6]],
			[["swarm", 20, 0.3], ["brute", 2, 2.0]],
			[["runner", 12, 0.45], ["grunt", 8, 0.7]],
			[["brute", 4, 1.8], ["swarm", 16, 0.3]],
			[["grunt", 12, 0.6], ["brute", 4, 1.5], ["runner", 10, 0.4]],
		],
	},
	{
		"name": "Twin Gates",
		"map": [
			"##########S#########",
			"#.....#*......#...*#",
			"#.....#.......#....#",
			"#.....#...#...#....#",
			"#.........#........#",
			"#.........#........#",
			"S....###.....###...#",
			"#.........P........#",
			"#.........#........#",
			"#.........#........#",
			"#.....#...#...#....#",
			"#.....#.......#....#",
			"#....*#......*#....#",
			"#########G##########",
		],
		"waves": [
			[["grunt", 14, 0.6], ["runner", 8, 0.5]],
			[["swarm", 30, 0.22], ["brute", 3, 1.5]],
			[["brute", 6, 1.4], ["runner", 12, 0.4]],
			[["grunt", 20, 0.45], ["swarm", 24, 0.25]],
			[["brute", 8, 1.2], ["runner", 16, 0.35]],
			[["swarm", 30, 0.2], ["brute", 10, 1.0], ["grunt", 20, 0.4]],
		],
	},
]
