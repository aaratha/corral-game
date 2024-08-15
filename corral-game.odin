package main

import "core:fmt"
import linalg "core:math/linalg"
import math "core:math"
import time "core:time"
import rl "vendor:raylib"
import "base:runtime"

SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720
PLAYER_SPEED :: 7
TETHER_LERP_FACTOR :: 6
PLAYER_LERP_FACTOR :: 6
CAMERA_LERP_FACTOR :: 6
FRICTION :: 0.7
BG_COLOR :: rl.BLACK
FG_COLOR :: rl.WHITE
PLAYER_COLOR :: rl.WHITE
PLAYER_RADIUS :: 12
REST_ROPE_LENGTH :: 8
EXT_ROPE_LENGTH :: 20
REST_LENGTH :: 1
EXT_REST_LENGTH :: 5
ROPE_MAX_DIST :: 70
EXT_ROPE_MAX_DIST :: 300
ENEMY_RADIUS :: 10
ENEMY_COLOR :: rl.RED
ENEMY_SPEED :: 0.5
TETHER_RADIUS :: 10
MIN_ZOOM :: 0.5
MAX_ZOOM :: 2
ZOOM_SPEED :: 0.06

mat :: distinct matrix[2, 2]f32

PhysicsObject :: struct {
	pos:      rl.Vector2,
	prev_pos: rl.Vector2,
}

CollisionBox :: struct {
    corner1: rl.Vector2,
    corner2: rl.Vector2
}

verlet_integrate :: proc(segment: ^PhysicsObject, dt: f32) {
	temp := segment.pos
	velocity := segment.pos - segment.prev_pos
	velocity = velocity * FRICTION
	segment.pos = segment.pos + velocity
	segment.prev_pos = temp
}

