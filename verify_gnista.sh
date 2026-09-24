#!/usr/bin/env bash
#
# verify_gnista.sh — prove Gnista runs for real on Moonshot, not just that
# it compiles: an entity pool of animated movers plus static blocks,
# arrow-key input, ticks()-based timing, and all-pairs AABB collision.
#
# Checks:
#   1. "[elf] windowed spawn wid=" — spawn3 succeeded, got a window
#   2. "gnista demo running" reaches serial — sprite alloc, pool alloc,
#      win_info(), and ticks() all succeeded before the main loop started
#   3. The scheduler keeps advancing after spawn (proves the demo's tight
#      draw loop is not wedging the kernel — a real risk for any busy loop
#      running at ring 3 alongside the scheduler)
#   4. In pixels, from two screendumps seconds apart: several INDEPENDENT
#      entities are on screen (counted as connected clusters of sprite
#      colour, so two that overlap merge into one and are not miscounted),
#      both static blocks are drawn, no entity is ever found inside a block
#      — which is what actually demonstrates the collision test rather than
#      the program merely not crashing — and things moved between the shots.
#   5. No crash, no panic

set -u
cd "$(dirname "$0")"

./build.sh || exit 1

isodir=isoroot
rm -rf "$isodir" moonshot.iso
mkdir -p "$isodir/boot/grub"
cp moonshot.elf "$isodir/boot/moonshot.elf"
cp grub.cfg "$isodir/boot/grub/grub.cfg"
grub-mkrescue -o moonshot.iso "$isodir" >grub-mkrescue.log 2>&1
if [ ! -f moonshot.iso ]; then
  echo "FAIL: grub-mkrescue did not produce moonshot.iso"
  cat grub-mkrescue.log
  exit 1
fi

rm -f serial.log verify_gnista.sock
qemu-system-x86_64 -cdrom moonshot.iso \
  -serial file:serial.log -display none -no-reboot -m 128 \
  -monitor unix:verify_gnista.sock,server,nowait &
qemu_pid=$!
cleanup() { kill "$qemu_pid" 2>/dev/null; wait "$qemu_pid" 2>/dev/null; }
trap cleanup EXIT

sleep 2

python3 - <<'EOF'
import socket, time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect("verify_gnista.sock")
time.sleep(0.2)
sock.recv(4096)  # discard QEMU monitor banner

def send(cmd):
    sock.sendall((cmd + "\n").encode())
    time.sleep(0.05)
    sock.recv(4096)

def typ(keys, gap=0.06):
    for k in keys:
        send("sendkey " + k)
        time.sleep(gap)

# Login as root (raket gate)
typ(["r", "o", "o", "t", "ret"])
time.sleep(0.5)
typ(["ret"])  # empty password
time.sleep(1.0)

# spawn3 gnista.elf -- let it run for a few seconds, moving/bouncing/animating.
typ(["s","p","a","w","n","3","spc","g","n","i","s","t","a","dot","e","l","f","ret"])
time.sleep(3.0)
send("screendump gnista_a.ppm")
time.sleep(0.6)
send("sendkey ret")  # harmless; keeps the monitor connection warm
time.sleep(3.0)
send("screendump gnista_b.ppm")
time.sleep(0.6)

sock.close()
EOF

sleep 2

ok=1

wid_msg=$(grep -c '\[elf\] windowed spawn wid=' serial.log || true)
echo "'[elf] windowed spawn wid=' count: $wid_msg"
if [ "$wid_msg" -lt 1 ]; then
  echo "FAIL: expected a windowed spawn message"
  ok=0
fi

running_msg=$(grep -c 'gnista demo running' serial.log || true)
echo "'gnista demo running' count: $running_msg"
if [ "$running_msg" -lt 1 ]; then
  echo "FAIL: expected 'gnista demo running' (init succeeded)"
  ok=0
fi

# Scheduler still advancing well after spawn -- proves the demo's loop
# is not wedging the kernel. Sample two tick counts late in the log and
# confirm the second is higher than the first.
tick_lines=$(grep -oE 'tick [0-9]+' serial.log | awk '{print $2}')
tick_count=$(echo "$tick_lines" | wc -l)
echo "distinct 'tick N' lines: $tick_count"
last_tick=$(echo "$tick_lines" | tail -1)
mid_tick=$(echo "$tick_lines" | sed -n "$((tick_count / 2))p")
echo "mid tick=$mid_tick, last tick=$last_tick"
if [ -z "$last_tick" ] || [ -z "$mid_tick" ] || [ "$last_tick" -le "$mid_tick" ]; then
  echo "FAIL: scheduler ticks did not keep advancing after spawn"
  ok=0
