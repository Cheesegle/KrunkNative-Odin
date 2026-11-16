package minidump

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:unicode/utf16"

// Symbolication with dbghelp: every thread of a dump, walked with
// StackWalk64 and named with SymFromAddrW / SymGetLineFromAddrW64.
//
// Krodin's own module is matched against the archived build in the symbols
// folders (dist/symbols/<commit>/krodin_client.exe + .pdb); system DLLs are
// used from this machine only when their timestamp and size match the dump,
// so a dump from another Windows build never gets wrong names. Code and
// unwind data come from those image files; stack memory from the dump.

foreign import dbghelp_lib "system:Dbghelp.lib"

ADDRESS64 :: struct {
	Offset:  u64,
	Segment: u16,
	Mode:    u32,
}

KDHELP64 :: struct {
	Thread:                         u64,
	ThCallbackStack:                u32,
	ThCallbackBStore:               u32,
	NextCallback:                   u32,
	FramePointer:                   u32,
	KiCallUserMode:                 u64,
	KeUserCallbackDispatcher:       u64,
	SystemRangeStart:               u64,
	KiUserExceptionDispatcher:      u64,
	StackBase:                      u64,
	StackLimit:                     u64,
	BuildVersion:                   u32,
	RetpolineStubFunctionTableSize: u32,
	RetpolineStubFunctionTable:     u64,
	RetpolineStubOffset:            u32,
	RetpolineStubSize:              u32,
	Reserved0:                      [2]u64,
}

STACKFRAME64 :: struct {
	AddrPC:         ADDRESS64,
	AddrReturn:     ADDRESS64,
	AddrFrame:      ADDRESS64,
	AddrStack:      ADDRESS64,
	AddrBStore:     ADDRESS64,
	FuncTableEntry: rawptr,
	Params:         [4]u64,
	Far:            win.BOOL,
	Virtual:        win.BOOL,
	Reserved:       [3]u64,
	KdHelp:         KDHELP64,
}

Read_Memory_Proc :: #type proc "system" (process: win.HANDLE, address: u64, buffer: rawptr, size: u32, bytes_read: ^u32) -> win.BOOL
Function_Table_Proc :: #type proc "system" (process: win.HANDLE, address: u64) -> rawptr
Module_Base_Proc :: #type proc "system" (process: win.HANDLE, address: u64) -> u64

@(default_calling_convention = "system")
foreign dbghelp_lib {
	SymInitializeW :: proc(process: win.HANDLE, search_path: cstring16, invade: win.BOOL) -> win.BOOL ---
	SymCleanup :: proc(process: win.HANDLE) -> win.BOOL ---
	SymSetOptions :: proc(options: u32) -> u32 ---
	SymLoadModuleExW :: proc(process: win.HANDLE, file: win.HANDLE, image_name: cstring16, module_name: cstring16, base: u64, size: u32, data: rawptr, flags: u32) -> u64 ---
	SymFromAddrW :: proc(process: win.HANDLE, address: u64, displacement: ^u64, symbol: ^win.SYMBOL_INFOW) -> win.BOOL ---
	SymGetLineFromAddrW64 :: proc(process: win.HANDLE, address: u64, displacement: ^u32, line: ^win.IMAGEHLP_LINE64) -> win.BOOL ---
	SymFunctionTableAccess64 :: proc(process: win.HANDLE, address: u64) -> rawptr ---
	SymGetModuleBase64 :: proc(process: win.HANDLE, address: u64) -> u64 ---
	StackWalk64 :: proc(machine: u32, process: win.HANDLE, thread: win.HANDLE, frame: ^STACKFRAME64, ctx: rawptr,
		read_memory: Read_Memory_Proc, function_table: Function_Table_Proc, module_base: Module_Base_Proc, translate: rawptr) -> win.BOOL ---
}

SYMOPT_UNDNAME :: 0x2
SYMOPT_LOAD_LINES :: 0x10
SYMOPT_FAIL_CRITICAL_ERRORS :: 0x200
SYMOPT_EXACT_SYMBOLS :: 0x400
SYMOPT_NO_PROMPTS :: 0x80000
IMAGE_FILE_MACHINE_AMD64 :: 0x8664
LOAD_LIBRARY_AS_IMAGE_RESOURCE :: 0x20
MAX_FRAMES :: 64

// A fake handle: dbghelp only needs a unique value when it does not invade a process.
@(private = "file")
SYM_PROCESS :: win.HANDLE(uintptr(0x4B524F44))

Image :: struct {
	module:  ^Module,
	handle:  win.HMODULE, // From LoadLibraryExW(AS_IMAGE_RESOURCE), or nil.
	mapped:  uintptr,     // Base of the mapped image, or 0.
	path:    string,      // The local file used, or "".
	symbols: bool,        // dbghelp found names for this module.
}

