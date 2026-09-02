#!/usr/bin/env srsh

# rshcalc: fast calculator REPL for SRSH 1.0.1+
# The expression hot path is SRSH's cached expression evaluator.

pi  := 3.1415926535897932384626433832795
tau := pi * 2.0
e   := 2.7182818284590452353602874713527
phi := 1.6180339887498948482045868343656
ln2 := 0.69314718055994530941723212145818
ln10 := 2.3025850929940456840179914546844
ans := 0

fn fmt(x)
  if type(x) == "float"
    if abs(x) < 0.0000000000001
      return "0"
    end
    nearest := round(x)
    if abs(x - nearest) < 0.0000000001
      return str(nearest)
    end
  end
  return str(x)
end

fn sqrt(x)
  if x < 0
    fail("sqrt domain error: x must be >= 0")
  end
  return x ** 0.5
end

fn cbrt(x)
  if x < 0
    return 0 - ((0 - x) ** (1.0 / 3.0))
  end
  return x ** (1.0 / 3.0)
end

fn floor(x)
  i := int(x)
  if x < i
    return i - 1
  end
  return i
end

fn ceil(x)
  i := int(x)
  if x > i
    return i + 1
  end
  return i
end

fn round(x)
  if x < 0
    return ceil(x - 0.5)
  end
  return floor(x + 0.5)
end

fn sign(x)
  if x < 0
    return -1
  end
  if x > 0
    return 1
  end
  return 0
end

fn clamp(x, lo, hi)
  if lo > hi
    fail("clamp: lo must be <= hi")
  end
  if x < lo
    return lo
  end
  if x > hi
    return hi
  end
  return x
end

fn rad(degrees) => degrees * pi / 180.0
fn deg(radians) => radians * 180.0 / pi
fn hypot(a, b) => sqrt(a * a + b * b)
fn sq(x) => x * x
fn root(x, n)
  if n == 0
    fail("root: degree cannot be zero")
  end
  if x < 0 and int(n) % 2 == 0
    fail("root domain error: even root of a negative number")
  end
  if x < 0
    return 0 - ((0 - x) ** (1.0 / n))
  end
  return x ** (1.0 / n)
end

fn norm_angle(x)
  y := x % tau
  if y > pi
    y -= tau
  end
  if y < 0 - pi
    y += tau
  end
  return y
end

# Minimax-ish Taylor polynomials after reducing to [-pi, pi].
# They avoid loops in the hot trig path and are accurate enough for a REPL.
fn sin(x)
  y := norm_angle(x)
  # Fold to [-pi/2, pi/2] before the polynomial.  This is both faster than a
  # longer series and dramatically improves accuracy near +/-pi.
  if y > pi / 2.0
    y := pi - y
  end
  if y < 0 - pi / 2.0
    y := (0 - pi) - y
  end
  z := y * y
  return y * (1.0 + z * (-0.16666666666666666 + z * (0.008333333333333333 + z * (-0.0001984126984126984 + z * (0.0000027557319223985893 + z * (-0.00000002505210838544172 + z * (0.00000000016059043836821615 + z * -0.0000000000007647163731819816)))))))
end

fn cos(x)
  y := abs(norm_angle(x))
  s := 1.0
  if y > pi / 2.0
    y := pi - y
    s := -1.0
  end
  z := y * y
  return s * (1.0 + z * (-0.5 + z * (0.041666666666666664 + z * (-0.001388888888888889 + z * (0.0000248015873015873 + z * (-0.0000002755731922398589 + z * (0.00000000208767569878681 + z * -0.000000000011470745597729725)))))))
end

fn tan(x)
  c := cos(x)
  if abs(c) < 0.00000000000001
    fail("tan domain error: cosine is zero")
  end
  return sin(x) / c
end

fn exp(x) => e ** x

fn ln(x)
  if x <= 0
    fail("ln domain error: x must be > 0")
  end

  y := x
  k := 0

  while y > 1.5
    y /= 2.0
    k += 1
  end

  while y < 0.75
    y *= 2.0
    k -= 1
  end

  z := (y - 1.0) / (y + 1.0)
  z2 := z * z
  term := z
  sumv := z
  d := 3
  i := 0

  while i < 18
    term *= z2
    sumv += term / d
    d += 2
    i += 1
  end

  return 2.0 * sumv + k * ln2
end

fn log10(x) => ln(x) / ln10
fn log2(x) => ln(x) / ln2

fn log(x, base := 10)
  if base <= 0 or base == 1
    fail("log domain error: base must be > 0 and != 1")
  end
  return ln(x) / ln(base)
end

fn atan(x)
  if x < 0
    return 0 - atan(0 - x)
  end
  if x > 1
    return pi / 2.0 - atan(1.0 / x)
  end
  if x > 0.5
    return pi / 4.0 + atan((x - 1.0) / (x + 1.0))
  end

  xx := x * x
  term := x
  sumv := x
  d := 3
  neg := yes
  i := 0

  while i < 18
    term *= xx
    if neg
      sumv -= term / d
    else
      sumv += term / d
    end
    neg := !neg
    d += 2
    i += 1
  end
  return sumv
