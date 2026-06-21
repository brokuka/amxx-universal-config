<p align="center">
  <img src="assets/logo.png" alt="Universal Config System" width="200">
</p>

<h1 align="center">Universal Config System</h1>

A flexible **INI-like configuration engine for AMX Mod X**. Parse, read, modify and
write config files with support for sections, key–value pairs, multi-value lines and
nested block structures. Comments and blank lines are preserved on a load/save
round-trip. Other plugins consume it through the registered natives.

- **Version:** 1.6.1
- **Author:** kukson
- **License:** MIT (see `LICENSE`).

---

## Features

- INI-like format: `[sections]`, `key = value`, multi-value lines.
- Nested block structures: `key { ... }` up to 5 levels deep.
- Typed getters: string / int / float / bool, plus string and float arrays.
- Path access into nested blocks: `cfg_get_value_by_path(section, "block/subkey", ...)`.
- Setters and structure editing: `cfg_set_value`, `cfg_set_int/float/bool`,
  `cfg_create_section`, `cfg_set_entry_type`, `cfg_delete_key`.
- **Comment round-trip:** `;` comment lines and blank-line spacing are captured on load
  and re-emitted on save, attached to the element they preceded.
- Quote-aware tokenizer for lines like `"text" "flag" "values"`.

## Installation

1. Copy `scripting/universal_config.sma` into your AMX Mod X `scripting/` folder.
2. Copy `scripting/include/universal_config.inc` into `scripting/include/`.
3. Compile:
   ```
   amxxpc universal_config.sma -i./include -o../plugins/universal_config.amxx
   ```
4. Add `universal_config.amxx` to `configs/plugins.ini` **before** any plugin that
   depends on it.

## Quick start

```pawn
#include <amxmodx>
#include <universal_config>

public plugin_init() {
    new ConfigFile:cfg = cfg_load_file("myplugin.ini");        // configs/myplugin.ini
    new ConfigSection:sec = cfg_get_section(cfg, "Settings");

    new name[64];
    cfg_get_value(sec, "name", name, charsmax(name));
    new rounds = cfg_get_int(sec, "max_rounds");
    new Float:speed = cfg_get_float(sec, "speed");

    // Modify and persist (comments/spacing are preserved):
    cfg_set_int(sec, "max_rounds", rounds + 1);
    cfg_save_config(cfg, "myplugin.ini");
}
```

Example `configs/myplugin.ini`:

```ini
[Settings]
; player display name
name = Player
max_rounds = 10
speed = 1.5

; nested block example (note the "= {" opener)
weapons = {
    "weapon_ak47" "1"
    "weapon_m4a1" "1"
}
```

## API overview

See `scripting/include/universal_config.inc` for the fully documented native list.

| Area | Natives |
|------|---------|
| Loading / lookup | `cfg_load_file`, `cfg_get_section`, `cfg_create_section`, `cfg_set_base_dir` |
| Reading | `cfg_get_value`, `cfg_get_value_by_path`, `cfg_get_int`, `cfg_get_float`, `cfg_get_bool` |
| Arrays | `cfg_get_value_array`, `cfg_get_float_array`, `cfg_get_value_array_by_path`, `cfg_get_top_level_keys`, `cfg_get_array_size` |
| Writing | `cfg_set_value`, `cfg_set_int`, `cfg_set_float`, `cfg_set_bool`, `cfg_delete_key` |
| Structure | `cfg_set_entry_type`, `cfg_set_entry_content_type`, `cfg_set_row_comment` |
| Saving | `cfg_save_config`, `cfg_write_file` |
| Introspection | `cfg_has_key`, `cfg_get_sections_count`, `cfg_get_section_name`, `cfg_get_section_data` |

## AI-assisted development (Claude Code skill)

