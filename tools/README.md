# SRSH stuffy wuffy

These are utilities written in RSH itself. They are examples of using the language as a real shell scripting environment rather than wrappers around another scripting language.

- `rfind.rsh` recursive file finder with RSH predicates/actions and POSIX bridge support.
- `rshcalc.rsh` interactive calculator REPL using SRSH's expression engine.

Run them from the source tree with:

```sh
./bin/srsh tools/rfind.rsh . -name '*.rsh'
./bin/srsh tools/rshcalc.rsh
```

After installing SRSH, their `#!/usr/bin/env srsh` shebangs also work when `srsh` is on `PATH`.
