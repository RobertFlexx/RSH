# This file is intentionally shaped like something you'd paste at the prompt.
space sys
  task kernel() =>
    cmd("uname", "-srmo").check().out.trim()

  task uptime() =>
    cmd("uptime", "-p").check().out.trim()
end

jobs := [
  sys.kernel(),
  sys.uptime()
]

= await_all(jobs)
