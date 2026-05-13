package monty

import "core:math/linalg"

// Object graph — Monty's long-term memory.
// Each object is stored as a sparse 3D graph:
//   nodes = pose + features at sampled surface points
//   identity = the collection of these nodes, not any single one
//
// During recognition, the LM asks:
//   "If I were at node N on object O with rotation R,
//    and moved by displacement D, where should I be now?
//    Are the features there consistent with what I sense?"

MAX_GRAPH_NODES :: 512
MAX_OBJECTS     :: 32
MIN_NODE_SPACING :: 0.15  // reject nodes closer than this in model space

// Features stored at each graph node
Stored_Features :: struct {
    roughness:   f32,
    temperature: f32,
    color:       Vec3,
    chem:        Chem_Signature,
    mask:        Stored_Feature_Mask,
}

Stored_Feature_Mask :: bit_set[Stored_Feature_Kind; u8]
Stored_Feature_Kind :: enum u8 { Roughness, Temperature, Color, Chemical }

Graph_Node :: struct {
    location:  Vec3,           // position in object-local frame
    normal:    Vec3,           // surface normal (point normal)
    curvature: f32,            // curvature magnitude
    features:  Stored_Features,
}

Object_Graph :: struct {
    name:       cstring,
    nodes:      [MAX_GRAPH_NODES]Graph_Node,
    node_count: int,
}

Model_Database :: struct {
    objects:      [MAX_OBJECTS]Object_Graph,
    object_count: int,
}

model_db_init :: proc(db: ^Model_Database) {
    db.object_count = 0
}

model_db_new_object :: proc(db: ^Model_Database, name: cstring) -> int {
    if db.object_count >= MAX_OBJECTS do return -1
    idx := db.object_count
    db.objects[idx] = {}
    db.objects[idx].name = name
    db.object_count += 1
    return idx
}

// Add a node, skipping if too close to an existing one (deduplication)
model_db_add_node :: proc(db: ^Model_Database, obj_idx: int, node: Graph_Node) -> bool {
    obj := &db.objects[obj_idx]
    if obj.node_count >= MAX_GRAPH_NODES do return false

    for i in 0..<obj.node_count {
        if linalg.distance(obj.nodes[i].location, node.location) < MIN_NODE_SPACING {
            return false
        }
    }
    obj.nodes[obj.node_count] = node
    obj.node_count += 1
    return true
}

// Linear nearest-neighbour search — correct and fast enough for <512 nodes
model_nearest_node :: proc(obj: ^Object_Graph, query: Vec3, max_dist: f32) -> (idx: int, dist: f32) {
    idx = -1
    dist = max_dist + 1

    for i in 0..<obj.node_count {
        d := linalg.distance(obj.nodes[i].location, query)
        if d < dist {
            dist = d
            idx = i
        }
    }

    if idx >= 0 && dist <= max_dist do return idx, dist
    return -1, dist
}

// Convert live CMP features → stored features
features_to_stored :: proc(f: Features) -> Stored_Features {
    s: Stored_Features
    if r, ok := f.roughness.?;   ok { s.roughness    = r; s.mask += {.Roughness}    }
    if t, ok := f.temperature.?; ok { s.temperature  = t; s.mask += {.Temperature}  }
    if c, ok := f.color.?;       ok { s.color        = c; s.mask += {.Color}        }
    return s
}
