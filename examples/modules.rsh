#!/usr/bin/env srsh

use "./modules/text.rsh" as text

rows := [" hello ", "", "world"] |> text.clean
@ rows -> row => = text.tag(row)
