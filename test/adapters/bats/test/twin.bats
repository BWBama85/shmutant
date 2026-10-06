setup() {
  . "$BATS_TEST_DIRNAME/../lib/parse.sh"
}

# The name of a test in parse.bats: Bats refuses a duplicate name only within one file, and the
# filter selects both.
@test "parse prints its input" {
  run parse 'twin'
  [ "$output" = twin ]
}
