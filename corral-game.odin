package main

import "base:runtime"
import "core:fmt"
import math "core:math"
import linalg "core:math/linalg"
import time "core:time"
import rl "vendor:raylib"


SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720
TETHER_LERP_FACTOR :: 6
PLAYER_LERP_FACTOR :: 6
CAMERA_LERP_FACTOR :: 6
FRICTION :: 0.7
BG_COLOR :: rl.BLACK
FG_COLOR :: rl.WHITE
PLAYER_COLOR :: rl.WHITE
PLAYER_RADIUS :: 12
REST_ROPE_LENGTH :: 8
REST_LENGTH :: 1
EXT_REST_LENGTH :: 5
ROPE_MAX_DIST :: 70
ENEMY_RADIUS :: 10
ENEMY_SPEED :: 0.5
TETHER_RADIUS :: 10
MIN_ZOOM :: 0.5
MAX_ZOOM :: 2
ZOOM_SPEED :: 0.06

mat :: distinct matrix[2, 2]f32

RopePoint :: struct {
	pos:      rl.Vector2,
	prev_pos: rl.Vector2,
}

Attributes :: struct {
	ext_rope_length: int,
	speed:           f32,
    box_size:        int,
}

Enemy :: struct {
	pos:      rl.Vector2,
	prev_pos: rl.Vector2,
	color:    rl.Color,
}

CollisionBox :: struct {
    pos: rl.Vector2,
    size: int,
	color:                 rl.Color,
	last_point_spawn_time: f64,
}

Item :: distinct union {
    CollisionBox,
    // Add any other types you want to be placeable here
}

Score :: struct {
	red:   int,
	green: int,
	blue:  int,
}

Point :: struct {
	pos:   rl.Vector2,
	color: rl.Color,
}

Store :: struct {
	is_open:             bool,
	money:               int,
	attributes:          Attributes,
	extend_rope_cost:    int,
	increase_speed_cost: int,
	increase_size_cost:  int,
	red_point_value:     int,
	green_point_value:   int,
	blue_point_value:    int,
}

store: Store

POINT_VALUE :: 10 // Each point is worth 10 money
UPGRADE_COST :: 100 // Each upgrade costs 100 money

verlet_integrate :: proc(object: ^$T, dt: f32) where T == RopePoint || T == Enemy {
	temp := object.pos
	velocity := object.pos - object.prev_pos
	velocity = velocity * FRICTION
	object.pos = object.pos + velocity
	object.prev_pos = temp
}

constrain_rope :: proc(rope: [dynamic]RopePoint, rest_length: f32) {
	for i in 1 ..= len(rope) - 2 {
		vec2prev := rope[i].pos - rope[i - 1].pos
		vec2next := rope[i + 1].pos - rope[i].pos
		dist2prev := rl.Vector2Length(vec2prev)
		dist2next := rl.Vector2Length(vec2next)
		if dist2prev > rest_length {
			vec2prev = rl.Vector2Normalize(vec2prev) * rest_length
		}
		if dist2next > rest_length {
			vec2next = rl.Vector2Normalize(vec2next) * rest_length
		}
		rope[i].pos = (rope[i - 1].pos + vec2prev + rope[i + 1].pos - vec2next) / 2
	}
}

initialize_rope :: proc(rope: [dynamic]RopePoint, length: int, anchor: rl.Vector2) {
	for i in 0 ..= length - 1 {
		rope[i] = RopePoint{anchor, anchor}
	}
}

update_rope :: proc(rope: [dynamic]RopePoint, ball_pos: rl.Vector2, rest_length: f32) {
	for i in 0 ..= len(rope) - 1 {
		verlet_integrate(&rope[i], 1.0 / 60.0)
	}
	rope[0].pos = ball_pos
	constrain_rope(rope, rest_length)
}

