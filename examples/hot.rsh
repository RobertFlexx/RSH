#!/usr/bin/env srsh

root := $1
? root == "" => root := "."
branch := $(git branch --show-current 2>/dev/null)
? branch == "" => branch := "no-branch"

ruby := glob(root ++ "/**/*.rb")
  |> reject(::p => contains(p, "/vendor/"))
  |> map(::p => %[path: p, bytes: len(readfile(p))])
  |> sort(::x => 0 - x.bytes)

= "#{len(ruby)} ruby files on #{branch}"
@ ruby -> item => = "#{item.bytes}  #{item.path}"