@(private = "file")
Walk_State :: struct {
	dump:   ^Dump,
	images: []Image,
}

@(private = "file")
g_walk: Walk_State

@(private = "file")
wide :: proc(text: string, allocator := context.temp_allocator) -> cstring16 {
	out := make([]u16, len(text) * 2 + 1, allocator)
	n := utf16.encode_string(out[:len(out) - 1], text)
	out[n] = 0
	return cstring16(raw_data(out))
}

@(private = "file")
narrow :: proc(text: [^]u16, allocator := context.temp_allocator) -> string {
	if text == nil { return "" }
	length := 0
	for text[length] != 0 && length < 4096 { length += 1 }
	out := make([]u8, length * 3, allocator)
	n := utf16.decode_to_utf8(out, text[:length])
	return string(out[:n])
}

// Maps `path` as an image and checks it is the very build the dump recorded.
@(private = "file")
image_open :: proc(path: string, module: ^Module) -> (handle: win.HMODULE, mapped: uintptr, ok: bool) {
	if !os.exists(path) { return }
	handle = win.LoadLibraryExW(wide(path), nil, transmute(win.LoadLibraryEx_Flags)u32(LOAD_LIBRARY_AS_IMAGE_RESOURCE))
	if handle == nil { return nil, 0, false }
	mapped = uintptr(handle) & ~uintptr(3)
	nt := mapped + uintptr((^u32)(mapped + 0x3C)^)
	timestamp := (^u32)(nt + 8)^
	size_of_image := (^u32)(nt + 0x50)^
	if timestamp != module.timestamp || size_of_image != module.size {
		win.FreeLibrary(handle)
		return nil, 0, false
	}
	return handle, mapped, true
}

@(private = "file")
walk_read_memory :: proc "system" (process: win.HANDLE, address: u64, buffer: rawptr, size: u32, bytes_read: ^u32) -> win.BOOL {
	out := ([^]u8)(buffer)[:size]
	if bytes_read != nil { bytes_read^ = 0 }
	// Code and unwind data from the matching image files first: the dump only
	// holds a few bytes of each module.
	for image in g_walk.images {
		if image.mapped == 0 { continue }
		base, end := image.module.base, image.module.base + u64(image.module.size)
		if address >= base && address < end {
			n := min(u64(size), end - address)
			src := ([^]u8)(image.mapped + uintptr(address - base))
			for i in 0 ..< n { out[i] = src[i] }
			if bytes_read != nil { bytes_read^ = u32(n) }
			return true
		}
	}
	// Stacks (and anything else the dump saved).
	for r in g_walk.dump.memory {
		if address >= r.start && address < r.start + r.size {
			n := min(u64(size), r.start + r.size - address)
			offset := r.rva + (address - r.start)
			if offset + n > u64(len(g_walk.dump.data)) { return false }
			for i in 0 ..< n { out[i] = g_walk.dump.data[offset + i] }
			if bytes_read != nil { bytes_read^ = u32(n) }
			return true
		}
	}
	return false
}

// The mapped image containing `address`, if any.
@(private = "file")
image_for :: proc "contextless" (address: u64) -> ^Image {
	for &image in g_walk.images {
		if image.mapped != 0 && address >= image.module.base && address < image.module.base + u64(image.module.size) { return &image }
	}
	return nil
}

// A data directory (RVA, size) of a mapped PE32+ image.
@(private = "file")
image_directory :: proc "contextless" (mapped: uintptr, index: int) -> (rva: u32, size: u32) {
	nt := mapped + uintptr((^u32)(mapped + 0x3C)^)
	entry := nt + 24 + 112 + uintptr(index) * 8
	return (^u32)(entry)^, (^u32)(entry + 4)^
}

RUNTIME_FUNCTION :: struct {
	begin, end, unwind: u32,
}

@(private = "file")
g_function_entry: RUNTIME_FUNCTION

// The unwind table entry for `address`, from the image's exception
// directory. dbghelp cannot read it itself without a live process.
@(private = "file")
function_table :: proc "system" (process: win.HANDLE, address: u64) -> rawptr {
	image := image_for(address)
	if image == nil { return SymFunctionTableAccess64(process, address) }
	rva, size := image_directory(image.mapped, 3)
	if rva == 0 || size < size_of(RUNTIME_FUNCTION) { return nil }
	entries := ([^]RUNTIME_FUNCTION)(image.mapped + uintptr(rva))[:size / size_of(RUNTIME_FUNCTION)]
	target := u32(address - image.module.base)
	low, high := 0, len(entries) - 1
	for low <= high {
		mid := (low + high) / 2
		entry := entries[mid]
		if target < entry.begin {
			high = mid - 1
		} else if target >= entry.end {
			low = mid + 1
		} else {
			g_function_entry = entry
			return &g_function_entry
		}
	}
	return nil
}

