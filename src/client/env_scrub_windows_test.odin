package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import win "core:sys/windows"
import kproto "../krunker"

when ODIN_TEST {
	ENV_SCRUB_TEST_NAME :: "KRODIN_TEST_FAKE_TOKEN"
	ENV_SCRUB_TEST_VALUE :: "KRODIN_TEST_FAKE_TOKEN_VALUE_123"
	ENV_SCRUB_TEST_KEEP :: "KRODIN_TEST_KEEP_ME"
	ENV_SCRUB_TEST_DIR :: "bin/test-env-scrub"

	@(private = "file")
	Saved_Env :: struct { name, value: string }

	// The test process's own secret-named variables, put back afterwards.
	@(private = "file")
	env_scrub_test_save :: proc() -> [dynamic]Saved_Env {
		saved := make([dynamic]Saved_Env, context.temp_allocator)
		all, _ := os.environ(context.temp_allocator)
		for entry in all {
			if len(entry) < 2 { continue }
			eq := strings.index_byte(entry[1:], '=') + 1
			if eq <= 0 || !env_name_is_secret(entry[:eq]) { continue }
			append(&saved, Saved_Env{entry[:eq], entry[eq + 1:]})
		}
		return saved
	}

	@(private = "file")
	env_scrub_test_restore :: proc(saved: [dynamic]Saved_Env) {
		for s in saved { _ = os.set_env(s.name, s.value) }
		_ = os.unset_env(ENV_SCRUB_TEST_NAME)
		_ = os.unset_env(ENV_SCRUB_TEST_KEEP)
	}

	@(private = "file")
	utf16_bytes :: proc(s: string) -> string {
		out := make([]u8, len(s) * 2, context.temp_allocator)
		for c, i in transmute([]u8)s { out[i * 2] = c }
		return string(out)
	}

	// A raw MiniDumpWriteDump of this process with CRASH_DUMP_TYPE and no
	// minidump.scrub pass, so only the environment scrub can keep values out.
	@(private = "file")
	env_scrub_test_raw_dump :: proc(path: string) -> (data: []u8, ok: bool) {
		os.make_directory_all(ENV_SCRUB_TEST_DIR)
		os.remove(path)
		wide := win.utf8_to_wstring(path, context.temp_allocator)
		file := win.CreateFileW(wide, win.GENERIC_READ | win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
		if file == win.INVALID_HANDLE_VALUE { return nil, false }
		written := bool(win.MiniDumpWriteDump(win.GetCurrentProcess(), win.GetCurrentProcessId(), file, CRASH_DUMP_TYPE, nil, nil, nil))
		win.CloseHandle(file)
		if !written { return nil, false }
		bytes, err := os.read_entire_file(path, context.temp_allocator)
		return bytes, err == nil
	}

	@(test)
	env_scrub_removes_secret_variables_and_keeps_others :: proc(t: ^testing.T) {
		saved := env_scrub_test_save()
		defer env_scrub_test_restore(saved)
		testing.expect(t, os.set_env(ENV_SCRUB_TEST_NAME, ENV_SCRUB_TEST_VALUE) == nil)
		testing.expect(t, os.set_env(ENV_SCRUB_TEST_KEEP, "plain value") == nil)
		path_before, path_ok := os.lookup_env_alloc("PATH", context.temp_allocator)

		names: [dynamic]string
		defer { for n in names { delete(n) }; delete(names) }
		env_scrub_secrets(&names)

		found := false
		for n in names {
			if n == ENV_SCRUB_TEST_NAME { found = true }
			testing.expectf(t, env_name_is_secret(n), "%q removed but not secret", n)
		}
		testing.expectf(t, found, "%s not in removed names %v", ENV_SCRUB_TEST_NAME, names[:])
		_, still := os.lookup_env_alloc(ENV_SCRUB_TEST_NAME, context.temp_allocator)
		testing.expect(t, !still, "the secret variable is gone")
		keep, kept := os.lookup_env_alloc(ENV_SCRUB_TEST_KEEP, context.temp_allocator)
		testing.expect(t, kept && keep == "plain value", "other variables are kept")
		path_after, path_after_ok := os.lookup_env_alloc("PATH", context.temp_allocator)
		testing.expect(t, path_ok == path_after_ok && path_before == path_after, "PATH is untouched")
		all, _ := os.environ(context.temp_allocator)
		for entry in all {
			if len(entry) < 2 { continue }
			eq := strings.index_byte(entry[1:], '=') + 1
			if eq > 0 { testing.expectf(t, !env_name_is_secret(entry[:eq]), "%q survived the scrub", entry[:eq]) }
			testing.expect(t, !strings.contains(entry, ENV_SCRUB_TEST_VALUE))
		}
	}

	@(test)
	env_scrub_logs_names_never_values :: proc(t: ^testing.T) {
		saved := env_scrub_test_save()
		defer env_scrub_test_restore(saved)
		previous_log := kproto.network_log_path
		log_path := ENV_SCRUB_TEST_DIR + "/network.log"
		os.make_directory_all(ENV_SCRUB_TEST_DIR)
		os.remove(log_path)
		kproto.network_log_close()
		kproto.network_log_path = log_path
		defer { kproto.network_log_close(); kproto.network_log_path = previous_log }

		testing.expect(t, os.set_env(ENV_SCRUB_TEST_NAME, ENV_SCRUB_TEST_VALUE) == nil)
		testing.expect(t, env_scrub_secrets_and_log() >= 1)
		kproto.network_log_close()
		data, err := os.read_entire_file(log_path, context.temp_allocator)
		testing.expect(t, err == nil, "the network log was written")
		text := string(data)
		testing.expectf(t, strings.contains(text, ENV_SCRUB_TEST_NAME), "the name is logged:\n%s", text)
		testing.expectf(t, !strings.contains(text, ENV_SCRUB_TEST_VALUE), "the value is never logged:\n%s", text)
		for s in saved {
			if len(s.value) >= 4 { testing.expectf(t, !strings.contains(text, s.value), "the value of %s is never logged", s.name) }
		}
		recent: [64][]u8
		count := kproto.network_log_recent_lines(recent[:])
		for line in recent[:count] { testing.expect(t, !strings.contains(string(line), ENV_SCRUB_TEST_VALUE), "recent log lines hold no value") }
	}

	// A real minidump (ProcessThreadData, environment block included, no
	// minidump.scrub) holds the fake token before the scrub and not after.
	@(test)
	env_scrub_keeps_token_out_of_real_dump :: proc(t: ^testing.T) {
		saved := env_scrub_test_save()
		defer env_scrub_test_restore(saved)
		testing.expect(t, os.set_env(ENV_SCRUB_TEST_NAME, ENV_SCRUB_TEST_VALUE) == nil)
		utf16 := utf16_bytes(ENV_SCRUB_TEST_VALUE)

		before, before_ok := env_scrub_test_raw_dump(ENV_SCRUB_TEST_DIR + "/before.dmp")
		if !testing.expect(t, before_ok, "dump before the scrub") { return }
		testing.expect(t, strings.contains(string(before), utf16), "control: the unscrubbed dump holds the environment value (UTF-16)")

		names: [dynamic]string
		defer { for n in names { delete(n) }; delete(names) }
		env_scrub_secrets(&names)

		after, after_ok := env_scrub_test_raw_dump(ENV_SCRUB_TEST_DIR + "/after.dmp")
		if !testing.expect(t, after_ok, "dump after the scrub") { return }
		testing.expect(t, !strings.contains(string(after), utf16), "no UTF-16 copy of the value after the scrub")
		testing.expect(t, !strings.contains(string(after), ENV_SCRUB_TEST_VALUE), "no UTF-8 copy of the value after the scrub")
		fmt.printf("env scrub dump: before=%d bytes after=%d bytes, removed %d names\n", len(before), len(after), len(names))
	}
}
