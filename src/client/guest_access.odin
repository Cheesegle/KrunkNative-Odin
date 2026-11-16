package main

// Guest (anonymous FRVR) access for live joins, without the browser helper.
//
// Krunker's page gets guest access from the FRVR SDK (frvr-sdk.min.js,
// FRVR.config.auth.enableAnonymousLogin): serviceClient.loginAsAnonymous()
// POSTs {"platform":"anonymous"} to https://crucible.frvr.com/v1/auth/login
// with Content-Type: application/json and stores the returned accessToken and
// refreshToken pair. getFreshAccessToken() POSTs {"refreshToken":...} to
// /v1/auth/refresh once the access token is within 60 seconds of its exp
// claim, and the matchmaker's seek-game and the game socket (at=) receive the
// access token exactly like an account token.
//
// The HTTP request runs on a worker thread so the frame loop never waits on
// it. network_log is not thread-safe, so the worker only fills its job and
// the frame thread logs the results after it finishes.

import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:thread"
import "core:time"
import curl "vendor:curl"
import access "../browser_access"
import shared "../shared"
import kproto "../krunker"

// The SDK's production apiBaseURL. Tests point this at a loopback server.
guest_auth_origin := "https://crucible.frvr.com/v1/auth"
// Whole sign-in budget, including a refresh that falls back to a login.
guest_auth_timeout_ms := 15000
// Empty means LOCALAPPDATA/Krodin. Tests use their own folder.
guest_cache_directory := ""

GUEST_CAPTCHA_HELPER_TEXT :: "Krunker requires verification (CAPTCHA) for this guest join. Verification opens the official page in the browser helper (krodin_browser.exe), which could not start. Rebuild the browser helper, or retry later."
GUEST_CAPTCHA_UNSUPPORTED_TEXT :: "Krunker requires verification (CAPTCHA) for this guest join. Verification needs the Windows browser helper, which this build does not have. Retry later."
GUEST_CAPTCHA_IDENTITY_TEXT :: "Verification finished in the browser under the browser's own account, so the guest join stopped to keep your guest identity. Retry Play as guest, or use Login."
GUEST_CAPTCHA_LOGIN_TEXT :: "Verification could not hand the game socket to a guest join. Retry Play as guest, or use Login to join with an account."

Guest_Status :: enum { IDLE, PENDING, READY, ERROR }
Guest_Step_Kind :: enum { LOGIN, REFRESH }

Guest_Step :: struct {
	kind: Guest_Step_Kind,
	result: kproto.Network_HTTP_Result,
}

// Owned by the worker until done is set, then by the frame thread.
Guest_Job :: struct {
	origin, refresh_token: string,
	timeout_ms: int,
	cancel, done: bool, // atomic
	steps: [2]Guest_Step,
	step_count: int,
	thread: ^thread.Thread,
}

Client_Guest :: struct {
	status: Guest_Status,
	// The current join uses the guest identity (Play as guest).
	active: bool,
	access_token, refresh_token: string,
	// One fresh token and one join retry after a rejection, never more.
	retried: bool,
	cache_loaded: bool,
	job: ^Guest_Job,
	started: time.Time,
	// Cancelled jobs finishing in the background; freed by the reaper.
	abandoned: [dynamic]^Guest_Job,
}

guest_log :: proc(text: string) { kproto.network_log("guest-auth", text) }

guest_register_secrets :: proc(guest: ^Client_Guest) {
	kproto.network_log_secret(guest.access_token)
	kproto.network_log_secret(guest.refresh_token)
	// Tokens also appear URL-encoded in matchmaker requests.
	for token in ([]string{guest.access_token, guest.refresh_token}) {
		if len(token) == 0 { continue }
		encoded := kproto.network_url_encode(token); defer delete(encoded)
		kproto.network_log_secret(encoded)
	}
}

// JWTs use base64url segments and dots. Anything else is not embedded in JSON.
guest_token_charset :: proc(token: string) -> bool {
	if len(token) == 0 || len(token) > 16384 { return false }
	for b in token { if !(b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '-' || b == '_' || b == '.' || b == '=') { return false } }
	return true
}

