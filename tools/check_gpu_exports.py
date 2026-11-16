"""Check that a built client exports the hybrid-GPU hints with the value 1.

NVIDIA Optimus and AMD PowerXpress drivers look up NvOptimusEnablement and
AmdPowerXpressRequestHighPerformance in the EXE's export table at process start
and switch it to the dedicated GPU when the exported value is 1.

Usage: python tools/check_gpu_exports.py [bin/krodin_client.exe ...]
Exits 0 when every file exports both symbols with value 1, else 1.
Standard library only (struct), so it also runs where dumpbin is missing.
"""
import struct
import sys

WANTED = ("NvOptimusEnablement", "AmdPowerXpressRequestHighPerformance")


def read_exports(path):
    data = open(path, "rb").read()
    if data[:2] != b"MZ":
        raise ValueError("not a PE file (no MZ header)")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("not a PE file (no PE signature)")
    sections_count = struct.unpack_from("<H", data, pe + 6)[0]
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directories = optional + (112 if magic == 0x20B else 96)  # PE32+ or PE32
    export_rva, export_size = struct.unpack_from("<II", data, directories)
    sections = []
    table = optional + optional_size
    for i in range(sections_count):
        s = table + 40 * i
        virtual_size, virtual_address, raw_size, raw_pointer = struct.unpack_from("<IIII", data, s + 8)
        sections.append((virtual_address, max(virtual_size, raw_size), raw_pointer, raw_size))

    def offset(rva):
        for address, size, raw, raw_size in sections:
            if address <= rva < address + size:
                if rva - address >= raw_size:
                    return None  # Zero-filled (.bss) data has no file bytes.
                return raw + rva - address
        raise ValueError("RVA 0x%x is outside every section" % rva)

    exports = {}
    if export_rva == 0 or export_size == 0:
        return exports, magic
    e = offset(export_rva)
    (functions_count, names_count, functions_rva, names_rva, ordinals_rva) = struct.unpack_from("<IIIII", data, e + 20)
    functions, names, ordinals = offset(functions_rva), offset(names_rva), offset(ordinals_rva)
    for i in range(names_count):
        name_offset = offset(struct.unpack_from("<I", data, names + 4 * i)[0])
        name = data[name_offset:data.index(b"\0", name_offset)].decode("ascii")
        ordinal = struct.unpack_from("<H", data, ordinals + 2 * i)[0]
        rva = struct.unpack_from("<I", data, functions + 4 * ordinal)[0]
        value_offset = offset(rva)
        value = 0 if value_offset is None else struct.unpack_from("<I", data, value_offset)[0]
        exports[name] = (rva, value)
    return exports, magic


def check(path):
    try:
        exports, magic = read_exports(path)
    except (OSError, ValueError, struct.error) as error:
        print("%s: FAIL (%s)" % (path, error))
        return False
    ok = True
    print("%s: %s, %d named export(s)" % (path, "PE32+" if magic == 0x20B else "PE32", len(exports)))
    for name in WANTED:
        if name not in exports:
            print("  %-38s MISSING" % name)
            ok = False
            continue
        rva, value = exports[name]
        good = value == 1
        ok = ok and good
        print("  %-38s rva=0x%08x value=%d %s" % (name, rva, value, "ok" if good else "WRONG VALUE"))
    return ok


def main(argv):
    paths = argv[1:] or ["bin/krodin_client.exe"]
    results = [check(path) for path in paths]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
