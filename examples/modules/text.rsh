prefix := "srsh"

fn tag(value) => "[#{prefix}] #{value}"

fn clean(lines_in) =>
  lines_in |> map(::x => x.trim()) |> reject(::x => x == "")
