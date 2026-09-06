# Reconnect recovery: remaining dependency work

PR #37 is a draft. Its URI/provider snapshot can request playback again, but
cannot guarantee exact queue restoration with shuffle. The observations below
were checked against pinned librespot `6d3ecd76115c08a5e606d6f6d2181932314afed2`.

## Current implementation and safe incremental correction

An active or paused track, position, up to 80 upcoming tracks, volume, shuffle
and repeat are captured. An unshuffled context can be reloaded with its manual
queue prefix; shuffled/custom playback is flattened into a list of URIs.

Repeat flags now travel in LoadRequestOptions before manually queued tracks
are appended. Recovery then sends RepeatTrack with the already-applied value.
In the pinned dependency that publishes both repeat flags without rebuilding
the context queue. This extra event is necessary: handle_load applies options
without emitting RepeatChanged, while Activate initially publishes defaults.
Normal interactive repeat controls continue using the existing set_repeat.

The old post-load repeat command rebuilt the context-derived queue suffix and
previous tracks. It did **not** discard a normal leading manual queue prefix:
clear_next_tracks explicitly retains that prefix.

The repeat correction does not solve shuffled recovery. Calling shuffle(true)
after a flattened load still generates a new permutation. Setting shuffle in
LoadRequestOptions also invokes shuffle_new. Simply setting the shuffle flag
and skipping that operation would leave ShuffleVec without inverse-shuffle
bookkeeping; switching shuffle off could not recover the original order.
Pending context resolution can also trigger another shuffle.

## Information the current snapshot cannot reconstruct

QueueTrack has only URI and provider. Exact recovery additionally needs:

- The original unshuffled context and its shuffle permutation/seed/initial item.
- Track occurrence identities and context indices, including duplicate URIs.
- The underlying context cursor while a manually queued track is current.
- Current, next and previous queue entries with metadata, manual priority,
  repeat delimiters/iterations and pagination/continuation state.
- A coherent generation tying the playback position and options to that queue.

Splitting the manual prefix from context tracks prevents manual additions from
becoming part of context repeat, but does not reconstruct the missing indices
or shuffle history. A capped URI list cannot promise continuation of the
original context beyond that captured window.

## Proposed dependency contract for discussion

Prefer a dependency-owned opaque PlaybackSnapshot rather than exposing a
flag to reinterpret a URI list as an exact snapshot. Capture it coherently
while Spirc still owns its Connect state, and retain the latest snapshot across
session-task termination. Keep authentication, Session handles, device ownership
and other clients' credentials outside it.

Restore context/shuffle bookkeeping, occurrence identities, queue/cursors and
options together, before requesting audio load. Ensure old context-resolution
results cannot later overwrite the restored generation. Publish queue, shuffle
and repeat events after applying state so socket and MPRIS observers agree.
Distinguish accepted restoration commands, committed Connect state and actual
Playing/Paused events; an enqueue acknowledgement does not prove audio resumed.

Avoid copying/serializing the entire context on every position update. Shared
immutable context data plus updates on queue/context changes are worth evaluating
inside librespot, where ownership and coherence can be enforced.

An API promising only “play this captured sequence” is a smaller alternative,
but must explicitly give up original context continuation and shuffle/unshuffle
semantics. It should not be described as exact recovery.

## Acceptance tests before marking the PR ready

Test the complete dependency restore operation, not only snapshot construction:

1. Paused shuffled A with manually queued B then context C/D retains position,
   pause and next order B/C/D after restore and context resolution.
2. Turning shuffle off restores the original unshuffled context order.
3. Duplicate URI occurrences retain their identities and cursor positions.
4. Recovery while a manually queued track is current resumes the context at the
   correct occurrence afterward; manual additions do not reappear on repeat.
5. Off/context/track repeat all reach both Connect and backend/MPRIS observers,
   preserving volume and the manual prefix without an extra context rebuild.
6. Queue continuation works beyond the 80 visible upcoming items; previous-track
   navigation and repeat delimiters remain coherent.
7. Stale resolver results and a remote takeover cannot replay an old generation.
8. A load accepted into the command queue that later fails is not reported as
   confirmed playback restoration.

Follow deterministic dependency tests with real paused/playing reconnect and
remote-takeover checks. These live recovery checks have not been performed for
this draft; the current tests cover capture and recovery-command dispatch only.
