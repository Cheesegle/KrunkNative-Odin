package main

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import gl "vendor:OpenGL"
import glfw "vendor:glfw"
import md "../minidump"
import menuui "../menu"

when ODIN_TEST {
	HANG_TEST_DIR :: "bin/test-hang"

	// The stalled "main loop" of the hang test, so the symbolicated stack has
	// a Krodin function to find.
	@(optimization_mode = "none")
	crash_test_hang_in_known_function :: proc(seconds: f64) {
		time.sleep(time.Duration(seconds * f64(time.Second)))
	}

	@(private = "file")
	Worker :: struct {
		stop: bool,
	}

	@(private = "file")
	worker_run :: proc(data: rawptr) {
		worker := (^Worker)(data)
		deadline := time.tick_now()
		for !sync.atomic_load(&worker.stop) && time.duration_seconds(time.tick_since(deadline)) < 30 {
			time.sleep(20 * time.Millisecond)
		}
	}

	@(private = "file")
	recovered_after :: proc(report: string) -> (seconds: f64, ok: bool) {
		marker := "recovered after "
		at := strings.index(report, marker)
		if at < 0 { return 0, false }
		rest := report[at + len(marker):]
		end := strings.index(rest, " s")
		if end < 0 { return 0, false }
		return strconv.parse_f64(rest[:end])
	}

	// A deliberately hung "main loop" (this test's thread) under the real
	// watchdog with short timings: hang.log + hang.dmp after 1 s, a second
	// dump after 2.5 s, "recovered after N s" when the loop resumes. The dump
	// must name Krodin's threads, hold only thread stacks (no heap: a token
	// placed on the heap must not be in it), stay small, and, when this test
	// binary has a PDB (built with -debug), symbolicate to Krodin names.
	when !KRODIN_VULKAN {
	@(test)
	crash_hang_dump_threads_memory_and_symbols :: proc(t: ^testing.T) {
		old_config, old_diag := g_crash_config, g_diag
		defer { g_crash_config, g_diag = old_config, old_diag }
		g_crash_config = {log_dir = HANG_TEST_DIR, hang_seconds = 1, second_dump_seconds = 2.5, poll_ms = 100}
		for name in ([]string{"hang.log", "hang.dmp", "hang-20s.dmp", "symbolicated.txt"}) { os.remove(fmt.tprintf("%s/%s", HANG_TEST_DIR, name)) }
		os.make_directory_all(HANG_TEST_DIR)

		// A token-like secret that exists only on the heap.
		secret_builder := strings.builder_make()
		defer strings.builder_destroy(&secret_builder)
		strings.write_string(&secret_builder, "KrodinHeapToken")
		HEX := "0123456789abcdef"
		for _ in 0 ..< 24 { strings.write_byte(&secret_builder, HEX[rand.int_max(16)]) }
		secret := strings.to_string(secret_builder)
		// And one in the environment block (UTF-16 in the process parameters,
		// which MiniDumpWithProcessThreadData saves and the scrub zeroes).
		env_secret := fmt.tprintf("KrodinEnvToken%d", rand.uint64())
		_ = os.set_env("KRODIN_TEST_DUMP_SECRET", env_secret)
		defer _ = os.unset_env("KRODIN_TEST_DUMP_SECRET")
		env_secret_utf16 := make([]u8, len(env_secret) * 2, context.temp_allocator)
		for c, i in transmute([]u8)env_secret { env_secret_utf16[i * 2] = c }

		diagnostics_name_thread("Krodin main (test)")
		worker := new(Worker)
		defer free(worker)
		worker_thread := thread.create_and_start_with_data(worker, worker_run, name = "Krodin test worker")
		defer {
			sync.atomic_store(&worker.stop, true)
			thread.join(worker_thread)
			thread.destroy(worker_thread)
		}

		// What the game captures at startup, so the sample report is complete.
		g_diag = {}
		if glfw.Init() {
			glfw.WindowHint(glfw.VISIBLE, glfw.FALSE)
			glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
			glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
			glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
			window, robust := client_create_window(64, 64, "Hang test", true)
			if window != nil {
				glfw.MakeContextCurrent(window)
				gl.load_up_to(4, 5, glfw.gl_set_proc_address)
				diagnostics_capture_gpu_info()
				g_diag.gl_robust_requested = robust
				glfw.DestroyWindow(window)
			}
			diagnostics_capture_monitors(nil)
			glfw.Terminate()
		}
		diagnostics_capture_system_info()
		client := new(Client)
		defer free(client)
		client.display_mode = .Fullscreen
		client.quality_settings = {shadows = true, lighting = i32(menuui.Lighting_Quality.NORMAL)}
		client.menu_fps_limit = menuui.MENU_FPS_LIMIT_MONITOR
		old_client := g_client
		g_client = client
		defer g_client = old_client
		for i in 0 ..< 150 { diag_frame_time(i % 40 == 0 ? 16.9 : 6.9) }
		diag_event(.FOCUS_GAINED)
		diag_event(.DISPLAY_MODE_APPLIED, i32(Display_Mode.Fullscreen), 1920 << 16 | 1080)
		diagnostics_watch(true, false)
		phase_frame_begin()
		phase_mark(.SWAP_BUFFERS)
		crash_handler_install()
		installed := true
		defer if installed { crash_handler_uninstall() }
		crash_test_hang_in_known_function(3.2)
		phase_frame_begin() // The loop resumes.
		hang_log := fmt.tprintf("%s/hang.log", HANG_TEST_DIR)
		report: string
		deadline := time.tick_now()
		for time.duration_seconds(time.tick_since(deadline)) < 3 {
			data, err := os.read_entire_file(hang_log, context.temp_allocator)
			if err == nil && strings.contains(string(data), "recovered after") { report = string(data); break }
			time.sleep(50 * time.Millisecond)
		}
		crash_handler_uninstall()
		installed = false
		testing.expect(t, sync.atomic_load(&g_diag.gl_reset_check_requested), "recovery asks the main loop for a GPU reset check")

		testing.expectf(t, strings.contains(report, "Krodin hang report") && strings.contains(report, "== System ==") && strings.contains(report, "== Recent frames ==") && strings.contains(report, "Display mode: Fullscreen") && strings.contains(report, "Windows: ") && strings.contains(report, "Display adapters:"), "hang.log:\n%s", report)
		testing.expectf(t, strings.contains(report, "== Still not responding ==") && strings.contains(report, "hang-20s.dmp"), "the second dump is noted:\n%s", report)
		seconds, ok := recovered_after(report)
		testing.expectf(t, ok && seconds >= 2.9 && seconds < 5, "recovery time %v (ok %v):\n%s", seconds, ok, report)
		testing.expect(t, !strings.contains(report, secret))

		for name in ([]string{"hang.dmp", "hang-20s.dmp"}) {
			path := fmt.tprintf("%s/%s", HANG_TEST_DIR, name)
			data, err := os.read_entire_file(path, context.allocator)
			if !testing.expectf(t, err == nil, "%s must exist", path) do continue
			defer delete(data)
			testing.expectf(t, len(data) < 2 * 1024 * 1024, "%s is %d bytes; dumps stay under 2 MB", name, len(data))
			testing.expectf(t, !strings.contains(string(data), secret), "%s contains heap memory (the test token)", name)
			testing.expectf(t, !strings.contains(string(data), string(env_secret_utf16)), "%s contains the environment block", name)
			dump, parsed := md.parse(data)
			if !testing.expectf(t, parsed, "%s must parse", name) do continue
			defer md.destroy(&dump)
			testing.expect(t, dump.has_thread_names, "the dump has a ThreadNamesStream")
			names := make([dynamic]string, context.temp_allocator)
			for thread in dump.threads { append(&names, thread.name) }
			for expected in ([]string{"Krodin main (test)", "Krodin test worker", "Krodin hang watchdog"}) {
				found := false
				for n in names { if n == expected { found = true } }
				testing.expectf(t, found, "%s: thread %q missing from %v", name, expected, names[:])
			}
			for stream in ([]u32{md.STREAM_THREAD_INFO_LIST, md.STREAM_HANDLE_DATA, md.STREAM_MEMORY_INFO_LIST}) {
				testing.expectf(t, md.has_stream(&dump, stream), "%s: stream %d missing", name, stream)
			}
			// Saved memory with contents is thread stacks, plus code bytes inside
			// modules and the fixed OS structures (TEB header, PEB,
			// KUSER_SHARED_DATA). Anything else (process parameters, the
			// environment, heap) is zeroed by the scrub.
			stack_bytes, code_bytes, os_bytes, leaked_bytes: u64
			for r in dump.memory {
				if md.stack_owner(&dump, r.start, r.size) != nil { stack_bytes += r.size; continue }
				if module := md.module_for(&dump, r.start); module != nil && r.start + r.size <= module.base + u64(module.size) { code_bytes += r.size; continue }
				// Per byte: TEB headers, the PEB and KUSER_SHARED_DATA may keep
				// their contents; every other byte must be zero.
				leaked_here: u64
				for i in 0 ..< r.size {
					if data[r.rva + i] == 0 { continue }
					address := r.start + i
					allowed := address >= md.KUSER_SHARED_DATA && address < md.KUSER_SHARED_DATA + 0x1000
					for thread in dump.threads {
						if allowed { break }
						if address >= thread.teb && address < thread.teb + md.SCRUB_TEB_KEEP { allowed = true; break }
						peb_bytes: [8]u8
						if md.read_memory(&dump, thread.teb + md.TEB_PEB_OFFSET, peb_bytes[:]) {
							peb := transmute(u64)peb_bytes
							if address >= peb && address < peb + md.SCRUB_PEB_KEEP { allowed = true }
						}
					}
					if allowed { os_bytes += 1 } else { leaked_here += 1 }
				}
				if leaked_here > 0 {
					leaked_bytes += leaked_here
					log.errorf("%s: %d non-zero bytes in a non-stack range 0x%X (+%d)", name, leaked_here, r.start, r.size)
				}
			}
			testing.expectf(t, leaked_bytes == 0, "%s: %d bytes of memory beyond thread stacks", name, leaked_bytes)
			testing.expectf(t, os_bytes <= 0x1000 * u64(2 + len(dump.threads)), "%s: %d bytes of TEB/PEB contents", name, os_bytes)
			log.infof("%s: %d code bytes near instruction pointers, %d bytes of TEB headers/PEB/shared data", name, code_bytes, os_bytes)
			log.infof("%s: %d bytes, %d threads, %d modules, %d bytes of stacks", name, len(data), len(dump.threads), len(dump.modules), stack_bytes)

			if name != "hang.dmp" { continue }
			exe_dir := filepath.dir(os.args[0])
			pdb := strings.concatenate({strings.trim_suffix(os.args[0], ".exe"), ".pdb"}, context.temp_allocator)
			if !os.exists(pdb) {
				log.infof("No PDB next to the test binary (%s); build with -debug to check symbolication", pdb)
				continue
			}
			absolute, _ := filepath.abs(exe_dir, context.temp_allocator)
			b := strings.builder_make(context.temp_allocator)
			result := md.symbolicate(&dump, {absolute}, &b)
			text := strings.to_string(b)
			_ = os.write_entire_file(fmt.tprintf("%s/symbolicated.txt", HANG_TEST_DIR), transmute([]u8)text)
			testing.expectf(t, strings.contains(text, "crash_test_hang_in_known_function"), "the hung frame is named:\n%s", text)
			testing.expectf(t, strings.contains(text, "crash_hang_dump_threads_memory_and_symbols"), "its caller is named:\n%s", text)
			testing.expectf(t, strings.contains(text, "crash_dump_windows_test.odin:"), "file:line is resolved:\n%s", text)
			testing.expectf(t, strings.contains(text, "\"Krodin hang watchdog\""), "thread names are printed:\n%s", text)
			testing.expect(t, result.krodin_frames > 2 && result.named_threads >= 3)
		}
	}
	} // GL-only test (OpenGL state or contexts)

	@(test)
	crash_dump_type_has_no_heap_flags :: proc(t: ^testing.T) {
		testing.expect_value(t, u32(CRASH_DUMP_TYPE) & CRASH_DUMP_FORBIDDEN_FLAGS, u32(0))
		testing.expect_value(t, u32(CRASH_DUMP_TYPE), u32(0x1000 | 0x20 | 0x4 | 0x800 | 0x100))
	}
}
