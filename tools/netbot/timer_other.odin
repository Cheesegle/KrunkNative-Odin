#+build !windows
package netbot

import "core:time"

// nanosleep on Linux is already sub-millisecond.
bot_sleep_begin :: proc() {}
bot_sleep_end :: proc() {}
bot_sleep :: proc(d: time.Duration) { time.sleep(d) }
