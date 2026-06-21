---
name: universal_config
description: Read and write INI-style config from an AMXX plugin via the Universal Config System (cfg_* natives from include/universal_config.inc). Use when a plugin needs to load configs, read values (string/int/float/bool/arrays, nested paths), or persist values back to .ini with comment round-trip. Covers the API, recipes, and the config-write caveats that bite (cfg_save_config vs cfg_write_file, nested-block limits).
---

# Universal Config System — consumer guide

`universal_config.amxx` is a **foundational engine** that parses/manages/writes INI-like
files with nested sections, key=value pairs, multi-value lines and `{ ... }` blocks. Other
plugins consume it through registered natives. **Never** open config files with the default
file API in a module — always go through `cfg_*`.

```pawn
#include <universal_config>
```

`universal_config.amxx` must be listed in `configs/plugins.ini` **before** any plugin that
uses it.

## Core types
- `ConfigFile:` handle from `cfg_load_file` (`CFG_FILE_INVALID` on failure).
- `ConfigSection:` handle from `cfg_get_section` / `cfg_create_section` (`CFG_SECTION_INVALID`).
- `EntryType:` `CFG_ENTRY_SIMPLE` | `CFG_ENTRY_BRACKET`.
- `ContentType:` `CFG_CONTENT_SIMPLE` | `CFG_CONTENT_STRINGS` | `CFG_CONTENT_ENTRIES`.

## Read recipe (the 90% case)
```pawn
new ConfigFile:cfg = cfg_load_file("mymod")          // ".ini" auto-appended
if (cfg == CFG_FILE_INVALID) return

new ConfigSection:sec = cfg_get_section(cfg, "Settings")
if (sec == CFG_SECTION_INVALID) return

new buf[64]
cfg_get_value(sec, "name", buf, charsmax(buf))       // string
new hp   = cfg_get_int(sec, "health")                // int
new spd  = cfg_get_float(sec, "speed")               // float
new on   = cfg_get_bool(sec, "enabled")              // bool

// nested path "block/subkey", multi-value index, block line index:
new v[64]
cfg_get_value_by_path(sec, "HUD/COLOR", v, charsmax(v), .index = 0, .lineIndex = 0)

// a whole space/quote-delimited line as an array (CALLER destroys it):
new Array:parts = cfg_get_value_array(sec, "spawn_points")
if (parts != Invalid_Array) { /* ... */ ArrayDestroy(parts) }
```
Read helpers: `cfg_get_value`, `cfg_get_value_by_path`, `cfg_get_int`, `cfg_get_float`,
`cfg_get_bool`, `cfg_get_value_array`, `cfg_get_float_array`, `cfg_get_value_array_by_path`,
`cfg_get_top_level_keys`, `cfg_get_array_size`, `cfg_has_key`.
**Any `Array:` returned by a `cfg_*` native is owned by the caller — `ArrayDestroy` it.**

## Write recipe
```pawn
cfg_set_value(sec, "name", "new")     // also cfg_set_int/float/bool
cfg_set_int(sec, "health", 100)
cfg_save_config(cfg, "mymod.ini")     // persist — ALWAYS pass the filename
```

## Write caveats (read before persisting — these bite)
- **Always pass the filename**: `cfg_save_config(cfg, "path/file.ini")`. The 1-arg form looks
  the name up internally and can silently yield an empty name (→ returns `false`) after many
  `cfg_load_file` calls. Reads still work in that state, so a menu can *show* values yet fail
  to save.
- **`cfg_save_config` vs `cfg_write_file`:** `cfg_write_file` writes a **single** section (other
  sections are dropped). For a multi-section file use `cfg_save_config`.
- **Comment round-trip:** `;` comment lines survive a load→save cycle (re-emitted before the
  element they preceded). But only comments **present in the loaded file** survive — elements
  created programmatically (e.g. a new block via `cfg_set_value`) carry no comment unless one
  already existed on that row. Use `cfg_set_row_comment` to attach an in-block hint to a
  programmatically created bracket row.
- **Nested-block writes are limited:** multi-column / multi-row nested brackets like
  `map = { 3x3 = { "a" "b" ... } }` are **not** cleanly writable through the public API (the
  leaf index is treated as a sibling-occurrence selector, not a column). Reading them is fine.

## Build
```bash
cd scripting
./amxxpc.exe yourmod.sma -i./include -o../plugins/yourmod.amxx
```
Recompile and fix every compiler warning before shipping.

## Full native reference
See `scripting/include/universal_config.inc` — every native has a doc comment with params and
return values. Read it first when touching config code.
