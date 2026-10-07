setup() {
  . "$BATS_TEST_DIRNAME/../lib/parse.sh"
}

# The name of a test in parse.bats: Bats refuses a duplicate name only within one file, so the
# filter selects both, and this one's failure carries the same witness.
@test "parse prints its input" {
  run parse 'twin'
  [ "$output" = twin ]
}
