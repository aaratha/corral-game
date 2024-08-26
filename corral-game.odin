package main

import "base:runtime"
import "core:fmt"
import math "core:math"
import linalg "core:math/linalg"
import "core:strings"
import time "core:time"
import rl "vendor:raylib"
import "core:math/rand"


SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720
TETHER_LERP_FACTOR :: 6
PLAYER_LERP_FACTOR :: 6
CAMERA_LERP_FACTOR :: 6
FRICTION :: 0.9
BG_COLOR :: rl.BLACK
FG_COLOR :: rl.WHITE
PLAYER_COLOR :: rl.WHITE
PLAYER_RADIUS :: 12
REST_ROPE_LENGTH :: 8
REST_LENGTH :: 1
EXT_REST_LENGTH :: 7
ROPE_MAX_DIST :: 70
ANIMAL_RADIUS :: 10
ANIMAL_SPEED :: 0.2
ENEMY_RADIUS :: 10
ENEMY_SPEED :: 0.8
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
	money:           int,
	item:            Item,
	kill_interval:   f64,
}

Animal :: struct {
	pos:      rl.Vector2,
	prev_pos: rl.Vector2,
	color:    rl.Color,
}

Enemy :: struct {
	pos:      rl.Vector2,
	prev_pos: rl.Vector2,
	color:    rl.Color,
}

CollisionBox :: struct {
	pos:                   rl.Vector2,
	size:                  int,
	color:                 rl.Color,
	last_point_spawn_time: f64,
	last_kill_time:        f64,
}

DeleteItem :: struct {}

Item :: distinct union {
	CollisionBox,
	DeleteItem,
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
	increase_kill_cost:  int,
	red_point_value:     int,
	green_point_value:   int,
	blue_point_value:    int,
}

store: Store

POINT_VALUE :: 10 // Each point is worth 10 money
UPGRADE_COST :: 100 // Each upgrade costs 100 money