handle_input :: proc(
	player_targ: ^rl.Vector2,
	leftClicking: ^bool,
	rightClicking: ^bool,
	enemies: ^[dynamic]Enemy,
	camera: ^rl.Camera2D,
	score: ^Score,
	attributes: ^Attributes,
    boxes: ^[dynamic]CollisionBox,
) {
	direction := rl.Vector2{0, 0}
	if rl.IsKeyDown(.W) {direction.y -= 1}
	if rl.IsKeyDown(.S) {direction.y += 1}
	if rl.IsKeyDown(.D) {direction.x += 1}
	if rl.IsKeyDown(.A) {direction.x -= 1}

	if rl.IsKeyDown(.SPACE) {
		mouse_pos := rl.GetMousePosition()
		world_mouse_pos := rl.GetScreenToWorld2D(mouse_pos, camera^)
		for i := 0; i < len(enemies); i += 1 {
			if rl.Vector2Distance(enemies[i].pos, world_mouse_pos) <= ENEMY_RADIUS {
				ordered_remove(enemies, i)
				break // Only remove one enemy per space press
			}
		}
	}

	camera.zoom += rl.GetMouseWheelMove() * ZOOM_SPEED
	camera.zoom = math.clamp(camera.zoom, MIN_ZOOM, MAX_ZOOM)

	leftClicking^ = rl.IsMouseButtonDown(rl.MouseButton.LEFT)
	rightClicking^ = rl.IsMouseButtonDown(rl.MouseButton.RIGHT)

	if direction.x != 0 || direction.y != 0 {
		length := rl.Vector2Length(direction)
		direction = direction * (f32(attributes.speed) / length)
	}

	player_targ.x += direction.x
	player_targ.y += direction.y

	if rl.IsKeyPressed(.E) {
		toggle_store()
	}

	if store.is_open {
		if rl.IsKeyPressed(.ENTER) {
			sell_points(score)
		}
		if rl.IsKeyPressed(.ONE) && store.money > store.extend_rope_cost {
			attributes.ext_rope_length += 1
			store.money -= store.extend_rope_cost
			store.extend_rope_cost += (store.extend_rope_cost / 1)
		}
		if rl.IsKeyPressed(.TWO) && store.money > store.increase_speed_cost {
			attributes.speed += 0.7
			store.money -= store.increase_speed_cost
			store.increase_speed_cost += (store.increase_speed_cost / 1)
		}
		if rl.IsKeyPressed(.THREE) && store.money > store.increase_size_cost {
			attributes.box_size += 20
            for &box in boxes {
                box.size = attributes.box_size
            }
			store.money -= store.increase_size_cost
			store.increase_size_cost += (store.increase_size_cost / 1)
		}
	}

}

update_ball_position :: proc(ball_pos, player_targ: ^rl.Vector2) {
	ball_pos.x += (player_targ.x - ball_pos.x) / PLAYER_LERP_FACTOR
	ball_pos.y += (player_targ.y - ball_pos.y) / PLAYER_LERP_FACTOR
}

update_tether :: proc(
	rope: ^[dynamic]RopePoint,
	ball_pos, tether_pos: ^rl.Vector2,
	leftClicking: ^bool,
	max_dist: int,
	camera: rl.Camera2D,
	attributes: Attributes,
) {
	mouse_pos := rl.GetMousePosition()
	world_mouse_position := rl.GetScreenToWorld2D(mouse_pos, camera)
	to_mouse := world_mouse_position - ball_pos^
	distance := rl.Vector2Length(to_mouse)

	// Calculate the desired tether position
	desired_tether_pos: rl.Vector2
	if distance > f32(max_dist) {
		desired_tether_pos = ball_pos^ + rl.Vector2Normalize(to_mouse) * f32(max_dist)
	} else {
		desired_tether_pos = world_mouse_position
	}

	// Apply lerping to the tether position
	tether_pos^ += (desired_tether_pos - tether_pos^) / TETHER_LERP_FACTOR

	// Update rope length based on clicking state
	if leftClicking^ && (len(rope^) < attributes.ext_rope_length) {
		runtime.append_elem(rope, RopePoint{tether_pos^, tether_pos^})
	} else if !leftClicking^ && len(rope^) > REST_ROPE_LENGTH {
		ordered_remove(rope, len(rope^) - 1)
	}
	// Update the last rope segment to match the tether position
	if len(rope^) > 0 {
		rope^[len(rope^) - 1].pos = tether_pos^
	}
}

