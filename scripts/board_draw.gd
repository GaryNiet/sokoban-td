extends RefCounted
## Tile rendering shared by the game and the level editor.


## `hole_up` / `hole_left`: the neighbouring cell is also a hole, so no inner wall shows on that side.
static func draw_tile(ci: CanvasItem, r: Rect2, ch: String, checker: bool, t: float,
		hole_up := false, hole_left := false) -> void:
	if ch == "#":
		ci.draw_rect(r, Color("2b2f45"))
		ci.draw_rect(Rect2(r.position, Vector2(r.size.x, 5)), Color("3a3f5c"))
		return
	if ch == "O":
		# a pit: black floor, with the far inner walls visible along the top and left edges
		ci.draw_rect(r, Color("06070c"))
		if not hole_up:
			ci.draw_rect(Rect2(r.position, Vector2(r.size.x, r.size.y * 0.32)), Color("1a1d2c"))
		if not hole_left:
			ci.draw_rect(Rect2(r.position, Vector2(r.size.x * 0.32, r.size.y)), Color("11131e"))
		return
	ci.draw_rect(r, Color("1c1f2e") if checker else Color("202436"))
	var cc := r.get_center()
	match ch:
		"*":
			ci.draw_rect(r.grow(-3), Color(1, 0.8, 0.3, 0.10 + 0.06 * sin(t * 3.0)))
			ci.draw_rect(r.grow(-3), Color("f2c94c"), false, 2.0)
			draw_star(ci, cc, 8.0, Color(0.95, 0.79, 0.3, 0.8))
		"S":
			for i in 3:
				var k := fmod(t * 0.8 + i / 3.0, 1.0)
				ci.draw_arc(cc, 4.0 + k * 18.0, 0, TAU, 24, Color(1, 0.35, 0.35, 1.0 - k), 2.0)
			ci.draw_circle(cc, 6.0, Color("e05555"))
		"G":
			var s := 15.0 + sin(t * 2.5) * 2.0
			ci.draw_colored_polygon(PackedVector2Array([cc + Vector2(0, -s), cc + Vector2(s * 0.75, 0),
				cc + Vector2(0, s), cc + Vector2(-s * 0.75, 0)]), Color("4fd1c5"))
			ci.draw_circle(cc, 4.0, Color.WHITE)


static func draw_star(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI / 2 + i * PI / 5
		pts.append(c + Vector2(cos(a), sin(a)) * (r if i % 2 == 0 else r * 0.45))
	ci.draw_colored_polygon(pts, col)


## Bracket in the corner of a cell that would lock a block forever.
static func draw_corner_mark(ci: CanvasItem, cell: Rect2, wall_left: bool, wall_up: bool) -> void:
	var r := cell.grow(-6)
	var col := Color(1, 1, 1, 0.13)
	var corner := Vector2(r.position.x if wall_left else r.end.x, r.position.y if wall_up else r.end.y)
	var sx := 1.0 if wall_left else -1.0
	var sy := 1.0 if wall_up else -1.0
	ci.draw_line(corner, corner + Vector2(10 * sx, 0), col, 2.0)
	ci.draw_line(corner, corner + Vector2(0, 10 * sy), col, 2.0)
