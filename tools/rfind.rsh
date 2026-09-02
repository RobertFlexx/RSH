#!/usr/bin/env srsh
# rfind: native RSH tree finder
# No external find/grep/sed. Uses RSH values + the built-in C bridge for
# POSIX fnmatch/readlink/write, which keeps matching and -print0 cheap.

bridge posix from "@self"
  fnmatch(cstr, cstr, i32) -> i32
  readlink(cstr, ptr, usize) -> isize
  write(i32, ptr, usize) -> isize
  strlen(cstr) -> usize
end

proto Options()
  slot root := "."
  slot name := void
  slot iname := void
  slot path := void
  slot regex := void
  slot kind := void
  slot min_depth := 0
  slot max_depth := 2147483647
  slot size := void
  slot mtime := void
  slot newer := void
  slot uid := void
  slot gid := void
  slot empty_only := no
  slot prune := []
  slot count_only := no
  slot json := no
  slot print0 := no
  slot absolute := no
  slot where := void
  slot action := void
  slot action_code := void
end

fn usage()
  = "rfind: native RSH file finder"
  = ""
  = "usage: rfind.rsh [ROOT] [OPTIONS]"
  = ""
  = "filters:"
  = "  -name GLOB          basename shell-pattern match"
  = "  -iname GLOB         case-insensitive -name"
  = "  -path GLOB          full-path shell-pattern match"
  = "  -regex REGEX        full-path RSH regex match"
  = "  -type f|d|l         regular file, directory, or symlink"
  = "  -mindepth N         ignore matches shallower than N"
  = "  -maxdepth N         do not descend below N"
  = "  -size SPEC          bytes; +N larger, -N smaller, k/m/g/t suffix"
  = "  -mtime SPEC         age in days; +N older, -N newer, N exact day"
  = "  -newer FILE         modification time newer than FILE"
  = "  -uid N              numeric owner uid"
  = "  -gid N              numeric owner gid"
  = "  -empty              empty regular files/directories"
  = "  -prune GLOB         skip descending into matching directories"
  = "  -where EXPR         RSH predicate; sees path/name/kind/depth/info"
  = ""
  = "output:"
  = "  -count              print only the number of matches"
  = "  -json               emit one JSON object per match"
  = "  -print0             NUL-terminate paths (for safe machine use)"
  = "  -absolute           print absolute paths"
  = "  -do CODE            run RSH code for every match instead of printing"
  = ""
  = "RSH extras:"
  = "  Multiple -prune options are allowed. Dotfiles are searched by default."
  = "  Symlink directories are never followed, matching find's safe default."
  = ""
  = "examples:"
  = "  rfind.rsh . -name '*.rb'"
  = "  rfind.rsh src -type f -size +64k"
  = "  rfind.rsh . -maxdepth 2 -iname '*.md'"
  = "  rfind.rsh . -type f -mtime -1 -json"
  = "  rfind.rsh /tmp -prune cache -name '*.log'"
  = "  rfind.rsh . -where 'kind == \"f\" && info.size > 1048576'"
  = "  rfind.rsh . -name '*.tmp' -do '= \"hit: #{path}\"'"
end


fn script_args()
  scope := locals()

  pairs := scope
    |> filter(::(k, v) => starts_with(k, "$") && k != "$0")
    |> map(::(k, v) => [int(k[1 ..< len(k)]), v])
    |> sort(::p => p[0])

  return pairs |> map(::p => p[1])
end

fn need_arg(args, i, flag)
  ? i + 1 >= len(args) => fail("#{flag} requires an argument")
  return args[i + 1]
end

fn append(xs, value) => flat([xs, [value]])

fn parse_nonneg(text, flag)
  ? text !~ '^[0-9]+$' => fail("#{flag}: expected a non-negative integer, got #{text}")
  return int(text)
end

