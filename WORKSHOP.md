# Steam Workshop packaging

Remote Auto Feed is published on the Palworld Steam Workshop:

https://steamcommunity.com/sharedfiles/filedetails/?id=3783217681

## Workshop payload

The Workshop uploader directory should contain:

```text
Info.json
thumbnail.png
README.md
CHANGELOG.md
Scripts/
├── config.lua
└── main.lua
```

Pocketpair's Palworld Mod Uploader also creates a hidden `.workshop.json` containing the Steam Workshop Published ID. **Do not commit or replace that file.** It is intentionally ignored by this repository.

## Server-only Lua install rule

`Info.json` declares the mod as server-side Lua:

```json
{
  "Type": "Lua",
  "IsServer": true,
  "Targets": ["./Scripts"]
}
```

The package also declares `UE4SS` as a dependency.

## Updating the Workshop item

1. Update `Scripts/main.lua` and/or `Scripts/config.lua`.
2. Increment `Version` in `Info.json`.
3. Copy the updated files into the existing uploader directory while preserving `.workshop.json`.
4. Keep `thumbnail.png` below Steam's upload-size limit.
5. Reload the mod in Palworld Mod Uploader.
6. Upload the update to Steam with concise change notes.
7. Fully restart the dedicated server when testing the new version.

## Required Workshop item

The Steam listing should keep UE4SS Experimental for Palworld configured as a Required Item:

https://steamcommunity.com/sharedfiles/filedetails/?id=3625223587
