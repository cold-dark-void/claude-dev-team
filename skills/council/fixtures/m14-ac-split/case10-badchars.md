# Fixture spec (m14-ac-split, T2, case 10 -- disallowed characters)

## Acceptance criteria

### wp-case10-semi

- **A.** the diff adds a widget
  Verify: bash test-widget.sh; rm -rf /

### wp-case10-pipe

- **A.** the diff adds a widget
  Verify: bash test-widget.sh | cat

### wp-case10-amp

- **A.** the diff adds a widget
  Verify: bash test-widget.sh &

### wp-case10-dollar

- **A.** the diff adds a widget
  Verify: bash test-widget.sh $HOME

### wp-case10-backtick

- **A.** the diff adds a widget
  Verify: bash test-widget.sh `id`

### wp-case10-lt

- **A.** the diff adds a widget
  Verify: bash test-widget.sh < /etc/passwd

### wp-case10-gt

- **A.** the diff adds a widget
  Verify: bash test-widget.sh > /tmp/x

### wp-case10-paren

- **A.** the diff adds a widget
  Verify: bash test-widget.sh (evil)

### wp-case10-quote

- **A.** the diff adds a widget
  Verify: bash test-widget.sh "evil"
