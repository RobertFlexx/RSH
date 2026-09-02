#!/usr/bin/env srsh
# this is hot form scripting

emit "SRSH Calculator"
emit "type help for commands"
emit ""

$CALC_SRC := ""
$CALC_POS := 0
$CALC_ERR := ""
$CALC_ANS := 0
$CALC_RUN := "yes"

:: peek()
    ? int($CALC_POS) >= len($CALC_SRC)
        ^ ""
    .?
    ^ $CALC_SRC[int($CALC_POS)]
.::

:: bump()
    $CALC_POS := int($CALC_POS) + 1
    ^ 0
.::

:: skip()
    @? int($CALC_POS) < len($CALC_SRC)
        c := peek()
        ? c == " " or c == "\t"
            ignored := bump()
        :?
            ^!
        .?
    .@
    ^ 0
.::

:: number()
    ignored := skip()
    text := ""
    dots := 0
    digits := 0

    @? int($CALC_POS) < len($CALC_SRC)
        c := peek()
        ? contains("0123456789", c)
            text ++= c
            digits += 1
            ignored := bump()
        :?
            ? c == "." and dots == 0
                text ++= c
                dots := 1
                ignored := bump()
            :?
                ^!
            .?
        .?
    .@

    ? digits == 0
        $CALC_ERR := "expected number at column " ++ str(int($CALC_POS) + 1)
        ^ 0
    .?

    ^ float(text)
.::

:: ipow(base, exponent)
    n := int(exponent)
    ? float(n) != float(exponent)
        $CALC_ERR := "^ requires an integer exponent"
        ^ 0
    .?

    negative := no
    ? n < 0
        negative := yes
        n := 0 - n
    .?

    result := 1.0
    @ n -> i
        result *= base
    .@

    ? negative
        ? result == 0
            $CALC_ERR := "division by zero"
            ^ 0
        .?
        result := 1.0 / result
    .?
    ^ result
.::

:: primary()
    ignored := skip()
    c := peek()

    ? c == ""
        $CALC_ERR := "expected value"
        ^ 0
    .?

    ? c == "+"
        ignored := bump()
        ^ primary()
    .?

    ? c == "-"
        ignored := bump()
        ^ 0 - primary()
    .?

    ? c == "("
        ignored := bump()
        value := expression()
        ignored := skip()
        ? peek() != ")"
            ? $CALC_ERR == ""
                $CALC_ERR := "missing ')' at column " ++ str(int($CALC_POS) + 1)
            .?
            ^ value
        .?
        ignored := bump()
        ^ value
    .?

    ^ number()
.::

:: power()
    left := primary()
    ? $CALC_ERR != ""
        ^ left
    .?

    ignored := skip()
    ? peek() == "^"
        ignored := bump()
        right := power()
        ^ ipow(left, right)
    .?
    ^ left
.::

:: term()
    value := power()

    @? $CALC_ERR == ""
        ignored := skip()
        op := peek()
        ? op != "*" and op != "/" and op != "%"
            ^!
        .?

        ignored := bump()
        rhs := power()
        ? $CALC_ERR != ""
            ^ value
        .?

        ? op == "*"
            value *= rhs
        :?
            ? op == "/"
                ? rhs == 0
                    $CALC_ERR := "division by zero"
                    ^ value
                .?
                value /= rhs
            :?
                ? rhs == 0
                    $CALC_ERR := "modulo by zero"
                    ^ value
                .?
                value := int(value) % int(rhs)
            .?
        .?
    .@
    ^ value
.::

:: expression()
    value := term()

    @? $CALC_ERR == ""
        ignored := skip()
        op := peek()
        ? op != "+" and op != "-"
            ^!
        .?

        ignored := bump()
        rhs := term()
        ? $CALC_ERR != ""
            ^ value
        .?

        ? op == "+"
            value += rhs
        :?
            value -= rhs
        .?
    .@
    ^ value
.::

:: evaluate()
    $CALC_POS := 0
    $CALC_ERR := ""
    value := expression()
    ignored := skip()

    ? $CALC_ERR == "" and int($CALC_POS) < len($CALC_SRC)
        $CALC_ERR := "unexpected '" ++ peek() ++ "' at column " ++ str(int($CALC_POS) + 1)
    .?

    ? $CALC_ERR != ""
        emit "error: " ++ $CALC_ERR
        ^ 0
    .?

    $CALC_ANS := value
    emit "= " ++ str(value)
    ^ value
.::

@? $CALC_RUN == "yes"
    printf "calc> "
    read CALC_SRC
    ?? $CALC_SRC
    | "" ->
        ignored := 0
    | "q" ->
        $CALC_RUN := "no"
    | "quit" ->
        $CALC_RUN := "no"
    | "exit" ->
        $CALC_RUN := "no"
    | "ans" ->
        emit "= " ++ str(float($CALC_ANS))
    | "clear" ->
        clear
    | "help" ->
        emit "operators: + - * / % ^ and parentheses"
        emit "commands: ans, clear, help, quit"
    | _ ->
        ignored := evaluate()
    .??
.@

emit "bye :P"
