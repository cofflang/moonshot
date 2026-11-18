#!/usr/bin/env python3
#
# gen_hostile_disks.py — part of the moonshot operating system.
#
# Copyright (C) 2026 tavro
#
# This file is part of moonshot, an operating system built from scratch.
# moonshot is free software, distributed under the GNU General Public
# License version 3 or (at your option) any later version, WITHOUT ANY
# WARRANTY; see the LICENSE file for the full text.
#
# Writes the corrupted jakel disk images that tests/verify_hostile_disks.sh
# boots, hostile disk formats. They are
# truncated images, directory loops, oversized lengths and unterminated names.
#
#   gen_hostile_disks.py list            one case name a line
#   gen_hostile_disks.py DIR [NAME...]   write DIR/NAME.img for each case
#
# The layout is jakel.c0's. Sector 0 is the superblock, the magic then five
# little-endian int64 fields (version, node count, name limit, first data
# sector, data sector count). The node table follows, 64 bytes a node, four
# int64 fields (type, parent, size, name length) and the name inline at +32.
# File data starts at the sector the superblock names.

import struct
import sys

SECTOR = 512
DISK_SECTORS = 20480
FREE, FILE, DIR = 0, 1, 2
NODES = 8
FIRST_DATA = 1 + NODES * 64 // SECTOR
INT64_MAX = (1 << 63) - 1


def node(kind, parent, size, name, name_len=None, raw_name=None):
    if raw_name is None:
        raw_name = name.encode()
    if name_len is None:
        name_len = len(raw_name)
    return struct.pack("<qqqq", kind, parent, size, name_len) + raw_name.ljust(32, b"\0")[:32]