random_outside_position :: proc(camera: rl.Camera2D) -> rl.Vector2 {
	// Calculate the camera's view boundaries
	camera_left := camera.target.x - camera.offset.x / camera.zoom
	camera_right := camera.target.x + (f32(SCREEN_WIDTH) - camera.offset.x) / camera.zoom
	camera_top := camera.target.y - camera.offset.y / camera.zoom
	camera_bottom := camera.target.y + (f32(SCREEN_HEIGHT) - camera.offset.y) / camera.zoom

	// Add a buffer to ensure enemies spawn well outside the view
	buffer := f32(100)

	// Generate a random position outside the camera's view
	x_pos, y_pos: f32
	if rl.GetRandomValue(0, 1) == 0 {
		// Spawn on left or right side
		x_pos =
			rl.GetRandomValue(0, 1) == 0 ? camera_left - ENEMY_RADIUS - buffer : camera_right + ENEMY_RADIUS + buffer
		y_pos = f32(
			rl.GetRandomValue(i32(camera_top - ENEMY_RADIUS), i32(camera_bottom + ENEMY_RADIUS)),
		)
	} else {
		// Spawn on top or bottom side
		x_pos = f32(
			rl.GetRandomValue(i32(camera_left - ENEMY_RADIUS), i32(camera_right + ENEMY_RADIUS)),
		)
		y_pos =
			rl.GetRandomValue(0, 1) == 0 ? camera_top - ENEMY_RADIUS - buffer : camera_bottom + ENEMY_RADIUS + buffer
	}

	return rl.Vector2{x_pos, y_pos}
}

spawn_enemy :: proc(enemies: ^[dynamic]Enemy, camera: rl.Camera2D) {
	spawn_pos := random_outside_position(camera)

	// Array of three colors to choose from
	colors := [3]rl.Color{rl.RED, rl.GREEN, rl.BLUE}

	// Randomly select one of the three colors
	random_color := colors[rl.GetRandomValue(0, 2)]

	append(enemies, Enemy{pos = spawn_pos, prev_pos = spawn_pos, color = random_color})
}

update_enemies :: proc(enemies: ^[dynamic]Enemy) {
	for &enemy in enemies {
		// Generate a random direction
		angle := f32(rl.GetRandomValue(0, 359)) * math.PI / 180.0
		direction := rl.Vector2{math.cos_f32(angle), math.sin_f32(angle)}

		// Move the enemy in the random direction
		enemy.pos += direction * ENEMY_SPEED

		// Apply verlet integration
		verlet_integrate(&enemy, 1.0 / 60.0)
	}
}

// Declare this at the top level of your file, outside any function
box_corner1: rl.Vector2

placeBox :: proc(
    boxes: ^[dynamic]CollisionBox,
	camera: ^rl.Camera2D,
) {
    mouse_pos := rl.GetMousePosition()
	world_mouse_position := rl.GetScreenToWorld2D(mouse_pos, camera^)

    if rl.IsMouseButtonPressed(.RIGHT) {
        append(boxes, CollisionBox{
            world_mouse_position - rl.Vector2{50,50},
            100,
            rl.WHITE,
            rl.GetTime()
        })
    }
}

placeItem :: proc(
    item: ^Item,
    boxes: ^[dynamic]CollisionBox,
    camera: ^rl.Camera2D,
) {
    if item != nil {
        switch type in item {
        case CollisionBox:
            placeBox(boxes, camera)
            // Add cases for any other placeable item types
        }
    }
}

