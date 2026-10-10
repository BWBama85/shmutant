# Loaded relative to where Bats starts, as a suite run from its root does: an adapter that did
# not start Bats in the clone would test the original library.
setup() {
  . lib/parse.sh
}

@test "parse rejects empty input" {
  run parse ''
  [ "$status" -ne 0 ]
}

# Its name starts with the one above: a filter without its end anchor runs both.
@test "parse rejects empty input with status 1" {
  run parse ''
  [ "$status" -eq 1 ]
}

# Its name ends with the one above: a filter without its start anchor runs both.
@test "also parse rejects empty input" {
  run parse 'x'
  [ "$status" -eq 0 ]
}

# Bats strips trailing newlines from $output, so this cannot see a dropped one.
@test "parse prints its input" {
  run parse 'word'
  [ "$output" = word ]
}

@test "parse.empty (status) [1]" {
  run parse ''
  [ "$status" -eq 1 ]
}

# The next three are matched by the name above with, in turn, its . left unescaped, its ( and )
# both left unescaped (an unescaped ( alone is no valid regex), and its [ left unescaped.
@test "parse-empty (status) [1]" {
  run parse 'x'
  [ "$status" -eq 0 ]
}

@test "parse.empty status [1]" {
  run parse 'x'
  [ "$status" -eq 0 ]
}

@test "parse.empty (status) 1" {
  run parse 'x'
  [ "$status" -eq 0 ]
}

@test "parse a{2}" {
  run parse 'a{2}'
  [ "$output" = 'a{2}' ]
}

# Matched by the name above with its { } left unescaped, as a repeat count.
@test "parse aa" {
  run parse 'x'
  [ "$status" -eq 0 ]
}

# Filtered on as written, printed as `parse refuses nothing`.
@test 'parse refuses "nothing"' {
  run parse ''
  [ "$status" -eq 1 ]
}

@test 'parse keeps \ ^ $ | * + ? { }' {
  run parse '\ ^ $ | * + ? { }'
  [ "$output" = '\ ^ $ | * + ? { }' ]
}

# Matched by the name above with its | left unescaped, as one side of an alternation.
@test 'parse keeps \ ^ $ and more' {
  run parse 'x'
  [ "$status" -eq 0 ]
}