end

fn asin(x)
  if x < -1 or x > 1
    fail("asin domain error: x must be in [-1, 1]")
  end
  if x == 1
    return pi / 2.0
  end
  if x == -1
    return 0 - pi / 2.0
  end
  return atan(x / sqrt(1.0 - x * x))
end

fn acos(x) => pi / 2.0 - asin(x)

fn sinh(x) => (exp(x) - exp(0 - x)) / 2.0
fn cosh(x) => (exp(x) + exp(0 - x)) / 2.0
fn tanh(x) => sinh(x) / cosh(x)

fn fact(n)
  whole := int(n)
  if n != whole or whole < 0
    fail("fact domain error: n must be a non-negative integer")
  end
  if whole > 10000
    fail("fact: refusing n > 10000")
  end

  out := 1
  i := 2
  while i <= whole
    out *= i
    i += 1
  end
  return out
end

fn gcd(a, b)
  x := abs(int(a))
  y := abs(int(b))
  while y != 0
    r := x % y
    x := y
    y := r
  end
  return x
end

fn lcm(a, b)
  x := int(a)
  y := int(b)
  if x == 0 or y == 0
    return 0
  end
  return abs(x * y) / gcd(x, y)
end

fn perm(n, r)
  nn := int(n)
  rr := int(r)
  if n != nn or r != rr or nn < 0 or rr < 0 or rr > nn
    fail("perm domain error: require integers 0 <= r <= n")
  end

  out := 1
  i := 0
  while i < rr
    out *= nn - i
    i += 1
  end
  return out
end

fn comb(n, r)
  nn := int(n)
  rr := int(r)
  if n != nn or r != rr or nn < 0 or rr < 0 or rr > nn
    fail("comb domain error: require integers 0 <= r <= n")
  end

  if rr > nn - rr
    rr := nn - rr
  end

  out := 1
  i := 1
  while i <= rr
    out := out * (nn - rr + i) / i
    i += 1
  end
  return int(out)
end

fn avg(xs)
  if len(xs) == 0
    fail("avg: empty list")
  end
  return sum(xs) / len(xs)
end

fn median(xs)
  vals := sort(xs)
  n := len(vals)
  if n == 0
    fail("median: empty list")
  end
  mid := int(n / 2)
  if n % 2 == 1
    return vals[mid]
  end
  return (vals[mid - 1] + vals[mid]) / 2.0
end

fn variance(xs)
  if len(xs) == 0
    fail("variance: empty list")
  end
  mean := avg(xs)
  return xs |> map(::x => (x - mean) ** 2) |> avg
end

fn stdev(xs) => sqrt(variance(xs))

fn fib(n)
  nn := int(n)
  if n != nn or nn < 0
    fail("fib domain error: n must be a non-negative integer")
  end
  if nn > 1000000
    fail("fib: refusing n > 1,000,000")
  end
  a := 0
  b := 1
  i := 0
  while i < nn
    nextv := a + b
    a := b
    b := nextv
    i += 1
  end
  return a
end

fn calc_ident(name)
  if name == "" or starts(name, "__")
    return no
  end

  first := name[0]
  if !contains("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_", first)
    return no
  end

  i := 1
  while i < len(name)
    c := name[i]
    if !contains("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_0123456789", c)
      return no
    end
    i += 1
  end
  return yes
end

fn calc_protected(name)
  return name in ["pi", "tau", "e", "phi", "ln2", "ln10", "ans"]
end

fn calc_show_help()
  emit ""
  emit "RSHCalc commands"
  emit "  help / ?           show this help"
  emit "  vars               show calculator variables"
  emit "  funcs              show math functions"
  emit "  constants          show constants"
  emit "  history            show recent expressions"
  emit "  time EXPR          evaluate and time once"
  emit "  bench N EXPR       evaluate EXPR N times (AST is cached)"
  emit "  clear              clear the terminal"
  emit "  quit / q / exit    leave"
  emit ""
  emit "Assignments"
  emit "  x := 2 * pi"
  emit "  radius := sqrt(144)"
  emit ""
  emit "Operators"
  emit "  +  -  *  /  %  **    and parentheses"
  emit ""
  emit "Math"
  emit "  sqrt cbrt root sq floor ceil round abs sign clamp hypot"
  emit "  sin cos tan asin acos atan rad deg"
  emit "  exp ln log log2 log10 sinh cosh tanh"
  emit "  fact fib gcd lcm perm comb min max avg median variance stdev sum"
  emit ""
  emit "Constants: pi tau e phi ln2 ln10"
  emit "Last result: ans"
  emit "Lists work too: avg([1,2,3,4])"
  emit ""
end

fn calc_show_funcs()
  emit "sqrt cbrt root sq floor ceil round abs sign clamp hypot"
  emit "sin cos tan asin acos atan rad deg"
  emit "exp ln log log2 log10 sinh cosh tanh"
  emit "fact fib gcd lcm perm comb min max avg median variance stdev sum"
