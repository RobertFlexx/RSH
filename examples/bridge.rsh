#!/usr/bin/env srsh

# @self is handy for libc-ish symbols already visible in the current process.
bridge c from "@self"
  strlen(cstr) -> usize
end

= "strlen('simple ruby shell')=#{c.strlen("simple ruby shell")}"