fn parse_options(args)
  opts := Options()
  i := 0

  if len(args) > 0 && !starts_with(args[0], "-")
    opts.root := args[0]
    i += 1
  end

  while i < len(args)
    arg := args[i]

    match arg
    | "-h" =>
      usage()
      return void

    | "--help" =>
      usage()
      return void

    | "-name" =>
      opts.name := need_arg(args, i, arg)
      i += 1

    | "-iname" =>
      opts.iname := need_arg(args, i, arg)
      i += 1

    | "-path" =>
      opts.path := need_arg(args, i, arg)
      i += 1

    | "-regex" =>
      opts.regex := need_arg(args, i, arg)
      i += 1

    | "-type" =>
      kind := need_arg(args, i, arg)
      ? !(kind in ["f", "d", "l"]) => fail("-type expects f, d, or l")
      opts.kind := kind
      i += 1

    | "-mindepth" =>
      opts.min_depth := parse_nonneg(need_arg(args, i, arg), arg)
      i += 1

    | "-maxdepth" =>
      opts.max_depth := parse_nonneg(need_arg(args, i, arg), arg)
      i += 1

    | "-size" =>
      opts.size := need_arg(args, i, arg)
      i += 1

    | "-mtime" =>
      opts.mtime := need_arg(args, i, arg)
      i += 1

    | "-newer" =>
      opts.newer := need_arg(args, i, arg)
      i += 1

    | "-uid" =>
      opts.uid := parse_nonneg(need_arg(args, i, arg), arg)
      i += 1

    | "-gid" =>
      opts.gid := parse_nonneg(need_arg(args, i, arg), arg)
      i += 1

    | "-where" =>
      opts.where := need_arg(args, i, arg)
      i += 1

    | "-do" =>
      opts.action := need_arg(args, i, arg)
      i += 1

    | "-empty" => opts.empty_only := yes
    | "-count" => opts.count_only := yes
    | "-json" => opts.json := yes
    | "-print0" => opts.print0 := yes
    | "-absolute" => opts.absolute := yes

    | "-prune" =>
      opts.prune := append(opts.prune, need_arg(args, i, arg))
      i += 1

    | _ => fail("unknown option #{arg}")
    end

    i += 1
  end

  ? opts.min_depth > opts.max_depth => fail("-mindepth cannot be greater than -maxdepth")
  ? opts.json && opts.print0 => fail("-json and -print0 cannot be used together")
  ? opts.action !== void && (opts.json || opts.print0) => fail("-do cannot be combined with -json or -print0")

  return opts
end

# readlink(2) returns -1 when path isn't a symlink. A one-byte buffer is enough
# for the test; we don't need to resolve the target here.
link_probe := cbuf(1)
fn symlink(path) => posix.readlink(path, link_probe, 1) >= 0

fn shell_match(pattern, text, insensitive := no)
  p := pattern
  s := text
  if insensitive
    p := lower(pattern)
    s := lower(text)
  end
  return posix.fnmatch(p, s, 0) == 0
end

fn children(path)
  normal := glob(path ++ "/*")
  hidden := glob(path ++ "/.*")

  return flat([normal, hidden])
    |> reject(::p => basename(p) in [".", ".."])
    |> uniq
    |> sort
end

fn type_of(path, info, is_link)
  ? is_link => return "l"
  ? info?.dir ?? no => return "d"
  ? info?.file ?? no => return "f"
  return "?"
end

fn parse_quantity(spec, label)
  ? spec !~ '^[+-]?[0-9]+([.][0-9]+)?[kKmMgGtT]?$' => fail("#{label}: bad quantity #{spec}")

  relation := "="
  body := spec
  first := spec[0]

  if first == "+"
    relation := "+"
    body := spec[1 ..< len(spec)]
  end

  if first == "-"
    relation := "-"
    body := spec[1 ..< len(spec)]
  end

  unit := lower(body[len(body) - 1])
  scale := 1

  if unit in ["k", "m", "g", "t"]
    body := body[0 ..< len(body) - 1]
    match unit
    | "k" => scale := 1024
    | "m" => scale := 1024 ** 2
    | "g" => scale := 1024 ** 3
    | "t" => scale := 1024 ** 4
    end
  end

  return [relation, float(body) * scale]
end

fn relation_match(value, spec, label, floor_value := no)
  rel, wanted := parse_quantity(spec, label)
  actual := value
  ? floor_value => actual := floor(value)

  match rel
  | "+" => return actual > wanted
  | "-" => return actual < wanted
  | _ => return actual == wanted
  end
end

fn pruned(path, opts)
  name := basename(path)
  return opts.prune |> any(::pattern => shell_match(pattern, name) || shell_match(pattern, path))
end

