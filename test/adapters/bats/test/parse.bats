setup() {
  . "$BATS_TEST_DIRNAME/../lib/parse.sh"
}

@test "parse rejects empty input" {
  run parse ''
  [ "$status" -ne 0 ]
}

# Its name starts with the one above: a selection that is not exact runs both.
@test "parse rejects empty input with status 1" {
  run parse ''
  [ "$status" -eq 1 ]
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

# Matched by the unescaped regex of the name above, and not by the escaped one.
@test "parse-empty status 1" {
  run parse 'x'
  [ "$status" -eq 0 ]
}

@test 'parse keeps \ ^ $ | * + ? { }' {
  run parse '\ ^ $ | * + ? { }'
  [ "$output" = '\ ^ $ | * + ? { }' ]
}
