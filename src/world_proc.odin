package monty

import "core:math"
import "core:math/linalg"

// Procedural infinite world used by the Sandbox level.
//
// Objects are placed on a 2D grid of cells. Each cell is hashed
// deterministically from its (x, z) integer coords; that hash decides
// whether the cell holds an object, which archetype, the jitter within
// the cell, etc. Same coords → same object every time, so the world is
// reproducible and you can fly back to find the same things.
//
// Streaming: each frame we add objects for any in-view cell that doesn't
// already have one, and remove objects whose cell has scrolled out of
// range. Memory stays bounded — only objects near the player exist.

PROC_CELL_SIZE   :: f32(10)
PROC_VIEW_RADIUS :: f32(38)
PROC_DENSITY     :: 30   // percent of cells that contain an object
PROC_BUFFER      :: f32(6)

@(private = "file")
hash_2d :: proc(x, z: i32) -> u32 {
	h := u32(x) * 73856093 ~ u32(z) * 19349663
	h ~= h >> 13
	h *= 0x5bd1e995
	h ~= h >> 15
	h *= 0x27d4eb2d
	h ~= h >> 15
	return h
}

Proc_Archetype :: struct {
	name:     cstring,
	kind:     Object_Kind,
	size:     f32,
	material: Surface_Material,
}

// Six archetypes — each distinct on multiple feature dimensions so that
// any sensor modality has something to discriminate by
proc_archetypes := [6]Proc_Archetype{
	{
		name = "Iron Asteroid",
		kind = .Sphere,
		size = 2.4,
		material = {roughness = 0.75, temperature = 0.65, color = {0.62, 0.32, 0.18},
		            smell = 0.30, chem_sig = {0.85, 0.10, 0.10}, resonance = 0.92},
	},
	{
		name = "Ice Boulder",
		kind = .Sphere,
		size = 2.0,
		material = {roughness = 0.18, temperature = 0.05, color = {0.72, 0.85, 0.98},
		            smell = 0.05, chem_sig = {0.05, 0.10, 0.90}, resonance = 0.22},
	},
	{
		name = "Crystal Spire",
		kind = .Cylinder,
		size = 1.4,
		material = {roughness = 0.10, temperature = 0.15, color = {0.55, 0.90, 1.00},
		            smell = 0.00, chem_sig = {0.05, 0.30, 0.85}, resonance = 0.70},
	},
	{
		name = "Lava Rock",
		kind = .Sphere,
		size = 1.9,
		material = {roughness = 0.60, temperature = 0.95, color = {0.95, 0.40, 0.10},
		            smell = 0.70, chem_sig = {0.80, 0.50, 0.10}, resonance = 0.50},
	},
	{
		name = "Methane Pocket",
		kind = .Sphere,
		size = 1.7,
		material = {roughness = 0.08, temperature = 0.40, color = {0.55, 0.85, 0.35},
		            smell = 0.95, chem_sig = {0.20, 0.95, 0.20}, resonance = 0.15},
	},
	{
		name = "Metal Debris",
		kind = .Cube,
		size = 1.5,
		material = {roughness = 0.40, temperature = 0.20, color = {0.72, 0.72, 0.78},
		            smell = 0.10, chem_sig = {0.50, 0.20, 0.30}, resonance = 0.97},
	},
}

// Pre-load all archetypes into the model database so the LM can
// recognise any object you encounter in the procedural world
seed_proc_archetypes :: proc(db: ^Model_Database) {
	model_db_init(db)
	for &arch in proc_archetypes {
		switch arch.kind {
		case .Sphere:
			seed_sphere(db, arch.name, arch.size, arch.material, 24)
		case .Cube:
			seed_cube(db, arch.name, arch.size * 0.5, arch.material, 9)
		case .Cylinder:
			seed_cylinder(db, arch.name, arch.size, arch.size * 1.5, arch.material, 12, 3)
		case .Torus, .LShape:
			seed_sphere(db, arch.name, arch.size, arch.material, 16)
		}
	}
}

// Streaming update — call each frame from the Sandbox level
world_proc_update :: proc(world: ^World, center: Vec3) {
	// 1. Remove objects whose cell has scrolled out of view
	for i := len(world.objects) - 1; i >= 0; i -= 1 {
		if linalg.distance(world.objects[i].pos, center) > PROC_VIEW_RADIUS + PROC_BUFFER {
			ordered_remove(&world.objects, i)
		}
	}

	// 2. Walk every cell that should be in view; spawn the cell's object
	//    if it has one and isn't already present
	radius_cells := i32(math.ceil(PROC_VIEW_RADIUS / PROC_CELL_SIZE)) + 1
	cx := i32(math.floor(center.x / PROC_CELL_SIZE))
	cz := i32(math.floor(center.z / PROC_CELL_SIZE))

	for dz in -radius_cells..=radius_cells {
		for dx in -radius_cells..=radius_cells {
			cell_x := cx + dx
			cell_z := cz + dz
			cell_center := Vec3{
				f32(cell_x) * PROC_CELL_SIZE + PROC_CELL_SIZE * 0.5,
				0,
				f32(cell_z) * PROC_CELL_SIZE + PROC_CELL_SIZE * 0.5,
			}
			if linalg.distance(cell_center, center) > PROC_VIEW_RADIUS do continue

			h := hash_2d(cell_x, cell_z)
			if int(h % 100) >= PROC_DENSITY do continue

			// Already represented?
			already := false
			for &existing in world.objects {
				if existing.cell_x == cell_x && existing.cell_z == cell_z {
					already = true
					break
				}
			}
			if already do continue

			// Pick archetype + jitter position within the cell
			arch_idx := int((h >> 8) % u32(len(proc_archetypes)))
			arch := &proc_archetypes[arch_idx]

			jitter_x := (f32((h >> 16) & 0xFF) / 255.0 - 0.5) * (PROC_CELL_SIZE * 0.5)
			jitter_z := (f32((h >> 24) & 0xFF) / 255.0 - 0.5) * (PROC_CELL_SIZE * 0.5)

			append(&world.objects, World_Object{
				kind     = arch.kind,
				pos      = Vec3{
					f32(cell_x) * PROC_CELL_SIZE + PROC_CELL_SIZE * 0.5 + jitter_x,
					0,
					f32(cell_z) * PROC_CELL_SIZE + PROC_CELL_SIZE * 0.5 + jitter_z,
				},
				size     = Vec3{arch.size, arch.size, arch.size},
				material = arch.material,
				name     = arch.name,
				cell_x   = cell_x,
				cell_z   = cell_z,
			})
		}
	}
}

// Find the archetype index for a given object (matched by name)
proc_archetype_index :: proc(name: cstring) -> int {
	for i in 0..<len(proc_archetypes) {
		if proc_archetypes[i].name == name do return i
	}
	return -1
}