solve_collisions :: proc(
	ball_pos: ^rl.Vector2,
	rope: [dynamic]RopePoint,
	enemies: ^[dynamic]Enemy,
	boxes: ^[dynamic]CollisionBox,
) {
	// Ball vs Enemies
	for i := 0; i < len(enemies); i += 1 {
		dir := ball_pos^ - enemies[i].pos
		distance := rl.Vector2Length(dir)
		min_dist := f32(PLAYER_RADIUS + ENEMY_RADIUS)
		if distance < min_dist {
			normal := rl.Vector2Normalize(dir)
			depth := min_dist - distance
			ball_pos^ = ball_pos^ + (normal * depth * 0.5)
			enemies[i].pos = enemies[i].pos - (normal * depth * 0.5)
		}
	}

	// Rope segments vs Enemies
	for i := 0; i < len(rope); i += 1 {
		for j := 0; j < len(enemies); j += 1 {
			dir := rope[i].pos - enemies[j].pos
			distance := rl.Vector2Length(dir)
			min_dist := f32(TETHER_RADIUS + ENEMY_RADIUS)

			if distance < min_dist {
				normal := rl.Vector2Normalize(dir)
				depth := min_dist - distance
				rope[i].pos = rope[i].pos + (normal * depth * 0.5)
				enemies[j].pos = enemies[j].pos - (normal * depth * 0.5)

			}
		}
	}

	// Enemies vs Enemies
	for i := 0; i < len(enemies) - 1; i += 1 {
		for j := i + 1; j < len(enemies); j += 1 {
			dir := enemies[i].pos - enemies[j].pos
			distance := rl.Vector2Length(dir)
			min_dist := f32(ENEMY_RADIUS * 2)

			if distance < min_dist {
				normal := rl.Vector2Normalize(dir)
				depth := min_dist - distance
				enemies[i].pos = enemies[i].pos + (normal * depth * 0.5)
				enemies[j].pos = enemies[j].pos - (normal * depth * 0.5)
			}
		}
	}

	// Enemies vs Box walls
	if enemies == nil || boxes == nil {
		return
	}

	BOX_INFLUENCE_DISTANCE :: 10.0 // Distance from box edge where collisions are checked

	// Enemies vs Boxes
	for &enemy in enemies {
		for box in boxes {
			// Calculate box boundaries
            left := min(box.pos.x, box.pos.x + f32(box.size))
            right := max(box.pos.x, box.pos.x + f32(box.size))
            top := min(box.pos.y, box.pos.y + f32(box.size))
            bottom := max(box.pos.y, box.pos.y + f32(box.size))

			// Check if enemy is within the influence distance of the box
			if enemy.pos.x >= left - BOX_INFLUENCE_DISTANCE &&
			   enemy.pos.x <= right + BOX_INFLUENCE_DISTANCE &&
			   enemy.pos.y >= top - BOX_INFLUENCE_DISTANCE &&
			   enemy.pos.y <= bottom + BOX_INFLUENCE_DISTANCE {

				// Check collision with left and right walls
				if enemy.pos.x - ENEMY_RADIUS < left {
					enemy.pos.x = left + ENEMY_RADIUS
					enemy.prev_pos.x = enemy.pos.x // Prevent sticking
				} else if enemy.pos.x + ENEMY_RADIUS > right {
					enemy.pos.x = right - ENEMY_RADIUS
					enemy.prev_pos.x = enemy.pos.x // Prevent sticking
				}

				// Check collision with top and bottom walls
				if enemy.pos.y - ENEMY_RADIUS < top {
					enemy.pos.y = top + ENEMY_RADIUS
					enemy.prev_pos.y = enemy.pos.y // Prevent sticking
				} else if enemy.pos.y + ENEMY_RADIUS > bottom {
					enemy.pos.y = bottom - ENEMY_RADIUS
					enemy.prev_pos.y = enemy.pos.y // Prevent sticking
				}
			}
		}
	}
}

update_box_colors :: proc(boxes: ^[dynamic]CollisionBox, enemies: [dynamic]Enemy) {
	for &box in boxes {
		enemies_in_box := make([dynamic]Enemy)
		defer delete(enemies_in_box)

		for enemy in enemies {
			if is_point_inside_box(enemy.pos, box) {
				append(&enemies_in_box, enemy)
			}
		}

		if len(enemies_in_box) > 0 {
			all_same_color := true
			first_color := enemies_in_box[0].color

			for i := 1; i < len(enemies_in_box); i += 1 {
				if enemies_in_box[i].color != first_color {
					all_same_color = false
					break
				}
			}

			if all_same_color {
				box.color = first_color
			} else {
				box.color = rl.WHITE
			}
		} else {
			box.color = rl.WHITE
		}
	}
}

spawn_points :: proc(
	boxes: ^[dynamic]CollisionBox,
	enemies: [dynamic]Enemy,
	points: ^[dynamic]Point,
) {
	POINT_SPAWN_INTERVAL :: 5 // Spawn interval in seconds
	POINT_RADIUS :: 5.0

	current_time := rl.GetTime()

	for &box in boxes {
		if box.color == rl.WHITE {
			continue // Skip white boxes
		}

		enemies_in_box := count_enemies_in_box(box, enemies)
		if enemies_in_box == 0 {
			continue // Skip boxes with no enemies
		}

		if current_time - box.last_point_spawn_time >= POINT_SPAWN_INTERVAL {
			for i in 0 ..< enemies_in_box {
				new_point := Point {
					pos   = random_position_in_box(box),
					color = box.color,
				}
				append(points, new_point)
			}
			box.last_point_spawn_time = current_time
		}
	}
}

