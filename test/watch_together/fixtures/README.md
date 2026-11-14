# Timing reference traces

`timing-v2.json` records outputs from uburoom's `shared/sync/timing.mjs` (2026-11-13), identified by its SHA-256. These are executable algorithm reference outputs, not mocked transport answers. Clock scenarios start with monotonic 0 and wall 1700000000000 ms. Each row advances both clocks by gap, begins an exchange, advances both by duration, adds the supplied timing and reads the result.

Clock columns: gap, duration, serverReceivedAt, serverSentAt, serverProcessingMs, clockEpoch, accepted, valid, serverTime, uncertaintyMs, stabilityMs, revision, reason. Null results mean the mapping is invalid.

Correction columns: now, target-minus-position error (seconds), eligible, context, uncertaintyMs, stabilityMs, frameSeconds, expectedRate. Inputs were evaluated sequentially by a fresh `correction()` for each scenario. Traces cover acquisition, persistent route changes, server steps, invalid exchanges, uncertainty-driven validity, discontinuities, convergence, stalled progress/backoff, noise, clock instability and context changes.
