package monty

import "core:os"
import "core:fmt"
import "core:mem"

SAVE_MAGIC   :: u32(0x4D4E5459) // "MNTY"
SAVE_VERSION :: u32(1)

Save_Data :: struct #packed {
	magic:            u32,
	version:          u32,
	levels_unlocked:  bit_set[Level_ID; u16],
	levels_completed: bit_set[Level_ID; u16],
	sensors:          bit_set[Sensor_Kind; u16],
	selected_level:   u8,
}

@(private = "file")
get_home :: proc() -> string {
	home := os.get_env_alloc("HOME", context.allocator)
	if home == "" do return "."
	return home
}

@(private = "file")
get_save_path :: proc() -> string {
	home := get_home()
	return fmt.tprintf("%s/.local/share/monty/save.dat", home)
}

@(private = "file")
get_save_dir :: proc() -> string {
	home := get_home()
	return fmt.tprintf("%s/.local/share/monty", home)
}

save_write :: proc(game: ^Game_State) {
	os.make_directory(get_save_dir())

	data := Save_Data{
		magic          = SAVE_MAGIC,
		version        = SAVE_VERSION,
		selected_level = u8(game.selected_level),
	}
	for i in 0..<LEVEL_COUNT {
		id := Level_ID(i)
		if game.levels[id].unlocked  { data.levels_unlocked  += {id} }
		if game.levels[id].completed { data.levels_completed += {id} }
	}
	for sk in Sensor_Kind {
		if sk in game.ship.sensors { data.sensors += {sk} }
	}

	bytes := ([^]u8)(&data)[:size_of(Save_Data)]
	_ = os.write_entire_file(get_save_path(), bytes)
}

save_load :: proc(game: ^Game_State) -> bool {
	data_bytes, err := os.read_entire_file_from_path(get_save_path(), context.allocator)
	if err != nil do return false
	defer delete(data_bytes)

	if len(data_bytes) < size_of(Save_Data) do return false

	data: Save_Data
	mem.copy(&data, raw_data(data_bytes), size_of(Save_Data))

	if data.magic != SAVE_MAGIC || data.version != SAVE_VERSION do return false

	for i in 0..<LEVEL_COUNT {
		id := Level_ID(i)
		game.levels[id].unlocked  = id in data.levels_unlocked
		game.levels[id].completed = id in data.levels_completed
	}
	game.levels[Level_ID.Motion].unlocked = true // always unlocked

	game.ship.sensors = {.Proprioception}
	for sk in Sensor_Kind {
		if sk in data.sensors { game.ship.sensors += {sk} }
	}

	if int(data.selected_level) < LEVEL_COUNT {
		game.selected_level = Level_ID(data.selected_level)
	}
	return true
}

save_reset :: proc(game: ^Game_State) {
	_ = os.remove(get_save_path())

	for i in 0..<LEVEL_COUNT {
		id := Level_ID(i)
		game.levels[id].unlocked  = (id == .Motion)
		game.levels[id].completed = false
	}
	game.ship.sensors   = {.Proprioception}
	game.selected_level = .Motion
}