// Mirrors the SDK's login and refresh handlers: both strings present and the
// access token valid for more than 60 seconds. Returns owned copies.
guest_pair_parse :: proc(body: []byte, now: i64) -> (access_token, refresh_token: string, ok: bool) {
	value, err := json.parse(body)
	if err != .None { return }
	defer json.destroy_value(value)
	object, is_object := value.(json.Object)
	if !is_object { return }
	access_value, access_ok := object["accessToken"].(json.String)
	refresh_value, refresh_ok := object["refreshToken"].(json.String)
	if !access_ok || !refresh_ok || !guest_token_charset(string(access_value)) || !guest_token_charset(string(refresh_value)) { return }
	if !access.token_fresh(string(access_value), now) { return }
	return strings.clone(string(access_value)), strings.clone(string(refresh_value)), true
}

guest_step_succeeded :: proc(result: ^kproto.Network_HTTP_Result) -> bool {
	if result.code != .E_OK || result.status < 200 || result.status >= 300 { return false }
	access_token, refresh_token, ok := guest_pair_parse(result.body[:], time.time_to_unix(time.now()))
	delete(access_token); delete(refresh_token)
	return ok
}

guest_job_run :: proc(data: rawptr) {
	job := cast(^Guest_Job)data
	start := time.tick_now()
	remaining :: proc(job: ^Guest_Job, start: time.Tick) -> int {
		return job.timeout_ms - int(time.duration_milliseconds(time.tick_since(start)))
	}
	if len(job.refresh_token) > 0 {
		body := strings.concatenate({`{"refreshToken":"`, job.refresh_token, `"}`}); defer delete(body)
		url := fmt.aprintf("%s/refresh", job.origin); defer delete(url)
		job.steps[0] = {.REFRESH, kproto.network_http_quiet(url, "POST", body, remaining(job, start), &job.cancel)}
		job.step_count = 1
		// Like the SDK, a failed refresh ends this identity; sign in again.
		if guest_step_succeeded(&job.steps[0].result) || intrinsics.atomic_load(&job.cancel) || remaining(job, start) <= 0 {
			intrinsics.atomic_store(&job.done, true)
			return
		}
	}
	url := fmt.aprintf("%s/login", job.origin); defer delete(url)
	job.steps[job.step_count] = {.LOGIN, kproto.network_http_quiet(url, "POST", `{"platform":"anonymous"}`, remaining(job, start), &job.cancel)}
	job.step_count += 1
	intrinsics.atomic_store(&job.done, true)
}

guest_job_free :: proc(job: ^Guest_Job) {
	if job.thread != nil {
		thread.join(job.thread)
		thread.destroy(job.thread)
		curl.global_cleanup()
	}
	for i in 0 ..< job.step_count { kproto.network_http_result_free(&job.steps[i].result) }
	delete(job.origin)
	delete(job.refresh_token)
	free(job)
}

// Frees finished background jobs; wait joins all of them (shutdown).
client_guest_reap :: proc(guest: ^Client_Guest, wait: bool = false) {
	for i := len(guest.abandoned) - 1; i >= 0; i -= 1 {
		job := guest.abandoned[i]
		if !wait && !intrinsics.atomic_load(&job.done) { continue }
		guest_job_free(job)
		ordered_remove(&guest.abandoned, i)
	}
}

client_guest_cancel :: proc(client: ^Client) {
	guest := &client.guest
	if guest.job != nil {
		guest_log("Guest sign-in cancelled; the worker aborts its request and late replies are discarded.")
		intrinsics.atomic_store(&guest.job.cancel, true)
		append(&guest.abandoned, guest.job)
		guest.job = nil
	}
	if guest.status == .PENDING { guest.status = .IDLE }
}

client_guest_shutdown :: proc(client: ^Client) {
	client_guest_cancel(client)
	client_guest_reap(&client.guest, true)
	delete(client.guest.abandoned)
	delete(client.guest.access_token)
	delete(client.guest.refresh_token)
	client.guest = {}
}

