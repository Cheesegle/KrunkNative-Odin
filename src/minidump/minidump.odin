package minidump

import "core:encoding/endian"
import "core:unicode/utf16"

// A small reader for Windows minidumps (the streams Krodin's crash and hang
// dumps contain). Used by tools/symbolicate and by the client tests that
// check what a dump holds. The reader only slices the file; nothing in it is
// trusted: every offset is bounds-checked.

STREAM_THREAD_LIST :: 3
STREAM_MODULE_LIST :: 4
STREAM_MEMORY_LIST :: 5
STREAM_EXCEPTION :: 6
STREAM_SYSTEM_INFO :: 7
STREAM_MEMORY64_LIST :: 9
STREAM_HANDLE_DATA :: 12
STREAM_UNLOADED_MODULE_LIST :: 14
STREAM_MEMORY_INFO_LIST :: 16
STREAM_THREAD_INFO_LIST :: 17
STREAM_THREAD_NAMES :: 24

// x64 CONTEXT field offsets.
CONTEXT_RSP :: 0x98
CONTEXT_RBP :: 0xA0
CONTEXT_RIP :: 0xF8

Module :: struct {
	base:      u64,
	size:      u32,
	timestamp: u32,
	path:      string, // Full path as recorded in the dump.
}

Thread :: struct {
	id:           u32,
	teb:          u64,
	stack_start:  u64,
	stack_size:   u32,
	stack_rva:    u32,
	context_rva:  u32,
	context_size: u32,
	name:         string,
	rip, rsp, rbp: u64,
}

Memory_Range :: struct {
	start: u64,
	size:  u64,
	rva:   u64,
}

Dump :: struct {
	data:             []u8,
	stream_types:     [dynamic]u32,
	modules:          [dynamic]Module,
	threads:          [dynamic]Thread,
	memory:           [dynamic]Memory_Range,
	has_thread_names: bool,
	// Crash dumps: the faulting thread and its context at the fault.
	exception_thread: u32,
	exception_code:   u32,
	exception_context_rva, exception_context_size: u32,
}

@(private)
u32_at :: proc(data: []u8, offset: u64) -> (u32, bool) {
	if offset + 4 > u64(len(data)) { return 0, false }
	return endian.get_u32(data[offset:offset + 4], .Little)
}

@(private)
u64_at :: proc(data: []u8, offset: u64) -> (u64, bool) {
	if offset + 8 > u64(len(data)) { return 0, false }
	return endian.get_u64(data[offset:offset + 8], .Little)
}

// A MINIDUMP_STRING (byte length, then UTF-16) as UTF-8.
@(private)
string_at :: proc(data: []u8, rva: u64, allocator := context.allocator) -> string {
	length, ok := u32_at(data, rva)
	if !ok || rva + 4 + u64(length) > u64(len(data)) || length > 4096 { return "" }
	units := make([]u16, length / 2, context.temp_allocator)
	for i in 0 ..< len(units) {
		units[i] = u16(data[rva + 4 + u64(i) * 2]) | u16(data[rva + 5 + u64(i) * 2]) << 8
	}
	out := make([]u8, len(units) * 3, allocator)
	n := utf16.decode_to_utf8(out, units)
	return string(out[:n])
}

