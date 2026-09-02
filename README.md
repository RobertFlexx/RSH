# srsh, Simple Ruby Shell

`srsh` is a Unix shell written in Ruby. Its scripting language is **RSH**.

The basic idea is pretty simple: keep the parts of a normal shell that are already good, then stop making people switch languages when a script gets serious.

```rsh
printf 'c\na\nb\n' | sort

files := glob("src/**/*.rb")
  |> reject(::p => contains(p, "/vendor/"))
  |> sort

? files |> len > 20 => = "that's a lot of Ruby"
```

`|` is still a Unix process pipe. `|>` is an RSH value pipe. They look related because they *are* related, but they move different things.

This tree reports **1.0.0**. It is the unreleased 1.0 line; the older 1.1/1.2 numbers were development snapshots and were a dumb way to version something that had not shipped yet.

## What SRSH is trying to be

Bash is fantastic at launching programs. It gets a lot less fun when you need nested data, workers, reusable modules, objects, error handling, higher-order functions, or a pile of state that has to remain understandable next month.

RSH is meant to cover that gap without turning the shell into a foreign environment:

```rsh
branch := $(git branch --show-current)

fn changed(path) => cmd("git", "diff", "--quiet", "--", path).result().status != 0

dirty := glob("src/**/*") |> filter(changed)
= "#{branch}: #{dirty |> len} changed files"
```

It is **not a Bash parser**. Existing Bash scripts still belong to Bash. The goal is that new automation can start as a shell one-liner and grow into a proper RSH program without a rewrite.

## Build and run

Ruby 3.2+ is required.

```sh
make test
./bin/srsh
```

The shell is fully usable as Ruby-only code. There is a tiny optional C extension for hot lexer work and Linux process naming:

```sh
make native
./bin/srsh
```

YJIT is enabled when the running Ruby supports it. Set `SRSH_YJIT=0` if you want it off.

Install somewhere else with:

```sh
make PREFIX="$HOME/.local" install
```

## The syntax has a reason

RSH has some odd-looking syntax, but the goal is not to win a weird-language contest.

There are a few boundaries you hit constantly in shell programming, and RSH gives each one a visible shape:

```text
command | command        bytes/processes move between Unix programs
value |> function        RSH values move through functions
$(command)               process output crosses into the value layer
name := value            local RSH binding
$NAME := value           exported process environment
::x => expression        tiny callable value
bridge ... from ...      RSH crosses into a native C ABI
```

That makes parsing less ambiguous around arbitrary Unix command names, and it lets hot scripts stay short without turning maintained code into punctuation soup.

Readable forms exist too:

```rsh
fn deploy(files, dry := no)
  if dry
    = "would deploy #{files |> len} files"
  else
    each files -> path
      emit path
    end
  end
end
```

The short forms lower to the same AST:

```rsh
:: twice(x) => x * 2
? ready => emit "go"
@ jobs -> job => = job.name
```

Use whichever one fits the size of the job.

## The REPL is actually an RSH REPL

Bindings, expressions and blocks work directly at the shell prompt:

```text
> x := 21
> = x * 2
42

> fn triple(n)
... return n * 3
... end
> = triple(10)
30
```

Multiline list/map/call expressions also continue properly:

```text
> jobs := [
...   fetch("a"),
...   fetch("b")
... ]
```

That same completeness logic is used for manually entered continuations. For an actual terminal paste, SRSH enables bracketed-paste mode and captures the whole clipboard payload before parsing any of it. Multi-line pastes get a small preview; press Enter once to run the whole program or Ctrl-C to throw it away. Embedded newlines never become a queue of accidental commands.

The editor keeps the old SRSH behavior too: prefix history prediction, Right Arrow to accept it, UTF-8 cursor movement, history navigation, and first-Tab/second-Tab completion.

## Shell side

Normal Unix muscle memory is supposed to work:

```sh
cat *.log | grep ERROR | sort -u
make -j8 && put "built"
long_job &
jobs
fg %1
```

Implemented shell features include:

