package main

import "core:testing"

@(test)
env_name_secret_predicate :: proc(t: ^testing.T) {
	secret := []string{
		"KRUNKER_ACCESS_TOKEN", "token", "GITHUB_TOKEN", "Authorization", "OAUTH_X", "API_KEY", "apikey", "MY_SECRET",
		"DB_PASSWORD", "Cookie", "SESSIONNAME", "aws_session_token", "GOOGLE_APPLICATION_CREDENTIALS", "x_TOKEN_y",
	}
	plain := []string{"", "PATH", "LOCALAPPDATA", "USERPROFILE", "TEMP", "WEBVIEW2_USER_DATA_FOLDER", "KRODIN_DEV", "TOKE", "SESSIO", "=C:"}
	for name in secret { testing.expectf(t, env_name_is_secret(name), "%q should be secret", name) }
	for name in plain { testing.expectf(t, !env_name_is_secret(name), "%q should not be secret", name) }
}