This repo ships a **[Claude Code](https://claude.com/claude-code) skill** at
[`.claude/skills/universal_config/SKILL.md`](.claude/skills/universal_config/SKILL.md).

When you develop a plugin with Claude Code inside (or alongside) this repo, the AI
automatically picks up the skill and gets a condensed, accurate guide to the engine —
the API surface, the read/write recipes, and the gotchas that bite (e.g.
`cfg_save_config` vs `cfg_write_file`, nested-block write limits). It helps the model
write correct `cfg_*` code without you having to explain the engine each time.

No setup needed — just have the skill file in your workspace.

## Use cases & recipes

Every scenario the engine is designed for, with runnable snippets.

### 1. Read a value with a default fallback

```pawn
new ConfigSection:sec = cfg_get_section(cfg, "Settings");
new name[64];
if (!cfg_get_value(sec, "name", name, charsmax(name))) {
    copy(name, charsmax(name), "Player"); // key missing -> use default
}
```

### 2. Typed reads (int / float / bool)

```pawn
new rounds      = cfg_get_int(sec, "max_rounds");      // 0 if missing
new Float:speed = cfg_get_float(sec, "speed");         // 0.0 if missing
new bool:hud    = cfg_get_bool(sec, "show_hud");       // false if missing
```

### 3. Multi-value line and string/float arrays

```ini
[Settings]
spawn = 100.0 250.5 32.0
colors = "red" "green" "blue"
```
```pawn
// Index into a multi-value line:
new Float:z = cfg_get_float(sec, "spawn", 2);          // 32.0

// Or pull the whole line as an array:
new Array:aPos = cfg_get_float_array(sec, "spawn");
if (aPos != Invalid_Array) {
    new Float:x = ArrayGetCell(aPos, 0);
    ArrayDestroy(aPos);                                 // caller owns it
}

new Array:aCol = cfg_get_value_array(sec, "colors");
if (aCol != Invalid_Array) {
    new buf[16];
    for (new i = 0; i < ArraySize(aCol); i++) {
        ArrayGetString(aCol, i, buf, charsmax(buf));    // red, green, blue
    }
    ArrayDestroy(aCol);
}
```

### 4. Nested key-value blocks — read by path

A block is opened with `key = {` and closed by `}` on its own line; each line inside
is its own `subkey = value` (or a deeper `subkey = {` block). Read any depth with a
`/`-separated path:

```ini
[HUD]
position = {
    top = {
        x = 10
        y = 20
    }
}
```
```pawn
new val[32];
cfg_get_value_by_path(sec, "position/top/x", val, charsmax(val)); // "10"
// cfg_get_value(sec, "position/top/x", ...) resolves the same path.
```

### 5. Iterate every row of a bracket block

```ini
[Shop]
weapons = {
    "weapon_ak47" "2500"
    "weapon_m4a1" "3100"
}
```
```pawn
new ConfigSection:shop = cfg_get_section(cfg, "Shop");
new rows = cfg_get_array_size(shop, "weapons");
for (new row = 0; row < rows; row++) {
    new Array:line = cfg_get_value_array_by_path(shop, "weapons", 0, row);
    if (line == Invalid_Array) continue;
    new id[32], price[16];
    ArrayGetString(line, 0, id, charsmax(id));
    ArrayGetString(line, 1, price, charsmax(price));
    ArrayDestroy(line);
}
```

### 6. Enumerate top-level keys of a section

```pawn
new Array:keys = cfg_get_top_level_keys(sec);
if (keys != Invalid_Array) {
    new k[MAX_KEY_LEN];
    for (new i = 0; i < ArraySize(keys); i++) {
        ArrayGetString(keys, i, k, charsmax(k));
    }
    ArrayDestroy(keys);
}
```

### 7. Enumerate all loaded sections

```pawn
new total = cfg_get_sections_count(), name[64];
for (new i = 0; i < total; i++) {
    cfg_get_section_name(i, name, charsmax(name));
}
```

### 8. Modify and persist (comment round-trip)

```pawn
cfg_set_int(sec, "max_rounds", 15);
cfg_set_bool(sec, "show_hud", true);
cfg_save_config(cfg, "myplugin.ini");   // comments & spacing preserved
```

### 9. Build a config entirely in code (no file yet)

```pawn
new ConfigFile:cfg = cfg_load_file("generated.ini"); // empty handle if absent
new ConfigSection:sec = cfg_create_section(cfg, "Settings");
cfg_set_value(sec, "name", "Default");
cfg_set_int(sec, "max_rounds", 10);
cfg_save_config(cfg, "generated.ini");
```

### 10. Create a bracket block in code + column hint

```pawn
new ConfigSection:sec = cfg_create_section(cfg, "Shop");
cfg_set_entry_type(sec, "weapons", CFG_ENTRY_BRACKET);
cfg_set_entry_content_type(sec, "weapons", CFG_CONTENT_ENTRIES);
// ... push rows via cfg_set_value paths ...
cfg_set_row_comment(sec, "weapons", 0, "; entity  price"); // in-block header
cfg_save_config(cfg, "shop.ini");
```

### 11. Existence check and deletion

```pawn
if (cfg_has_key(sec, "deprecated_opt")) {
    cfg_delete_key(sec, "deprecated_opt");
    cfg_save_config(cfg, "myplugin.ini");
}
```

### 12. Custom base directory

```pawn
cfg_set_base_dir("addons/amxmodx/configs/mymod");
new ConfigFile:cfg = cfg_load_file("core.ini"); // -> configs/mymod/core.ini
```

## Notes & caveats

- **`cfg_save_config` vs `cfg_write_file`:** `cfg_save_config` persists a whole
  multi-section file; `cfg_write_file` writes a *single* section (others are dropped).
  Always pass the file name explicitly: `cfg_save_config(cfg, "path/file.ini")`.
- **Comment round-trip** preserves only comments that were present in the loaded file.
  Elements created programmatically (e.g. a new block via `cfg_set_value`) carry no
  leading comment unless one already existed on that row — use `cfg_set_row_comment`
  to attach an in-block hint.
- **Limits:** up to 256 sections, 64 values per section, 5 nesting levels, and 32
  loaded config files (guarded — loading more is refused with a log error).

## Build environment

Built and tested with the AMX Mod X 1.9 compiler (`amxxpc 1.9.0.5294`). No external
module dependencies — only `amxmodx` / `amxmisc`.
