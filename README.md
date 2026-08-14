<div align="center">

# 🍓 Remote Auto Feed

### Keep working Pals fed without sending them across the base to a feed box.

[![Version](https://img.shields.io/badge/version-v1.0.0-2ea44f?style=flat-square)](CHANGELOG.md)
[![Palworld](https://img.shields.io/badge/Palworld-1.0-00a2ff?style=flat-square)](https://store.steampowered.com/app/1623730/Palworld/)
[![UE4SS](https://img.shields.io/badge/UE4SS-Lua-6f42c1?style=flat-square)](https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587)
[![Server](https://img.shields.io/badge/server-Windows%20Dedicated-0078d4?style=flat-square&logo=windows)](#-requirements)
[![License](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)](LICENSE)

[![Download v1.0.0](https://img.shields.io/badge/Download-v1.0.0-2ea44f?style=for-the-badge&logo=github)](https://github.com/MoritzT/RemoteAutoFeed/raw/refs/heads/main/dist/RemoteAutoFeed-v1.0.0-server-only.zip)
[![Steam Workshop](https://img.shields.io/badge/Steam-Workshop-1b2838?style=for-the-badge&logo=steam)](https://steamcommunity.com/sharedfiles/filedetails/?id=3783217681)

**Server-side only · No client installation required · Uses Palworld's native food-consumption path**

</div>

---

## 🚀 What is Remote Auto Feed?

**Remote Auto Feed** is a Palworld dedicated-server mod that prevents working base Pals from wasting time walking to a feed box whenever they become hungry.

Palworld still chooses the normal feed box and food item. Remote Auto Feed waits for that vanilla target to be initialized, stops the walk, and feeds the Pal remotely through Palworld's own item-use API.

> The goal is simple: **keep Pals at work while preserving normal server-side food consumption and satiety behavior.**

---

## ✨ Features

| Feature | Description |
|---|---|
| 🍓 **Remote feeding** | Hungry base Pals can eat without walking to the selected feed box. |
| 🖥️ **Server-side only** | Clients do **not** need to install the mod. |
| 📦 **Vanilla feed-box selection** | Palworld still decides which feed box and food slot are used. |
| 🔧 **Native item use** | Food is consumed with Palworld's `RequestUseToCharacter()` path instead of directly editing inventory values. |
| ❤️ **Percentage-based target** | Pals are fed to at least **90% of their own maximum FullStomach** by default. |
| 🛡️ **Vanilla limits respected** | Respects `EatMaxNum` with an additional hard safety cap. |
| 🔒 **Feed-box concurrency protection** | One complete remote meal at a time per physical feed-box container prevents same-box races. |
| 📝 **Clean production logging** | One compact log line per completed meal. |
| 🐛 **Optional debug logging** | Detailed target, queue, movement and per-bite diagnostics when needed. |

---

## 💻 Requirements & Compatibility

| Requirement | Status | Notes |
|---|:---:|---|
| Palworld 1.0 | ✅ | Current target version |
| Windows Dedicated Server | ✅ | Required by this build |
| UE4SS Experimental | ✅ | Required dependency |
| Client-side install | ❌ | Not required |
| Custom client UI/assets | ❌ | None |

### Required dependency

**UE4SS Experimental for Palworld**  
https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587

---

## 📥 Installation

### Option 1 — Steam Workshop

The easiest installation method is the official Workshop item:

### 👉 [Remote Auto Feed on Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3783217681)

Install/enable both:

1. **UE4SS Experimental for Palworld**
2. **Remote Auto Feed**
3. Fully restart the Palworld dedicated server.

The Workshop package is declared as server-side Lua:

```json
{
  "Type": "Lua",
  "IsServer": true,
  "Targets": ["./Scripts"]
}
```

---

### Option 2 — Manual UE4SS install

Download the ready-to-use package:

### 👉 [Download RemoteAutoFeed v1.0.0 — server only](https://github.com/MoritzT/RemoteAutoFeed/raw/refs/heads/main/dist/RemoteAutoFeed-v1.0.0-server-only.zip)

Extract it so your UE4SS installation contains:

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

Then fully restart the dedicated server.

<details>
<summary><strong>🔐 Release checksum</strong></summary>

```text
SHA-256
9cbe6758a9c29fd0fb7ea493220f842bfcab3670947ee71cc78788502cbe5a0e
```

</details>

---

## ⚙️ Configuration

Configuration is stored in:

```text
Scripts/config.lua
```

### Common settings

| Setting | Default | Description |
|---|:---:|---|
| `Enabled` | `true` | Enables Remote Auto Feed. |
| `RequireDedicatedServer` | `true` | Prevents the mod from running outside the intended dedicated-server environment. |
| `MealLogging` | `true` | Writes one compact line for each completed remote meal. |
| `DebugLogging` | `false` | Enables detailed troubleshooting logs. |
| `TargetSatietyPercent` | `0.90` | Feeds to at least 90% of the Pal's own maximum stomach capacity. |
| `MinRemoteBites` | `1` | Minimum number of valid food items consumed after entering the hunger flow. |
| `HardMaxRemoteBites` | `20` | Absolute safety cap while still respecting a lower vanilla `EatMaxNum`. |

<details>
<summary><strong>🧪 Advanced timing settings</strong></summary>

| Setting | Default | Purpose |
|---|:---:|---|
| `TargetResolveRetryMs` | `50` | Delay between attempts to resolve the vanilla feed-box target. |
| `TargetResolveMaxAttempts` | `20` | Maximum target-resolution attempts. |
| `VerifyDelayMs` | `150` | Delay before verifying that a bite increased FullStomach. |
| `BetweenBitesDelayMs` | `50` | Delay between successful bites. |
| `ContainerQueueRetryMs` | `50` | Retry delay while another Pal owns the same feed-box lock. |
| `CompletedStateRetentionMs` | `5000` | Briefly retains completed action state to prevent immediate duplicate re-entry. |
| `SatietyEpsilon` | `0.001` | Floating-point tolerance for satiety comparisons. |

</details>

### Example: change the recovery target

```lua
TargetSatietyPercent = 0.90
```

`0.90` means **90%**. Because food is consumed as whole items, the final value can exceed the exact target.

---

## 📝 Logging

Production defaults are intentionally lightweight:

```lua
MealLogging = true
DebugLogging = false
```

A completed meal looks like:

```text
[RemoteAutoFeed] MEAL | Pal=BP_Serpent_C | items=5 | fullness=50.0%->99.9% | target=90.0% | status=complete
```

That gives server admins the important information without filling the log with per-bite details.

For troubleshooting:

```lua
DebugLogging = true
```

Debug mode adds target-resolution retries, movement cancellation, feed-box queue/lock activity, individual bites, stack diagnostics, FullStomach verification and Approach re-entry suppression.

Warnings and errors remain visible even when debug logging is disabled.

---

## 🧠 How it works

When Palworld enters its normal:

```text
RecoverHungry
└── ApproachToFoodBox
    └── Eat
```

Remote Auto Feed intercepts the process after Palworld has initialized the real target:

1. Palworld selects the feed box normally.
2. The mod resolves the hungry Pal and its real `FPalInstanceID`.
3. The selected feed-box `UPalItemContainer` is resolved.
4. The concrete `ApproachToFoodBox` movement is cancelled.
5. Food is consumed through `RequestUseToCharacter(PalInstanceID, 1)`.
6. Each bite is verified by checking the target Pal's `FullStomach` increase.
7. Feeding continues until the configured percentage target or vanilla bite limit is reached.
8. The hunger action is ended and the Pal can continue working.

### What the mod does **not** do

- It does **not** directly modify `StackCount`.
- It does **not** directly set `FullStomach`.
- It does **not** add custom RPCs or replicated classes.
- It does **not** require a client-side mod.

---

## 🔒 Concurrency & safety

Only one complete remote meal can own a physical feed-box container at a time. If several hungry Pals target the same box, later meals wait briefly while their feed-box movement remains cancelled.

Different feed boxes can still serve Pals concurrently.

The individual Pal's **FullStomach increase is the authoritative success check**. Feed-box stack changes are treated as diagnostics because other server systems may also modify inventory at the same time.

If the mod cannot safely resolve the vanilla target, container, Pal instance ID, maximum stomach or hunger parameters, it abandons the remote attempt and leaves vanilla feeding available instead of forcing an unsafe state.

---

## 📁 Repository structure

```text
RemoteAutoFeed/
├── CHANGELOG.md
├── Info.json
├── LICENSE
├── README.md
├── enabled.txt
├── dist/
│   └── RemoteAutoFeed-v1.0.0-server-only.zip
└── Scripts/
    ├── config.lua
    └── main.lua
```

---

## 📜 Changelog

See [CHANGELOG.md](CHANGELOG.md) for release history.

### v1.0.0

- Initial public release
- Remote server-side feeding
- 90% normalized satiety target
- Feed-box concurrency protection
- Compact production meal logging
- Optional detailed debug logging
- No client installation required

---

## ⚠️ Compatibility note

Palworld and UE4SS can change across game updates. Re-test server-side mods after major Palworld updates and keep backups of important worlds.

---

## 📄 License

Released under the [MIT License](LICENSE).

Palworld is a trademark of Pocketpair, Inc. This project is an unofficial community mod and is not affiliated with or endorsed by Pocketpair.

Third-party trademarks, game assets and other third-party materials are not covered by this repository's MIT license unless explicitly stated.

---

<div align="center">

### 🍓 Keep your Pals fed. Keep your base moving.

[Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3783217681) · [Download v1.0.0](https://github.com/MoritzT/RemoteAutoFeed/raw/refs/heads/main/dist/RemoteAutoFeed-v1.0.0-server-only.zip) · [Changelog](CHANGELOG.md)

</div>
