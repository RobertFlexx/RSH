# Moving an old srsh 0.8 setup to 1.0

The old shell was one large Ruby file. 1.0 is not, but it keeps the bits users actually interacted with: `~/.srshrc`, `~/.srsh_history`, themes, Ruby plugins, the predictive prompt, normal Unix commands, and the original block spellings.

Old RSH still parses:

```rsh
if $X == 2
  emit "yes"
else
  emit "no"
end

while $RUNNING
  work
end

times 3
  emit $it
end

fn twice x
  return int($x) * 2
end
```

New code can use the more capable expression layer and either readable or hot forms:

```rsh
fn twice(x) => int(x) * 2
? X == 2 => emit "yes"
@ 3 -> i => = twice(i)
```

A few intentional changes:

- `:=` is a local RSH binding; `$NAME :=` writes the process environment.
- `..` is an inclusive range, `..<` is exclusive.
- `++` is explicit string concatenation.
- `|` is a Unix process pipe; `|>` is an RSH value pipeline.
- missing variables can be made errors with `option nounset yes` or `option strict yes`.
- normal shell wildcard expansion now works; use quoted wildcards when you want literal `*`/`?` characters.

The brief development-only 1.0.x/1.1/1.2 directories were never release lines. The code they introduced is folded into the unreleased 1.0.0 tree.