// The nearest exported name at or below `address` (system DLLs without a PDB).
@(private = "file")
nearest_export :: proc(address: u64) -> (name: string, offset: u64, ok: bool) {
	image := image_for(address)
	if image == nil { return }
	rva, size := image_directory(image.mapped, 0)
	if rva == 0 || size < 40 { return }
	directory := image.mapped + uintptr(rva)
	name_count := (^u32)(directory + 0x18)^
	functions := ([^]u32)(image.mapped + uintptr((^u32)(directory + 0x1C)^))
	names := ([^]u32)(image.mapped + uintptr((^u32)(directory + 0x20)^))
	ordinals := ([^]u16)(image.mapped + uintptr((^u32)(directory + 0x24)^))
	target := u32(address - image.module.base)
	best: u32
	for i in 0 ..< name_count {
		function := functions[ordinals[i]]
		if function <= target && function > best && (function < rva || function >= rva + size) {
			best = function
			name = string(cstring(rawptr(image.mapped + uintptr(names[i]))))
		}
	}
	if best == 0 { return }
	return name, u64(target - best), true
}

@(private = "file")
module_base :: proc "system" (process: win.HANDLE, address: u64) -> u64 {
	return SymGetModuleBase64(process, address)
}

// "module!function+0x12 [file:line]" for one address. `lookup` is the
// address used for the name and line (return address - 1 for callers).
describe_address :: proc(dump: ^Dump, address, lookup: u64, allocator := context.temp_allocator) -> (text: string, krodin_symbol: bool) {
	module := module_for(dump, address)
	module_name := module != nil ? base_name(module.path) : "?"
	buffer: [(size_of(win.SYMBOL_INFOW) + 512 * 2) / 8 + 1]u64
	symbol := (^win.SYMBOL_INFOW)(&buffer[0])
	symbol.SizeOfStruct = size_of(win.SYMBOL_INFOW)
	symbol.MaxNameLen = 511
	displacement: u64
	b := strings.builder_make(allocator)
	if SymFromAddrW(SYM_PROCESS, lookup, &displacement, symbol) {
		name := narrow(([^]u16)(&symbol.Name[0]))
		fmt.sbprintf(&b, "%s!%s+0x%X", module_name, name, displacement + (address - lookup))
		krodin_symbol = strings.contains(name, "::")
	} else if name, offset, ok := nearest_export(lookup); ok {
		fmt.sbprintf(&b, "%s!%s+0x%X (nearest export)", module_name, name, offset + (address - lookup))
	} else if module != nil {
		fmt.sbprintf(&b, "%s+0x%X", module_name, address - module.base)
	} else {
		fmt.sbprintf(&b, "0x%X", address)
	}
	line: win.IMAGEHLP_LINE64
	line.SizeOfStruct = size_of(win.IMAGEHLP_LINE64)
	line_displacement: u32
	if SymGetLineFromAddrW64(SYM_PROCESS, lookup, &line_displacement, &line) {
		fmt.sbprintf(&b, "  [%s:%d]", narrow(([^]u16)(line.FileName)), line.LineNumber)
	}
	return strings.to_string(b), krodin_symbol
}

Symbolicate_Result :: struct {
	frames:         int, // Frames printed across all threads.
	krodin_frames:  int, // Frames named with an Odin (package::proc) symbol.
	named_threads:  int,
	matched_images: int,
}

