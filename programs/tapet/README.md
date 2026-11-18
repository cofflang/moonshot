# tapet

`./build.sh` builds `build/tapet.elf` with the gated coff1 and smed toolchain.
The kernel embeds the standalone ELF and jakel seeds `tapet.elf` at the filesystem
root on ordinary boot. No new automatic login action is installed.

Run `start tapet.elf picture.spr 7 64 48`, then
`write hylla.bg picture.spr`. Start hylla or press `r` in its window.
The arguments are output path, decimal seed, width and height. The seed is between
0 and 2147483647. Dimensions must fit both the window ceiling and hylla's image
limits. Return codes are 1 for invalid arguments, 2 for allocation failure and 3
for a failed write. An existing output file can be overwritten.

The single pattern is a diagonal weave. The same arguments produce the same
pixels and header without consulting the clock. The file contains width, height
and one frame as little-endian 64-bit words, then blue, green, red and an unused
zero byte per pixel. Every RGB pixel is nonzero. Recipes are not stored.

Hylla tiles the picture at its original size in its own window. Closing hylla
removes the picture from view. The lock covers it. This program does not change
the desktop layout or install a background process.

`tests/verify_tapet.sh` runs a ring-3 fixture in an isolated temporary tree. It
substitutes tapet for the existing tone test payload to isolate generator checks
from normal boot delivery. `TAPET_RED=1` corrupts the frame count in that
fixture and must fail the fixed-file hash check. The test also checks hylla
pixels, lock coverage across two frames and calls `tools/screenshot.sh`.

`TAPET_RED=pixels` selects a missing background file after checking the generated
hash and must fail the hylla pixel assertion. `TAPET_RED=lock` skips the lock key
after checking hylla pixels and must fail wallpaper coverage. Both controls change
only the temporary guest setup.

`tests/verify_tapet_boot.sh` boots the normal profile with the unmodified standalone
program, runs the documented shell command, refreshes the existing hylla and checks the
generated picture through
hylla at three framebuffer coordinates. It does not substitute the tone payload.
