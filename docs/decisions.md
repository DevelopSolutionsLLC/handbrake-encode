# Decisions

## 001 — Replace the source after a verified encode

Decided 2026-11-20. On success the script deletes the source; the output must exist and its
duration must be within 5 % of the source's. Why: the script exists to shrink a library in
place, and keeping both copies doubles storage until someone cleans up. Forbids: deleting the
source on any path that has not checked HandBrake's exit status, the duration and the move.
Rejected: keeping sources by default, which leaves cleanup to a person. Reopen if a caller
needs the source kept; add a flag rather than change the default.

## 002 — A `mkdir` lock serialises encodes

Decided 2026-11-20. `$TMPDIR/encode.lock` is created with `mkdir`, holds the owner's PID, and is
reclaimed when that PID is dead. Why: `mkdir` is atomic on macOS, Linux and WSL, while `flock`
is absent on macOS; the earlier PID file let two waiters start together and made directory mode
wait on itself. Forbids: a check-then-write PID file. Rejected: `flock`, which macOS lacks.
Reopen if the script drops macOS.

Amended 2026-11-20. The directory is made privately with `mkdir` and renamed into place with a
`pid.<PID>` marker inside, and a dead holder's lock changes hands by renaming that marker. Why:
`mkdir` followed by a PID write left a lock without a PID that no waiter reclaimed when the
holder died in between, and reclaiming by `rm -rf` let a second waiter delete the lock the
first had just re-created, so both encoded (8 of 15 trials with eight waiters). Forbids:
removing a lock directory that holds a marker other than one's own, or a live run's private
directory inside it. A dead run's private directory stranded in a markerless lock is removed by
a waiter; left in place it blocked every waiter for good. Rejected: a PID file
claimed with `noclobber` and stolen by rename, which deadlocked 14 of 15 trials when a waiter
took a live claimant's file; an age limit for PID-less locks, which the marker makes
unnecessary.
