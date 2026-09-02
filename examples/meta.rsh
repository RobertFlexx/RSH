#!/usr/bin/env srsh

name := $1
? name == "" => name := "gang"
dry := $2 == "--dry"

code greeting
  emit "wsg #{name}"
  emit "cwd=#{cwd()}"
end

if dry
  emit "would run:"
  = sourceof(greeting)
else
  run(greeting)
end

formula := "len(name) * 2"
= "meta expression result=#{eval(formula)}"
