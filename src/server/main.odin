package server_main

// Krodin dedicated server entry point. Everything lives in the `dedicated`
// package so the tests can drive the same code (settings, rotation, ticks,
// networking) without starting a process.

import "core:os"

import "dedicated"

main :: proc() {
	os.exit(dedicated.run(os.args[1:]))
}
