package symbolicate

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import md "../../src/minidump"

// Prints every thread of a Krodin crash or hang dump with function names and
// file:line, using the build's archived symbols.
//
//   odin build tools/symbolicate -out:bin/krodin_symbolicate.exe
//   bin\krodin_symbolicate.exe logs\hang.dmp dist\symbols\<commit>
//
// The symbols folder holds the krodin_client.exe and krodin_client.pdb that
// package-windows.ps1 archived for the tester zip the dump came from (the zip
// name ends in the same commit). With no folder, the dump's own directory and
// bin\ are searched.

main :: proc() {
	if len(os.args) < 2 || os.args[1] == "-h" || os.args[1] == "--help" {
		fmt.eprintln("Usage: krodin_symbolicate <dump.dmp> [symbols folder ...]")
		fmt.eprintln("The symbols folder is dist\\symbols\\<commit> (krodin_client.exe + krodin_client.pdb).")
		os.exit(2)
	}
	dump_path := os.args[1]
	data, err := os.read_entire_file(dump_path, context.allocator)
	if err != nil {
		fmt.eprintf("Cannot read %s: %v\n", dump_path, err)
		os.exit(1)
	}
	dump, ok := md.parse(data)
	if !ok {
		fmt.eprintf("%s is not a minidump\n", dump_path)
		os.exit(1)
	}
	defer md.destroy(&dump)

	dirs := make([dynamic]string)
	for arg in os.args[2:] {
		absolute, _ := filepath.abs(arg, context.allocator)
		append(&dirs, absolute)
	}
	if len(dirs) == 0 {
		dump_dir, _ := filepath.abs(filepath.dir(dump_path), context.allocator)
		bin_dir, _ := filepath.abs("bin", context.allocator)
		append(&dirs, dump_dir, bin_dir)
	}
	b := strings.builder_make()
	fmt.sbprintf(&b, "Dump: %s (%d bytes)\nSymbols: %s\n", dump_path, len(data), strings.join(dirs[:], "; ", context.temp_allocator))
	result := md.symbolicate(&dump, dirs[:], &b)
	fmt.print(strings.to_string(b))
	if result.krodin_frames == 0 {
		fmt.eprintln("\nNo Krodin function names were resolved: check that the symbols folder matches the build that wrote the dump.")
		os.exit(3)
	}
}
