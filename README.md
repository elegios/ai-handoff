# Handoff

This repository contains a few small scripts that can be used to add handoff functionality to an editor, where you write some `TODO(ai):` comments in a file and then tell an AI to do what's requested. Requires work to be done in a `jj` repository, and `jq` and `fish` must be installed.

The idea is that you start a session with, e.g., claude code in the `sandbox` directory (ideally sandboxed in some way), tell it to read `AGENTS.md`, then give your editor the path to that sandbox, and then you're ready.

The setup requires files in `sandbox` to be both read and writeable from inside and outside the sandbox, and that changes are reflected between them basically instantly.

Most of the functionality is located in the `handoff` fish script, so it should be _relatively_ easy to integrate into new editors. Presently there's only an Emacs implementation.

## Emacs setup

Load `ai-handoff.el` in Emacs in your preferred way. Make sure to set `ai/handoff-directory` to an absolute path to `sandbox`. After that you can call `ai/handoff` to start a handoff. You can keep editing while the handoff is running, `jj` will merge changes. If there are conflicts, they'll appear in the relevant files, as usual.

Once a handoff has been completed `ai/handoff-diff` can be used (in a buffer for the same file) to see the diff of what was written by the agent.
