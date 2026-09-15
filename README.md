# EreFBIOpenUpDoor
Project Zomboid MOD:

https://steamcommunity.com/sharedfiles/filedetails/?id=2732513069

## Sandbox translations

Build 42 switched to JSON translations in [42.15](https://theindiestone.com/forums/topic/92435-42150-unstable-released/). The paths below are relative to `Contents/mods/EreFBIOpenUpDoor/`:

| Game build | Translation file |
| --- | --- |
| B41 | `media/lua/shared/Translate/<locale>/Sandbox_<locale>.txt` |
| Current B42 | `42/media/lua/shared/Translate/<locale>/Sandbox.json` |

Verified against the installed B42.20.4 vanilla files and `zombie.core.Translator`: JSON files contain a flat object of translation keys and string values, encoded as UTF-8 without a BOM. The locale comes from the directory (`EN`, `ES`, etc.); there is no `Sandbox_EN` wrapper or locale suffix on the filename.

```json
{
    "Sandbox_EreFBIOpenUpDoor": "FBI Open Up Door",
    "Sandbox_EreFBIOpenUpDoor_AutoCloseDoor": "Auto-Close Doors",
    "Sandbox_EreFBIOpenUpDoor_AutoCloseDoor_tooltip": "If enabled, doors opened by the mod will automatically close after the player passes through them."
}
```

Keep the `Sandbox_` prefix and the case-sensitive `_tooltip` suffix. Use JSON escapes such as `\n` for newlines and `\"` for quotes. Literal percentages must use `%%` to display `%`, as documented in the [42.20.1 notes](https://theindiestone.com/forums/topic/98369-build-42201-stable-hotfix-released/). Each locale includes the page title plus labels and tooltips for all 14 options in `42/media/sandbox-options.txt`.

In-game check: open Custom Sandbox with the mod enabled in B42, select English and a translated language, and check the page title, all option labels, hover tooltips, newlines, and percentage signs.
