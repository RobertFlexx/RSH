#!/usr/bin/env srsh

tmp := "/tmp/srsh-defer-example-#{status()}"

fn demo(path)
  writefile(path, "temporary")
  defer rmfile(path)

  = "inside: #{exists(path)}"
  return readfile(path)
end

= demo(tmp)
= "after: #{exists(tmp)}"
