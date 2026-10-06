Describe 'twin'
  Include lib/parse.sh

  # The description of an example in parse_spec.sh: --example selects both.
  It 'prints its input'
    When call parse 'twin'
    The output should equal 'twin'
  End
End
