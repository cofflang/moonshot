# jakel locking and kept node ids

jakel's tables (the node arrays, each folder's entry list and each file's
data) are changed both by the shell task, which runs with interrupts on and
is preempted by the timer, and by ring-3 file syscalls, which run with
interrupts off. Every public jakel call that reads or changes the tables
therefore runs inside `jakel_lock`, which turns interrupts off and nests.
Each `name_held` function is the body and expects its caller to hold the
lock. This file lists what touches the tables without the lock and why that
is sound, and every place that keeps a node id beyond one jakel call.

## Inside jakel.c0 without the lock

- `jakel_valid`, `jakel_is_dir`, `jakel_stamp`, `jakel_can_read`,
  `jakel_can_write`, `jakel_can_add`, `jakel_can_place`, `jakel_can_replace`
  are single loads from the fixed node arrays, which are allocated once at
  boot and never freed, so a read never faults. Every change calls them
  again inside its own locked body, so a stale answer seen outside a lock
  only picks a message.
- `jakel_alloc_node`, `jakel_free_node`, `jakel_add_child`,
  `jakel_remove_child`, `jakel_copy_name`, `jakel_str_eq`, `jakel_str_len`,
  `jakel_dalloc`, `jakel_dfree`, `jakel_used_bytes` are helpers called only
  from locked bodies or from boot code. chrone reads `jakel_used_bytes` from
  the timer interrupt, which cannot run inside a locked section.
- `jakel_init`, `jakel_load`, `jakel_install_pack` (its seed calls are
  locked), the `jakel_drop_*` functions, the self tests, the seeded songs and
  sprites, `jakel_bounds_test` and `jakel_largest_free` run only at boot,
  before the scheduler starts, with interrupts off.
- `jakel_sync` is the one exception named at the lock. Its drive writes are
  slow port I/O, so it copies the node table under the lock, then copies
  each sector under the lock from the node as it is at that moment
  (`jakel_sync_sector`), limited to the size the table recorded and zero
  past what the node still holds, and writes the sector with interrupts on.
  It keeps no pointer into jakel past an unlock. `jakel_sync_write` reads
  only its own copy of the table.

## Outside jakel.c0, direct loads of jakel's arrays

- syscall.c0 `sys_dispatch`. Ring-3 syscalls run with interrupts off, so a
  whole syscall is one section.
- `spawn_program_owned`, `clock_offset_save`, `sks_run`,
  `shell_tab_complete`, `interpret`, `run3`, `sk_execute`'s source check,
  `write`, `copy`'s destination, `rename` (`sk_rename_held`) and `change`
  (`sk_change_cwd`) find, check and act inside their own jakel section.
- The remaining shell type checks (echo --file, list, make, copy's source,
  `sk_foreign_output`, `sk_replace_refused`, `sk_start_refused`) are one load
  each from the fixed arrays to pick a message or refuse early. The jakel
  call that acts afterwards checks again under the lock.

## Node ids kept outside jakel

Folder ids are refused by jakel itself when they do not name a live folder
(`jakel_lookup_held`, `jakel_open_held` at the start and at every path step,
`jakel_list_held`, `jakel_where_held`), so no stale id makes jakel read a
file's data as an entry list. An id that must keep naming the same node
carries the node's creation stamp (`jakel_stamp`), which no two nodes share
within a boot. The stamp is always taken in the same jakel section that
found the node.

- Window working folder, skalman.c0 `sk_cwd_base` with `sk_cwd_stamp_base`.
  Read through `sk_cwd(f)` and `sk_cwd_stamp(f)` in one section. Set by
  `sk_change_cwd` (change, which finds the folder and keeps its stamp in one
  section), `sk_set_cwd_stamped` (split and SYS_SHELL, with the stamp the
  caller read together with the folder) and `sk_set_cwd` (the root folder,
  for shell_init and `raket_reset_session`). A folder that is gone or whose
  slot holds another node sends the window to the root folder, and the
  window prints "the working folder is gone, back in /".
- Task working folder, syscall.c0 `task_cwd_base` with
  `task_cwd_stamp_base`. Every spawn passes the caller's folder together with
  the stamp it read with it, and `spawn_program_owned` refuses a folder that
  no longer has that stamp. The stamp travels in the spawn record (rec + 64)
  and `spawn_elf_entry` stores it. `task_cwd` falls back to the root and
  says so on serial.
- Open files, syscall.c0 `fd_file_base` with `fd_stamp_base`. SYS_OPEN
  stores the stamp. SYS_READ and SYS_WRITE refuse a slot whose file is gone
  or replaced (`fd_live`). SYS_CLOSE frees the slot either way.
- Ids held for one shell command (make's parent folders, write's and copy's
  target, rename's source and destination, execute's source) are acted on
  by a jakel call that checks the node again, or inside one section.
- Paths, not ids. Ring-3 programs (hylla, skrift, pensel, utsikt and the
  rest) name files by path through SYS_OPEN and SYS_LISTDIR each time.
  kakel, dvala and the script engine keep no node ids, and tid.zone is
  looked up by name each time.