collect_points :: proc(rope: [dynamic]RopePoint, points: ^[dynamic]Point, score: ^Score) {
	COLLECT_RADIUS :: TETHER_RADIUS + 5.0

	i := 0
	for i < len(points) {
		collected := false
		for rope_point in rope {
			if rl.Vector2Distance(rope_point.pos, points[i].pos) <= COLLECT_RADIUS {
				// Increase the corresponding score
				if points[i].color == rl.RED {
					score.red += 1
				} else if points[i].color == rl.GREEN {
					score.green += 1
				} else if points[i].color == rl.BLUE {
					score.blue += 1
				}

				// Remove the collected point
				ordered_remove(points, i)
				collected = true
				break
			}
		}
		if !collected {
			i += 1
		}
	}
}

toggle_store :: proc() {
	store.is_open = !store.is_open
}

sell_points :: proc(score: ^Score) {
	store.money += (score.red + score.green + score.blue) * POINT_VALUE
	score.red = 0
	score.green = 0
	score.blue = 0
}


count_enemies_in_box :: proc(box: CollisionBox, enemies: [dynamic]Enemy) -> int {
	count := 0
	for enemy in enemies {
		if is_point_inside_box(enemy.pos, box) {
			count += 1
		}
	}
	return count
}

random_position_in_box :: proc(box: CollisionBox) -> rl.Vector2 {
	min_x := min(box.pos.x, box.pos.x + f32(box.size))
	max_x := max(box.pos.x, box.pos.x + f32(box.size))
	min_y := min(box.pos.y, box.pos.y + f32(box.size))
	max_y := max(box.pos.y, box.pos.y + f32(box.size))

	return rl.Vector2 {
		f32(rl.GetRandomValue(i32(min_x), i32(max_x))),
		f32(rl.GetRandomValue(i32(min_y), i32(max_y))),
	}
}


// Helper function to remove an element from a dynamic array
ordered_remove :: proc(
	arr: ^$T,
	index: int,
) where T == [dynamic]RopePoint ||
	T == [dynamic]Enemy ||
	T == [dynamic]Point {
	if index < 0 || index >= len(arr^) {
		return
	}

	// Shift elements to fill the gap
	for i := index; i < len(arr^) - 1; i += 1 {
		arr^[i] = arr^[i + 1]
	}

	// Remove the last element
	pop(arr)
}

is_point_inside_box :: proc(point: rl.Vector2, box: CollisionBox) -> bool {
    left := min(box.pos.x, box.pos.x + f32(box.size))
    right := max(box.pos.x, box.pos.x + f32(box.size))
    top := min(box.pos.y, box.pos.y + f32(box.size))
    bottom := max(box.pos.y, box.pos.y + f32(box.size))

	return point.x >= left && point.x <= right && point.y >= top && point.y <= bottom
}

