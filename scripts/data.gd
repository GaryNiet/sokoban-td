extends RefCounted
## Static game data: towers, enemies, combos and level layouts.

const TOWERS := {
	"bolt": {
		"name": "Bolt Tower", "color": Color("f2c94c"),
		"dmg": 10.0, "rate": 2.0, "range": 2.8,
		"desc": "Fast single-target shots.",
	},
	"cannon": {
		"name": "Cannon", "color": Color("eb8a3c"),
		"dmg": 22.0, "rate": 0.6, "range": 2.6, "splash": 0.9,
		"desc": "Slow shells that explode on impact.",
	},
	"frost": {
		"name": "Frost Spire", "color": Color("6fd3f2"),
		"dmg": 4.0, "rate": 1.0, "range": 2.0, "slow": 0.4,
		"desc": "Pulses to chill and slow everything nearby.",
	},
	"tesla": {
		"name": "Tesla Coil", "color": Color("b27cf2"),
		"dmg": 14.0, "rate": 0.8, "range": 2.4, "chain": 3,
		"desc": "Lightning that jumps between 3 enemies.",
	},
	"stone": {
		"name": "Stone Block", "color": Color("8d8f9a"),
		"dmg": 0.0, "rate": 0.0, "range": 0.0,
		"desc": "Pure blocker. Towers touching it get +0.5 range.",
	},
}

const ENEMIES := {
	"grunt": {"name": "Grunt", "hp": 30.0, "speed": 1.6, "armor": 0.0, "size": 0.26, "color": Color("e05555"), "gap": 1.1},
	"runner": {"name": "Runner", "hp": 16.0, "speed": 3.0, "armor": 0.0, "size": 0.22, "color": Color("7fe07a"), "gap": 0.55},
	"brute": {"name": "Brute", "hp": 110.0, "speed": 0.9, "armor": 4.0, "size": 0.32, "color": Color("b8463f"), "gap": 1.6},
	"splitter": {"name": "Splitter", "hp": 45.0, "speed": 1.4, "armor": 0.0, "size": 0.28, "color": Color("e07ad0"), "gap": 1.2},
	"splitling": {"name": "Splitling", "hp": 12.0, "speed": 2.4, "armor": 0.0, "size": 0.16, "color": Color("f0a8e4"), "gap": 0.4},
}

# Keyed by the two tower types sorted alphabetically. Stone pairs are handled in code.
const COMBOS := {
	"bolt+bolt": {"name": "Volley", "desc": "+35% fire rate"},
	"cannon+cannon": {"name": "Barrage", "desc": "+50% splash radius"},
	"frost+frost": {"name": "Deep Freeze", "desc": "slow becomes 60%"},
	"tesla+tesla": {"name": "Overload", "desc": "+2 chain targets"},
	"bolt+cannon": {"name": "Crossfire", "desc": "both +25% damage"},
	"bolt+frost": {"name": "Ice Shards", "desc": "Bolt +0.6 range, Frost x2 damage"},
	"bolt+tesla": {"name": "Charged Bolts", "desc": "Bolt +50% damage, Tesla +1 chain"},
	"cannon+frost": {"name": "Shatter", "desc": "Cannon x2 dmg vs slowed, Frost +10% slow"},
	"cannon+tesla": {"name": "Magnetized", "desc": "Cannon +30% splash, Tesla +25% dmg"},
	"frost+tesla": {"name": "Superconduct", "desc": "Tesla +40% damage, Frost +0.5 range"},
}

# Map legend:
#   #  wall          .  floor         S  enemy spawn    G  core (enemy goal)
#   P  player start  D  dock (where your blocks are placed)
#   *  power tile: +50% damage / +0.5 range, usually somewhere you can never push back out of
const LEVELS := [
	{
		"name": "The Crossing",
		"waves": 4,
		"tip": "A single gap splits the field. Corners hold blocks forever - choose them wisely.",
		"map": [
			"################",
			"#......#.......#",
			"#..D...#...D...#",
			"S......#.......#",
			"#..D...#..*....#",
			"#..P...........G",
			"#......#...D...#",
			"#..D...#.......#",
			"#......#..D....#",
			"#*.....#......*#",
			"################",
		],
	},
	{
		"name": "Switchback",
		"waves": 5,
		"tip": "The road doubles back on itself. One tower can cover both lanes.",
		"map": [
			"################",
			"S.....#........#",
			"#.....#..D.....#",
			"#..D..#....##..#",
			"#.....#.*..#...#",
			"#..P..#..D.#.D.#",
			"#.D........#...#",
			"#.....#....#...#",
			"#.*...#..D.#*..#",
			"#.....#....#...G",
			"################",
		],
	},
	{
		"name": "Twin Gates",
		"waves": 6,
		"tip": "Two gates, one core. Enemies alternate between the spawns.",
		"map": [
			"#######S########",
			"#..............#",
			"#.D..#....#..D.#",
			"#....#.*..#....#",
			"#.*..#....#....#",
			"S..D.#.P..#.D..#",
			"#....#....#..*.#",
			"#....#.D..#....#",
			"#....###..###..#",
			"#..............#",
			"#######G########",
		],
	},
]