// The cache holds "v1\n<refresh>\n<access>", DPAPI-encrypted for this user.
guest_cache_load :: proc() -> string {
	when ODIN_OS == .Windows { return access.cache_load(guest_cache_directory, access.GUEST_CACHE_NAME) }
	else { return "" }
}
guest_cache_save :: proc(value: string) -> bool {
	when ODIN_OS == .Windows { return access.cache_save(value, guest_cache_directory, access.GUEST_CACHE_NAME) }
	else { return false }
}
guest_cache_clear :: proc() {
	when ODIN_OS == .Windows { access.cache_invalidate(guest_cache_directory, access.GUEST_CACHE_NAME) }
}

guest_cache_value :: proc(guest: ^Client_Guest) -> string {
	return fmt.aprintf("v1\n%s\n%s", guest.refresh_token, guest.access_token)
}

guest_cache_parse :: proc(value: string) -> (access_token, refresh_token: string, ok: bool) {
	lines := strings.split(value, "\n"); defer delete(lines)
	if len(lines) != 3 || lines[0] != "v1" || !guest_token_charset(lines[1]) || !guest_token_charset(lines[2]) { return }
	return strings.clone(lines[2]), strings.clone(lines[1]), true
}

guest_begin :: proc(client: ^Client, refresh: string) -> bool {
	guest := &client.guest
	guest.status, guest.started = .PENDING, time.now()
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK {
		guest.status = .ERROR
		krunker_ws_set_status(client, "Could not initialize libcurl for guest sign-in.")
		return false
	}
	job := new(Guest_Job)
	job.origin, job.refresh_token, job.timeout_ms = strings.clone(guest_auth_origin), strings.clone(refresh), guest_auth_timeout_ms
	guest_register_secrets(guest)
	guest_log(fmt.tprintf("%s; worker thread started with timeout=%dms origin=%s. Tokens omitted.", len(refresh) > 0 ? "Renewing guest access with the stored refresh token (POST /refresh), falling back to an anonymous login" : "Requesting anonymous FRVR access (POST /login platform=anonymous)", job.timeout_ms, job.origin))
	job.thread = thread.create_and_start_with_data(job, guest_job_run, context)
	if job.thread == nil {
		curl.global_cleanup()
		guest_job_free(job)
		guest.status = .ERROR
		krunker_ws_set_status(client, "Could not start the guest sign-in worker. Retry Play as guest.")
		return false
	}
	guest.job = job
	krunker_ws_set_status(client, len(refresh) > 0 ? "Renewing guest access..." : "Signing in as guest...")
	return true
}

// Reuse fresh guest access, else refresh or sign in on the worker. A browser
// link never reaches the browser helper on this path.
client_guest_connect :: proc(client: ^Client, link: ^shared.Join_Link, connect: proc(^Client, ^shared.Join_Link) -> bool = krunker_ws_connect_ready, load: proc() -> string = guest_cache_load) -> bool {
	guest := &client.guest
	if guest.status == .PENDING { return true }
	if !guest.cache_loaded {
		guest.cache_loaded = true
		cached := load(); defer delete(cached)
		if access_token, refresh_token, ok := guest_cache_parse(cached); ok {
			delete(guest.access_token); delete(guest.refresh_token)
			guest.access_token, guest.refresh_token = access_token, refresh_token
			guest_log("Loaded the guest token pair from the encrypted DPAPI cache. Tokens omitted.")
		}
	}
	guest_register_secrets(guest)
	now := time.time_to_unix(time.now())
	if access.token_fresh(guest.access_token, now) {
		guest_log("Reusing guest access; expiry is more than 60 seconds away.")
		guest.status = .READY
		return connect(client, link)
	}
	delete(guest.access_token); guest.access_token = ""
	refresh := access.token_fresh(guest.refresh_token, now) ? guest.refresh_token : ""
	return guest_begin(client, refresh)
}

// A rejected guest token gets one new token and one join retry.
client_guest_retry :: proc(client: ^Client, rejected: bool) -> bool {
	guest := &client.guest
	if !rejected || !guest.active { return false }
	guest_log("Krunker rejected the guest access token; discarding it.")
	delete(guest.access_token); guest.access_token = ""
	if guest.retried {
		guest_log("Guest retry already used; stopping without another sign-in.")
		guest.status = .ERROR
		return false
	}
	guest.retried = true
	refresh := access.token_fresh(guest.refresh_token, time.time_to_unix(time.now())) ? guest.refresh_token : ""
	guest_log("Requesting new guest access for the single permitted retry.")
	return guest_begin(client, refresh)
}

