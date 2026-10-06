Describe 'parse'
  Include lib/parse.sh

  It 'rejects empty input'
    When call parse ''
    The status should be failure
  End

  # Its description starts with the one above: a selection that is not exact runs both.
  It 'rejects empty input with status 1'
    When call parse ''
    The status should equal 1
  End

  # The output subject drops trailing newlines, so this cannot see a dropped one.
  It 'prints its input'
    When call parse 'word'
    The output should equal 'word'
  End

  It 'refuses [empty] input *?'
    When call parse ''
    The status should equal 1
  End

  # Matched by the description above as an unescaped pattern, and not by the escaped one.
  It 'refuses e input XY'
    When call parse 'x'
    The output should equal 'x'
  End

  # Its own description does not select it: ShellSpec reads the | as alternation.
  It 'keeps a|b'
    When call parse 'a|b'
    The output should equal 'a|b'
  End
End
