Vim-ugdb
========

This is a (so far very much proof-of-concept) plugin remotely control instances of ugdb via the provided IPC interface.

ugdb is an alternative tui for GDB. (So far it is also unfinished and unpublished, but hopefully that will change soon.)

Vim-ugdb currently supports the following commands:

- **UGDBBreakpoint:** Set a breakpoint at the current file and line.
- **UGDBSelectInstance:** Manually select the ugdb instance to connect to.

TODO:

- Keep server object active (maybe, we will see if that makes sense)
- Smart server selection (maybe interactive fallback) using get_instance_info
- Timeout on missbehaving servers
