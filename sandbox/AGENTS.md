# AI Handoff Protocol

This directory is one end of a file-based handoff channel to a process
outside this sandbox. Your job is to watch for incoming commands and
act on them.

## Start watching

Run `handoff_monitor.py` as a background monitor (the `Monitor` tool, not
plain `Bash`) so each incoming command arrives as a notification instead of
requiring you to poll:

```
python3 handoff_monitor.py .
```

The script only does the mechanical part: it watches the directory, and
for each new `handoff` file it atomically writes `ACK` to `handoff.ack`
and prints `COMMAND path='<path>'`. It does not touch `handoff.return` —
that's on you, per command. Re-arm the monitor if it expires; it's meant
to stay running for the whole session.

## Handling a command

Each command names one file (an absolute or cwd-relative path):

1. Read that file yourself — do not try to regex the comment syntax, just
   read and understand it like any other code.
2. Find comments containing the marker `TODO(ai):`. The instruction is
   everything from the marker to the end of that comment (a single line,
   or a whole block/paragraph of comment lines, depending on the
   language).
3. Do what each TODO says, then remove the TODO comment. You may touch
   other files if needed, but most of the change should land in the
   targeted file.
4. Check `tests.json` in this directory for entries whose `glob` matches
   the file (see format below) and run them. Make tests pass if that
   requires only small, obvious fixes beyond the TODOs; don't chase
   unrelated failures.
5. Write the result by piping JSON into the helper (it validates JSON and
   writes atomically — never write `handoff.return` by hand):

   ```
   echo '{"todos_found": N, "todos_fixed": N, "tests_run": N, "tests_pass": N, "info": ""}' \
     | python3 write_return.py .
   ```

   Fields: `todos_found`, `todos_fixed`, `tests_run`, `tests_pass` are
   integers. `info` is free text — leave it `""` unless a TODO couldn't
   be completed or something about the change is worth flagging.

## tests.json format

```json
[{"glob": "**/*.sh", "cmd": "shellcheck '{file}'", "cd": true}]
```

A glob matches when it matches the file's path. `{file}` in `cmd` is
substituted with the file (if `cd` is true, just its basename, and the
command runs from the directory containing the file); `{file}` may be
absent from `cmd` entirely.

## Code style

Keep edits close to what the TODO asks for — no drive-by refactors. Add
very few comments, if any, and never comments that reference the TODO,
this protocol, or what the code used to say.