parse :: proc(data: []u8, allocator := context.allocator) -> (dump: Dump, ok: bool) {
	context.allocator = allocator
	dump.data = data
	if len(data) < 32 || string(data[:4]) != "MDMP" { return dump, false }
	stream_count, _ := u32_at(data, 8)
	directory, _ := u32_at(data, 12)
	if stream_count > 1024 { return dump, false }
	names_rva, names_size: u32
	for i in 0 ..< u64(stream_count) {
		entry := u64(directory) + i * 12
		type, type_ok := u32_at(data, entry)
		size, _ := u32_at(data, entry + 4)
		rva, rva_ok := u32_at(data, entry + 8)
		if !type_ok || !rva_ok { return dump, false }
		append(&dump.stream_types, type)
		switch type {
		case STREAM_THREAD_LIST:
			count, _ := u32_at(data, u64(rva))
			for t in 0 ..< u64(min(count, 4096)) {
				off := u64(rva) + 4 + t * 48
				if off + 48 > u64(len(data)) { break }
				thread: Thread
				thread.id, _ = u32_at(data, off)
				thread.teb, _ = u64_at(data, off + 16)
				thread.stack_start, _ = u64_at(data, off + 24)
				thread.stack_size, _ = u32_at(data, off + 32)
				thread.stack_rva, _ = u32_at(data, off + 36)
				thread.context_size, _ = u32_at(data, off + 40)
				thread.context_rva, _ = u32_at(data, off + 44)
				thread.rsp, _ = u64_at(data, u64(thread.context_rva) + CONTEXT_RSP)
				thread.rbp, _ = u64_at(data, u64(thread.context_rva) + CONTEXT_RBP)
				thread.rip, _ = u64_at(data, u64(thread.context_rva) + CONTEXT_RIP)
				append(&dump.threads, thread)
			}
		case STREAM_MODULE_LIST:
			count, _ := u32_at(data, u64(rva))
			for m in 0 ..< u64(min(count, 4096)) {
				off := u64(rva) + 4 + m * 108
				if off + 108 > u64(len(data)) { break }
				module: Module
				module.base, _ = u64_at(data, off)
				module.size, _ = u32_at(data, off + 8)
				module.timestamp, _ = u32_at(data, off + 16)
				name_rva, _ := u32_at(data, off + 20)
				module.path = string_at(data, u64(name_rva))
				append(&dump.modules, module)
			}
		case STREAM_MEMORY_LIST:
			count, _ := u32_at(data, u64(rva))
			for m in 0 ..< u64(min(count, 65536)) {
				off := u64(rva) + 4 + m * 16
				start, start_ok := u64_at(data, off)
				range_size, _ := u32_at(data, off + 8)
				range_rva, rva_ok := u32_at(data, off + 12)
				if !start_ok || !rva_ok { break }
				append(&dump.memory, Memory_Range{start, u64(range_size), u64(range_rva)})
			}
		case STREAM_MEMORY64_LIST:
			count, _ := u64_at(data, u64(rva))
			base_rva, _ := u64_at(data, u64(rva) + 8)
			current := base_rva
			for m in 0 ..< min(count, 65536) {
				off := u64(rva) + 16 + m * 16
				start, start_ok := u64_at(data, off)
				range_size, size_ok := u64_at(data, off + 8)
				if !start_ok || !size_ok { break }
				append(&dump.memory, Memory_Range{start, range_size, current})
				current += range_size
			}
		case STREAM_EXCEPTION:
			dump.exception_thread, _ = u32_at(data, u64(rva))
			dump.exception_code, _ = u32_at(data, u64(rva) + 8)
			dump.exception_context_size, _ = u32_at(data, u64(rva) + 160)
			dump.exception_context_rva, _ = u32_at(data, u64(rva) + 164)
		case STREAM_THREAD_NAMES:
			names_rva, names_size = rva, size
		}
	}
	// Thread names last, once the thread list is known.
	if names_size >= 4 {
		dump.has_thread_names = true
		count, _ := u32_at(data, u64(names_rva))
		for n in 0 ..< u64(min(count, 4096)) {
			off := u64(names_rva) + 4 + n * 12
			id, id_ok := u32_at(data, off)
			name_rva, name_ok := u64_at(data, off + 4)
			if !id_ok || !name_ok { break }
			for &thread in dump.threads {
				if thread.id == id { thread.name = string_at(data, name_rva) }
			}
		}
	}
	return dump, true
}

destroy :: proc(dump: ^Dump) {
	for module in dump.modules { delete(module.path) }
	for thread in dump.threads { delete(thread.name) }
	delete(dump.modules)
	delete(dump.threads)
	delete(dump.memory)
	delete(dump.stream_types)
	dump^ = {}
}

has_stream :: proc(dump: ^Dump, type: u32) -> bool {
	for t in dump.stream_types { if t == type { return true } }
	return false
}

// Bytes at `address` from the dump's memory ranges (thread stacks).
read_memory :: proc(dump: ^Dump, address: u64, out: []u8) -> bool {
	for r in dump.memory {
		if address >= r.start && address + u64(len(out)) <= r.start + r.size {
			offset := r.rva + (address - r.start)
			if offset + u64(len(out)) > u64(len(dump.data)) { return false }
			copy(out, dump.data[offset:offset + u64(len(out))])
			return true
		}
	}
	return false
}

module_for :: proc(dump: ^Dump, address: u64) -> ^Module {
	for &module in dump.modules {
		if address >= module.base && address < module.base + u64(module.size) { return &module }
	}
	return nil
}

// The file name part of a module path.
base_name :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '\\' || path[i] == '/' { return path[i + 1:] }
	}
	return path
}

// The thread a stack range belongs to, if any.
stack_owner :: proc(dump: ^Dump, start, size: u64) -> ^Thread {
	for &thread in dump.threads {
		if start >= thread.stack_start && start + size <= thread.stack_start + u64(thread.stack_size) { return &thread }
	}
	return nil
}

// --- Scrubbing ------------------------------------------------------------
//
// MiniDumpWithProcessThreadData saves the PEB, the TEBs and the process
// parameters, which point at the environment block and command line (heap
// memory that can hold anyone's secrets). scrub zeroes every saved byte
// that is not a thread stack, module image bytes (code near each thread's
// instruction pointer), a TEB's first SCRUB_TEB_KEEP bytes (stack bounds,
// thread id, last error), the PEB page or KUSER_SHARED_DATA. It works in
// place on the dump file's bytes and allocates nothing, so the crash handler
// can run it.

SCRUB_TEB_KEEP :: 0x100
SCRUB_PEB_KEEP :: 0x1000
KUSER_SHARED_DATA :: 0x7FFE0000
TEB_PEB_OFFSET :: 0x60