fn empty_entry(path, info, is_link)
  ? is_link => return no
  ? info.file => return info.size == 0
  ? info.dir => return len(children(path)) == 0
  return no
end

fn matches(path, depth, info, is_link, opts, newer_time)
  ? depth < opts.min_depth => return no

  name := basename(path)
  kind := type_of(path, info, is_link)

  ? opts.name !== void && !shell_match(opts.name, name) => return no
  ? opts.iname !== void && !shell_match(opts.iname, name, yes) => return no
  ? opts.path !== void && !shell_match(opts.path, path) => return no
  ? opts.regex !== void && path !~ opts.regex => return no
  ? opts.kind !== void && kind != opts.kind => return no

  if opts.where !== void
    verdict := attempt(:: => eval(opts.where))
    ? !verdict.ok => fail("-where at #{path}: #{verdict.error.message}")
    ? !bool(verdict.value) => return no
  end

  # Broken symlinks have no File.stat metadata. They can still match path/name/type.
  if info === void
    if opts.size !== void || opts.mtime !== void || opts.uid !== void || opts.gid !== void || opts.newer !== void || opts.empty_only
      return no
    end
    return yes
  end

  ? opts.size !== void && !relation_match(info.size, opts.size, "-size") => return no

  if opts.mtime !== void
    age_days := (clock() - info.mtime) / 86400
    ? !relation_match(age_days, opts.mtime, "-mtime", yes) => return no
  end

  ? opts.newer !== void && info.mtime <= newer_time => return no
  ? opts.uid !== void && info.uid != opts.uid => return no
  ? opts.gid !== void && info.gid != opts.gid => return no
  ? opts.empty_only && !empty_entry(path, info, is_link) => return no

  return yes
end

fn absolute_path(path)
  # realpath() is deliberately avoided so broken symlinks still print.
  ? starts_with(path, "/") => return path
  base := cwd()
  ? path == "." => return base
  ? starts_with(path, "./") => return base ++ "/" ++ path[2 ..< len(path)]
  return base ++ "/" ++ path
end

fn display_path(path, opts)
  ? opts.absolute => return absolute_path(path)
  return path
end

fn emit_zero(path)
  bytes := posix.strlen(path)
  data := cbuf(bytes + 1)
  data.write(path)
  written := posix.write(1, data, bytes + 1)
  ? written < 0 => fail("write failed")
end

fn emit_match(path, depth, info, is_link, opts)
  shown := display_path(path, opts)
  name := basename(path)
  kind := type_of(path, info, is_link)

  if opts.action_code !== void
    run(opts.action_code)
    return
  end

  if opts.print0
    emit_zero(shown)
    return
  end

  if opts.json
    row := %[
      path: shown,
      name: basename(path),
      type: kind,
      depth: depth,
      size: info?.size ?? void,
      mtime: info?.mtime ?? void,
      uid: info?.uid ?? void,
      gid: info?.gid ?? void,
      mode: info?.mode ?? void
    ]
    = json_dump(row)
    return
  end

  = shown
end

fn safe_stat(path)
  result := attempt(:: => stat(path))
  ? result.ok => return result.value
  return void
end

fn walk(path, depth, opts, newer_time, total)
  is_link := symlink(path)
  info := void
  ? !is_link => info := safe_stat(path)

  if matches(path, depth, info, is_link, opts, newer_time)
    total.swap(::n => n + 1)
    ? !opts.count_only => emit_match(path, depth, info, is_link, opts)
  end

  ? depth >= opts.max_depth => return
  ? is_link => return
  ? info === void || !info.dir => return
  ? pruned(path, opts) => return

  each children(path) -> child
    walk(child, depth + 1, opts, newer_time, total)
  end
end

args := script_args()

try
  opts := parse_options(args)

  if opts !== void
    ? !exists(opts.root) && !symlink(opts.root) => fail("#{opts.root}: no such file or directory")
    ? opts.action !== void => opts.action_code := code(opts.action)

    newer_time := void
    if opts.newer !== void
      ? !exists(opts.newer) => fail("-newer: #{opts.newer}: no such file")
      newer_time := stat(opts.newer).mtime
    end

    total := atom(0)
    walk(opts.root, 0, opts, newer_time, total)

    ? opts.count_only => = total.get()
  end

catch err
  = "rfind: #{err.message}"
  return 2
end

return 0
