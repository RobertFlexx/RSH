#!/usr/bin/env srsh

# Objects, functions, tasks and safe process values in one script.

space mathx
  fn square(x) => x * x
  fn positive(x) => x > 0
end

trait Labeled
  fn label() => "#{self.name}:#{self.bias}"
end

proto Worker(name, bias := 0) with Labeled
  slot name := name
  slot bias := bias

  fn score(x) => mathx.square(x) + self.bias

  task score_later(x)
    sleep(0.002)
    return self.score(x)
  end
end

workers := [0,1,2,3] |> map(::i => Worker("w#{i}", i))
jobs := enumerate(workers) |> map(::pair => pair[1].score_later(pair[0] + 2))
= "async scores=#{await_all(jobs)}"

hits := atom(0)
parallel(0 ..< 64, ::i => hits.swap(::n => n + 1), 8)
= "thread-safe hits=#{hits.get()}"

ch := chan(1)
task send_one(out, value)
  out.send(value)
  return value
end
producer := send_one(ch, "hello from task")
= ch.recv(1)
producer.await(1)
ch.close()

head, second, *tail := [10,20,30,40]
= "destructure=#{head + second}; rest=#{tail}"

try
  assert(workers |> len == 4, "worker count changed")
  = workers |> map(::w => w.label())
catch err
  = "error: #{err.message}"
finally
  emit "checked workers"
end

safe := cmd("printf", "%s", "argv stays data")
= safe.capture()

code later
  = "code values are parsed before they run"
end
run(later)

fn cube(x) => x ** 3
= "functional=#{[1,2,3,4] |> filter(mathx.positive) |> map(cube) |> sum}"
