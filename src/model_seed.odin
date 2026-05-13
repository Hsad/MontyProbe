package monty

import "core:math"
import "core:math/linalg"

// Analytical sampling of world objects into the model database.
// This is the "ideal learning" shortcut — in a real scenario the player
// would have built these models in the Touch level. Here we pre-populate
// from ground truth so later levels work standalone.

// Sample points on a sphere surface using a fibonacci spiral
seed_sphere :: proc(db: ^Model_Database, name: cstring, radius: f32, mat: Surface_Material, n: int) {
	obj_idx := model_db_new_object(db, name)
	if obj_idx < 0 do return

	stored := Stored_Features{
		roughness   = mat.roughness,
		temperature = mat.temperature,
		color       = mat.color,
		mask        = {.Roughness, .Temperature, .Color},
	}

	phi := math.PI * (3 - math.sqrt(f32(5)))   // golden angle
	for i in 0..<n {
		y := 1 - (f32(i) / f32(n - 1)) * 2
		r := math.sqrt(1 - y * y)
		theta := phi * f32(i)
		x := math.cos(theta) * r
		z := math.sin(theta) * r

		normal := Vec3{x, y, z}
		loc    := normal * radius

		model_db_add_node(db, obj_idx, Graph_Node{
			location  = loc,
			normal    = normal,
			curvature = 1.0 / radius,
			features  = stored,
		})
	}
}

// Sample points on a cube surface
seed_cube :: proc(db: ^Model_Database, name: cstring, half: f32, mat: Surface_Material, per_face: int) {
	obj_idx := model_db_new_object(db, name)
	if obj_idx < 0 do return

	stored := Stored_Features{
		roughness   = mat.roughness,
		temperature = mat.temperature,
		color       = mat.color,
		mask        = {.Roughness, .Temperature, .Color},
	}

	faces := [6][2]Vec3{
		{{ 1,  0,  0}, { 0,  1,  0}},
		{{-1,  0,  0}, { 0,  1,  0}},
		{{ 0,  1,  0}, { 1,  0,  0}},
		{{ 0, -1,  0}, { 1,  0,  0}},
		{{ 0,  0,  1}, { 0,  1,  0}},
		{{ 0,  0, -1}, { 0,  1,  0}},
	}

	side := int(math.sqrt(f32(per_face)))
	if side < 2 do side = 2

	for f in faces {
		normal := f[0]
		up     := f[1]
		right  := linalg.cross(normal, up)

		for i in 0..<side {
			for j in 0..<side {
				u := (f32(i) / f32(side - 1)) * 2 - 1
				v := (f32(j) / f32(side - 1)) * 2 - 1
				loc := normal * half + right * u * half + up * v * half
				model_db_add_node(db, obj_idx, Graph_Node{
					location  = loc,
					normal    = normal,
					curvature = 0,
					features  = stored,
				})
			}
		}
	}
}

// Sample points on a cylinder (curved surface + top/bottom caps)
seed_cylinder :: proc(db: ^Model_Database, name: cstring, radius, half_h: f32, mat: Surface_Material, n_around, n_along: int) {
	obj_idx := model_db_new_object(db, name)
	if obj_idx < 0 do return

	stored := Stored_Features{
		roughness   = mat.roughness,
		temperature = mat.temperature,
		color       = mat.color,
		mask        = {.Roughness, .Temperature, .Color},
	}

	for ai in 0..<n_around {
		a := f32(ai) / f32(n_around) * 2 * math.PI
		cx := math.cos(a)
		cz := math.sin(a)
		for hi in 0..<n_along {
			h := (f32(hi) / f32(n_along - 1)) * 2 - 1
			loc := Vec3{cx * radius, h * half_h, cz * radius}
			model_db_add_node(db, obj_idx, Graph_Node{
				location  = loc,
				normal    = Vec3{cx, 0, cz},
				curvature = 1.0 / radius,
				features  = stored,
			})
		}
	}
}

// Populate the database with all world objects (used by drones level)
seed_world_objects :: proc(db: ^Model_Database, world: ^World) {
	model_db_init(db)
	for &obj in world.objects {
		switch obj.kind {
		case .Sphere:
			seed_sphere(db, obj.name, obj.size.x, obj.material, 24)
		case .Cube:
			seed_cube(db, obj.name, obj.size.x * 0.5, obj.material, 9)
		case .Cylinder:
			seed_cylinder(db, obj.name, obj.size.x, obj.size.y * 0.5, obj.material, 12, 3)
		case .Torus, .LShape:
			seed_sphere(db, obj.name, obj.size.x, obj.material, 16)
		}
	}
}
