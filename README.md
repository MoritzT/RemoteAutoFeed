<div align="center">

# 🍓 Remote Auto Feed

### Keep working Pals fed without sending them across the base to a feed box.

[![Version](https://img.shields.io/badge/version-v1.1.0-2ea44f?style=flat-square)](CHANGELOG.md)
[![Palworld](https://img.shields.io/badge/Palworld-1.0-00a2ff?style=flat-square)](https://store.steampowered.com/app/1623730/Palworld/)
[![UE4SS](https://img.shields.io/badge/UE4SS-Lua-6f42c1?style=flat-square)](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587)
[![Server](https://img.shields.io/badge/server-Windows%20Dedicated-0078d4?style=flat-square&logo=windows)](#-requirements)
[![License](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)](LICENSE)

[![Download v1.1.0](https://img.shields.io/badge/Download-v1.1.0-2ea44f?style=for-the-badge&logo=github)](https://github.com/MoritzT/RemoteAutoFeed/raw/refs/heads/main/dist/RemoteAutoFeed-v1.1.0-server-only.zip)
[![Steam Workshop](https://img.shields.io/badge/Steam-Workshop-1b2838?style=for-the-badge&logo=steam)](https://steamcommunity.com/sharedfiles/filedetails/?id=3783217681)

**Server-side only · No client installation required · Uses Palworld's native food-consumption path**

</div>

---

## 🚀 What is Remote Auto Feed?

Remote Auto Feed is a Palworld dedicated-server mod that prevents working base
Pals from wasting time walking to a feed box whenever they become hungry.

Palworld still chooses the normal feed box and food item. Remote Auto Feed
waits for that vanilla target, stops the walk, and feeds the Pal remotely
through Palworld's own item-use API.

v1.1.0 adds a conservative starvation safety net for long-running servers
where a critically hungry Pal becomes stuck before the vanilla hunger flow
reaches the normal Remote Auto Feed hook.

## ✨ Features

| Feature | Description |
|---|---|
| 🍓 **Remote feeding** | Hungry base Pals eat without walking to the selected feed box. |
| 🛡️ **Starvation safety net** | Recovers critically hungry Pals stuck before or inside `RecoverHungry`. |
| 🖥️ **Server-side only** | Clients do not need the mod. |
| 📦 **Vanilla feed-box selection** | Palworld still selects the feed box and food slot. |
| 🔧 **Native item use** | Uses `RequestUseToCharacter()` rather than direct inventory edits. |
| ❤️ **90% target** | Percentage-based target using each Pal's own maximum stomach capacity. |
| 🍽️ **Multi-batch meals** | Can continue beyond one vanilla `EatMaxNum` batch. |
| 🔒 **Feed-box locking** | Serializes complete meals per physical feed-box container. |
| 📝 **Clean logging** | Compact `MEAL` and `SAFETY` lines; detailed diagnostics are opt-in. |

## 🆕 v1.1.0

The safety net covers two observed stuck states:

1. A critically hungry Pal stays in sleep/work and never enters `RecoverHungry`.
2. A critically hungry Pal enters `RecoverHungry` but never reaches `ChangeActionApproach`.

The fallback only nudges Palworld's AI state. Actual feeding still uses the
vanilla-selected feed box, real inventory, and `RequestUseToCharacter()`.

Low-nutrition food can also continue into another verified batch if one
`EatMaxNum` batch is not enough to reach the configured target.

## 💻 Requirements

- Palworld dedicated server on Windows
- UE4SS Experimental for Palworld
- No client-side Remote Auto Feed installation

**UE4SS Experimental:**  
https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587

## 📥 Installation

### Steam Workshop

https://steamcommunity.com/sharedfiles/filedetails/?id=3783217681

### Manual UE4SS install

[Download RemoteAutoFeed v1.1.0 — server only](https://github.com/MoritzT/RemoteAutoFeed/raw/refs/heads/main/dist/RemoteAutoFeed-v1.1.0-server-only.zip)

Extract so UE4SS contains:

```text
ue4ss/
└── Mods/
    └── RemoteAutoFeed/
        ├── enabled.txt
        ├── LICENSE
        ├── README.md
        ├── CHANGELOG.md
        └── Scripts/
            ├── config.lua
            └── main.lua
```

SHA-256:

```text
335107c8add88e763616339136f689a2d6f2bb12778298989a6a4683fea61738
```

## ⚙️ Configuration

```lua
MealLogging = true
DebugLogging = false

TargetSatietyPercent = 0.90
TargetResolveRetryMs = 50
TargetResolveMaxAttempts = 200

SafetyNetEnabled = true
SafetyNetCheckIntervalMs = 10000
SafetyNetTriggerPercent = 0.30
SafetyNetGraceScans = 3
SafetyNetCooldownScans = 3
SafetyNetMaxNudgesPerEpisode = 3

RemoteMealBatchPauseMs = 100
HardMaxRemoteBites = 40
```

## 📝 Logging

```text
[RemoteAutoFeed] MEAL | Pal=BP_Serpent_C | items=5 | fullness=50.0%->99.9% | target=90.0% | status=complete
```

```text
[RemoteAutoFeed] SAFETY | Pal=BP_..._C | actor=BP_..._C_2147... | fullness=29.5% | fix=kick-recover-approach | nudge=1
```

Warnings and errors remain visible with debug logging disabled.

## 🧠 How it works

1. Palworld selects the feed box normally.
2. Remote Auto Feed resolves the hungry Pal and selected feed-box container.
3. Physical `ApproachToFoodBox` movement is cancelled.
4. Food is consumed with `RequestUseToCharacter(PalInstanceID, 1)`.
5. Every bite is verified against that Pal's `FullStomach`.
6. Feeding continues to the configured target, using another batch if needed.
7. The hunger action ends and the Pal continues working.

The mod does not directly modify `StackCount` or set `FullStomach`.

## 🔒 Safety

- Per-feed-box container locking
- Individual-Pal `FullStomach` verification
- Safe abandonment when required vanilla objects cannot be resolved
- Safety-net grace period, cooldown, and per-episode nudge cap
- No custom RPCs, replicated classes, client assets, or client UI

## 📁 Repository structure

```text
RemoteAutoFeed/
├── CHANGELOG.md
├── Info.json
├── LICENSE
├── README.md
├── enabled.txt
├── dist/
│   ├── RemoteAutoFeed-v1.0.0-server-only.zip
│   └── RemoteAutoFeed-v1.1.0-server-only.zip
└── Scripts/
    ├── config.lua
    └── main.lua
```

## 📄 License

Released under the [MIT License](LICENSE).

Palworld is a trademark of Pocketpair, Inc. This project is an unofficial
community mod and is not affiliated with or endorsed by Pocketpair.

<div align="center">

### 🍓 Keep your Pals fed. Keep your base moving.

[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3783217681) · [Download v1.1.0](https://github.com/MoritzT/RemoteAutoFeed/raw/refs/heads/main/dist/RemoteAutoFeed-v1.1.0-server-only.zip) · [Changelog](CHANGELOG.md)

</div>