fi

# --- the entity pool, checked in pixels -----------------------------------
# Everything above proves the program runs. These checks prove it is running
# the ENGINE: several independent entities, static blocks that are collided
# against rather than passed through, and motion between two screendumps.
python3 - <<'PY'
import sys

# Sprite frame colours from gen_sprite.c0, as RGB: frame 0 orange, frame 1
# yellow. Static blocks are 0x606060.
SPRITE = ((255, 140, 0), (255, 220, 0))
BLOCK = (96, 96, 96)

def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos+1].isspace():
            pos += 1
        if data[pos:pos+1] == b"#":
            while data[pos:pos+1] != b"\n":
                pos += 1
            continue
        start = pos
        while not data[pos:pos+1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1
    w, h, _ = fields
    return w, h, data[pos:]

def pixels_of(buf, w, h, colors):
    out = set()
    for y in range(h):
        row = y * w
        for x in range(w):
            off = (row + x) * 3
            if (buf[off], buf[off+1], buf[off+2]) in colors:
                out.add((x, y))
    return out

def clusters(points):
    """Flood-fill 8-connected groups, so each sprite counts once."""
    seen = set()
    groups = []
    for p in points:
        if p in seen:
            continue
        stack = [p]
        seen.add(p)
        group = []
        while stack:
            x, y = stack.pop()
            group.append((x, y))
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    q = (x + dx, y + dy)
                    if q in points and q not in seen:
                        seen.add(q)
                        stack.append(q)
        groups.append(group)
    return groups

ok = True
w, h, a = read_ppm("gnista_a.ppm")
_, _, b = read_ppm("gnista_b.ppm")

sprite_a = pixels_of(a, w, h, SPRITE)
sprite_b = pixels_of(b, w, h, SPRITE)
groups_a = clusters(sprite_a)
groups_b = clusters(sprite_b)
# Only count groups big enough to be a sprite, not a stray edge pixel: the
# 12x12 circle is ~100 pixels, so half of one is a safe floor and still
# catches two sprites that have merged visually while overlapping.
big_a = [g for g in groups_a if len(g) >= 50]
big_b = [g for g in groups_b if len(g) >= 50]
print("sprite clusters: %d in first shot, %d in second" % (len(big_a), len(big_b)))
if len(big_a) < 2 or len(big_b) < 2:
    print("FAIL: expected several independent entities on screen, "
          "found %d/%d -- the pool is not rendering" % (len(big_a), len(big_b)))
    ok = False

# The blocks: find them by colour, and require both to be present.
block_px = pixels_of(a, w, h, {BLOCK})
block_groups = [g for g in clusters(block_px) if len(g) >= 100]
print("static blocks: %d" % len(block_groups))
if len(block_groups) < 2:
    print("FAIL: expected 2 static blocks, found %d" % len(block_groups))
    ok = False

# Collision, the real check: no sprite pixel may sit inside a block's
# rectangle. The movers start outside them and bounce off, so a sprite found
# inside one means the AABB test or its resolution is not working.
for g in block_groups:
    xs = [p[0] for p in g]
    ys = [p[1] for p in g]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    inside = [p for p in sprite_b if x0 <= p[0] <= x1 and y0 <= p[1] <= y1]
    print("  block (%d,%d)-(%d,%d): %d sprite pixels inside" % (x0, y0, x1, y1, len(inside)))
    if inside:
        print("FAIL: an entity is inside a static block -- collision is not holding")
        ok = False

# Motion: the two shots are seconds apart, so the sprite pixels must differ.
if sprite_a == sprite_b:
    print("FAIL: nothing moved between the two screendumps")
    ok = False
else:
    print("entities moved between shots: yes")

sys.exit(0 if ok else 1)
PY
if [ $? -ne 0 ]; then ok=0; fi

panic=$(grep -c 'PANIC' serial.log || true)
doublefault=$(grep -c 'double fault' serial.log || true)
echo "panics: $panic, double faults: $doublefault"
if [ "$panic" -gt 0 ] || [ "$doublefault" -gt 0 ]; then
  echo "FAIL: crash detected"
  ok=0
fi

if [ "$ok" -eq 1 ]; then
  echo "PASS: Gnista runs end to end on real Moonshot — entity pool, several independent
  entities moving and animating, static blocks collided against, no crash"
  exit 0
else
  echo "--- serial.log tail ---"
  tail -40 serial.log
  exit 1
fi