constrain_rope :: proc(rope: [dynamic]PhysicsObject, rest_length: f32) {
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

initialize_rope :: proc(rope: [dynamic]PhysicsObject, length: int, anchor: rl.Vector2) {
	for i in 0 ..= length - 1 {
		rope[i] = PhysicsObject{anchor, anchor}
	}
}

update_rope :: proc(rope: [dynamic]PhysicsObject, ball_pos: rl.Vector2, rest_length: f32) {
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
	enemies: ^[dynamic]PhysicsObject,
    camera: ^rl.Camera2D
) {
	direction := rl.Vector2{0, 0}
	if rl.IsKeyDown(.W) {direction.y -= 1}
	if rl.IsKeyDown(.S) {direction.y += 1}
	if rl.IsKeyDown(.D) {direction.x += 1}
	if rl.IsKeyDown(.A) {direction.x -= 1}

    camera.zoom += rl.GetMouseWheelMove() * ZOOM_SPEED
    camera.zoom = math.clamp(camera.zoom, MIN_ZOOM, MAX_ZOOM)

	leftClicking^ = rl.IsMouseButtonDown(rl.MouseButton.LEFT)
    rightClicking^ = rl.IsMouseButtonDown(rl.MouseButton.RIGHT)

	if direction.x != 0 || direction.y != 0 {
		length := rl.Vector2Length(direction)
		direction = direction * (PLAYER_SPEED / length)
	}

	player_targ.x += direction.x
	player_targ.y += direction.y
}

update_ball_position :: proc(ball_pos, player_targ: ^rl.Vector2) {
	ball_pos.x += (player_targ.x - ball_pos.x) / PLAYER_LERP_FACTOR
	ball_pos.y += (player_targ.y - ball_pos.y) / PLAYER_LERP_FACTOR
}

update_tether :: proc(
    rope: ^[dynamic]PhysicsObject,
    ball_pos, tether_pos: ^rl.Vector2,
    leftClicking: ^bool,
    max_dist: int,
    camera: rl.Camera2D,
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
    if leftClicking^ && (len(rope^) < EXT_ROPE_LENGTH) {
        runtime.append_elem(rope, PhysicsObject{tether_pos^, tether_pos^})
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
        x_pos = rl.GetRandomValue(0, 1) == 0 ? camera_left - ENEMY_RADIUS - buffer :
            camera_right + ENEMY_RADIUS + buffer
        y_pos = f32(rl.GetRandomValue(
            i32(camera_top - ENEMY_RADIUS),
            i32(camera_bottom + ENEMY_RADIUS)
        ))
    } else {
        // Spawn on top or bottom side
        x_pos = f32(rl.GetRandomValue(
            i32(camera_left - ENEMY_RADIUS),
            i32(camera_right + ENEMY_RADIUS)
        ))
        y_pos = rl.GetRandomValue(0, 1) == 0 ? camera_top - ENEMY_RADIUS - buffer :
            camera_bottom + ENEMY_RADIUS + buffer
    }

    return rl.Vector2{x_pos, y_pos}
}

spawn_enemy :: proc(enemies: ^[dynamic]PhysicsObject, camera: rl.Camera2D) {
	spawn_pos := random_outside_position(camera)
	append(enemies, PhysicsObject{pos = spawn_pos, prev_pos = spawn_pos})
}

update_enemies :: proc(enemies: ^[dynamic]PhysicsObject) {
    for &enemy in enemies {
        // Generate a random direction
        angle := f32(rl.GetRandomValue(0, 359)) * math.PI / 180.0
        direction := rl.Vector2{
            math.cos_f32(angle),
            math.sin_f32(angle),
        }

        // Move the enemy in the random direction
        enemy.pos += direction * ENEMY_SPEED

        // Apply verlet integration
        verlet_integrate(&enemy, 1.0 / 60.0)
    }
}

createBox :: proc(rightClicking: ^bool, boxes: ^[dynamic]CollisionBox) {
    corner1: rl.Vector2
    corner2: rl.Vector2

    if rl.IsMouseButtonPressed(.RIGHT) {
        rightClicking^ = true
        corner1 = rl.GetMousePosition()
    }

    if rightClicking^ {
        corner2 = rl.GetMousePosition()

        // Draw the box in real-time
        rl.DrawRectangleLines(
            i32(min(corner1.x, corner2.x)),
            i32(min(corner1.y, corner2.y)),
            i32(abs(corner2.x - corner1.x)),
            i32(abs(corner2.y - corner1.y)),
            rl.WHITE
        )
    }

    if rl.IsMouseButtonReleased(.RIGHT) {
        rightClicking^ = false
        // Add the new box to the boxes array
        append(boxes, CollisionBox{corner1, corner2})
    }
}

solve_collisions :: proc(
	ball_pos: ^rl.Vector2,
	ball_rad: int,
	rope: [dynamic]PhysicsObject,
	tether_rad: int,
	enemies: ^[dynamic]PhysicsObject,
	enemy_rad: int,
) {
	// Ball vs Enemies
	for i := 0; i < len(enemies); i += 1 {
		dir := ball_pos^ - enemies[i].pos
		distance := rl.Vector2Length(dir)
		min_dist := f32(ball_rad + enemy_rad)
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
			min_dist := f32(tether_rad + enemy_rad)

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
			min_dist := f32(enemy_rad * 2)

			if distance < min_dist {
				normal := rl.Vector2Normalize(dir)
				depth := min_dist - distance
				enemies[i].pos = enemies[i].pos + (normal * depth * 0.5)
				enemies[j].pos = enemies[j].pos - (normal * depth * 0.5)
			}
		}
	}
}

