# Changelog

## v1.1.0

- Adds a conservative starvation safety net for long-running dedicated servers.
- Recovers critically hungry Pals that remain stuck in sleep/work and never enter the vanilla `RecoverHungry` flow.
- Recovers critically hungry Pals that enter `RecoverHungry` but stall before `ChangeActionApproach`.
- Safety interventions only nudge Palworld's AI state; they do not directly set `FullStomach` or directly modify food stacks.
- Adds unique runtime `actor=` identifiers to safety/debug telemetry.
- Increases feed-box target resolution retries to 200 for complex and multi-level bases.
- Treats vanilla `EatMaxNum` as a per-batch size and continues into another verified batch when low-nutrition food cannot reach the target in one batch.
- Raises the separate total remote-meal safety cap to 40 verified bites.
- Successful meals that require more than 10 items no longer generate a false bite-limit warning.
- Keeps detailed debug/watchdog output disabled by default while the starvation safety net remains active.
- No client mod required.

## v1.0.0

- Initial public release.
- Server-side remote feeding for working base Pals.
- Uses Palworld's native `RequestUseToCharacter()` item-use path.
- 90% normalized satiety target by default.
- Per-feed-box concurrency protection.
- Compact production meal logging and optional detailed debug logging.
- No client mod required.