verlet_integrate :: proc(object: ^$T, dt: f32) where T == RopePoint || T == Animal || T == Enemy {
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
	animals: ^[dynamic]Animal,
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
		for i := 0; i < len(animals); i += 1 {
			if rl.Vector2Distance(animals[i].pos, world_mouse_pos) <= ANIMAL_RADIUS {
				ordered_remove(animals, i)
				break // Only remove one animal per space press
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
			sell_points(score, attributes)
		}
		if rl.IsKeyPressed(.ONE) && attributes.money > store.extend_rope_cost {
			attributes.ext_rope_length += 1
			attributes.money -= store.extend_rope_cost
			store.extend_rope_cost += (store.extend_rope_cost / 1)
		}
		if rl.IsKeyPressed(.TWO) && attributes.money > store.increase_speed_cost {
			attributes.speed += 0.7
			attributes.money -= store.increase_speed_cost
			store.increase_speed_cost += (store.increase_speed_cost / 1)
		}
		if rl.IsKeyPressed(.THREE) && attributes.money > store.increase_size_cost {
			attributes.box_size += 20
			for &box in boxes {
				box.size = attributes.box_size
			}
			attributes.money -= store.increase_size_cost
			store.increase_size_cost += (store.increase_size_cost / 1)
		}
		if rl.IsKeyPressed(.FOUR) && attributes.money > store.increase_kill_cost {
			attributes.kill_interval *= 0.75
			attributes.money -= store.increase_kill_cost
			store.increase_kill_cost += (store.increase_kill_cost / 1)
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

	// Add a buffer to ensure animals spawn well outside the view
	buffer := f32(100)

	// Generate a random position outside the camera's view
	x_pos, y_pos: f32
	if rl.GetRandomValue(0, 1) == 0 {
		// Spawn on left or right side
		x_pos =
			rl.GetRandomValue(0, 1) == 0 ? camera_left - ANIMAL_RADIUS - buffer : camera_right + ANIMAL_RADIUS + buffer
		y_pos = f32(
			rl.GetRandomValue(i32(camera_top - ANIMAL_RADIUS), i32(camera_bottom + ANIMAL_RADIUS)),
		)
	} else {
		// Spawn on top or bottom side
		x_pos = f32(
			rl.GetRandomValue(i32(camera_left - ANIMAL_RADIUS), i32(camera_right + ANIMAL_RADIUS)),
		)
		y_pos =
			rl.GetRandomValue(0, 1) == 0 ? camera_top - ANIMAL_RADIUS - buffer : camera_bottom + ANIMAL_RADIUS + buffer
	}

	return rl.Vector2{x_pos, y_pos}
}

spawn_animal :: proc(animals: ^[dynamic]Animal, camera: rl.Camera2D) {
	spawn_pos := random_outside_position(camera)

	// Array of three colors to choose from
	colors := [3]rl.Color{rl.RED, rl.GREEN, rl.BLUE}

	// Randomly select one of the three colors
	random_color := colors[rl.GetRandomValue(0, 2)]

	append(animals, Animal{pos = spawn_pos, prev_pos = spawn_pos, color = random_color})
}

spawn_enemy :: proc(enemies: ^[dynamic]Enemy, camera: rl.Camera2D) {
	spawn_pos := random_outside_position(camera)

	// Array of three colors to choose from

	// Randomly select one of the three colors

	append(enemies, Enemy{pos = spawn_pos, prev_pos = spawn_pos, color = rl.PINK})
}

update_animals :: proc(animals: ^[dynamic]Animal) {
	for &animal in animals {
		// Generate a random direction
		angle := f32(rl.GetRandomValue(0, 359)) * math.PI / 180.0
		direction := rl.Vector2{math.cos_f32(angle), math.sin_f32(angle)}

		// Move the animal in the random direction
		animal.pos += direction * ANIMAL_SPEED

		// Apply verlet integration
		verlet_integrate(&animal, 1.0 / 60.0)
	}
}

update_enemies :: proc(enemies: ^[dynamic]Enemy, boxes: [dynamic]CollisionBox) {
	for &enemy in enemies {
		// Check if there are any boxes
		if len(boxes) == 0 {
			continue // No boxes to move towards
		}

		// Find the nearest box
		nearest_box := &boxes[0]
		min_distance := rl.Vector2Distance(enemy.pos, nearest_box.pos)

		for &box in boxes {
			distance := rl.Vector2Distance(enemy.pos, box.pos)
			if distance < min_distance {
				min_distance = distance
				nearest_box = &box
			}
		}

		// Calculate the direction towards the nearest box
		direction := (nearest_box.pos - enemy.pos) * FRICTION

		// Normalize the direction vector (make it unit length)
		if min_distance > 0 {
			direction = rl.Vector2Normalize(nearest_box.pos - enemy.pos)
		}

		// Move the enemy towards the nearest box using lerp
		enemy.pos += direction * ENEMY_SPEED // Adjust speed as necessary
		//
		// Apply verlet integration to simulate smooth movement
		verlet_integrate(&enemy, 1.0 / 60.0)
	}
}

// Declare this at the top level of your file, outside any function
box_corner1: rl.Vector2

placeBox :: proc(boxes: ^[dynamic]CollisionBox, attributes: ^Attributes, camera: ^rl.Camera2D) {
	mouse_pos := rl.GetMousePosition()
	world_mouse_position := rl.GetScreenToWorld2D(mouse_pos, camera^)

	if rl.IsMouseButtonPressed(.RIGHT) {
		append(
			boxes,
			CollisionBox{world_mouse_position, attributes.box_size, rl.WHITE, rl.GetTime(), 0},
		)
	}
}

delete_item :: proc(boxes: ^[dynamic]CollisionBox, camera: ^rl.Camera2D) {
	mouse_pos := rl.GetMousePosition()
	world_mouse_pos := rl.GetScreenToWorld2D(mouse_pos, camera^)

	if rl.IsMouseButtonPressed(.RIGHT) {
		for i := 0; i < len(boxes); i += 1 {
			if is_point_inside_box(world_mouse_pos, boxes[i]) {
				ordered_remove(boxes, i)
				break // Only remove one animal per space press
			}
		}
	}
}

placeItem :: proc(
	item: ^Item,
	boxes: ^[dynamic]CollisionBox,
	attributes: ^Attributes,
	camera: ^rl.Camera2D,
) {
	if item != nil {
		switch type in item {
		case CollisionBox:
			placeBox(boxes, attributes, camera)
		// Add cases for any other placeable item types
		case DeleteItem:
			delete_item(boxes, camera)
		}
	}
}

solve_collisions :: proc(
	ball_pos: ^rl.Vector2,
	rope: [dynamic]RopePoint,
	animals: ^[dynamic]Animal,
	enemies: ^[dynamic]Enemy,
	boxes: ^[dynamic]CollisionBox,
	rightClicking: ^bool,
) {

	// Ball vs Animals
	for i := 0; i < len(animals); i += 1 {
		dir := ball_pos^ - animals[i].pos
		distance := rl.Vector2Length(dir)
		min_dist := f32(PLAYER_RADIUS + ANIMAL_RADIUS)
		if distance < min_dist {
			normal := rl.Vector2Normalize(dir)
			depth := min_dist - distance
			ball_pos^ = ball_pos^ + (normal * depth * 0.5)
			animals[i].pos = animals[i].pos - (normal * depth * 0.5)
		}
	}

	// Rope segments vs Animals
	if rl.IsKeyDown(.LEFT_SHIFT) == false {
		for i := 0; i < len(rope); i += 1 {
			for j := 0; j < len(animals); j += 1 {
				dir := rope[i].pos - animals[j].pos
				distance := rl.Vector2Length(dir)
				min_dist := f32(TETHER_RADIUS + ANIMAL_RADIUS + 4)

				if distance < min_dist {
					normal := rl.Vector2Normalize(dir)
					depth := min_dist - distance
					rope[i].pos = rope[i].pos + (normal * depth * 0.5)
					animals[j].pos = animals[j].pos - (normal * depth * 0.5)
				}
			}
		}
	}

	// Animals vs Animals
	for i := 0; i < len(animals) - 1; i += 1 {
		for j := i + 1; j < len(animals); j += 1 {
			dir := animals[i].pos - animals[j].pos
			distance := rl.Vector2Length(dir)
			min_dist := f32(ANIMAL_RADIUS * 2)

			if distance < min_dist {
				normal := rl.Vector2Normalize(dir)
				depth := min_dist - distance
				animals[i].pos = animals[i].pos + (normal * depth * 0.5)
				animals[j].pos = animals[j].pos - (normal * depth * 0.5)
			}
		}
	}

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

	// Enemies vs Rope Points
	for i := 0; i < len(rope); i += 1 {
		for j := 0; j < len(enemies); j += 1 {
			dir := rope[i].pos - enemies[j].pos
			distance := rl.Vector2Length(dir)
			min_dist := f32(TETHER_RADIUS + ENEMY_RADIUS + 4)

			if distance < min_dist {
				normal := rl.Vector2Normalize(dir)
				depth := min_dist - distance
				rope[i].pos = rope[i].pos + (normal * depth * 0.5)
				enemies[j].pos = enemies[j].pos - (normal * depth * 0.5)
			}
		}
	}

	// Enemies vs Animal s
	for i := 0; i < len(enemies); i += 1 {
		for j := 0; j < len(animals); j += 1 {
			dir := enemies[i].pos - animals[j].pos
			distance := rl.Vector2Length(dir)
			min_dist := f32(ENEMY_RADIUS + ANIMAL_RADIUS)

			if distance < min_dist {
				normal := rl.Vector2Normalize(dir)
				depth := min_dist - distance
				enemies[i].pos = enemies[i].pos + (normal * depth * 0.5)
				animals[j].pos = animals[j].pos - (normal * depth * 0.5)
			}
		}
	}

	// Animals vs Box walls
	if animals == nil || boxes == nil {
		return
	}

	BOX_INFLUENCE_DISTANCE :: 10.0 // Distance from box edge where collisions are checked

	// Animals vs Boxes
	for &animal in animals {
		for box in boxes {
			// Calculate box boundaries
			left := box.pos.x - f32(box.size / 2)
			right := box.pos.x + f32(box.size / 2)
			top := box.pos.y - f32(box.size / 2)
			bottom := box.pos.y + f32(box.size / 2)
			// Check if animal is within the influence distance of the box
			if animal.pos.x >= left - BOX_INFLUENCE_DISTANCE &&
			   animal.pos.x <= right + BOX_INFLUENCE_DISTANCE &&
			   animal.pos.y >= top - BOX_INFLUENCE_DISTANCE &&
			   animal.pos.y <= bottom + BOX_INFLUENCE_DISTANCE {

				// Check collision with left and right walls
				if animal.pos.x - ANIMAL_RADIUS < left {
					animal.pos.x = left + ANIMAL_RADIUS
					animal.prev_pos.x = animal.pos.x // Prevent sticking
				} else if animal.pos.x + ANIMAL_RADIUS > right {
					animal.pos.x = right - ANIMAL_RADIUS
					animal.prev_pos.x = animal.pos.x // Prevent sticking
				}

				// Check collision with top and bottom walls
				if animal.pos.y - ANIMAL_RADIUS < top {
					animal.pos.y = top + ANIMAL_RADIUS
					animal.prev_pos.y = animal.pos.y // Prevent sticking
				} else if animal.pos.y + ANIMAL_RADIUS > bottom {
					animal.pos.y = bottom - ANIMAL_RADIUS
					animal.prev_pos.y = animal.pos.y // Prevent sticking
				}
			}
		}
	}
}

update_box_colors :: proc(boxes: ^[dynamic]CollisionBox, animals: [dynamic]Animal, enemies: [dynamic]Enemy) {
	for &box in boxes {

		animals_in_box := make([dynamic]Animal)
		defer delete(animals_in_box)

		for animal in animals {
			if is_point_inside_box(animal.pos, box) {
				append(&animals_in_box, animal)
			}
		}

		enemies_in_box := make([dynamic]int)
        defer delete(enemies_in_box)

        // Count enemies in the box
        for enemy, index in enemies {
            if is_point_inside_box(enemy.pos, box) {
                append(&enemies_in_box, index)
            }
        }

		if len(animals_in_box) > 0 {
			all_same_color := true
			first_color := animals_in_box[0].color

			for i := 1; i < len(animals_in_box); i += 1 {
				if animals_in_box[i].color != first_color {
					all_same_color = false
					break
				}
			}

			if all_same_color {
				box.color = first_color
			} else {
				box.color = rl.WHITE
			}


        // Check if there are only enemies in the box
		} else if len(enemies_in_box) > 0 && count_animals_in_box(box, animals) == 0 {
			box.color = rl.PINK
		} else {
			box.color = rl.WHITE
		}
	}
}

spawn_points :: proc(
	boxes: ^[dynamic]CollisionBox,
	animals: [dynamic]Animal,
	points: ^[dynamic]Point,
) {
	POINT_SPAWN_INTERVAL :: 5 // Spawn interval in seconds
	POINT_RADIUS :: 5.0

	current_time := rl.GetTime()

	for &box in boxes {
		if box.color == rl.WHITE {
			continue // Skip white boxes
		}

		animals_in_box := count_animals_in_box(box, animals)
		if animals_in_box == 0 {
			continue // Skip boxes with no animals
		}

		if current_time - box.last_point_spawn_time >= POINT_SPAWN_INTERVAL {
			for i in 0 ..< animals_in_box {
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

sell_points :: proc(score: ^Score, attributes: ^Attributes) {
	attributes.money += (score.red + score.green + score.blue) * POINT_VALUE
	score.red = 0
	score.green = 0
	score.blue = 0
}

count_animals_in_box :: proc(box: CollisionBox, animals: [dynamic]Animal) -> int {
	count := 0
	for animal in animals {
		if is_point_inside_box(animal.pos, box) {
			count += 1
		}
	}
	return count
}

random_position_in_box :: proc(box: CollisionBox) -> rl.Vector2 {
	left := box.pos.x - f32(box.size / 2)
	right := box.pos.x + f32(box.size / 2)
	top := box.pos.y - f32(box.size / 2)
	bottom := box.pos.y + f32(box.size / 2)

	return rl.Vector2 {
		f32(rl.GetRandomValue(i32(left), i32(right))),
		f32(rl.GetRandomValue(i32(top), i32(bottom))),
	}
}

// Helper function to remove an element from a dynamic array
ordered_remove :: proc(
    arr: ^$T,
    index: int,
) where T == [dynamic]RopePoint ||
    T == [dynamic]Animal ||
    T == [dynamic]Point ||
    T == [dynamic]Enemy ||
	T == [dynamic]CollisionBox {
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
	left := box.pos.x - f32(box.size / 2)
	right := box.pos.x + f32(box.size / 2)
	top := box.pos.y - f32(box.size / 2)
	bottom := box.pos.y + f32(box.size / 2)


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
	animals: [dynamic]Animal,
	enemies: [dynamic]Enemy,
	score: Score,
	rightClicking: ^bool,
	boxes: [dynamic]CollisionBox,
	points: [dynamic]Point,
	store: ^Store,
	attributes: Attributes,
	index: ^i32,
) {
	player_color := rl.WHITE
	rl.BeginDrawing()
	rl.BeginMode2D(camera)
	rl.ClearBackground(BG_COLOR)
	rl.DrawCircleV(ball_pos, ball_rad, player_color)

	if rl.IsKeyDown(.LEFT_SHIFT) {
		player_color = rl.PINK
	}

	for i in 0 ..= rope_length - 2 {
		rl.DrawLineEx(rope[i].pos, rope[i + 1].pos, 3, player_color)
		if i == rope_length - 2 {
			rl.DrawCircle(
				i32(rope[i + 1].pos.x),
				i32(rope[i + 1].pos.y),
				TETHER_RADIUS,
				player_color,
			)
		}
	}

	for animal in animals {
		rl.DrawCircle(i32(animal.pos.x), i32(animal.pos.y), ANIMAL_RADIUS, animal.color)
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

	// Update this part in the draw_scene function
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
			i32(int(box.pos.x) - box.size / 2),
			i32(int(box.pos.y) - box.size / 2),
			i32(box.size),
			i32(box.size),
			box.color,
		)
	}

	// Draw points
	for point in points {
		rl.DrawCircleV(point.pos, 5, point.color)
	}



	rl.EndMode2D()

	gui_camera := rl.Camera2D {
		offset   = {0, 0},
		target   = {0, 0},
		rotation = 0,
		zoom     = 1,
	}

	rl.BeginMode2D(gui_camera)

	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), 20)

	// Draw your GUI elements here
	// Example:
	money_text: [256]u8
	fmt.bprintf(money_text[:], "Money: %d", attributes.money)

	// Convert to cstring and add the textSize parameter
	rl.GuiLabel(rl.Rectangle{10, 10, 100, 30}, cstring(&money_text[0]))

	rl.GuiLabel(rl.Rectangle{10, f32(rl.GetScreenHeight() - 40), 100, 30}, cstring("Pause: ESC"))

	rl.GuiLabel(rl.Rectangle{f32(rl.GetScreenWidth()) - 245, 10, 100, 30}, cstring("Score:"))

	// Draw each score in its respective color
	red_score_str := fmt.tprintf("{}", score.red)
	green_score_str := fmt.tprintf("{}", score.green)
	blue_score_str := fmt.tprintf("{}", score.blue)

	x_offset := i32(rl.GetScreenWidth()) - 170
	y_pos := i32(17)

	rl.DrawText(cstring(raw_data(red_score_str)), x_offset, y_pos, 20, rl.RED)
	x_offset += i32(rl.MeasureText(cstring(raw_data(red_score_str)), 20)) + 8

	rl.DrawText(cstring(raw_data(green_score_str)), x_offset, y_pos, 20, rl.GREEN)
	x_offset += i32(rl.MeasureText(cstring(raw_data(green_score_str)), 20)) + 8

	rl.DrawText(cstring(raw_data(blue_score_str)), x_offset, y_pos, 20, rl.BLUE)

	tray_x := i32(rl.GetScreenWidth()) - 70
	tray_y := i32(rl.GetScreenHeight() / 2 - 75)
	tray_w := i32(50)
	tray_h := i32(177)

	rl.DrawRectangleLines(tray_x, tray_y, tray_w, tray_h, rl.GRAY)

	icons := []rl.GuiIconName {
		.ICON_CURSOR_HAND,
		.ICON_BOX_DOTS_BIG,
		.ICON_CUBE, // Example of another icon
		.ICON_BIN,
	}
	icons_str := icons_to_cstring(icons)

	rl.GuiToggleGroup(
		rl.Rectangle{f32(tray_x + 5), f32(tray_y + 5), f32(tray_w - 10), f32(40)},
		icons_str,
		index,
	)

	if rl.GuiButton(
		rl.Rectangle{f32(rl.GetScreenWidth() - 70), f32(rl.GetScreenHeight() - 70), 40, 40},
		"$"
	) {store.is_open = !store.is_open}

	if store.is_open {
		menu_width := i32(300)
		menu_height := i32(300)

		// Calculate the position to center the menu on the screen
		menu_x := i32(f32(rl.GetScreenWidth() / 2) - (f32(menu_width) / 2))
		menu_y := i32(f32(rl.GetScreenHeight() / 2) - (f32(menu_height) / 2))

		rl.DrawRectangle(menu_x, menu_y, menu_width, menu_height, rl.ColorAlpha(rl.BLACK, 0.7))
		rl.GuiGroupBox(rl.Rectangle{f32(menu_x), f32(menu_y), f32(menu_width), f32(menu_height)}, "Store")

		rl.DrawText("Press ENTER to sell", menu_x + 10, menu_y + 240, 20, rl.WHITE)
		rl.GuiTextBox(rl.Rectangle{f32(menu_x + 10), f32(menu_y + 10), 200, 30}, "Red Point ($10)", 0, false)
		rl.GuiTextBox(rl.Rectangle{f32(menu_x + 10), f32(menu_y + 45), 200, 30}, "Green Point ($10)", 0, false)
		rl.GuiTextBox(rl.Rectangle{f32(menu_x + 10), f32(menu_y + 80), 200, 30}, "Blue Point ($10)", 0, false)
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
		rl.DrawText("4: Increase Box Size", menu_x + 10, menu_y + 210, 20, rl.BLUE)
		inc_kill_cost_speed := fmt.tprintf("(${})", store.increase_kill_cost)
		rl.DrawText(
			cstring(raw_data(inc_kill_cost_speed)),
			menu_x + 230,
			menu_y + 210,
			20,
			rl.YELLOW,
		)
	}


	rl.EndMode2D()

	rl.EndDrawing()
}

item_switch :: proc(index: i32, attributes: ^Attributes) {
	switch index {
	case 0:
		attributes.item = nil
	case 1:
		attributes.item = CollisionBox {
			pos                   = {0, 0}, // Default position
			size                  = attributes.box_size,
			color                 = rl.WHITE,
			last_point_spawn_time = 0,
		}
	case 2:
		attributes.item = nil
	case 3:
		attributes.item = DeleteItem{}
	}
}

eliminate_enemies_in_boxes :: proc(
    boxes: ^[dynamic]CollisionBox,
    enemies: ^[dynamic]Enemy,
	animals: ^[dynamic]Animal,
	attributes: ^Attributes,
) {
	current_time := rl.GetTime()

    for &box in boxes {
        // Skip if the last elimination was too recent
        if current_time - box.last_kill_time < attributes.kill_interval {
            continue
        }

        enemies_in_box := make([dynamic]int)
        defer delete(enemies_in_box)

        // Count enemies in the box
        for enemy, index in enemies {
            if is_point_inside_box(enemy.pos, box) {
                append(&enemies_in_box, index)
            }
        }

        // Check if there are only enemies in the box
        if len(enemies_in_box) > 0 && count_animals_in_box(box, animals^) == 0 {

            // Choose a random enemy to eliminate
			random_index := rand.int_max(len(enemies_in_box))
			enemy_to_remove := enemies_in_box[random_index]

			// Remove the enemy
			ordered_remove(enemies, enemy_to_remove)

			// Update the last elimination time for this box
			box.last_kill_time = current_time
        }
	}
}

icons_to_cstring :: proc(icons: []rl.GuiIconName) -> cstring {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for icon, i in icons {
		icon_text := rl.GuiIconText(icon, "")
		strings.write_string(&builder, string(icon_text))
		if i < len(icons) - 1 {
			strings.write_byte(&builder, '\n') // Add newline between icons, but not after the last one
		}
	}

	return strings.clone_to_cstring(strings.to_string(builder))
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

	item: Item = nil
	index: i32 = 0

	attributes := Attributes {
		ext_rope_length = 10,
		speed           = 4,
		box_size        = 100,
		money           = 0,
		item            = item,
		kill_interval   = 2.0,
	}

	anchor := rl.Vector2{f32(rl.GetScreenWidth() / 2), 50}
	rest_length := REST_LENGTH
	rope := make([dynamic]RopePoint, rope_length)
	initialize_rope(rope, rope_length, anchor)

	animals := make([dynamic]Animal, 0)

	enemies := make([dynamic]Enemy, 0)

	boxes := make([dynamic]CollisionBox, 0)

	points := make([dynamic]Point, 0)

	score := Score{0, 0, 0}

	box := CollisionBox {
		pos                   = {0, 0},
		size                  = 100,
		color                 = rl.WHITE,
		last_point_spawn_time = 0.0,
		last_kill_time        = 0.0,
	}

	pause := true
	framesCounter := 0

	rl.SetTargetFPS(60)

	camera: rl.Camera2D
	cameraTarget := rl.Vector2{0, 0}

	spawnInterval := 1.0 // Spawn interval in seconds
	lastSpawnTime := rl.GetTime()

	camera.zoom = 1.0 // Adjust this value for zoom in or out

	rl.SetExitKey(rl.KeyboardKey.KEY_NULL)

	store = Store {
		is_open             = false,
		attributes          = attributes,
		extend_rope_cost    = 10,
		increase_speed_cost = 10,
		increase_size_cost  = 160,
		increase_kill_cost  = 40,
		red_point_value     = 10,
		green_point_value   = 10,
		blue_point_value    = 10,
	}

	for !rl.WindowShouldClose() {
		if rl.IsKeyPressed(rl.KeyboardKey.ESCAPE) {
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
				&animals,
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
			placeItem(&attributes.item, &boxes, &attributes, &camera)
			update_animals(&animals) // Update animals to move towards the player
			update_enemies(&enemies, boxes) // Update animals to move towards the player
			solve_collisions(&ball_pos, rope, &animals, &enemies, &boxes, &rightClicking)
			update_box_colors(&boxes, animals, enemies)
			spawn_points(&boxes, animals, &points)
			collect_points(rope, &points, &score)
			item_switch(index, &attributes)
			eliminate_enemies_in_boxes(&boxes, &enemies, &animals, &attributes)
			rope[len(rope) - 1].pos += (tether_pos - rope[len(rope) - 1].pos) / TETHER_LERP_FACTOR

			// Spawn animals periodically
			if rl.GetTime() - lastSpawnTime > spawnInterval {
				spawn_animal(&animals, camera)
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
			animals,
			enemies,
			score,
			&rightClicking,
			boxes,
			points,
			&store,
			attributes,
			&index,
		)
	}
}