// Writes every thread's call stack to `b`. `symbol_dirs` are searched for the
// matching Krodin build (exe + pdb).
symbolicate :: proc(dump: ^Dump, symbol_dirs: []string, b: ^strings.Builder) -> (result: Symbolicate_Result) {
	SymSetOptions(SYMOPT_UNDNAME | SYMOPT_LOAD_LINES | SYMOPT_FAIL_CRITICAL_ERRORS | SYMOPT_EXACT_SYMBOLS | SYMOPT_NO_PROMPTS)
	search := strings.join(symbol_dirs, ";", context.temp_allocator)
	if !SymInitializeW(SYM_PROCESS, wide(search), false) {
		fmt.sbprintf(b, "SymInitializeW failed (error %d)\n", win.GetLastError())
		return
	}
	defer SymCleanup(SYM_PROCESS)

	images := make([]Image, len(dump.modules), context.temp_allocator)
	for &module, i in dump.modules {
		image := &images[i]
		image.module = &module
		name := base_name(module.path)
		candidates := make([dynamic]string, context.temp_allocator)
		for dir in symbol_dirs { append(&candidates, strings.concatenate({dir, "\\", name}, context.temp_allocator)) }
		append(&candidates, module.path)
		for candidate in candidates {
			if handle, mapped, ok := image_open(candidate, &module); ok {
				image.handle, image.mapped, image.path = handle, mapped, candidate
				break
			}
		}
		image_name := len(image.path) > 0 ? image.path : module.path
		if SymLoadModuleExW(SYM_PROCESS, nil, wide(image_name), nil, module.base, module.size, nil, 0) != 0 {
			if len(image.path) > 0 { result.matched_images += 1 }
		}
	}
	defer for image in images { if image.handle != nil { win.FreeLibrary(image.handle) } }
	g_walk = {dump, images}
	defer g_walk = {}

	exe_module: ^Module
	if len(dump.modules) > 0 { exe_module = &dump.modules[0] }
	fmt.sbprintf(b, "Modules: %d (%d matched with local images or archived symbols)\n", len(dump.modules), result.matched_images)
	if exe_module != nil {
		matched := len(images[0].path) > 0
		fmt.sbprintf(b, "Krodin module: %s, %s\n", exe_module.path, matched ? fmt.tprintf("matched %s", images[0].path) : "NO matching exe/pdb in the symbols folders (names unavailable)")
	}
	if dump.exception_code != 0 { fmt.sbprintf(b, "Exception 0x%08X on thread %d\n", dump.exception_code, dump.exception_thread) }
	fmt.sbprintf(b, "Threads: %d%s\n", len(dump.threads), dump.has_thread_names ? "" : " (the dump has no thread names)")

	for &thread in dump.threads {
		if len(thread.name) > 0 { result.named_threads += 1 }
		fmt.sbprintf(b, "\nThread %d \"%s\"%s\n", thread.id, len(thread.name) > 0 ? thread.name : "(unnamed)", thread.id == dump.exception_thread && dump.exception_code != 0 ? "  <== exception" : "")
		ctx_rva, ctx_size := thread.context_rva, thread.context_size
		if thread.id == dump.exception_thread && dump.exception_context_rva != 0 { ctx_rva, ctx_size = dump.exception_context_rva, dump.exception_context_size }
		if ctx_size < size_of(win.CONTEXT) || u64(ctx_rva) + u64(size_of(win.CONTEXT)) > u64(len(dump.data)) {
			fmt.sbprintf(b, "  (no usable register context)\n")
			continue
		}
		Aligned :: struct #align (16) { ctx: win.CONTEXT }
		aligned: Aligned
		copy(([^]u8)(&aligned.ctx)[:size_of(win.CONTEXT)], dump.data[ctx_rva:][:size_of(win.CONTEXT)])
		frame: STACKFRAME64
		frame.AddrPC = {Offset = aligned.ctx.Rip, Mode = 3}
		frame.AddrFrame = {Offset = aligned.ctx.Rbp, Mode = 3}
		frame.AddrStack = {Offset = aligned.ctx.Rsp, Mode = 3}
		reached_krodin := false
		last_module: ^Module
		count := 0
		for count < MAX_FRAMES {
			if !StackWalk64(IMAGE_FILE_MACHINE_AMD64, SYM_PROCESS, nil, &frame, &aligned.ctx, walk_read_memory, function_table, module_base, nil) { break }
			pc := frame.AddrPC.Offset
			if pc == 0 { break }
			lookup := count == 0 ? pc : pc - 1
			text, is_krodin := describe_address(dump, pc, lookup)
			fmt.sbprintf(b, "  #%02d 0x%016X %s\n", count, pc, text)
			if is_krodin { result.krodin_frames += 1; reached_krodin = true }
			last_module = module_for(dump, pc)
			count += 1
		}
		result.frames += count
		// A walk that stops in a module without unwind data (a driver from
		// another machine) can still show where Krodin was: scan the stack for
		// return addresses into the Krodin module.
		if !reached_krodin && exe_module != nil && last_module != exe_module {
			scan_stack(dump, &thread, exe_module, b, &result)
		}
	}
	return
}

@(private = "file")
scan_stack :: proc(dump: ^Dump, thread: ^Thread, exe: ^Module, b: ^strings.Builder, result: ^Symbolicate_Result) {
	start := max(thread.rsp, thread.stack_start)
	end := thread.stack_start + u64(thread.stack_size)
	printed := 0
	for address := start; address + 8 <= end && printed < 24; address += 8 {
		value_bytes: [8]u8
		if !read_memory(dump, address, value_bytes[:]) { continue }
		value := transmute(u64)value_bytes
		if value < exe.base || value >= exe.base + u64(exe.size) { continue }
		text, is_krodin := describe_address(dump, value, value - 1)
		if !is_krodin { continue }
		if printed == 0 { fmt.sbprintf(b, "  Stack scan (return-address candidates into %s, may include stale entries):\n", base_name(exe.path)) }
		fmt.sbprintf(b, "    [rsp+0x%X] 0x%016X %s\n", address - thread.rsp, value, text)
		result.krodin_frames += 1
		printed += 1
	}
}
