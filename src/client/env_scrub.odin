package main

import "core:strings"
import kproto "../krunker"

// Token safety net (Krodin's own; Krunker has no equivalent).
//
// Crash and hang dumps are written with MiniDumpWithProcessThreadData, which
// saves the PEB and so the environment block and command line. minidump.scrub
// already zeroes those, but dumps must never hold tokens even if that scrub
// misses something, so at startup every environment variable whose name looks
// secret is removed from this process's own environment (Windows only, where
// dumps exist and nothing reads such variables: the KRUNKER_ACCESS_TOKEN /
// .env fallback is disabled there). Child processes (the browser helper)
// inherit the cleaned environment. Only names are ever logged, never values.
//
// Tokens never arrive on Krodin's command line: parse_client_options rejects
// unknown options and join links (with at=/bpt=) are only pasted in the HUD.

ENV_SECRET_NAME_WORDS :: [?]string{"TOKEN", "AUTH", "KEY", "SECRET", "PASSWORD", "COOKIE", "SESSION", "CREDENTIAL"}

// True when the variable name contains a secret-like word, ignoring ASCII case.
env_name_is_secret :: proc(name: string) -> bool {
	words := ENV_SECRET_NAME_WORDS
	for word in words {
		if len(word) > len(name) { continue }
		for start in 0 ..= len(name) - len(word) {
			if strings.equal_fold(name[start:start + len(word)], word) { return true }
		}
	}
	return false
}

// Removes the secret-named variables and logs their names (never values) to
// the network log. Returns how many were removed.
env_scrub_secrets_and_log :: proc() -> int {
	names: [dynamic]string
	defer {
		for name in names { delete(name) }
		delete(names)
	}
	env_scrub_secrets(&names)
	if len(names) > 0 {
		kproto.network_log("startup", strings.concatenate({"Removed secret-named environment variables (names only): ", strings.join(names[:], ", ", context.temp_allocator)}, context.temp_allocator))
	}
	return len(names)
}