- `fork`/`exec` pipelines and process groups
- `|`, `&&`, `||`, `;`, background `&`
- `<`, `>`, `>>`, `2>`, `2>>`
- `jobs`, `fg`, `bg`
- command substitution with nested `$(...)`
- aliases
- `$VAR`, `${VAR}`, `$?`, `$!`, positional arguments
- pathname globbing (`*`, `?`, `[...]`, and recursive `**` where Ruby's glob supports it)
- `~` expansion
- command lookup caching
- `cd`, `pwd`, `ls`, `printf`, `export`, `read`, `source`, `which`/`type`
- `pushd`, `popd`, `dirs`, `umask`, `kill`
- `option pipefail`, `option nounset`, `option noclobber`
- `option strict yes` as a shortcut for `pipefail + nounset`

No-match globs stay literal, which is a much less surprising default for an interactive shell.

## Values and functional scripting

RSH has integers, floats, strings, booleans, `void`, lists, maps, ranges, lambdas, code values, tasks, prototypes, namespaces, native handles and structured commands.

```rsh
users := json(readfile("users.json"))

enabled := users
  |> filter(::u => u?.enabled ?? no)
  |> sort(::u => lower(u.name))

= enabled |> map(::u => u.name)
```

The usual functional operations are built in:

```text
map filter reject fold find any all count sum
sort uniq flat zip enumerate take drop chunk group
each tap partial compose
```

Named functions are first-class too:

```rsh
fn square(x) => x * x
= 1 .. 10 |> map(square) |> sum
```

## Objects without a ceremony tax

RSH uses prototypes plus traits. There is no class-inheritance maze to climb through just to hold some state.

```rsh
trait Named
  fn label() => "#{self.name}: #{self.value}"
end

proto Counter(name, start := 0) with Named
  slot name := name
  slot value := start

  fn inc(by := 1)
    self.value += by
    return self
  end
end

hits := Counter("hits")
hits.inc(3)
= hits.label()
```

Object slot updates are synchronized, so objects can be an explicit shared-state tool between tasks.

## Concurrency

Async RSH functions return task values immediately:

```rsh
task fetch(url)
  return cmd("curl", "-fsS", url).check().out
end

jobs := urls |> map(fetch)
pages := await_all(jobs)
```

You can spawn a lambda directly:

```rsh
job := &:: => expensive_io()
= job.await(2.0)
```

Shared mutation is explicit:

```rsh
hits := atom(0)
workers := 0 ..< 32 |> map(::i => &:: => hits.swap(::n => n + 1))
await_all(workers)
= hits.get()
```

There are channels too:

```rsh
queue := chan(8)
queue.send("hello")
= queue.recv(1)
queue.close()
```

`parallel()` is a Ruby thread pool, which is great for I/O and subprocess waits. On CRuby the GVL still exists; SRSH does not pretend otherwise. `pmap()` uses Unix fork workers when you actually want CPU parallelism.

`race()` cancels losing task handles. A failing `await_all()` cancels still-running siblings before propagating the error.

## Modules, namespaces and cleanup

Namespaces can live in the same file:

```rsh
space mathx
  bias := 10
  fn bump(x) => x + bias
end

= mathx.bump(5)
```

Or load a file as a namespace:

```rsh
use "./lib/http.rsh" as http
= http.get("https://example.com")
```

Module paths are resolved relative to the importing script when possible, and import cycles are rejected.

Cleanup is LIFO and tied to the current execution scope:

```rsh
fn build()
  tmp := "/tmp/my-build.lock"
  writefile(tmp, "busy")
  defer rmfile(tmp)

  # return, error, whatever; the cleanup still runs
  return compile()
end
```

There is a block form when cleanup takes more than one statement:

```rsh
defer
  close_stuff()
  emit "cleaned up"
end
```

## Structured process values

Shell strings are convenient. They are not always what you want for untrusted filenames or arguments.

```rsh
result := cmd("git", "rev-parse", "--verify", ref).check()
sha := result.out.trim()
```

`cmd()` keeps argv as argv. It does not feed your data back through shell parsing.

Available methods include `.argv()`, `.run()`, `.result()`, `.capture()`, `.check()` and `.task()`.

## C interop: `bridge`

This is the native boundary:

```rsh
bridge c from "@self"
  strlen(cstr) -> usize
end

= c.strlen("hello")
```

Or load a specific shared library:

```rsh
bridge math from "libm.so.6"
  cos(f64) -> f64
  pow(f64, f64) -> f64
end

= math.cos(0.0)
```

For output buffers/pointer APIs:

```rsh
bridge libc from "libc.so.6"
  gethostname(ptr, usize) -> i32
end

buf := cbuf(256)
libc.gethostname(buf, buf.size())
= buf.string()
```

Supported ABI names are:

```text
void bool
 i8  u8  i16 u16  i32 u32  i64 u64
isize usize
f32 f64
cstr ptr
```

`@self` means the current process' symbol table. Bridges resolve their symbols once when declared, so calls do not repeatedly search the library.

This is real FFI. A wrong C signature can crash the SRSH process, because C does not care about your feelings. See `docs/SECURITY.md` before feeding native pointers to random libraries.

## Errors and strict scripts

```rsh
try
  cfg := json(readfile("config.json"))
catch err
  = "config failed: #{err.message}"
  cfg := %[]
finally
  audit("config attempted")
end
```

For value pipelines:

```rsh
result := attempt(:: => risky())
? !result.ok => = result.error.message
```

For shell-side stricter behavior:

```rsh
option strict yes
option noclobber yes
```

`strict` currently means `nounset + pipefail`; it does **not** try to clone all of Bash's `set -e` edge cases.

## Metascripting

RSH code can be a value instead of a string you hope parses later:

```rsh
code cleanup
  @ glob("tmp/*.log") -> file
    rm $file
  .@
end

? dry => = sourceof(cleanup)
? !dry => run(cleanup)
```

The reflective toolbox includes `code()`, `run()`, `eval()`, `sourceof()`, `valid()`, `locals()`, `fns()`, `protos()` and `traits()`.

## Ruby plugins

Ruby is still part of the point. A Ruby plugin can register builtins, hooks and themes through the SRSH API. Plugins are trusted code and are permission-checked before auto-loading.

RSH plugins are supported too if you want to stay entirely in the language.

## Process identity

SRSH sets `$SHELL`, argv0, and the Linux process name to `srsh`. That keeps process-oriented tools from calling your active shell `ruby` just because Ruby is the engine.

The executable behind the process is still Ruby. That is intentional, not something SRSH tries to disguise.

## Repo layout

```text
bin/srsh
lib/srsh/
  app.rb
  editor.rb
  builtins.rb
  history.rb
  plugins.rb
  process_identity.rb
  state.rb
  theme.rb
  language/
  shell/
ext/srsh_native/       optional accelerator
examples/
docs/
test/
```

The code is split by job, not by architectural cosplay. If a file gets big because the job is big, it gets split when that actually makes it easier to work on.

## Current status

The project is still unreleased. `1.0.0` means “the 1.0 tree,” not “independently audited and incapable of bugs.” A shell has too much surface area for that kind of claim.

Run the tests, beat on it, and report the ugly cases. Those are usually more useful than another feature bullet.