draw_scene :: proc(
	camera: rl.Camera2D,
	ball_pos: rl.Vector2,
	ball_rad: f32,
	rope: [dynamic]RopePoint,
	rope_length: int,
	pause: bool,
	framesCounter: int,
	enemies: [dynamic]Enemy,
	score: Score,
	rightClicking: ^bool,
	boxes: [dynamic]CollisionBox,
	points: [dynamic]Point,
	store: Store,
) {
	rl.BeginDrawing()
	rl.BeginMode2D(camera)
	rl.ClearBackground(BG_COLOR)
	rl.DrawCircleV(ball_pos, ball_rad, PLAYER_COLOR)

	for i in 0 ..= rope_length - 2 {
		rl.DrawLineEx(rope[i].pos, rope[i + 1].pos, 3, PLAYER_COLOR)
		if i == rope_length - 2 {
			rl.DrawCircle(
				i32(rope[i + 1].pos.x),
				i32(rope[i + 1].pos.y),
				TETHER_RADIUS,
				PLAYER_COLOR,
			)
		}
	}

	for enemy in enemies {
		rl.DrawCircle(i32(enemy.pos.x), i32(enemy.pos.y), ENEMY_RADIUS, enemy.color)
	}

	// Calculate corner positions relative to the camera view
	screen_width := f32(rl.GetScreenWidth())
	screen_height := f32(rl.GetScreenHeight())
	top_left := camera.target - camera.offset / camera.zoom
	bottom_left := rl.Vector2{top_left.x, top_left.y + screen_height / camera.zoom}
	top_right := rl.Vector2{top_left.x + screen_width / camera.zoom, top_left.y}

	// Draw UI elements
	rl.DrawText("PAUSE: TAB", i32(bottom_left.x) + 10, i32(bottom_left.y) - 25, 20, FG_COLOR)
	rl.DrawText("MONEY:", i32(top_left.x) + 10, i32(top_left.y) + 10, 20, rl.GOLD)
	fps_str := fmt.tprintf("%d", store.money)
	rl.DrawText(
		cstring(raw_data(fps_str)),
		i32(top_left.x) + 100,
		i32(top_left.y) + 10,
		20,
		rl.GOLD,
	)

	// Update this part in the draw_scene function
	rl.DrawText("SCORE: ", i32(top_right.x) - 180, i32(top_right.y) + 10, 20, rl.WHITE)

	// Draw each score in its respective color
	red_score_str := fmt.tprintf("{}", score.red)
	green_score_str := fmt.tprintf("{}", score.green)
	blue_score_str := fmt.tprintf("{}", score.blue)

	x_offset := i32(top_right.x) - 95
	y_pos := i32(top_right.y) + 10

	rl.DrawText(cstring(raw_data(red_score_str)), x_offset, y_pos, 20, rl.RED)
	x_offset += i32(rl.MeasureText(cstring(raw_data(red_score_str)), 20)) + 10

	rl.DrawText(cstring(raw_data(green_score_str)), x_offset, y_pos, 20, rl.GREEN)
	x_offset += i32(rl.MeasureText(cstring(raw_data(green_score_str)), 20)) + 10

	rl.DrawText(cstring(raw_data(blue_score_str)), x_offset, y_pos, 20, rl.BLUE)

	if rightClicking^ {
		rl.DrawText(
			"RIGHT CLICKING",
			i32(top_right.x - 600) - 150,
			i32(top_right.y) + 10,
			20,
			rl.GREEN,
		)
	}

	if pause && (framesCounter / 30) % 2 != 0 {
		pause_text_pos := camera.target
		rl.DrawText("PAUSED", i32(pause_text_pos.x) - 50, i32(pause_text_pos.y), 30, FG_COLOR)
	}


	for box in boxes {
        rl.DrawRectangleLines(
            i32(box.pos.x),
            i32(box.pos.y),
            i32(box.size),
            i32(box.size),
            box.color,
        )
	}

	// Draw points
	for point in points {
		rl.DrawCircleV(point.pos, 5, point.color)
	}

	if store.is_open {
		menu_width := i32(300)
		menu_height := i32(300)

		// Calculate the position to center the menu on the screen
		menu_x := i32(camera.target.x - (f32(menu_width) / 2))
		menu_y := i32(camera.target.y - (f32(menu_height) / 2))

		rl.DrawRectangle(menu_x, menu_y, menu_width, menu_height, rl.ColorAlpha(rl.BLACK, 0.7))
		rl.DrawRectangleLines(menu_x, menu_y, menu_width, menu_height, rl.WHITE)

		rl.DrawText("Store Menu", menu_x + 10, menu_y + 10, 20, rl.WHITE)
		rl.DrawText("Press ENTER to sell", menu_x + 10, menu_y + 240, 20, rl.WHITE)
		rl.DrawText("Red Point ($10)", menu_x + 10, menu_y + 40, 20, rl.RED)
		rl.DrawText("Green Point ($10)", menu_x + 10, menu_y + 70, 20, rl.GREEN)
		rl.DrawText("Blue Point ($10)", menu_x + 10, menu_y + 100, 20, rl.BLUE)
		rl.DrawText("1: Extend Rope", menu_x + 10, menu_y + 130, 20, rl.BLUE)
		ext_rope_cost_str := fmt.tprintf("(${})", store.extend_rope_cost)
		rl.DrawText(
			cstring(raw_data(ext_rope_cost_str)),
			menu_x + 170,
			menu_y + 130,
			20,
			rl.YELLOW,
		)
		rl.DrawText("2: Increase Speed", menu_x + 10, menu_y + 160, 20, rl.BLUE)
		inc_speed_cost_speed := fmt.tprintf("(${})", store.increase_speed_cost)
		rl.DrawText(
			cstring(raw_data(inc_speed_cost_speed)),
			menu_x + 210,
			menu_y + 160,
			20,
			rl.YELLOW,
		)
		rl.DrawText("3: Increase Box Size", menu_x + 10, menu_y + 190, 20, rl.BLUE)
		inc_size_cost_speed := fmt.tprintf("(${})", store.increase_size_cost)
		rl.DrawText(
			cstring(raw_data(inc_size_cost_speed)),
			menu_x + 230,
			menu_y + 190,
			20,
			rl.YELLOW,
		)
	}


	rl.EndMode2D()
	rl.EndDrawing()
}

