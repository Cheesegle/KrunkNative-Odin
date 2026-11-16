#+build !windows

package main

// The hybrid-GPU exports, MMCSS and power throttling are Windows features;
// other platforms have nothing to set up.
client_platform_init :: proc() {
}

client_platform_fini :: proc() {
}
