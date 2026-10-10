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

  # Matched by the description above with its [ and ] left unbracketed.
  It 'refuses e input *?'
    When call parse 'x'
    The output should equal 'x'
  End

  # Matched by the description above with its * left unbracketed.
  It 'refuses [empty] input X?'
    When call parse 'x'
    The output should equal 'x'
  End

  # Matched by the description above with its ? left unbracketed.
  It 'refuses [empty] input *X'
    When call parse 'x'
    The output should equal 'x'
  End

  # Its own description selects it only with the | turned into ?: ShellSpec reads a | as
  # alternation, which selects the example below instead.
  It 'keeps a|b'
    When call parse 'a|b'
    The output should equal 'a|b'
  End

  # One side of the alternation ShellSpec reads `keeps a|b` as.
  It 'b'
    When call parse 'x'
    The output should equal 'x'
  End

  # Matched by the description `keeps a|b` with its | turned into ?, any one byte.
  It 'keeps a-b'
    When call parse 'x'
    The output should equal 'x'
  End
End
