# Changelog

## v1.0.0

- Initial public release.
- Server-side remote feeding for working base Pals.
- Cancels concrete `ApproachToFoodBox` movement after Palworld initializes the vanilla feed-box target.
- Uses Palworld's native `RequestUseToCharacter()` item-use path.
- Normalizes the recovery target to 90% of each Pal's own maximum stomach capacity by default.
- Preserves any higher vanilla `RecoverSatietyTo` value.
- Respects vanilla `EatMaxNum` with an additional hard safety cap.
- Serializes complete meals per physical feed-box container.
- Uses the individual Pal's `FullStomach` increase as authoritative bite verification.
- Adds compact production meal logging with Pal, item count, fullness before/after, target and status.
- Keeps detailed target, per-bite, queue and hook diagnostics behind `DebugLogging`.
- Keeps warnings and errors visible even when detailed debug logging is disabled.
- Cleans completed hunger-action state after a short retention window for long-running servers.
- No client mod required.
