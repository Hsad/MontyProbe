package monty

import rl "vendor:raylib"
import "core:math/linalg"

Vec3 :: [3]f32
Vec2 :: [2]f32
Color :: rl.Color

MAX_TRAIL :: 2000
MAX_DRONES :: 8

Ship :: struct {
	pos:       Vec3,
	vel:       Vec3,
	heading:   f32,           // yaw in radians
	pitch:     f32,
	speed:     f32,
	trail:     [dynamic]Vec3, // displacement history
	drones:    [MAX_DRONES]Drone,
	drone_count: int,
	sensors:   Sensor_Set,
}

// Bitset of which sensors the ship has earned
Sensor_Set :: bit_set[Sensor_Kind]

Sensor_Kind :: enum {
	Proprioception,
	Chemical,
	Light_Probe,
	Contact,
	Range,
	Optic_Array,
	Sonar,
}

Drone :: struct {
	active:   bool,
	pos:      Vec3,
	vel:      Vec3,
	heading:  f32,
	sensors:  Sensor_Set,
	trail:    [dynamic]Vec3,
}

ship_init :: proc(ship: ^Ship) {
	ship.pos = {0, 0, 0}
	ship.vel = {0, 0, 0}
	ship.heading = 0
	ship.pitch = 0
	ship.speed = 0
	ship.trail = make([dynamic]Vec3, 0, MAX_TRAIL)
	ship.drone_count = 0
	ship.sensors = {.Proprioception}
}

ship_cleanup :: proc(ship: ^Ship) {
	delete(ship.trail)
	for i in 0..<ship.drone_count {
		if ship.drones[i].active {
			delete(ship.drones[i].trail)
		}
	}
}

ship_forward :: proc(ship: ^Ship) -> Vec3 {
	return {
		linalg.cos(ship.pitch) * linalg.sin(ship.heading),
		linalg.sin(ship.pitch),
		linalg.cos(ship.pitch) * linalg.cos(ship.heading),
	}
}

ship_update :: proc(ship: ^Ship, dt: f32) {
	fwd := ship_forward(ship)
	ship.vel = fwd * ship.speed
	ship.pos += ship.vel * dt

	// Record trail
	if len(ship.trail) == 0 || linalg.distance(ship.pos, ship.trail[len(ship.trail) - 1]) > 0.1 {
		if len(ship.trail) >= MAX_TRAIL {
			ordered_remove(&ship.trail, 0)
		}
		append(&ship.trail, ship.pos)
	}
}

ship_draw :: proc(ship: ^Ship) {
	fwd := ship_forward(ship)

	// Ship body — simple triangle/cone shape
	tip := ship.pos + fwd * 1.0
	left := ship.pos + Vec3{-fwd.z, 0, fwd.x} * 0.4 - fwd * 0.5
	right := ship.pos + Vec3{fwd.z, 0, -fwd.x} * 0.4 - fwd * 0.5
	top := ship.pos + Vec3{0, 0.3, 0} - fwd * 0.3

	rl.DrawTriangle3D(tip, left, right, Color{100, 180, 255, 255})
	rl.DrawTriangle3D(tip, right, top, Color{70, 130, 200, 255})
	rl.DrawTriangle3D(tip, top, left, Color{70, 130, 200, 255})
	rl.DrawTriangle3D(left, top, right, Color{50, 100, 170, 255})

	// Engine glow
	if ship.speed > 0.1 {
		engine_pos := ship.pos - fwd * 0.6
		rl.DrawSphere(engine_pos, 0.15, Color{255, 150, 50, 200})
	}
}

ship_draw_trail :: proc(ship: ^Ship) {
	if len(ship.trail) < 2 do return
	for i in 1..<len(ship.trail) {
		alpha := u8(f32(i) / f32(len(ship.trail)) * 180)
		rl.DrawLine3D(ship.trail[i - 1], ship.trail[i], Color{100, 180, 255, alpha})
	}
}
