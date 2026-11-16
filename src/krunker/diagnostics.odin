package krunker

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

NETWORK_LOG_PATH :: "logs/krunker-network.log"
// Pending text the writer has not written yet. When it is full, lines are
// dropped and counted rather than making the caller wait on the disk or console.
NETWORK_LOG_BUFFER_LIMIT :: 1 << 20
network_log_attempt: u64
network_log_started: time.Time
network_log_secrets: [dynamic]string
network_log_file_warning: bool
// Tests may point this elsewhere; call network_log_close first so the next
// line opens the new path.
network_log_path := NETWORK_LOG_PATH
// Kept open across lines; network_log_close releases it on shutdown.
network_log_file: ^os.File

// Lines are redacted and formatted on the calling thread, then appended to a
// bounded buffer. A background writer prints and writes them, so neither the
// frame loop nor the WebSocket thread waits on file or console I/O.
Network_Log_Writer :: struct {
	mutex: sync.Mutex,
	wake, drained: sync.Cond,
	pending, writing: [dynamic]byte,
	busy, stop: bool,
	dropped, total_dropped: int,
	thread: ^thread.Thread,
}
network_log_writer: Network_Log_Writer
// Guards the secret list and the attempt clock, which several threads read.
network_log_state_mutex: sync.Mutex

when ODIN_TEST {
	// Caller-side cost of network_log, for the frame-cost regression test.
	network_log_profile_ns: i64
}

network_log_secret :: proc(secret: string) {
	if len(secret) == 0 do return
	sync.mutex_lock(&network_log_state_mutex)
	defer sync.mutex_unlock(&network_log_state_mutex)
	for existing in network_log_secrets { if existing == secret do return }
	append(&network_log_secrets, strings.clone(secret))
}

network_log_sensitive_key :: proc(key: string) -> bool {
	keys := []string{"accessToken", "validationToken", "captchaToken", "clientKey", "clientId", "clientUID", "at", "bpt", "token", "authorization", "cookie", "set-cookie", "password", "access_token", "refresh_token"}
	for candidate in keys {
		if strings.equal_fold(key, candidate) do return true
	}
	return false
}

network_log_word :: proc(b: byte) -> bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '_' || b == '-'
}

// Redact BEFORE truncating, including secrets echoed outside a JSON/query field.
// The returned string is owned by the caller.
network_log_safe :: proc(input: string, limit: int = 16384) -> string {
	value := strings.clone(input)
	defer delete(value)
	sync.mutex_lock(&network_log_state_mutex)
	for secret in network_log_secrets {
		replaced, allocated := strings.replace_all(value, secret, "[REDACTED]")
		if allocated { delete(value); value = replaced }
	}
	sync.mutex_unlock(&network_log_state_mutex)
	out: [dynamic]byte
	defer delete(out)
	i := 0
	for i < len(value) {
		start := i
		if network_log_word(value[i]) {
			for i < len(value) && network_log_word(value[i]) { i += 1 }
			key := value[start:i]
			j := i
			if j < len(value) && (value[j] == '"' || value[j] == '\'') { j += 1 }
			for j < len(value) && (value[j] == ' ' || value[j] == '\t') { j += 1 }
			if network_log_sensitive_key(key) && j < len(value) && (value[j] == ':' || value[j] == '=') {
				j += 1
				for j < len(value) && (value[j] == ' ' || value[j] == '\t') { j += 1 }
				quote: byte
				if j < len(value) && (value[j] == '"' || value[j] == '\'') { quote = value[j]; j += 1 }
				append(&out, value[start:j])
				append(&out, "[REDACTED]")
				line_value := strings.equal_fold(key, "authorization") || strings.equal_fold(key, "cookie") || strings.equal_fold(key, "set-cookie")
				for j < len(value) {
					b := value[j]
					if quote != 0 {
						if b == '\\' && j+1 < len(value) { j += 2; continue }
						if b == quote do break
					} else {
						if b == '\r' || b == '\n' do break
						if !line_value && (b == '&' || b == '#' || b == ' ' || b == '\t' || b == ',' || b == '}' || b == ']' || b == '"' || b == '\'') do break
					}
					j += 1
				}
				i = j
				continue
			}
			// JWTs can appear in free text without a field name.
			if strings.has_prefix(key, "eyJ") && len(key) > 12 {
				for i < len(value) && (network_log_word(value[i]) || value[i] == '.' || value[i] == '=') { i += 1 }
				append(&out, "[REDACTED JWT]")
			} else { append(&out, key) }
			continue
		}
		if value[i] < 32 || value[i] == 127 { append(&out, ' ') } else { append(&out, value[i]) }
		i += 1
	}
	if len(out) > limit { return fmt.aprintf("%s ... [truncated; sanitized bytes=%d]", string(out[:limit]), len(out)) }
	return strings.clone(string(out[:]))
}

// Safe to call from any thread. It never waits on I/O, except to open the
// file for the first line after start-up or network_log_close.
network_log :: proc(stage, message: string) {
	profile_start: time.Tick
	when ODIN_TEST { profile_start = time.tick_now() }
	safe := network_log_safe(message)
	defer delete(safe)
	stamp, _ := time.time_to_rfc3339(time.now(), include_nanos = false, allocator = context.temp_allocator)
	sync.mutex_lock(&network_log_state_mutex)
	attempt, started := network_log_attempt, network_log_started
	sync.mutex_unlock(&network_log_state_mutex)
	elapsed := attempt == 0 ? 0.0 : time.duration_milliseconds(time.since(started))
	line := fmt.tprintf("[Krunker][%s][attempt=%d +%.1fms][%s] %s\n", stamp, attempt, elapsed, stage, safe)
	network_log_enqueue(line)
	when ODIN_TEST { sync.atomic_add(&network_log_profile_ns, i64(time.tick_since(profile_start))) }
}