end

fn calc_bench(expr, n)
  if n <= 0
    fail("bench: N must be positive")
  end
  if n > 1000000
    fail("bench: refusing more than 1,000,000 iterations")
  end

  start := clock()
  value := 0
  i := 0
  while i < n
    value := eval(expr)
    i += 1
  end
  elapsed := clock() - start
  per := elapsed * 1000000.0 / n
  emit "= #{fmt(value)}"
  emit "  #{n} evals in #{elapsed}s  (#{per} us/eval)"
  return value
end

$CALC_RUNNING := "yes"
$CALC_LINE := ""
$CALC_HISTORY := env("HOME") ++ "/.srsh_calc_history"

# Keep calculator history from growing forever.
if exists($CALC_HISTORY)
  try
    __old_history := split(readfile($CALC_HISTORY), "\n")
    if len(__old_history) > 1000
      writefile($CALC_HISTORY, join(drop(__old_history, len(__old_history) - 1000), "\n") ++ "\n")
    end
  catch __hist_error
    # History is optional; never stop the calculator over it.
    blank := yes
  end
end

emit "RSHCalc 1.0: fast calculator REPL"
emit "SRSH expression engine · type help for commands"
emit ""

while $CALC_RUNNING == "yes"
  printf '\033[1;36mcalc\033[0m \033[90m›\033[0m '
  read CALC_LINE
  __line := trim($CALC_LINE)

  if __line != ""
    try
      appendfile($CALC_HISTORY, __line ++ "\n")
    catch __history_write_error
      blank := yes
    end
  end

  match __line
  | "" => blank := yes
  | ["q", "quit", "exit"] => $CALC_RUNNING := "no"
  | ["help", "?"] => calc_show_help()
  | "funcs" => calc_show_funcs()
  | "constants" ->
    emit "pi   = #{fmt(pi)}"
    emit "tau  = #{fmt(tau)}"
    emit "e    = #{fmt(e)}"
    emit "phi  = #{fmt(phi)}"
    emit "ln2  = #{fmt(ln2)}"
    emit "ln10 = #{fmt(ln10)}"
  | "vars" ->
    __visible := keys(locals()) |> filter(::k => !starts(k, "__")) |> sort
    each __visible -> __name
      __value := locals()[__name]
      if type(__value) in ["int", "float", "Complex"]
        emit "#{__name} = #{fmt(__value)}"
      end
    end
  | "history" ->
    if exists($CALC_HISTORY)
      try
        __history := split(readfile($CALC_HISTORY), "\n")
        __start := max(len(__history) - 21, 0)
        __recent := drop(__history, __start)
        each __recent -> __entry
          if __entry != ""
            emit "  #{__entry}"
          end
        end
      catch __history_error
        emit "history unavailable: #{__history_error.message}"
      end
    else
      emit "history is empty"
    end
  | "clear" => clear
  | ? starts(it, "time ") ->
    __parts := split(__line, " ")
    __expr := trim(join(drop(__parts, 1), " "))
    try
      __started := clock()
      __value := eval(__expr)
      __elapsed := clock() - __started
      ans := __value
      emit "= #{fmt(__value)}"
      emit "  #{__elapsed * 1000000.0} us"
    catch __err
      emit "error: #{__err.message}"
    end
  | ? starts(it, "bench ") ->
    __parts := split(__line, " ")
    if len(__parts) < 3
      emit "usage: bench N EXPR"
    else
      __count := int(__parts[1])
      __expr := trim(join(drop(__parts, 2), " "))
      try
        ans := calc_bench(__expr, __count)
      catch __err
        emit "error: #{__err.message}"
      end
    end
  | ? contains(it, ":=") ->
    __parts := split(__line, ":=")
    __name := trim(__parts[0])
    __expr := trim(join(drop(__parts, 1), ":="))

    if !calc_ident(__name)
      emit "error: invalid variable name '#{__name}'"
    else
      if calc_protected(__name)
        emit "error: '#{__name}' is a protected calculator name"
      else
        try
          __value := eval(__expr)
          __kind := type(__value)
          if !(__kind in ["int", "float", "Complex"])
            fail("calculator variables must hold numbers, got #{__kind}")
          end

          # __value already exists in the root script scope.  Generate only the
          # validated target name, so complex/big numeric values never need to be
          # converted back into source text.
          run(code(__name ++ " := __value"))
          ans := __value
          emit "#{__name} = #{fmt(__value)}"
        catch __err
          emit "error: #{__err.message}"
        end
      end
    end
  | _ ->
    try
      __value := eval(__line)
      __kind := type(__value)
      if !(__kind in ["int", "float", "Complex"])
        fail("expected a numeric result, got #{__kind}")
      end
      ans := __value
      emit "= #{fmt(__value)}"
    catch __err
      emit "error: #{__err.message}"
    end
  end
end

emit "bye :P"