// Helper function to remove an element from a dynamic array
ordered_remove :: proc(arr: ^[dynamic]PhysicsObject, index: int) {
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

draw_scene :: proc(
	camera: rl.Camera2D,
	ball_pos: rl.Vector2,
	ball_rad: f32,
	rope: [dynamic]PhysicsObject,
	rope_length: int,
	pause: bool,
	framesCounter: int,
	enemies: [dynamic]PhysicsObject,
	score: int,
    rightClicking: ^bool
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
		rl.DrawCircle(i32(enemy.pos.x), i32(enemy.pos.y), ENEMY_RADIUS, ENEMY_COLOR)
	}

    // Calculate corner positions relative to the camera view
    screen_width := f32(rl.GetScreenWidth())
    screen_height := f32(rl.GetScreenHeight())
    top_left := camera.target - camera.offset / camera.zoom
    bottom_left := rl.Vector2{top_left.x, top_left.y + screen_height / camera.zoom}
    top_right := rl.Vector2{top_left.x + screen_width / camera.zoom, top_left.y}

    // Draw UI elements
    rl.DrawText("PRESS SPACE to PAUSE BALL MOVEMENT", i32(bottom_left.x) + 10, i32(bottom_left.y) - 25, 20, FG_COLOR)
    rl.DrawText("FPS: ", i32(top_left.x) + 10, i32(top_left.y) + 10, 20, FG_COLOR)
    fps_str := fmt.tprintf("%d", rl.GetFPS())
    rl.DrawText(cstring(raw_data(fps_str)), i32(top_left.x) + 60, i32(top_left.y) + 10, 20, FG_COLOR)
    rl.DrawText("SCORE: ", i32(top_right.x) - 150, i32(top_right.y) + 10, 20, rl.GREEN)
    score_str := fmt.tprintf("%d", score)
    rl.DrawText(cstring(raw_data(score_str)), i32(top_right.x) - 70, i32(top_right.y) + 10, 20, rl.GREEN)
    if rightClicking^ {
        rl.DrawText("RIGHT CLICKING", i32(top_right.x - 600) - 150, i32(top_right.y) + 10, 20, rl.GREEN)
    }

    if pause && (framesCounter / 30) % 2 != 0 {
        pause_text_pos := camera.target
        rl.DrawText("PAUSED", i32(pause_text_pos.x) - 50, i32(pause_text_pos.y), 30, FG_COLOR)
    }
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

	anchor := rl.Vector2{f32(rl.GetScreenWidth() / 2), 50}
	rest_length := REST_LENGTH
	rope := make([dynamic]PhysicsObject, rope_length)
	initialize_rope(rope, rope_length, anchor)

	enemies := make([dynamic]PhysicsObject, 0)
    boxes := make([dynamic]CollisionBox, 0)
	score := 0

	pause := true
	framesCounter := 0

	rl.SetTargetFPS(60)

	camera: rl.Camera2D
	cameraTarget := rl.Vector2{0,0}

	spawnInterval := 1.0 // Spawn interval in seconds
	lastSpawnTime := rl.GetTime()

    camera.zoom = 1.0 // Adjust this value for zoom in or out

	for !rl.WindowShouldClose() {
		if rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
			pause = !pause
		}
		if !pause {
			if leftClicking {
				rest_length = EXT_REST_LENGTH
				max_dist = EXT_ROPE_MAX_DIST
			} else {
				rest_length = REST_LENGTH
				max_dist = ROPE_MAX_DIST
			}
			handle_input(&player_targ, &leftClicking, &rightClicking, &enemies, &camera)
			update_ball_position(&ball_pos, &player_targ)
			update_rope(rope, ball_pos, f32(rest_length))
			update_tether(&rope, &ball_pos, &tether_pos, &leftClicking, max_dist, camera)
			update_enemies(&enemies) // Update enemies to move towards the player
			solve_collisions(&ball_pos, PLAYER_RADIUS, rope, TETHER_RADIUS, &enemies, ENEMY_RADIUS)
			rope[len(rope) - 1].pos +=
				(tether_pos - rope[len(rope) - 1].pos) / TETHER_LERP_FACTOR
            createBox(&rightClicking, &boxes)

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
            &rightClicking
		)
	}
}
