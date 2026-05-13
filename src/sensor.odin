package monty

// The Cortical Messaging Protocol — Monty's universal data format.
// Every sensor, regardless of modality, produces CMP messages.
// "Features at a pose" — this is the atomic unit of the whole system.

CMP_Message :: struct {
	location:    Vec3,     // where in world this was sensed
	orientation: Vec3,     // surface normal or probe direction
	features:    Features, // what was sensed (modality-dependent)
	confidence:  f32,      // [0, 1]
}

Features :: struct {
	brightness:  Maybe(f32),
	temperature: Maybe(f32),
	roughness:   Maybe(f32),
	color:       Maybe(Vec3),
	smell:       Maybe(f32),
	resonance:   Maybe(f32),
}