@(private)
Scrub_Lists :: struct {
	threads_rva, threads_count: u64,
	modules_rva, modules_count: u64,
	memory_rva, memory_count:   u64,
	memory64_rva, memory64_count, memory64_base: u64,
}

@(private)
scrub_lists :: proc(data: []u8) -> (lists: Scrub_Lists, ok: bool) {
	if len(data) < 32 || string(data[:4]) != "MDMP" { return }
	stream_count, _ := u32_at(data, 8)
	directory, _ := u32_at(data, 12)
	for i in 0 ..< u64(min(stream_count, 1024)) {
		entry := u64(directory) + i * 12
		type, type_ok := u32_at(data, entry)
		rva, rva_ok := u32_at(data, entry + 8)
		if !type_ok || !rva_ok { return }
		count, _ := u32_at(data, u64(rva))
		switch type {
		case STREAM_THREAD_LIST: lists.threads_rva, lists.threads_count = u64(rva), u64(min(count, 4096))
		case STREAM_MODULE_LIST: lists.modules_rva, lists.modules_count = u64(rva), u64(min(count, 4096))
		case STREAM_MEMORY_LIST: lists.memory_rva, lists.memory_count = u64(rva), u64(min(count, 65536))
		case STREAM_MEMORY64_LIST:
			count64, _ := u64_at(data, u64(rva))
			lists.memory64_rva, lists.memory64_count = u64(rva), min(count64, 65536)
			lists.memory64_base, _ = u64_at(data, u64(rva) + 8)
		}
	}
	return lists, true
}

// Bytes at a process address from the saved memory, without allocating.
@(private)
scrub_read_u64 :: proc(data: []u8, lists: Scrub_Lists, address: u64) -> (u64, bool) {
	for m in 0 ..< lists.memory_count {
		off := lists.memory_rva + 4 + m * 16
		start, _ := u64_at(data, off)
		size, _ := u32_at(data, off + 8)
		rva, _ := u32_at(data, off + 12)
		if address >= start && address + 8 <= start + u64(size) { return u64_at(data, u64(rva) + address - start) }
	}
	return 0, false
}

// The end of the kept interval containing `address`, or 0 when it is not kept;
// `next` is the start of the nearest kept interval above it.
@(private)
scrub_kept :: proc(data: []u8, lists: Scrub_Lists, address: u64) -> (end: u64, next: u64) {
	next = max(u64)
	consider :: proc(address, start, size: u64, end, next: ^u64) {
		if size == 0 { return }
		if address >= start && address < start + size {
			end^ = max(end^, start + size)
		} else if start > address {
			next^ = min(next^, start)
		}
	}
	for t in 0 ..< lists.threads_count {
		off := lists.threads_rva + 4 + t * 48
		teb, _ := u64_at(data, off + 16)
		stack_start, _ := u64_at(data, off + 24)
		stack_size, _ := u32_at(data, off + 32)
		consider(address, stack_start, u64(stack_size), &end, &next)
		consider(address, teb, SCRUB_TEB_KEEP, &end, &next)
		if peb, ok := scrub_read_u64(data, lists, teb + TEB_PEB_OFFSET); ok { consider(address, peb, SCRUB_PEB_KEEP, &end, &next) }
	}
	for m in 0 ..< lists.modules_count {
		off := lists.modules_rva + 4 + m * 108
		base, _ := u64_at(data, off)
		size, _ := u32_at(data, off + 8)
		consider(address, base, u64(size), &end, &next)
	}
	consider(address, KUSER_SHARED_DATA, 0x1000, &end, &next)
	return
}

@(private)
scrub_range :: proc(data: []u8, lists: Scrub_Lists, start, size, rva: u64) -> (zeroed: u64) {
	if rva + size > u64(len(data)) { return 0 }
	address := start
	for address < start + size {
		end, next := scrub_kept(data, lists, address)
		if end > address {
			address = end
			continue
		}
		stop := min(next, start + size)
		for i in address ..< stop { data[rva + i - start] = 0 }
		zeroed += stop - address
		address = stop
	}
	return
}

// Zeroes saved memory outside stacks, images, TEB headers, the PEB and
// KUSER_SHARED_DATA. Returns how many bytes were zeroed.
scrub :: proc(data: []u8) -> (zeroed: u64, ok: bool) {
	lists := scrub_lists(data) or_return
	for m in 0 ..< lists.memory_count {
		off := lists.memory_rva + 4 + m * 16
		start, _ := u64_at(data, off)
		size, _ := u32_at(data, off + 8)
		rva, _ := u32_at(data, off + 12)
		zeroed += scrub_range(data, lists, start, u64(size), u64(rva))
	}
	current := lists.memory64_base
	for m in 0 ..< lists.memory64_count {
		off := lists.memory64_rva + 16 + m * 16
		start, _ := u64_at(data, off)
		size, _ := u64_at(data, off + 8)
		zeroed += scrub_range(data, lists, start, size, current)
		current += size
	}
	return zeroed, true
}
