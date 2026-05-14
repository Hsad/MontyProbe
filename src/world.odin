package monty

import rl "vendor:raylib"

// The shared world — same objects across all levels.
// What changes is how you perceive them.

Object_Kind :: enum {
	Sphere,
	Cube,
	Cylinder,
	Torus,
	LShape,
}

// 3 chemical channels — each object has a unique "scent signature"
// Think of these as distinct molecular receptors on the sensor
CHEM_CHANNELS :: 3

Chem_Signature :: [CHEM_CHANNELS]f32

Surface_Material :: struct {
	roughness:   f32,
	temperature: f32,
	color:       Vec3,
	smell:       f32,           // overall emission strength
	chem_sig:    Chem_Signature, // per-channel chemical profile [0-1]
	resonance:   f32,           // sound reflectivity
}

World_Object :: struct {
	kind:     Object_Kind,
	pos:      Vec3,
	size:     Vec3,
	rotation: f32,
	material: Surface_Material,
	name:     cstring,
	// Procedural streaming: which (cell_x, cell_z) this object owns
	cell_x:   i32,
	cell_z:   i32,
}

World :: struct {
	objects:   [dynamic]World_Object,
	bounds:    f32, // half-size of play area
}

world_init :: proc(world: ^World) {
	world.bounds = 30
	world.objects = make([dynamic]World_Object, 0, 16)

	// Populate with a few objects scattered in space
	// Each object has a unique chemical signature across 3 channels:
	//   Channel 0 (Red/Sulfur):   volcanic/metallic compounds
	//   Channel 1 (Green/Organic): biological/carbon compounds
	//   Channel 2 (Blue/Ice):      water/crystal compounds
	// The mixture at any point is the sum of all nearby signatures,
	// weighted by distance — this is what the sensor reads.

	append(&world.objects, World_Object{
		kind = .Sphere,
		pos  = {8, 0, -5},
		size = {2, 2, 2},
		material = {roughness = 0.3, temperature = 0.5, color = {0.8, 0.3, 0.2}, smell = 0.8, chem_sig = {0.9, 0.1, 0.2}, resonance = 0.4},
		name = "Asteroid Alpha",
	})
	append(&world.objects, World_Object{
		kind = .Cube,
		pos  = {-10, 0, 8},
		size = {2.5, 2.5, 2.5},
		material = {roughness = 0.9, temperature = 0.2, color = {0.3, 0.7, 0.4}, smell = 0.6, chem_sig = {0.1, 0.9, 0.3}, resonance = 0.9},
		name = "Cargo Crate",
	})
	append(&world.objects, World_Object{
		kind = .Cylinder,
		pos  = {5, 0, 12},
		size = {1.5, 4, 1.5},
		material = {roughness = 0.1, temperature = 0.8, color = {0.9, 0.8, 0.2}, smell = 0.7, chem_sig = {0.6, 0.6, 0.1}, resonance = 0.6},
		name = "Fuel Tank",
	})
	append(&world.objects, World_Object{
		kind = .Sphere,
		pos  = {-6, 0, -12},
		size = {3, 3, 3},
		material = {roughness = 0.6, temperature = 0.1, color = {0.4, 0.4, 0.8}, smell = 0.5, chem_sig = {0.1, 0.2, 0.9}, resonance = 0.3},
		name = "Ice Rock",
	})
	append(&world.objects, World_Object{
		kind = .Cube,
		pos  = {15, 0, 0},
		size = {1.5, 3, 1.5},
		material = {roughness = 0.5, temperature = 0.9, color = {0.9, 0.2, 0.5}, smell = 0.9, chem_sig = {0.8, 0.3, 0.7}, resonance = 0.7},
		name = "Beacon",
	})
}

world_cleanup :: proc(world: ^World) {
	delete(world.objects)
}

// Draw world objects — but only if the level allows it (e.g., level 0 = invisible)
world_draw :: proc(world: ^World, visible: bool) {
	// Always draw a faint grid for spatial reference
	for i in -30..=30 {
		alpha: u8 = 20
		fi := f32(i)
		rl.DrawLine3D({fi, -0.5, -30}, {fi, -0.5, 30}, Color{40, 40, 60, alpha})
		rl.DrawLine3D({-30, -0.5, fi}, {30, -0.5, fi}, Color{40, 40, 60, alpha})
	}

	if !visible do return

	for &obj in world.objects {
		c := Color{
			u8(obj.material.color.x * 255),
			u8(obj.material.color.y * 255),
			u8(obj.material.color.z * 255),
			255,
		}
		switch obj.kind {
		case .Sphere:
			rl.DrawSphere(obj.pos, obj.size.x, c)
			rl.DrawSphereWires(obj.pos, obj.size.x, 8, 8, Color{255, 255, 255, 40})
		case .Cube:
			rl.DrawCube(obj.pos, obj.size.x, obj.size.y, obj.size.z, c)
			rl.DrawCubeWires(obj.pos, obj.size.x, obj.size.y, obj.size.z, Color{255, 255, 255, 40})
		case .Cylinder:
			rl.DrawCylinder(obj.pos, obj.size.x, obj.size.x, obj.size.y, 12, c)
		case .Torus, .LShape:
			rl.DrawSphere(obj.pos, obj.size.x, c) // placeholder
		}
	}
}
