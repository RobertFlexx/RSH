# RSH language guide

RSH is the programming language inside Simple Ruby Shell. It is meant for shell work first, but it is not restricted to shell-shaped programs.

There are two rules worth knowing before the syntax dump:

1. normal Unix commands should still look normal;
2. when RSH crosses a boundary, the syntax should tell you which boundary it crossed.

That is why `|`, `|>`, `$()` and `bridge` are different things instead of one overloaded mega-pipe.

## Commands and values

This is a Unix pipeline:

```rsh
printf 'c\na\nb\n' | sort
```

This is an RSH value pipeline:

```rsh
[3, 1, 2] |> sort |> map(::x => x * 10)
```

This brings command output into RSH:

```rsh
kernel := $(uname -r)
```

This calls C without starting another process:

```rsh
bridge c from "@self"
  strlen(cstr) -> usize
end

= c.strlen("abc")
```

Those are four different execution/data models, so they are four visibly different forms.

## Bindings

```rsh
name := "Robert"
count := 4
$counted := "environment value"
$EDITOR := "vim"

count += 1
name ++= "!"
```

`:=` always creates a binding in the current lexical scope. Compound assignment updates the nearest existing local.

A leading `$` on an assignment means the process environment. Worker tasks are not allowed to mutate the process environment behind the owner thread's back.

At the shell-command layer, locals and environment variables can be expanded with `$name`, `${name}`, `$1`, `$?`, and `$!`.

## Literals

```rsh
42
-12
0xff
0b1010
0o755
1_000_000
3.14159
2.5e6

yes
no
void

"hello #{name}"
'literal #{name}'
[[raw text #{name}]]

[1, 2, 3]
%[name: "srsh", ready: yes]
1 .. 10
0 ..< 10
```

Double strings interpolate full RSH expressions. Single and raw strings do not.

`%[...]` is a map literal. Braces are intentionally not block syntax in RSH, which keeps shell text and language blocks from fighting over the same punctuation.

## Operators

From loose to tight, the useful groups are roughly:

```text
??
or  ||
and &&
== != === !== =~ !~ in
< <= > >=
|>
.. ..<
+ - ++
* / %
**
```

`++` is string concatenation. `+` stays numeric unless coercion makes sense.

`===` / `!==` are strict comparisons. `==` / `!=` keep the shell-friendly numeric comparison behavior.

Regex operators use a string pattern:

```rsh
? name =~ "^[A-Z]" => = "starts uppercase"
```

## Value pipelines

`|>` sends the left value to the function on the right as its first argument:

```rsh
files := glob("src/**/*.rb")
  |> reject(::p => contains(p, "/vendor/"))
  |> map(::p => basename(p))
  |> uniq
  |> sort
```

The parser treats `|>` as an expression continuation, so long pipelines can be laid out vertically without backslashes.

Normal `|` is reserved for process pipelines. That separation is one of the main RSH design choices.

## Functions and lambdas

Readable function:

```rsh
fn scale(x, by := 2)
  return x * by
end
```

Expression function:

```rsh
fn scale(x, by := 2) => x * by
```

The expression can start on the next physical line too, which is handy while pasting:

```rsh
fn scale(x, by := 2) =>
  x * by
```

Hot spelling:

```rsh
:: scale(x, by := 2) => x * by
```

Anonymous callables:

```rsh
::x => x * 2
::(a, b) => a + b
::(head, *tail) => tail |> len
:: => clock()
```

Named functions are first-class values:

```rsh
fn square(x) => x * x
= 1 .. 10 |> map(square) |> sum
```

Closures capture lexical values.

## If / guards

Readable:

```rsh
if score >= 90
  emit "great"
else
  emit "keep going"
end
```

One line:

```rsh
if score >= 90 => emit "great"
```

Hot form:

```rsh
? score >= 90
  emit "great"
:?
  emit "keep going"
.?
```

Hot guard:

```rsh
? score >= 90 => emit "great"
```

## Loops

Readable:

```rsh
each users -> user
  = user.name
end
```

Hot:

```rsh
@ users -> user
  = user.name
.@
```

One-line forms:

```rsh
each users -> user => = user.name
@ users -> user => = user.name
```

Pairs can destructure in the loop head:

```rsh
each %[a: 1, b: 2] -> key, value
  = "#{key}=#{value}"
end
```

Integers iterate `0...N`.

While loops:

```rsh
while pending
  work()
end
```

or:

```rsh
@? pending
  work()
.@
```

`break` / `continue` have hot aliases `^!` / `^>`.

## Destructuring

```rsh
head, second, *rest := [10, 20, 30, 40]
```

A single rest name is allowed and must be last.

## Pattern matching

```rsh
match status
| 200..299 => = "ok"
| [401,403] => = "auth"
| ? it >= 500 => = "server"
| _ => = "other"
end
```

Hot form:

```rsh
?? status
| 200..299 ->
  = "ok"
| _ ->
  = "other"
.??
```

Patterns can be values, ranges, lists, partial maps, prototype references, or guard expressions beginning with `?` / `when`.

## Safe access and null coalescing

```rsh
cfg := json(readfile("config.json"))
host := cfg?.server?.host ?? "localhost"
first := cfg?.hosts?[0] ?? host
```

Normal `.` and `[]` are strict. `?.` and `?[]` return `void` when the access cannot be completed.

## Functional collection toolbox

```text
map filter reject fold find any all count sum
each sort uniq flat zip enumerate take drop chunk group
tap partial compose
```

Most collection operations also have method form:

```rsh
= [1,2,3,4].filter(::x => x % 2 == 0).map(::x => x ** 2).sum()
```

Use whichever reads better.

## Prototypes and traits

RSH uses composable prototypes rather than class inheritance.

```rsh
trait Printable
  fn show()
    = "#{self.name}=#{self.value}"
  end
end

proto Counter(name, start := 0) with Printable
  slot name := name
  slot value := start

  fn inc(by := 1)
    self.value += by
    return self
  end
end

counter := Counter("requests", 10)
counter.inc()
```

`self` is implicit in methods. Slot compound updates use synchronized object updates.

Reflection helpers include `fields()`, `methods()`, `protoof()`, `is()` and `clone()`.

## Namespaces

Inline namespace:

```rsh
space build
  root := "out"
  fn artifact(name) => root ++ "/" ++ name
end

= build.artifact("app")
```

A `space` can hold bindings, functions, tasks, prototypes, traits, nested spaces, bridges, modules and code declarations.

## Modules

```rsh
use "./lib/net.rsh" as net
= net.fetch(url)
```

The imported file runs inside a namespace rather than dumping its locals into the caller.

Relative paths are resolved against the current script when SRSH can determine one. Recursive import cycles are rejected.

## Cleanup with `defer`

Single cleanup:

```rsh
fn work()
  tmp := make_tmp()
  defer rmfile(tmp)
  return use_tmp(tmp)
end
```

Block cleanup:

```rsh
defer
  unlock()
  rmfile(tmp)
end
```

Defers are LIFO and run when the current script/function execution scope leaves, including through `return` and exceptions.

## Structured errors

```rsh
try
  cfg := json(readfile("config.json"))
catch err
  = err.message
  cfg := %[]
finally
  audit("attempted")
end
```

The caught error is an RSH map-like value with at least `.type` and `.message`.

Hot/value style:

```rsh
result := attempt(:: => risky())
? !result.ok => = result.error.message
```

`fail(message)` raises an RSH runtime error. `assert(condition, message)` is available too.

## Async tasks

```rsh
task fetch(url)
  return cmd("curl", "-fsS", url).check().out
end

jobs := urls |> map(fetch)
results := await_all(jobs)
```

Expression task:

```rsh
task square_later(x) => x * x
```

and, like functions, the body can be on the next physical line after `=>`.

Spawn a callable immediately:

```rsh
job := &:: => expensive_io()
= job.await(2.0)
```

Task methods:

```text
.await([timeout])
.done()
.status()
.cancel()
```

`race(tasks)` returns the winner and cancels losers. `await_all(tasks)` preserves order and cancels still-running siblings when one fails.

## Atoms and channels

Shared scalar-ish state:

```rsh
hits := atom(0)
hits.swap(::n => n + 1)
= hits.get()
```

Channels:

```rsh
ch := chan(16)
ch.send(value)
value := ch.recv(1.0)
ch.close()
```

A capacity of zero is currently an unbounded queue; positive capacities apply backpressure.

## Thread and process parallelism

```rsh
rows := parallel(inputs, fetch, 8)
```

`parallel` uses Ruby threads. Good for files, network calls and subprocess waits.

```rsh
hashes := pmap(files, hash_one, cpu_count())
```

`pmap` uses Unix fork workers when available, so CPU-heavy Ruby work can use multiple cores even under CRuby's GVL. Results preserve input order.

## Shell command values

```rsh
job := cmd("git", "rev-parse", "--verify", ref)
result := job.result()
```

Methods:

```text
.argv()      copy of argv
.run()       inherit terminal, return status
.result()    capture stdout/stderr/status
.capture()   stdout as a string
.check()     result, but raise on nonzero status
.task()      run structured command in an RSH task
```

Use `cmd()` when filenames/URLs/data should stay argv and should not be interpreted as shell code.

## C ABI bridges

Readable declaration:

```rsh
bridge libc from "libc.so.6"
  getpid() -> i32
  strlen(cstr) -> usize
  gethostname(ptr, usize) -> i32
end
```

Call it like a namespace:

```rsh
= libc.getpid()
= libc.strlen("hello")
```

`@self` binds against the current process:

```rsh
bridge c from "@self"
  strlen(cstr) -> usize
end
```

Writable memory:

```rsh
buf := cbuf(256)
libc.gethostname(buf, buf.size())
= buf.string()
```

`cbuf` methods:

```text
.size()
.address()
.ptr()
.read([offset], [length])
.write(string, [offset])
.string([max])
.clear()
```

ABI type names:

```text
void bool
 i8 u8 i16 u16 i32 u32 i64 u64
isize usize
f32 f64
cstr ptr
```

Bridges are intentionally thin. They resolve the dynamic symbol once and then call the native function directly. Read the security document: the wrong signature can crash the process.

## Files, strings, JSON and paths

Useful hot-script helpers include:

```text
readfile writefile appendfile
exists file dir glob stat
mkdirp rmfile cpfile mvfile
basename dirname ext
json json_dump
lines words replace
upper lower trim split join
shellquote
```

These are for values. Normal shell commands remain available when a dedicated Unix tool is the better choice.

## Metascripting

Parsed code block:

```rsh
code cleanup
  rm -rf build/tmp
end
```

Inspect or execute later:

```rsh
= sourceof(cleanup)
run(cleanup)
```

Dynamic expression/code helpers:

```text
eval(string)
code(string)
run(code_or_string)
valid(string [, "expr"])
sourceof(code)
locals()
fns()
protos()
traits()
```

Parsed `code ... end` is preferable when the source is known ahead of time.

## Shell strictness options

At the command prompt or in startup config:

```sh
option pipefail yes
option nounset yes
option noclobber yes
```

Shortcut:

```sh
option strict yes
```

`strict` means `pipefail + nounset`. RSH deliberately does not copy Bash `set -e`; its context-sensitive behavior is too easy to misunderstand. Use structured errors/checking when failure really matters.

## Interactive multiline input

The REPL asks the parser whether the input is complete. This works for blocks *and* expressions:

```text
> values := [
... 1,
... 2,
... 3
... ]
```

It also handles a command ending in `|`, `&&`, `||`, redirection, an unclosed quote, command substitution, or a trailing backslash as incomplete shell input.

Background jobs use the same process-group model as the interactive shell. `jobs`, `fg`, `bg`, and `wait %N` operate on those jobs; `exec command ...` replaces SRSH with a command when a wrapper no longer needs to stay around.

That behavior is what makes pasting larger snippets practical; the shell no longer has to recognize every possible multiline construct with a pile of prompt regexes.

## Compatibility forms

The original 0.8 spellings still exist, including `if/else/end`, `while/end`, `times/end` and old `fn name args ... end` functions.

The newer hot forms are there for short code, not to force old scripts into a new costume.