@(private = "file")
network_log_warn_file :: proc() {
	if !network_log_file_warning { fmt.eprintln("[Krunker] Could not write logs/krunker-network.log; diagnostics continue on console."); network_log_file_warning = true }
}

@(private = "file")
network_log_enqueue :: proc(line: string) {
	w := &network_log_writer
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	if network_log_file == nil {
		os.make_directory_all(os.dir(network_log_path))
		file, err := os.open(network_log_path, {.Write, .Append, .Create})
		if err == nil { network_log_file = file } else { network_log_warn_file() }
	}
	if w.thread == nil {
		// The buffers outlive any one caller's context, so use the heap.
		w.pending.allocator, w.writing.allocator = runtime.heap_allocator(), runtime.heap_allocator()
		context.allocator = runtime.heap_allocator()
		w.thread = thread.create(network_log_writer_run)
		if w.thread != nil { thread.start(w.thread) }
	}
	if w.thread == nil {
		// No writer thread could start: write synchronously, as before.
		if !network_log_write(network_log_file, transmute([]byte)line) { network_log_reopen_later() }
		return
	}
	if len(w.pending) + len(line) > NETWORK_LOG_BUFFER_LIMIT { w.dropped += 1; return }
	append(&w.pending, line)
	sync.cond_signal(&w.wake)
}

// Prints and writes one batch. Returns false when the file write failed.
@(private = "file")
network_log_write :: proc(file: ^os.File, data: []byte) -> bool {
	if os.stdout != nil { os.write(os.stdout, data) }
	if file == nil do return true
	_, err := os.write(file, data)
	return err == nil
}

// Hold the writer mutex. The next line reopens the file, as before.
@(private = "file")
network_log_reopen_later :: proc() {
	network_log_warn_file()
	if network_log_file != nil { os.close(network_log_file) }
	network_log_file = nil
}

@(private = "file")
network_log_writer_run :: proc(t: ^thread.Thread) {
	w := &network_log_writer
	for {
		sync.mutex_lock(&w.mutex)
		for len(w.pending) == 0 && !w.stop { sync.cond_wait(&w.wake, &w.mutex) }
		if len(w.pending) == 0 {
			sync.mutex_unlock(&w.mutex)
			break
		}
		w.pending, w.writing = w.writing, w.pending
		dropped := w.dropped
		w.dropped = 0
		w.total_dropped += dropped
		file := network_log_file
		w.busy = true
		sync.mutex_unlock(&w.mutex)
		ok := true
		if dropped > 0 {
			note := fmt.tprintf("[Krunker][log] %d lines dropped: the log writer fell behind\n", dropped)
			ok = network_log_write(file, transmute([]byte)note)
		}
		ok = network_log_write(file, w.writing[:]) && ok
		clear(&w.writing)
		free_all(context.temp_allocator)
		sync.mutex_lock(&w.mutex)
		if !ok && network_log_file == file { network_log_reopen_later() }
		w.busy = false
		sync.cond_broadcast(&w.drained)
		sync.mutex_unlock(&w.mutex)
	}
}

// Waits until every line logged so far has been written.
network_log_flush :: proc() {
	w := &network_log_writer
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	for w.thread != nil && (len(w.pending) > 0 || w.busy) {
		sync.cond_signal(&w.wake)
		sync.cond_wait(&w.drained, &w.mutex)
	}
}

// For the crash handler: writes what is still buffered, without waiting. If
// another thread holds the lock it gives up rather than deadlock.
network_log_crash_flush :: proc() {
	w := &network_log_writer
	if !sync.mutex_try_lock(&w.mutex) do return
	defer sync.mutex_unlock(&w.mutex)
	if len(w.pending) > 0 {
		network_log_write(network_log_file, w.pending[:])
		clear(&w.pending)
	}
}

// Writes everything still buffered, stops the writer and closes the file.
// The next line starts a new writer and reopens network_log_path.
network_log_close :: proc() {
	w := &network_log_writer
	network_log_flush()
	sync.mutex_lock(&w.mutex)
	writer := w.thread
	w.stop = true
	sync.cond_signal(&w.wake)
	sync.mutex_unlock(&w.mutex)
	if writer != nil {
		thread.join(writer)
		thread.destroy(writer)
	}
	sync.mutex_lock(&w.mutex)
	defer sync.mutex_unlock(&w.mutex)
	w.thread, w.stop = nil, false
	delete(w.pending)
	delete(w.writing)
	w.pending, w.writing = nil, nil
	if network_log_file != nil { os.close(network_log_file) }
	network_log_file = nil
}

network_log_clear_secrets :: proc() {
	sync.mutex_lock(&network_log_state_mutex)
	defer sync.mutex_unlock(&network_log_state_mutex)
	for secret in network_log_secrets { delete(secret) }
	delete(network_log_secrets)
	network_log_secrets = nil
}

network_log_begin :: proc() {
	network_log_clear_secrets()
	sync.mutex_lock(&network_log_state_mutex)
	network_log_attempt += 1
	network_log_started = time.now()
	sync.mutex_unlock(&network_log_state_mutex)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	network_log("join", fmt.tprintf("BEGIN exe=%s handoff=v2 cwd=%s log=%s/%s", os.args[0], cwd, cwd, NETWORK_LOG_PATH))
}
