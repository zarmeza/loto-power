<!-- carrot-handoff:begin -->
## Handoff notes

This repository uses zanoria to carry a task between agent tools.
The note is `.carrot.md`, committed to this repository.

Before starting work here, run `zanoria load`. If a note exists it
describes work already in progress: read it, follow its `Next action`, and
do not re-derive what its `Decisions` section already settled.

Before you finish, run `zanoria save "<one-line task>"` and then
fill in `Tried and failed` and `Decisions` by hand. The tool can record
the git state; it cannot know what you tried.

Two things to leave alone. `State` is machine-derived and regenerates on
every save, so edits to it are lost. And do not add a `##` heading of your
own: only the six canonical headings round-trip in place, so dated or
thematic context belongs under a `###` inside an existing section.

Commit the note. An uncommitted note does not survive a context reset.
<!-- carrot-handoff:end -->