def image(nodes, data=b"", sb_count=NODES, sb_first=None, sectors=DISK_SECTORS, magic=b"JAKELBK\0"):
    # The table is laid out for a count the kernel accepts, the superblock
    # fields can say something else.
    if sb_first is None:
        sb_first = 1 + sb_count * 64 // SECTOR
    table_nodes = sb_count if 8 <= sb_count <= 128 and sb_count % 8 == 0 else NODES
    sb = magic + struct.pack("<qqqqq", 1, sb_count, 32, sb_first, 0)
    body = sb.ljust(SECTOR, b"\0") + b"".join(nodes).ljust(table_nodes * 64, b"\0")
    start = (1 + table_nodes * 64 // SECTOR) * SECTOR
    return (body.ljust(start, b"\0") + data).ljust(sectors * SECTOR, b"\0")


ROOT = node(DIR, 0, 0, "/")


def cases():
    c = {}

    # Truncated images.
    full = image([ROOT, node(FILE, 0, 600, "a.txt")], b"x" * 600)
    c["trunc_magic_only"] = full[:8]
    c["trunc_mid_superblock"] = full[:300]
    c["trunc_superblock_only"] = full[:SECTOR]
    c["trunc_mid_table"] = full[:SECTOR + 3 * 64 + 20]
    c["trunc_table_only"] = full[:FIRST_DATA * SECTOR]
    c["trunc_mid_data"] = full[:FIRST_DATA * SECTOR + 100]
    wide = image([ROOT, node(FILE, 0, 64 * SECTOR, "big.bin")], b"y" * (64 * SECTOR))
    c["trunc_data_claims_more"] = wide[:FIRST_DATA * SECTOR + 2 * SECTOR]
    c["trunc_full_table_128"] = image([ROOT], sb_count=128)[:20 * SECTOR]

    # Loops in the directory tree.
    c["loop_two_cycle"] = image([ROOT, node(DIR, 2, 0, "a"), node(DIR, 1, 0, "b")])
    c["loop_self_parent"] = image([ROOT, node(DIR, 1, 0, "a")])
    c["loop_root_child_of_dir"] = image([node(DIR, 1, 0, "/"), node(DIR, 0, 0, "a")])
    c["loop_ring_of_seven"] = image([ROOT] + [node(DIR, i % 7 + 1, 0, "d%d" % i) for i in range(1, 8)])
    c["loop_file_parent_cycle"] = image([ROOT, node(FILE, 2, 0, "f"), node(FILE, 1, 0, "g")])
    c["loop_root_self_file"] = image([node(FILE, 0, 0, "/")])

    # Oversized lengths and counts.
    c["big_size_int64_max"] = image([ROOT, node(FILE, 0, INT64_MAX, "big")])
    c["big_size_2p62"] = image([ROOT, node(FILE, 0, 1 << 62, "big")])
    c["big_size_negative"] = image([ROOT, node(FILE, 0, -1, "neg")])
    c["big_size_int64_min"] = image([ROOT, node(FILE, 0, -(1 << 63), "min")])
    c["big_size_past_image"] = image([ROOT, node(FILE, 0, 4 * 1024 * 1024, "past")])
    c["big_size_past_arena"] = image([ROOT, node(FILE, 0, 64 * 1024 * 1024, "huge")])
    c["big_size_two_files"] = image([ROOT, node(FILE, 0, 6 * 1024 * 1024, "a"), node(FILE, 0, 6 * 1024 * 1024, "b")])
    c["big_name_len_2p62"] = image([ROOT, node(FILE, 0, 0, "n", name_len=1 << 62)])
    c["big_name_len_negative"] = image([ROOT, node(FILE, 0, 0, "n", name_len=-5)])
    c["big_name_len_int64_max"] = image([ROOT, node(FILE, 0, 0, "n", name_len=INT64_MAX)])
    c["big_node_count"] = image([ROOT], sb_count=1 << 40, sb_first=2)
    c["big_node_count_129"] = image([ROOT], sb_count=129, sb_first=2)
    c["zero_node_count"] = image([ROOT], sb_count=0, sb_first=1)
    c["negative_node_count"] = image([ROOT], sb_count=-8, sb_first=-7)
    c["odd_node_count"] = image([ROOT], sb_count=12, sb_first=2)
    c["first_data_mismatch"] = image([ROOT], sb_first=3)
    c["first_data_huge"] = image([ROOT], sb_first=1 << 40)
    c["parent_far_outside"] = image([ROOT, node(FILE, 1 << 40, 0, "evil")])
    c["parent_negative"] = image([ROOT, node(FILE, -1, 0, "evil")])
    c["parent_int64_min"] = image([ROOT, node(FILE, -(1 << 63), 0, "evil")])
    c["type_invalid"] = image([ROOT, node(77, 0, 0, "odd"), node(-3, 0, 0, "odd2")])
    c["parent_is_file"] = image([ROOT, node(FILE, 0, 0, "f"), node(FILE, 1, 0, "g")])
    c["root_is_file"] = image([node(FILE, 0, 4, "/")], b"abcd")

    # Names without a terminator.
    full32 = b"A" * 32
    c["name_32_bytes_no_nul"] = image([ROOT, node(FILE, 0, 0, "", name_len=32, raw_name=full32)])
    c["name_len_31_no_nul"] = image([ROOT, node(FILE, 0, 0, "", name_len=31, raw_name=full32)])
    c["name_len_huge_no_nul"] = image([ROOT, node(FILE, 0, 0, "", name_len=1000, raw_name=full32)])
    c["name_every_node_no_nul"] = image(
        [ROOT] + [node(FILE, 0, 0, "", name_len=32, raw_name=full32) for _ in range(NODES - 1)])
    c["name_len_zero_with_bytes"] = image([ROOT, node(FILE, 0, 0, "", name_len=0, raw_name=full32)])
    c["name_dir_no_nul"] = image([ROOT, node(DIR, 0, 0, "", name_len=32, raw_name=full32)])
    c["name_slashes"] = image([ROOT, node(FILE, 0, 0, "a/b/../c"), node(FILE, 0, 0, "/")])
    c["name_duplicates"] = image([ROOT, node(FILE, 0, 0, "dup"), node(FILE, 0, 0, "dup")])
    c["file_named_test"] = image([ROOT, node(FILE, 0, 8, "test")], struct.pack("<q", 1 << 40))
    c["bad_magic_near"] = image([ROOT], magic=b"JAKELBK\x01")
    return c


def main(argv):
    all_cases = cases()
    if len(argv) == 2 and argv[1] == "list":
        print("\n".join(all_cases))
        return 0
    if len(argv) < 2:
        print("usage: gen_hostile_disks.py list | DIR [NAME...]", file=sys.stderr)
        return 2
    names = argv[2:] or list(all_cases)
    for name in names:
        if name not in all_cases:
            print("no such case: " + name, file=sys.stderr)
            return 2
        with open("%s/%s.img" % (argv[1], name), "wb") as f:
            f.write(all_cases[name])
    return 0


sys.exit(main(sys.argv))