main :: proc() {
	rl.SetConfigFlags(rl.ConfigFlags{.MSAA_4X_HINT})
	rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "ball and chain")
	defer rl.CloseWindow()

	ball_pos := rl.Vector2{f32(rl.GetScreenWidth() / 2), f32(rl.GetScreenHeight() / 2)}
	ball_rad := f32(PLAYER_RADIUS)
	player_targ := rl.Vector2{f32(rl.GetScreenWidth() / 2), f32(rl.GetScreenHeight() / 2)}
	tether_pos := rl.Vector2{}
	leftClicking := false
	rightClicking := false
	max_dist := ROPE_MAX_DIST

	rope_length := REST_ROPE_LENGTH

	attributes := Attributes {
		ext_rope_length = 10,
		speed           = 4,
        box_size        = 100,
	}

	anchor := rl.Vector2{f32(rl.GetScreenWidth() / 2), 50}
	rest_length := REST_LENGTH
	rope := make([dynamic]RopePoint, rope_length)
	initialize_rope(rope, rope_length, anchor)

	enemies := make([dynamic]Enemy, 0)

	boxes := make([dynamic]CollisionBox, 0)

	points := make([dynamic]Point, 0)

	score := Score{0, 0, 0}

    box := CollisionBox{
        pos = {0, 0},
        size = 100,
        color = rl.WHITE,
        last_point_spawn_time = 0.0,
    }
    item: Item = box

	pause := true
	framesCounter := 0

	rl.SetTargetFPS(60)

	camera: rl.Camera2D
	cameraTarget := rl.Vector2{0, 0}

	spawnInterval := 1.0 // Spawn interval in seconds
	lastSpawnTime := rl.GetTime()

	camera.zoom = 1.0 // Adjust this value for zoom in or out

	store = Store {
		is_open             = false,
		money               = 0,
		attributes          = attributes,
		extend_rope_cost    = 10,
		increase_speed_cost = 10,
		increase_size_cost  = 100,
		red_point_value     = 10,
		green_point_value   = 10,
		blue_point_value    = 10,
	}

	for !rl.WindowShouldClose() {
		if rl.IsKeyPressed(rl.KeyboardKey.TAB) {
			pause = !pause
		}
		if !pause {
			if leftClicking {
				rest_length = EXT_REST_LENGTH
				max_dist = attributes.ext_rope_length * 20
			} else {
				rest_length = REST_LENGTH
				max_dist = ROPE_MAX_DIST
			}

			handle_input(
				&player_targ,
				&leftClicking,
				&rightClicking,
				&enemies,
				&camera,
				&score,
				&attributes,
                &boxes,
			)
			update_ball_position(&ball_pos, &player_targ)
			update_rope(rope, ball_pos, f32(rest_length))
			update_tether(
				&rope,
				&ball_pos,
				&tether_pos,
				&leftClicking,
				max_dist,
				camera,
				attributes,
			)
            placeItem(&item, &boxes, &camera)
			update_enemies(&enemies) // Update enemies to move towards the player
			solve_collisions(&ball_pos, rope, &enemies, &boxes)
			update_box_colors(&boxes, enemies)
			spawn_points(&boxes, enemies, &points)
			collect_points(rope, &points, &score)
			rope[len(rope) - 1].pos += (tether_pos - rope[len(rope) - 1].pos) / TETHER_LERP_FACTOR

			// Spawn enemies periodically
			if rl.GetTime() - lastSpawnTime > spawnInterval {
				spawn_enemy(&enemies, camera)
				lastSpawnTime = rl.GetTime()
			}
			cameraTarget += (ball_pos - cameraTarget) / CAMERA_LERP_FACTOR
		} else {
			framesCounter += 1
		}

		camera.target = cameraTarget
		camera.offset = rl.Vector2{f32(rl.GetScreenWidth() / 2), f32(rl.GetScreenHeight() / 2)}
		camera.rotation = 0.0 // No rotation

		draw_scene(
			camera,
			ball_pos,
			ball_rad,
			rope,
			len(rope),
			pause,
			framesCounter,
			enemies,
			score,
			&rightClicking,
			boxes,
			points,
			store,
		)
	}
}
