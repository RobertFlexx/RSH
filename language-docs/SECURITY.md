# Security notes

SRSH is a shell. If you run a command, source a script, load a plugin, call native C, or execute generated code, that code has your user account's privileges. There is no pretend sandbox hiding underneath it.

Things the runtime does try to get right:

- `~/.srsh` state directories are private where the OS permits it.
- history/state writes use temporary files and atomic replacement.
- automatically loaded rc/plugin files must be regular files owned by the current user and not group/world writable.
- symlinked auto-loaded plugins are refused.
- script, token, nesting, recursion and command-substitution sizes are bounded.
- `readfile()` and structured process capture have size limits.
- `cmd(...)` keeps argv data out of shell reparsing.
- ordinary list/map/string data is copied across RSH task boundaries; deliberate shared mutation uses objects, atoms or channels.
- worker tasks cannot silently rewrite the process environment or a shared `space`.
- structured command children are reaped on error paths.

## Dynamic code

`code name ... end` is preferable when you know the code at parse time: the body is parsed before it can run.

`code(string)`, `eval(string)`, `run(string)`, `sh(string)` and `capture(string)` are intentionally dynamic. Do not build those strings from hostile input and then call them. Use values and `cmd(...)` when data is not trusted.

Ruby plugins are trusted code. That is a feature of a Ruby shell, not a security boundary.

## Native C bridges

`bridge` uses the platform C ABI directly. Signature checking only checks the RSH declaration; SRSH cannot prove that the C function on the other side actually has that signature.

A bad pointer, wrong return type, incorrect calling convention, use-after-free in a library, or just a buggy C function can segfault the entire shell. This is normal FFI territory.

Prefer `cstr` for input strings and `cbuf()` for bounded writable memory. Keep raw `ptr` use small and boring. `@self` exposes symbols from the current process and loaded runtime libraries, so only bind symbols you understand.

## Concurrency

Task cancellation stops the Ruby thread as best it can; it does not undo file writes or network activity that already happened.

`parallel()` uses Ruby threads. On CRuby, the GVL still limits CPU-bound Ruby bytecode. `pmap()` uses `fork` on Unix and therefore has process-copy semantics instead.

Objects expose synchronized slot updates, but synchronization does not magically make a multi-step algorithm race-free. Use atoms/channels when the ownership story is clearer that way.

## Audit status

SRSH has automated parser, shell, TTY and concurrency tests, but it has not had an independent security audit. Treat that sentence more seriously than a big “production ready” badge.
