# RSH 1.0 language tour (hot form)
name := "Ruby shell"
ports := [22, 80, 443]
server := %[name: "main", tls: yes]

emit "hello from " ++ name

? 443 in ports
  emit "https enabled"
:?
  emit "no https"
.?

@ 3 -> tick
  emit "tick " ++ str(tick + 1)
.@

:: greet(who, count := 2)
  @ int(count) -> i
    emit "hey " ++ str(who) ++ " #" ++ str(i + 1)
  .@
  ^ count
.::

greet("gang", 3)

platform := env("OSTYPE") ?? "unknown"
?? platform
| "darwin" ->
  emit "mac"
| "linux" ->
  emit "linux"
| _ ->
  emit "some unix-ish thing"
.??

# Normal shell remains normal shell.
printf 'srsh\n' | tr a-z A-Z