guest_failure_text :: proc(result: ^kproto.Network_HTTP_Result) -> string {
	switch {
	case result.code == .E_OPERATION_TIMEDOUT:
		return "Guest sign-in timed out. Check your connection and retry Play as guest."
	case result.code != .E_OK:
		return fmt.tprintf("Guest sign-in failed: could not reach the FRVR login service (curl %v: %s). See logs/krunker-network.log", result.code, result.error_text)
	case result.status < 200 || result.status >= 300:
		safe := kproto.network_log_safe(string(result.body[:]), 240); defer delete(safe)
		return fmt.tprintf("Guest sign-in failed: HTTP %d, body=%s. See logs/krunker-network.log", result.status, safe)
	case:
		return fmt.tprintf("Guest sign-in failed: the login service returned no usable token pair (HTTP %d). See logs/krunker-network.log", result.status)
	}
}

client_guest_tick :: proc(client: ^Client, connect: proc(^Client, ^shared.Join_Link) -> bool = krunker_ws_connect_ready, persist: proc(string) -> bool = guest_cache_save) {
	guest := &client.guest
	client_guest_reap(guest)
	job := guest.job
	if job == nil { return }
	if !intrinsics.atomic_load(&job.done) {
		if time.since(guest.started) > time.Duration(job.timeout_ms + 2000) * time.Millisecond {
			guest_log("Guest sign-in passed its deadline; abandoning the worker.")
			client_guest_cancel(client)
			guest.status = .ERROR
			krunker_ws_set_status(client, "Guest sign-in timed out. Check your connection and retry Play as guest.")
		}
		return
	}
	guest.job = nil
	defer guest_job_free(job)
	now := time.time_to_unix(time.now())
	// Register every returned token before any of the bodies is logged.
	for i in 0 ..< job.step_count {
		if access_token, refresh_token, ok := guest_pair_parse(job.steps[i].result.body[:], now); ok {
			kproto.network_log_secret(access_token); kproto.network_log_secret(refresh_token)
			delete(access_token); delete(refresh_token)
		}
	}
	for i in 0 ..< job.step_count {
		step := &job.steps[i]
		r := &step.result
		guest_log(fmt.tprintf("POST %s/%s HTTP=%d curl=%v (%s) cancelled=%v body_limit_exceeded=%v total_ms=%.1f body=%s", job.origin, step.kind == .LOGIN ? "login" : "refresh", r.status, r.code, r.error_text, r.cancelled, r.limit_exceeded, r.total_ms, string(r.body[:])))
	}
	last := &job.steps[job.step_count - 1]
	if job.steps[0].kind == .REFRESH && !guest_step_succeeded(&job.steps[0].result) {
		guest_log("Guest refresh failed; the stored refresh token and its cache entry were discarded.")
		delete(guest.refresh_token); guest.refresh_token = ""
		guest_cache_clear()
	}
	access_token, refresh_token, ok := guest_pair_parse(last.result.body[:], now)
	if last.result.code != .E_OK || last.result.status < 200 || last.result.status >= 300 || !ok {
		delete(access_token); delete(refresh_token)
		guest.status = .ERROR
		krunker_ws_set_status(client, guest_failure_text(&last.result))
		return
	}
	delete(guest.access_token); delete(guest.refresh_token)
	guest.access_token, guest.refresh_token = access_token, refresh_token
	guest_register_secrets(guest)
	exp, _ := access.token_expiry(guest.access_token)
	guest_log(fmt.tprintf("Guest access ready via %s; access exp_unix=%d remaining_seconds=%d (decoded only, signature not verified). Tokens omitted.", last.kind == .LOGIN ? "anonymous login" : "refresh", exp, exp - now))
	value := guest_cache_value(guest); defer delete(value)
	if !persist(value) { guest_log("Guest token pair kept in memory only; the encrypted cache was not updated.") }
	guest.status = .READY
	krunker_ws_set_status(client, "Signed in as guest. Resolving lobby...")
	connect(client, &client.join_link)
}
