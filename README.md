# Remote Auto Feed

![Remote Auto Feed](assets/banner.png)

**Server-side UE4SS Lua mod for Palworld 1.0. Clients do not need to install the mod.**

Remote Auto Feed prevents working base Pals from walking to a feed box whenever they become hungry. Palworld still selects the normal feed box and food; the server then uses Palworld's own item-use path to feed the Pal remotely, cancels the feed-box movement action, and lets the Pal continue working.

[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3783217681)

## Features

- No more trips to the feed box for working base Pals.
- Dedicated-server only; no client installation required.
- Uses the feed box selected by vanilla Palworld.
- Uses Palworld's own `RequestUseToCharacter()` item-use function rather than directly editing inventory or hunger values.
- Feeds each hungry Pal to at least 90% of its own maximum stomach capacity by default.
- Respects vanilla `EatMaxNum` with an additional safety cap.
- Serializes complete meals per physical feed-box container so multiple hungry Pals cannot race the same inventory.
- Lightweight one-line meal logging for server admins.
- Optional detailed debugging for target resolution, movement cancellation, individual bites and queue activity.

## How it works

When Palworld enters its normal `RecoverHungry -> ApproachToFoodBox` flow, Remote Auto Feed:

1. Lets Palworld initialize and select the actual feed box.
2. Resolves the hungry Pal and its real `FPalInstanceID`.
3. Resolves the selected feed-box item container.
4. Cancels the concrete `ApproachToFoodBox` movement.
5. Consumes food through Palworld's own `RequestUseToCharacter(PalInstanceID, 1)` path.
6. Verifies each bite by checking that the specific Pal's `FullStomach` increased.
7. Continues until the configured percentage of that Pal's own `GetMaxFullStomach()` is reached, while respecting `EatMaxNum`.
8. Ends the hunger action so the Pal can continue working.

Remote Auto Feed does **not** directly modify `StackCount` or `FullStomach`.

## Requirements

- Palworld 1.0
- Windows dedicated server
- [UE4SS Experimental for Palworld](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587)

## Steam Workshop installation

The recommended installation is through the [Steam Workshop item](https://steamcommunity.com/sharedfiles/filedetails/?id=3783217681).

The Workshop package declares:

```json
{
  "Type": "Lua",
  "IsServer": true,
  "Targets": ["./Scripts"]
}
```

and lists `UE4SS` as a dependency.

After enabling the Workshop item and UE4SS for the dedicated server, fully restart the Palworld server process.

## Manual UE4SS installation

Copy the repository's `Scripts` directory and `enabled.txt` into:

```text
ue4ss/
└── Mods/
    └── RemoteAutoFeed/
        ├── enabled.txt
        └── Scripts/
            ├── config.lua
            └── main.lua
```

Then fully restart the dedicated server.

## Configuration

Configuration lives in `Scripts/config.lua`.

### Recovery target

```lua
TargetSatietyPercent = 0.90
```

`0.90` means the Pal is fed to at least 90% of its own maximum stomach capacity. Whole food items can overshoot the target; for example, a Pal at 89.9% may finish near 100% after consuming one whole berry.

### Logging

Production defaults:

```lua
MealLogging = true
DebugLogging = false
```

A completed meal emits one compact line:

```text
[RemoteAutoFeed] MEAL | Pal=BP_Serpent_C | items=5 | fullness=50.0%->99.9% | target=90.0% | status=complete
```

This records which Pal ate, how many items were consumed, fullness before/after and the target.

Warnings and errors are always logged.

For troubleshooting, enable:

```lua
DebugLogging = true
```

Detailed mode additionally logs target initialization/retries, movement cancellation, feed-box locks/queues, per-bite item/stack diagnostics, `FullStomach` verification and Approach re-entry suppression.

## Concurrency

Only one complete Remote Auto Feed meal runs at a time per physical feed-box container. Hungry Pals targeting the same box are queued while their feed-box movement remains cancelled. Different feed boxes can still serve Pals concurrently.

The individual Pal's `FullStomach` increase is the authoritative proof that a bite succeeded. Feed-box stack changes are diagnostic only because other consumers may also touch the inventory.

## Safety / fallback

Before movement is cancelled, the mod must successfully resolve the vanilla feed-box target, container, Pal instance ID, maximum stomach and recovery parameters. If setup fails, Remote Auto Feed abandons the remote attempt and leaves vanilla feeding available while logging a warning.

The mod adds no custom RPCs, replicated classes, client UI or client assets.

## Compatibility note

Palworld and UE4SS can change across game updates. Re-test server-side mods after major Palworld updates and keep backups of important worlds.

## License

Source code is released under the [MIT License](LICENSE).

Palworld is a trademark of Pocketpair, Inc. This project is an unofficial community mod and is not affiliated with or endorsed by Pocketpair. Third-party trademarks, game assets and other third-party materials are not covered by this repository's MIT license unless explicitly stated.
