Describe 'twin'
  Describe 'parse'
    Include lib/parse.sh

    # The description of an example in parse_spec.sh: --example selects both, and this one's
    # full name, `twin parse prints its input`, carries that example's witness.
    It 'prints its input'
      When call parse 'twin'
      The output should equal 'twin'
    End
  End
End
