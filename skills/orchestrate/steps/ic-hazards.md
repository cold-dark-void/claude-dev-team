<!-- IC hazard checklist. Step 8 injects this into every implementation spawn and every rework spawn. Source list: writes inside if, missing final newline, check-then-act races, retry without deadline. -->

# IC hazard checklist

Check the diff against this list before you commit.

- **Writes inside `if`.** A command inside `if`, `&&`, `||`, or `!` runs with errexit off. Add `|| return 1` to every write in that position (`printf`, `cat`, `awk`) when a partial result would be harmful.
- **Missing final newline.** A file can end without a newline. Every `while read` loop needs `|| [ -n "$line" ]`.
- **Check-then-act races.** A check followed by an action is a race. Ask what happens when another process acts between the two. On a failed lock-stamp write, undo and return 1.
- **Retry without a deadline.** A retry loop needs a deadline on every path, including every `continue`.
