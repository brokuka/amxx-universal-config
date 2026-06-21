/**
 * ================================================================================================
 *  Universal Config System
 * ================================================================================================
 *
 *  Description:
 *      A flexible INI-like configuration engine for AMX Mod X: parse, read, modify
 *      and write config files with support for sections, key-value pairs, multi-value
 *      lines and nested block structures. Comments and blank lines are preserved on
 *      a load/save round-trip. Other plugins use it through the registered natives
 *      (see include/universal_config.inc).
 *
 *  Usage (consumer plugin):
 *      new ConfigFile:cfg = cfg_load_file("myplugin.ini");
 *      new ConfigSection:sec = cfg_get_section(cfg, "Settings");
 *      new value[64];
 *      cfg_get_value(sec, "name", value, charsmax(value));
 *
 *  Version: 1.6.1
 *  Author:  kukson
 *  License: free to use and modify, keep the author credit.
 *
 * ================================================================================================
 */

/* ============================================================================================== */
/*                                    [ INCLUDES & CONSTANTS ]                                    */
/* ============================================================================================== */

#include <amxmodx>
#include <amxmisc>

#define PLUGIN "Universal Config System"
#define VERSION "1.6.1"
#define AUTHOR "kukson"

#define MAX_SECTIONS 256
#define MAX_VALUES 64
#define MAX_KEY_LEN 32
#define MAX_VALUE_LEN 512
#define MAX_NESTED_LEVELS 5
#define MAX_PATH_PARTS MAX_NESTED_LEVELS

new g_szConfigDir[64] = ""
#define DEFAULT_CONFIG_FILE "core.ini"

#define DEBUG 0


/* ============================================================================================== */
/*                                  [ ENUMS & DATA STRUCTURES ]                                   */
/* ============================================================================================== */

enum ConfigError {
    CFG_ERR_NONE = 0,
    CFG_ERR_INVALID_SECTION,
    CFG_ERR_INVALID_ARGS,
    CFG_ERR_KEY_NOT_FOUND,
    CFG_ERR_INDEX_OUT_OF_BOUNDS,
    CFG_ERR_TYPE_MISMATCH,
    CFG_ERR_INTERNAL
}

enum ConfigFile {
    CFG_FILE_INVALID = -1
}

enum ConfigSection {
    CFG_SECTION_INVALID = -1
}

enum EntryType {
    CFG_ENTRY_SIMPLE,
    CFG_ENTRY_BRACKET
}

enum ContentType {
    CFG_CONTENT_SIMPLE = 0,
    CFG_CONTENT_STRINGS,
    CFG_CONTENT_ENTRIES
}

enum _:ValueStruct {
    bool:v_bActive,
    v_szKey[MAX_KEY_LEN],
    EntryType:v_eEntryType,
    ContentType:v_eContentType,
    Array:v_aValues,
    v_iValueCount,
    v_iLevel,
    Array:v_aComments      // Leading "; ..." lines captured before this entry (Invalid_Array if none)
}

enum _:SubEntryStruct {
    se_szKey[MAX_KEY_LEN],
    EntryType:se_eEntryType,
    ContentType:se_eContentType,
    Array:se_aValues,
    se_iValueCount,
    se_iLevel,
    Array:se_aComments     // Leading "; ..." lines captured before this row (Invalid_Array if none)
}

/* ============================================================================================== */
/*                                        [ GLOBAL STATE ]                                        */
/* ============================================================================================== */

new Trie:g_tSections
new g_iSectionCount = 0
new g_SectionData[MAX_SECTIONS][MAX_VALUES][ValueStruct]
new g_iValueCount[MAX_SECTIONS]
new g_SectionNames[MAX_SECTIONS][64]
new Array:g_SectionComments[MAX_SECTIONS]      // Leading comment block before each "[section]" (Invalid_Array if none)
new Array:g_aPendingComments = Invalid_Array    // Comment lines read but not yet attached to an element (parse-time)
new g_iFileCount = 0
new ConfigFile:g_iCurrentLoadingFile = CFG_FILE_INVALID
new g_szFileNames[32][64]

// Cache for performance
new g_szLastPath[128]
new ConfigSection:g_lastPathSection = CFG_SECTION_INVALID
new g_iLastPathEntry = -1


/* ============================================================================================== */
/*                           [ PLUGIN LIFECYCLE & NATIVE REGISTRATION ]                           */
/* ============================================================================================== */

public plugin_precache() {
    g_tSections = TrieCreate()
    register_concmd("dump_config", "cmd_dump_config", ADMIN_CVAR, "Dumps all configurations")

    #if DEBUG == 1
        log_amx("Plugin precache initialized")
    #endif
}

public plugin_init() {
	register_plugin(PLUGIN, VERSION, AUTHOR)
	log_amx("[UniversalConfig] Plugin initialized (v%s)", VERSION)
}

public plugin_natives() {
    register_native("cfg_load_file", "native_load_file", 0)
    register_native("cfg_get_section", "native_get_section", 0)
    register_native("cfg_get_value", "native_get_value", 0)
    register_native("cfg_write_file", "native_write_file", 0)
    register_native("cfg_get_section_data", "native_get_section_data", 0)
    register_native("cfg_get_value_by_path", "native_get_value_by_path", 0)
    register_native("cfg_get_top_level_keys", "native_get_top_level_keys", 0)
    register_native("cfg_get_value_array_by_path", "native_get_value_array", 0)

    register_native("cfg_get_int", "native_get_int", 0)
    register_native("cfg_get_float", "native_get_float", 0)
    register_native("cfg_get_bool", "native_get_bool", 0)
    register_native("cfg_get_value_array", "native_get_value_array_simple", 0)
    register_native("cfg_set_value", "native_set_value", 0)
    register_native("cfg_set_int", "native_set_int", 0)
    register_native("cfg_set_float", "native_set_float", 0)
    register_native("cfg_set_bool", "native_set_bool", 0)
    register_native("cfg_delete_key", "native_delete_key", 0)
    register_native("cfg_has_key", "native_has_key", 0)
    register_native("cfg_save_config", "native_save_config", 0)
    register_native("cfg_get_float_array", "native_get_float_array", 0)
    register_native("cfg_get_array_size", "native_get_array_size", 0)
    register_native("cfg_create_section", "native_create_section", 0)
    register_native("cfg_set_entry_type", "native_set_entry_type", 0)
    register_native("cfg_set_entry_content_type", "native_set_entry_content_type", 0)
    register_native("cfg_set_base_dir", "native_set_base_dir", 0)
    register_native("cfg_get_sections_count", "native_get_sections_count", 0)
    register_native("cfg_get_section_name", "native_get_section_name", 0)
    register_native("cfg_set_row_comment", "native_set_row_comment", 0)
}


/* ============================================================================================== */
/*                               [ NATIVES - FILE & VALUE ACCESS ]                                */
/* ============================================================================================== */

public ConfigFile:native_load_file(plugin_id, argc) {
    new szFileName[64], szFullFileName[68]
    if (argc == 0) {
        copy(szFileName, charsmax(szFileName), DEFAULT_CONFIG_FILE)
        #if DEBUG == 1
            log_amx("No filename provided, using default: %s", szFileName)
        #endif
    } else {
        get_string(1, szFileName, charsmax(szFileName))
        #if DEBUG == 1
            log_amx("Received filename from args: %s", szFileName)
        #endif
    }

    cfg_ensure_ini(szFileName, szFullFileName, charsmax(szFullFileName))

    return cfg_load_file(szFullFileName)
}

public ConfigSection:native_get_section(plugin_id, argc) {
    if (argc != 2) {
        #if DEBUG == 1
            log_amx("cfg_get_section: Invalid argument count (%d), expected 2", argc)
        #endif
        return CFG_SECTION_INVALID
    }
    new ConfigFile:config = ConfigFile:get_param(1)
    new szSection[64]
    get_string(2, szSection, charsmax(szSection))

    if (config == CFG_FILE_INVALID || !szSection[0]) {
        #if DEBUG == 1
            log_amx("cfg_get_section: Invalid config handle (%d) or empty section name", _:config)
        #endif
        return CFG_SECTION_INVALID
    }
    return cfg_get_section(config, szSection)
}

public bool:native_get_value(plugin_id, argc) {
    if (argc != 5) {
        #if DEBUG == 1
            log_amx("cfg_get_value: Invalid argument count (%d), expected 5", argc)
        #endif
        return false
    }
    new ConfigSection:section = ConfigSection:get_param(1)
    new szKey[MAX_KEY_LEN], szValue[MAX_VALUE_LEN], iLen = get_param(4), iIndex = get_param(5)
    get_string(2, szKey, charsmax(szKey))

    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount || iLen <= 0 || iIndex < 0) {
        return false
    }

    if (cfg_get_value_by_path(section, szKey, szValue, iLen, iIndex)) {
        set_string(3, szValue, iLen)
        return true
    }
    return false
}

public bool:native_write_file(plugin_id, argc) {
    if (argc < 2 || argc > 3) {
        #if DEBUG == 1
            log_amx("cfg_write_file: Invalid argument count (%d), expected 2 or 3", argc)
        #endif
        return false
    }

    new ConfigFile:cfg = CFG_FILE_INVALID
    new szFileName[64], szSection[64]

    if (argc == 2) {
        get_string(1, szFileName, charsmax(szFileName))
        get_string(2, szSection, charsmax(szSection))
    } else {
        cfg = ConfigFile:get_param(1)
        get_string(2, szFileName, charsmax(szFileName))
        get_string(3, szSection, charsmax(szSection))
    }

    if (!szFileName[0] || !szSection[0]) {
        #if DEBUG == 1
            log_amx("cfg_write_file: Empty filename or section")
        #endif
        return false
    }

    return cfg_write_file(cfg, szFileName, szSection)
}

public Array:native_get_section_data(plugin_id, argc) {
    if (argc != 1) {
        #if DEBUG == 1
            log_amx("cfg_get_section_data: Invalid argument count (%d), expected 1", argc)
        #endif
        return Invalid_Array
    }
    new ConfigSection:section = ConfigSection:get_param(1)
    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount) {
        #if DEBUG == 1
            log_amx("cfg_get_section_data: Invalid section (%d), section count=%d", _:section, g_iSectionCount)
        #endif
        return Invalid_Array
    }
    return cfg_get_section_data(section)
}

public bool:native_get_value_by_path(plugin_id, argc) {
    if (argc < 4 || argc > 6) {
        #if DEBUG == 1
            log_amx("native_get_value_by_path: Invalid argument count (%d), expected 4-6", argc)
        #endif
        return false
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    new szPath[128], szValue[MAX_VALUE_LEN], iLen = get_param(4)
    new iIndex = (argc >= 5) ? get_param(5) : 0
    new iLineIndex = (argc == 6) ? get_param(6) : 0
    get_string(2, szPath, charsmax(szPath))
    get_string(3, szValue, charsmax(szValue))

    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount || iLen <= 0 || iIndex < 0 || iLineIndex < 0) {
        #if DEBUG == 1
            log_amx("native_get_value_by_path: Invalid params - Section=%d, Len=%d, Index=%d, LineIndex=%d", _:section, iLen, iIndex, iLineIndex)
        #endif
        return false
    }

    new iTargetIndex = iIndex
    if (cfg_get_value_by_path(section, szPath, szValue, iLen, iTargetIndex, iLineIndex)) {
        set_string(3, szValue, iLen)
        return true
    }
    #if DEBUG == 1
        log_amx("native_get_value_by_path: Failed to get value for path '%s'", szPath)
    #endif
    return false
}

public Array:native_get_top_level_keys(plugin_id, argc) {
    if (argc != 1) {
        #if DEBUG == 1
            log_amx("cfg_get_top_level_keys: Invalid argument count (%d), expected 1", argc)
        #endif
        return Invalid_Array
    }
    new ConfigSection:section = ConfigSection:get_param(1)
    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount) {
        #if DEBUG == 1
            log_amx("cfg_get_top_level_keys: Invalid section (%d), section count=%d", _:section, g_iSectionCount)
        #endif
        return Invalid_Array
    }
    return cfg_get_top_level_keys(section)
}

public Array:native_get_value_array(plugin_id, argc) {
    if (argc < 2 || argc > 4) {
        #if DEBUG == 1
            log_amx("native_get_value_array: Invalid argument count (%d), expected 2-4", argc)
        #endif
        return Invalid_Array
    }
    new ConfigSection:section = ConfigSection:get_param(1)
    new szPath[128]
    get_string(2, szPath, charsmax(szPath))
    new iIndex = (argc >= 3) ? get_param(3) : 0
    new iLineIndex = (argc == 4) ? get_param(4) : 0

    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount || iIndex < 0 || iLineIndex < 0) {
        #if DEBUG == 1
            log_amx("native_get_value_array: Invalid params - Section=%d, Index=%d, LineIndex=%d", _:section, iIndex, iLineIndex)
        #endif
        return Invalid_Array
    }
    return cfg_get_value_array_by_path(section, szPath, iIndex, iLineIndex)
}


/* ============================================================================================== */
/*                                  [ NATIVES - TYPED GETTERS ]                                   */
/* ============================================================================================== */

public any:native_get_int(plugin_id, argc) {
    if (argc < 2) {
        log_error(AMX_ERR_NATIVE, "cfg_get_int: Invalid argument count (%d), expected at least 2", argc)
        return 0
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (!cfg_valid_section(section)) return 0

    new szKey[MAX_KEY_LEN], szValue[MAX_VALUE_LEN]
    get_string(2, szKey, charsmax(szKey))
    new iIndex = (argc >= 3) ? get_param(3) : 0

    if (!cfg_resolve_value(section, szKey, szValue, charsmax(szValue), iIndex)) return 0
    return str_to_num(szValue)
}

public Float:native_get_float(plugin_id, argc) {
    if (argc < 2) {
        log_error(AMX_ERR_NATIVE, "cfg_get_float: Invalid argument count (%d), expected at least 2", argc)
        return 0.0
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (!cfg_valid_section(section)) return 0.0

    new szKey[MAX_KEY_LEN], szValue[MAX_VALUE_LEN]
    get_string(2, szKey, charsmax(szKey))
    new iIndex = (argc >= 3) ? get_param(3) : 0

    if (!cfg_resolve_value(section, szKey, szValue, charsmax(szValue), iIndex)) return 0.0

    // Trim whitespace; empty after trimming -> 0.0
    trim(szValue)
    if (szValue[0] == EOS) return 0.0

    // str_to_float + epsilon correction for small magnitudes
    return cfg_apply_epsilon(str_to_float(szValue))
}

public Array:native_get_value_array_simple(plugin_id, argc) {
    if (argc < 2) {
        log_error(AMX_ERR_NATIVE, "cfg_get_value_array: Invalid argument count (%d), expected at least 2", argc)
        return Invalid_Array
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    new szKey[MAX_KEY_LEN]
    get_string(2, szKey, charsmax(szKey))
    new iIndex = (argc >= 3) ? get_param(3) : 0

    if (!cfg_valid_section(section)) return Invalid_Array

    new iEntry = cfg_find_entry(section, szKey, iIndex)
    if (iEntry == -1) return Invalid_Array

    new Array:aResult = ArrayCreate(MAX_VALUE_LEN)

    if (g_SectionData[_:section][iEntry][v_eEntryType] == CFG_ENTRY_BRACKET) {
        // Collect all strings from all sub-entries
        if (g_SectionData[_:section][iEntry][v_eContentType] == CFG_CONTENT_ENTRIES) {
            new Array:aSubEntries = g_SectionData[_:section][iEntry][v_aValues]
            new iSubSize = ArraySize(aSubEntries)
            new subEntry[SubEntryStruct]
            for (new i = 0; i < iSubSize; i++) {
                ArrayGetArray(aSubEntries, i, subEntry)
                if (subEntry[se_eEntryType] == CFG_ENTRY_SIMPLE) {
                    new Array:aVals = subEntry[se_aValues]
                    new iValSize = ArraySize(aVals)
                    new szTemp[MAX_VALUE_LEN]
                    for (new j = 0; j < iValSize; j++) {
                        ArrayGetString(aVals, j, szTemp, charsmax(szTemp))
                        trim_quotes(szTemp, szTemp, charsmax(szTemp))
                        ArrayPushString(aResult, szTemp)
                    }
                }
            }
        } else { // CFG_CONTENT_STRINGS
            new Array:aVals = g_SectionData[_:section][iEntry][v_aValues]
            new iValSize = ArraySize(aVals)
            new szTemp[MAX_VALUE_LEN]
            for (new j = 0; j < iValSize; j++) {
                ArrayGetString(aVals, j, szTemp, charsmax(szTemp))
                trim_quotes(szTemp, szTemp, charsmax(szTemp))
                ArrayPushString(aResult, szTemp)
            }
        }
    } else {
        // Simple entry - split by space/quotes as before
        new szValue[MAX_VALUE_LEN]
        ArrayGetString(g_SectionData[_:section][iEntry][v_aValues], 0, szValue, charsmax(szValue))
        cfg_split_values(szValue, aResult)
    }

    if (ArraySize(aResult) == 0) {
        ArrayDestroy(aResult)
        return Invalid_Array
    }

    return aResult
}

public Array:native_get_float_array(plugin_id, argc) {
    if (argc < 2) {
        log_error(AMX_ERR_NATIVE, "cfg_get_float_array: Invalid argument count (%d), expected at least 2", argc)
        return Invalid_Array
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (!cfg_valid_section(section)) return Invalid_Array

    new szKey[MAX_KEY_LEN], szValue[MAX_VALUE_LEN]
    get_string(2, szKey, charsmax(szKey))
    new iIndex = (argc >= 3) ? get_param(3) : 0

    if (!cfg_resolve_value(section, szKey, szValue, charsmax(szValue), iIndex)) return Invalid_Array

    new Array:aStrings = ArrayCreate(MAX_VALUE_LEN)
    cfg_split_values(szValue, aStrings)

    new iSize = ArraySize(aStrings)
    if (iSize == 0) {
        ArrayDestroy(aStrings)
        return Invalid_Array
    }

    new Array:aResult = ArrayCreate(1) // 1 cell for float
    for (new i = 0; i < iSize; i++) {
        new szTemp[MAX_VALUE_LEN]
        ArrayGetString(aStrings, i, szTemp, charsmax(szTemp))
        trim(szTemp)
        ArrayPushCell(aResult, cfg_apply_epsilon(str_to_float(szTemp)))
    }

    ArrayDestroy(aStrings)
    return aResult
}

public bool:native_get_bool(plugin_id, argc) {
    if (argc < 2) {
        log_error(AMX_ERR_NATIVE, "cfg_get_bool: Invalid argument count (%d), expected at least 2", argc)
        return false
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (!cfg_valid_section(section)) return false

    new szKey[MAX_KEY_LEN], szValue[MAX_VALUE_LEN]
    get_string(2, szKey, charsmax(szKey))
    new iIndex = (argc >= 3) ? get_param(3) : 0

    if (!cfg_resolve_value(section, szKey, szValue, charsmax(szValue), iIndex)) return false
    return bool:str_to_num(szValue)
}


/* ============================================================================================== */
/*                               [ NATIVES - SETTERS & STRUCTURE ]                                */
/* ============================================================================================== */

public bool:native_set_value(plugin_id, argc) {
    if (argc < 3) {
        log_error(AMX_ERR_NATIVE, "cfg_set_value: Invalid argument count (%d), expected at least 3", argc)
        return false
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (!cfg_valid_section(section)) return false

    new szKey[MAX_KEY_LEN], szValue[MAX_VALUE_LEN]
    get_string(2, szKey, charsmax(szKey))
    get_string(3, szValue, charsmax(szValue))
    new iIndex = (argc >= 4) ? get_param(4) : 0
    new iLineIndex = (argc >= 5) ? get_param(5) : 0

    return cfg_set_value(section, szKey, szValue, iIndex, iLineIndex)
}

public bool:native_set_int(plugin_id, argc) {
    if (argc < 3) {
        log_error(AMX_ERR_NATIVE, "cfg_set_int: Invalid argument count (%d), expected at least 3", argc)
        return false
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (!cfg_valid_section(section)) return false

    new szKey[MAX_KEY_LEN], szValue[MAX_VALUE_LEN]
    get_string(2, szKey, charsmax(szKey))
    new iValue = get_param(3)
    new iIndex = (argc >= 4) ? get_param(4) : 0

    formatex(szValue, charsmax(szValue), "%d", iValue)
    return cfg_set_value(section, szKey, szValue, iIndex)
}

public bool:native_set_float(plugin_id, argc) {
    if (argc < 3) {
        log_error(AMX_ERR_NATIVE, "cfg_set_float: Invalid argument count (%d), expected at least 3", argc)
        return false
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (!cfg_valid_section(section)) return false

    new szKey[MAX_KEY_LEN], szValue[MAX_VALUE_LEN]
    get_string(2, szKey, charsmax(szKey))
    new Float:fValue = get_param_f(3)
    new iIndex = (argc >= 4) ? get_param(4) : 0

    formatex(szValue, charsmax(szValue), "%f", fValue)
    return cfg_set_value(section, szKey, szValue, iIndex)
}

public bool:native_set_bool(plugin_id, argc) {
    if (argc < 3) {
        log_error(AMX_ERR_NATIVE, "cfg_set_bool: Invalid argument count (%d), expected at least 3", argc)
        return false
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (!cfg_valid_section(section)) return false

    new szKey[MAX_KEY_LEN], szValue[MAX_VALUE_LEN]
    get_string(2, szKey, charsmax(szKey))
    new bool:bValue = bool:get_param(3)
    new iIndex = (argc >= 4) ? get_param(4) : 0

    formatex(szValue, charsmax(szValue), "%d", bValue)
    return cfg_set_value(section, szKey, szValue, iIndex)
}

public bool:native_set_entry_type(plugin_id, argc) {
    if (argc < 2) return false
    new ConfigSection:section = ConfigSection:get_param(1)
    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount) return false

    new szKey[MAX_KEY_LEN]
    get_string(2, szKey, charsmax(szKey))
    new EntryType:type = EntryType:get_param(3)

    new iTargetEntry = -1
    for (new i = 0; i < g_iValueCount[_:section]; i++) {
        if (g_SectionData[_:section][i][v_bActive] && equali(g_SectionData[_:section][i][v_szKey], szKey)) {
            if (iTargetEntry == -1) {
                iTargetEntry = i
                if (g_SectionData[_:section][i][v_eEntryType] != type) {
                    if (type == CFG_ENTRY_BRACKET) {
                        if (g_SectionData[_:section][i][v_aValues] != Invalid_Array) {
                            ArrayDestroy(g_SectionData[_:section][i][v_aValues])
                        }
                        g_SectionData[_:section][i][v_eContentType] = CFG_CONTENT_ENTRIES
                        g_SectionData[_:section][i][v_aValues] = ArrayCreate(SubEntryStruct)
                    } else if (g_SectionData[_:section][i][v_eEntryType] == CFG_ENTRY_BRACKET) {
                        if (g_SectionData[_:section][i][v_aValues] != Invalid_Array) {
                            ArrayDestroy(g_SectionData[_:section][i][v_aValues])
                        }
                        g_SectionData[_:section][i][v_eContentType] = CFG_CONTENT_SIMPLE
                        g_SectionData[_:section][i][v_aValues] = ArrayCreate(MAX_VALUE_LEN)
                    }
                    g_SectionData[_:section][i][v_eEntryType] = type
                }
            } else if (type == CFG_ENTRY_BRACKET) {
                // When setting type to BLOCK, remove any following duplicates of this key
                if (g_SectionData[_:section][i][v_aValues] != Invalid_Array) {
                    ArrayDestroy(g_SectionData[_:section][i][v_aValues])
                }
                g_SectionData[_:section][i][v_bActive] = false
            }
        }
    }

    if (iTargetEntry != -1) {
        // Entry type/content may have changed and duplicates were deactivated;
        // drop the path cache so the next lookup re-resolves the entry.
        cfg_invalidate_cache()
        return true
    }

    // Create new entry if not found
    if (g_iValueCount[_:section] >= MAX_VALUES) return false
    new iNewEntry = g_iValueCount[_:section]++
    g_SectionData[_:section][iNewEntry][v_bActive] = true
    copy(g_SectionData[_:section][iNewEntry][v_szKey], MAX_KEY_LEN, szKey)
    g_SectionData[_:section][iNewEntry][v_eEntryType] = type
    if (type == CFG_ENTRY_BRACKET) {
        g_SectionData[_:section][iNewEntry][v_eContentType] = CFG_CONTENT_ENTRIES
        g_SectionData[_:section][iNewEntry][v_aValues] = ArrayCreate(SubEntryStruct)
    } else {
        g_SectionData[_:section][iNewEntry][v_eContentType] = CFG_CONTENT_SIMPLE
        g_SectionData[_:section][iNewEntry][v_aValues] = ArrayCreate(MAX_VALUE_LEN)
    }
    g_SectionData[_:section][iNewEntry][v_iLevel] = 0
    return true
}

public bool:native_set_entry_content_type(plugin_id, argc) {
    if (argc < 2) return false
    new ConfigSection:section = ConfigSection:get_param(1)
    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount) return false

    new szKey[MAX_KEY_LEN]
    get_string(2, szKey, charsmax(szKey))
    new ContentType:type = ContentType:get_param(3)

    for (new i = 0; i < g_iValueCount[_:section]; i++) {
        if (g_SectionData[_:section][i][v_bActive] && equali(g_SectionData[_:section][i][v_szKey], szKey)) {
            if (g_SectionData[_:section][i][v_eContentType] != type) {
                new bool:bOldEntries = (g_SectionData[_:section][i][v_eContentType] == CFG_CONTENT_ENTRIES)
                new bool:bNewEntries = (type == CFG_CONTENT_ENTRIES)

                if (bOldEntries != bNewEntries) {
                    if (g_SectionData[_:section][i][v_aValues] != Invalid_Array) {
                        ArrayDestroy(g_SectionData[_:section][i][v_aValues])
                    }
                    g_SectionData[_:section][i][v_aValues] = bNewEntries ? ArrayCreate(SubEntryStruct) : ArrayCreate(MAX_VALUE_LEN)
                }
                g_SectionData[_:section][i][v_eContentType] = type
            }
            return true
        }
    }

    // Create new entry if not found
    if (g_iValueCount[_:section] >= MAX_VALUES) return false
    new iNewEntry2 = g_iValueCount[_:section]++
    g_SectionData[_:section][iNewEntry2][v_bActive] = true
    copy(g_SectionData[_:section][iNewEntry2][v_szKey], MAX_KEY_LEN, szKey)
    g_SectionData[_:section][iNewEntry2][v_eEntryType] = CFG_ENTRY_SIMPLE // Default, user should set BRACKET separately
    g_SectionData[_:section][iNewEntry2][v_eContentType] = type
    g_SectionData[_:section][iNewEntry2][v_aValues] = ArrayCreate(MAX_VALUE_LEN)
    g_SectionData[_:section][iNewEntry2][v_iLevel] = 0
    return true
}


/* ============================================================================================== */
/*                              [ NATIVES - QUERY, SECTION & SAVE ]                               */
/* ============================================================================================== */

public bool:native_delete_key(plugin_id, argc) {
    if (argc < 2) {
        log_error(AMX_ERR_NATIVE, "cfg_delete_key: Invalid argument count (%d), expected at least 2", argc)
        return false
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (!cfg_valid_section(section)) return false

    new szKey[MAX_KEY_LEN]
    get_string(2, szKey, charsmax(szKey))

    return cfg_delete_key(section, szKey)
}

public bool:native_has_key(plugin_id, argc) {
    if (argc < 2) {
        log_error(AMX_ERR_NATIVE, "cfg_has_key: Invalid argument count (%d), expected at least 2", argc)
        return false
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (!cfg_valid_section(section)) return false

    new szKey[MAX_KEY_LEN]
    get_string(2, szKey, charsmax(szKey))

    return cfg_has_key(section, szKey)
}

public any:native_get_array_size(plugin_id, argc) {
    if (argc < 2) {
        log_error(AMX_ERR_NATIVE, "cfg_get_array_size: Invalid argument count (%d), expected at least 2", argc)
        return 0
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (!cfg_valid_section(section)) return 0

    new szKey[MAX_KEY_LEN]
    get_string(2, szKey, charsmax(szKey))

    return cfg_get_array_size(section, szKey)
}

public ConfigSection:native_create_section(plugin_id, argc) {
    if (argc < 1 || argc > 2) {
        log_error(AMX_ERR_NATIVE, "cfg_create_section: Invalid argument count (%d), expected 1 or 2", argc)
        return CFG_SECTION_INVALID
    }

    new ConfigFile:cfg = CFG_FILE_INVALID
    new szName[64]
    if (argc == 2) {
        cfg = ConfigFile:get_param(1)
        get_string(2, szName, charsmax(szName))
    } else {
        get_string(1, szName, charsmax(szName))
    }

    new ConfigSection:section = cfg_get_section(cfg, szName)
    if (section != CFG_SECTION_INVALID) return section

    new ConfigFile:oldFile = g_iCurrentLoadingFile
    g_iCurrentLoadingFile = cfg
    section = cfg_register_section(szName)
    g_iCurrentLoadingFile = oldFile

    return section
}

public bool:native_save_config(plugin_id, argc) {
    if (argc < 1 || argc > 2) {
        log_error(AMX_ERR_NATIVE, "cfg_save_config: Invalid argument count (%d), expected 1 or 2", argc)
        return false
    }

    new ConfigFile:cfg = ConfigFile:get_param(1)
    new szFileName[64]
    if (argc == 2) {
        get_string(2, szFileName, charsmax(szFileName))
    } else {
        if (_:cfg >= 0 && _:cfg < g_iFileCount) {
            copy(szFileName, charsmax(szFileName), g_szFileNames[_:cfg])
        }
    }

    if (cfg == CFG_FILE_INVALID || !szFileName[0]) return false

    new szFullFileName[64]
    cfg_ensure_ini(szFileName, szFullFileName, charsmax(szFullFileName))

    new szPath[128], szDir[128]
    get_configsdir(szDir, charsmax(szDir))
    formatex(szPath, charsmax(szPath), "%s/%s/%s", szDir, g_szConfigDir, szFullFileName)

    // Extract the file's directory path so it can be created if missing
    copy(szDir, charsmax(szDir), szPath)
    new iPos = strlen(szDir) - 1
    while (iPos >= 0 && szDir[iPos] != 47 && szDir[iPos] != 92) iPos--
    if (iPos >= 0) szDir[iPos] = 0

    if (!dir_exists(szDir)) {
        cfg_create_directory(szDir)
    }

    new File = fopen(szPath, "wt")
    if (!File) return false

    new bool:bFirst = true
    for (new ConfigSection:sec = ConfigSection:0; _:sec < g_iSectionCount; sec++) {
        if (!g_SectionNames[_:sec][0]) continue

        // Check whether this section belongs to this file
        new szTrieKey[128]
        formatex(szTrieKey, charsmax(szTrieKey), "%d_%s", _:cfg, g_SectionNames[_:sec])
        new any:checkSec
        if (!TrieGetCell(g_tSections, szTrieKey, checkSec) || ConfigSection:checkSec != sec) {
            continue
        }

        // Inter-section spacing normally comes from the next section's captured
        // leading blank line(s). Sections created at runtime have none, so insert
        // a single separator blank to keep them readable.
        if (!bFirst && g_SectionComments[_:sec] == Invalid_Array) fprintf(File, "^n")
        bFirst = false

        cfg_write_comments(File, g_SectionComments[_:sec], "")
        fprintf(File, "[%s]^n", g_SectionNames[_:sec])
        for (new i = 0; i < g_iValueCount[_:sec]; i++) {
            if (g_SectionData[_:sec][i][v_bActive] && g_SectionData[_:sec][i][v_iLevel] == 0) {
                // Captured leading trivia provides the blank for file-loaded entries;
                // entries created at runtime have none, so insert a default separator
                // blank (also yields the blank line after the "[section]" header).
                if (g_SectionData[_:sec][i][v_aComments] == Invalid_Array) fprintf(File, "^n")
                cfg_write_entry(File, sec, i, 0)
            }
        }
    }

    fclose(File)
    return true
}


/* ============================================================================================== */
/*                        [ NATIVES - BASE DIR, SECTION INFO & COMMENTS ]                         */
/* ============================================================================================== */

public native_set_base_dir(plugin_id, argc) {
    if (argc != 1) return

    get_string(1, g_szConfigDir, charsmax(g_szConfigDir))
    trim(g_szConfigDir)

    #if DEBUG == 1
        log_amx("cfg_set_base_dir: Base config dir set to '%s'", g_szConfigDir)
    #endif
}

public native_get_sections_count(plugin_id, num_params) {
    return g_iSectionCount
}

public native_get_section_name(plugin_id, num_params) {
    new index = get_param(1)
    if (index < 0 || index >= g_iSectionCount) return 0

    set_string(2, g_SectionNames[index], get_param(3))
    return 1
}

// Sets the leading "; ..." comment of a bracket-block row (e.g. the column hint
// above the first data row). Lets a module attach the same in-block hint that a
// file round-trip would preserve, so blocks it creates programmatically match.
// comment is a single line (include the leading ';'); empty clears it.
public bool:native_set_row_comment(plugin_id, argc) {
    if (argc != 4) {
        log_error(AMX_ERR_NATIVE, "cfg_set_row_comment: Invalid argument count (%d), expected 4", argc)
        return false
    }

    new ConfigSection:section = ConfigSection:get_param(1)
    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount) return false

    new szKey[MAX_KEY_LEN]
    get_string(2, szKey, charsmax(szKey))
    new iRow = get_param(3)
    new szComment[256]
    get_string(4, szComment, charsmax(szComment))

    // Find the top-level bracket entry for this key.
    new iEntry = cfg_find_entry(section, szKey)
    if (iEntry == -1 || g_SectionData[_:section][iEntry][v_eEntryType] != CFG_ENTRY_BRACKET) return false
    if (g_SectionData[_:section][iEntry][v_eContentType] != CFG_CONTENT_ENTRIES) return false

    new Array:aSubEntries = g_SectionData[_:section][iEntry][v_aValues]
    if (aSubEntries == Invalid_Array || iRow < 0 || iRow >= ArraySize(aSubEntries)) return false

    new subEntry[SubEntryStruct]
    ArrayGetArray(aSubEntries, iRow, subEntry)

    if (subEntry[se_aComments] != Invalid_Array) {
        ArrayDestroy(subEntry[se_aComments])
        subEntry[se_aComments] = Invalid_Array
    }
    if (szComment[0]) {
        subEntry[se_aComments] = ArrayCreate(256)
        ArrayPushString(subEntry[se_aComments], szComment)
    }

    ArraySetArray(aSubEntries, iRow, subEntry)
    return true
}


/* ============================================================================================== */
/*                               [ CORE - FILE LOADING & PARSING ]                                */
/* ============================================================================================== */

public ConfigFile:cfg_load_file(const szFileName[]) {
    // Guard the file-handle table: writing past g_szFileNames would corrupt
    // memory and make later cfg_save_config silently fail (empty file name).
    if (g_iFileCount >= sizeof(g_szFileNames)) {
        log_amx("ERROR: Max config files limit (%d) reached, cannot load '%s'", sizeof(g_szFileNames), szFileName);
        return CFG_FILE_INVALID;
    }

    new szPath[128];
    get_configsdir(szPath, charsmax(szPath));
    formatex(szPath, charsmax(szPath), "%s/%s/%s", szPath, g_szConfigDir, szFileName);

    #if DEBUG == 1
        log_amx("cfg_load_file: Trying to load file '%s' at path '%s'", szFileName, szPath);
        if (!file_exists(szPath)) {
            log_amx("cfg_load_file: ERROR - File '%s' does not exist!", szPath);
        } else {
            log_amx("cfg_load_file: File '%s' exists, starting load.", szPath);
        }
    #endif

    g_iCurrentLoadingFile = ConfigFile:g_iFileCount;
    copy(g_szFileNames[_:g_iFileCount], charsmax(g_szFileNames[]), szFileName);
    cfg_load_file_internal(szPath); // Try to load if present; ignore errors (for new files)

    #if DEBUG == 1
        log_amx("cfg_load_file: Assigned handle %d for file '%s'.", _:g_iFileCount, szFileName);
    #endif

    return ConfigFile:g_iFileCount++;
}

stock bool:cfg_load_file_internal(const szFilePath[]) {
    new File = fopen(szFilePath, "rt");
    if (!File) {
        #if DEBUG == 1
            log_amx("cfg_load_file_internal: ERROR - Failed to open file '%s'.", szFilePath);
        #endif
        return false;
    }

    #if DEBUG == 1
        log_amx("cfg_load_file_internal: File '%s' opened successfully, starting parse.", szFilePath);
    #endif

    new szLine[256], szSection[64];
    new ConfigSection:currentSection = CFG_SECTION_INVALID;
    new iCurrentLevel = 0;
    new bool:bInBlock[MAX_NESTED_LEVELS];
    new iBlockEntry[MAX_NESTED_LEVELS];
    new iLineCount = 0;
    for (new i = 0; i < MAX_NESTED_LEVELS; i++) bInBlock[i] = false, iBlockEntry[i] = -1;

    while (!feof(File)) {
        fgets(File, szLine, charsmax(szLine));
        trim(szLine);
        iLineCount++;
        #if DEBUG == 1
            if (szLine[0]) {
                log_amx("cfg_load_file_internal: Reading line %d: '%s'", iLineCount, szLine);
            } else {
                log_amx("cfg_load_file_internal: Skipped empty line %d.", iLineCount);
            }
        #endif

        // Accumulate comment AND blank lines; they attach as the leading trivia
        // of the next element (section/entry/row) so cfg_save_config round-trips
        // the exact comments and spacing. Blank lines are stored as "".
        if (szLine[0] == ';' || !szLine[0]) {
            if (g_aPendingComments == Invalid_Array) g_aPendingComments = ArrayCreate(256);
            ArrayPushString(g_aPendingComments, szLine);
            continue;
        }

        if (szLine[0] == '[') {
            cfg_parse_section(szLine, szSection, charsmax(szSection));
            currentSection = cfg_register_section(szSection);
            #if DEBUG == 1
                log_amx("cfg_load_file_internal: Registered section '%s' (ID: %d).", szSection, _:currentSection);
            #endif
            iCurrentLevel = 0;
            for (new i = 0; i < MAX_NESTED_LEVELS; i++) bInBlock[i] = false;
            continue;
        }
        if (currentSection != CFG_SECTION_INVALID) {
            #if DEBUG == 1
                log_amx("cfg_load_file_internal: Processing line in section '%s'.", g_SectionNames[_:currentSection]);
            #endif
            cfg_process_line(currentSection, szLine, iCurrentLevel, bInBlock, iBlockEntry);
        } else {
            #if DEBUG == 1
                log_amx("cfg_load_file_internal: WARNING - Line outside any section ignored: '%s'.", szLine);
            #endif
        }
    }

    fclose(File);

    // Drop any trailing comments not followed by an element (nothing to attach to).
    if (g_aPendingComments != Invalid_Array) {
        ArrayDestroy(g_aPendingComments);
        g_aPendingComments = Invalid_Array;
    }

    #if DEBUG == 1
        log_amx("cfg_load_file_internal: Finished processing file '%s', lines processed: %d.", szFilePath, iLineCount);
        log_amx("cfg_load_file_internal: Total sections loaded: %d.", g_iSectionCount);
        for (new ConfigSection:sec = ConfigSection:0; _:sec < g_iSectionCount; sec++) {
            log_amx("cfg_load_file_internal: Section %d: '%s', keys: %d.", _:sec, g_SectionNames[_:sec], g_iValueCount[_:sec]);
        }
    #endif
    return true;
}

stock cfg_process_line(ConfigSection:section, const szLine[], &iCurrentLevel, bool:bInBlock[], iBlockEntry[]) {
    new szTrimmedLine[256], iEntry
    copy(szTrimmedLine, charsmax(szTrimmedLine), szLine)
    trim(szTrimmedLine)

    #if DEBUG == 1
        log_amx("Processing line: '%s' (Level: %d)", szTrimmedLine, iCurrentLevel)
    #endif

    if (szTrimmedLine[0] == '}') {
        if (iCurrentLevel > 0) {
            iCurrentLevel--
            bInBlock[iCurrentLevel] = false
            iBlockEntry[iCurrentLevel] = -1
            #if DEBUG == 1
                log_amx("Closed block at level %d", iCurrentLevel)
            #endif
        }
        return
    }

    if (contain(szTrimmedLine, "=") != -1 && szTrimmedLine[strlen(szTrimmedLine) - 1] == '{') {
        new szKey[32], szValue[128]
        cfg_get_key_value(szTrimmedLine, szKey, charsmax(szKey), szValue, charsmax(szValue))
        if (iCurrentLevel < MAX_NESTED_LEVELS) {
            new iNewEntry = -1
            if (iCurrentLevel > 0) {
                // Creating a nested block inside another block
                new Array:aSubEntries

                if (iCurrentLevel == 1) {
                    // Level 1: parent is in g_SectionData
                    new iParentEntry = iBlockEntry[0]
                    aSubEntries = g_SectionData[_:section][iParentEntry][v_aValues]
                    if (aSubEntries == Invalid_Array) {
                        aSubEntries = ArrayCreate(SubEntryStruct)
                        g_SectionData[_:section][iParentEntry][v_aValues] = aSubEntries
                        g_SectionData[_:section][iParentEntry][v_eContentType] = CFG_CONTENT_ENTRIES
                    }
                } else {
                    // Level 2+: parent is nested, use helper function
                    aSubEntries = cfg_get_nested_array(section, iBlockEntry, iCurrentLevel - 1)
                    if (aSubEntries == Invalid_Array) {
                        aSubEntries = ArrayCreate(SubEntryStruct)
                        cfg_set_nested_array(section, iBlockEntry, iCurrentLevel - 1, aSubEntries)
                    }
                }

                new subEntry[SubEntryStruct]
                copy(subEntry[se_szKey], MAX_KEY_LEN, szKey)
                subEntry[se_eEntryType] = CFG_ENTRY_BRACKET
                subEntry[se_eContentType] = CFG_CONTENT_ENTRIES
                subEntry[se_aValues] = ArrayCreate(SubEntryStruct)
                subEntry[se_iLevel] = iCurrentLevel
                subEntry[se_aComments] = cfg_take_pending_comments()
                ArrayPushArray(aSubEntries, subEntry)
                iNewEntry = ArraySize(aSubEntries) - 1

                // Update parent count
                if (iCurrentLevel == 1) {
                    g_SectionData[_:section][iBlockEntry[0]][v_iValueCount] = ArraySize(aSubEntries)
                } else {
                    cfg_update_nested_count(section, iBlockEntry, iCurrentLevel - 1, ArraySize(aSubEntries))
                }

                #if DEBUG == 1
                    log_amx("Created nested block subEntry '%s' at level %d, subEntry index %d, total subEntries=%d", szKey, iCurrentLevel, iNewEntry, ArraySize(aSubEntries))
                #endif
            } else {
                // Level 0: creating top-level block
                if (g_iValueCount[_:section] >= MAX_VALUES) {
                    #if DEBUG == 1
                        log_amx("ERROR: Max values limit (%d) reached for section %d", MAX_VALUES, _:section)
                    #endif
                    return
                }
                iNewEntry = g_iValueCount[_:section]++;
                g_SectionData[_:section][iNewEntry][v_bActive] = true
                copy(g_SectionData[_:section][iNewEntry][v_szKey], MAX_KEY_LEN, szKey)
                g_SectionData[_:section][iNewEntry][v_eEntryType] = CFG_ENTRY_BRACKET
                g_SectionData[_:section][iNewEntry][v_eContentType] = CFG_CONTENT_ENTRIES
                g_SectionData[_:section][iNewEntry][v_aValues] = ArrayCreate(SubEntryStruct)
                g_SectionData[_:section][iNewEntry][v_iLevel] = iCurrentLevel
                g_SectionData[_:section][iNewEntry][v_aComments] = cfg_take_pending_comments()
            }
            iBlockEntry[iCurrentLevel] = iNewEntry
            bInBlock[iCurrentLevel] = true
            iCurrentLevel++
            #if DEBUG == 1
                log_amx("Opened block '%s' at level %d, index %d", szKey, iCurrentLevel - 1, iNewEntry)
            #endif
        }
        return
    }

    // Handle lines like "text" "flag" "values" "actions"
    if (iCurrentLevel > 0 && bInBlock[iCurrentLevel - 1] && szTrimmedLine[0] == '"') {
        new Array:aValues = ArrayCreate(MAX_VALUE_LEN)
        new iValueCount = cfg_parse_quoted_line_full(szTrimmedLine, aValues)
        if (iValueCount > 0) {
            iEntry = iBlockEntry[iCurrentLevel - 1]
            new Array:aSubEntries
            if (iCurrentLevel == 1) {
                aSubEntries = g_SectionData[_:section][iEntry][v_aValues]
            } else {
                aSubEntries = cfg_get_nested_array(section, iBlockEntry, iCurrentLevel - 1)
            }
            if (aSubEntries == Invalid_Array) {
                aSubEntries = ArrayCreate(SubEntryStruct)
                if (iCurrentLevel == 1) {
                    g_SectionData[_:section][iEntry][v_aValues] = aSubEntries
                    g_SectionData[_:section][iEntry][v_eContentType] = CFG_CONTENT_ENTRIES
                } else {
                    cfg_set_nested_array(section, iBlockEntry, iCurrentLevel - 1, aSubEntries)
                }
            }
            new subEntry[SubEntryStruct]
            subEntry[se_eEntryType] = CFG_ENTRY_SIMPLE
            subEntry[se_eContentType] = CFG_CONTENT_STRINGS
            subEntry[se_aValues] = aValues
            subEntry[se_iValueCount] = iValueCount
            subEntry[se_iLevel] = iCurrentLevel
            subEntry[se_aComments] = cfg_take_pending_comments()
            ArrayPushArray(aSubEntries, subEntry)
            if (iCurrentLevel == 1) {
                g_SectionData[_:section][iEntry][v_iValueCount] = ArraySize(aSubEntries)
            } else {
                cfg_update_nested_count(section, iBlockEntry, iCurrentLevel - 1, ArraySize(aSubEntries))
            }
            #if DEBUG == 1
                new szTemp[MAX_VALUE_LEN]
                log_amx("Added sub-entry with %d values at level %d:", iValueCount, iCurrentLevel)
                for (new i = 0; i < iValueCount; i++) {
                    ArrayGetString(aValues, i, szTemp, charsmax(szTemp))
                    log_amx("  Value[%d]: '%s'", i, szTemp)
                }
            #endif
            return
        }
        ArrayDestroy(aValues) // Cleanup if parsing failed
    }

    // Fallback for standard key = value
    new szKey[32], szValue[128]
    cfg_get_key_value(szTrimmedLine, szKey, charsmax(szKey), szValue, charsmax(szValue))
    new Array:aSubEntries
    if (iCurrentLevel > 0 && bInBlock[iCurrentLevel - 1]) {
        iEntry = iBlockEntry[iCurrentLevel - 1]
        if (iCurrentLevel == 1) {
            aSubEntries = g_SectionData[_:section][iEntry][v_aValues]
        } else {
            aSubEntries = cfg_get_nested_array(section, iBlockEntry, iCurrentLevel - 1)
        }
        if (aSubEntries == Invalid_Array) {
            aSubEntries = ArrayCreate(SubEntryStruct)
            if (iCurrentLevel == 1) {
                g_SectionData[_:section][iEntry][v_aValues] = aSubEntries
                g_SectionData[_:section][iEntry][v_eContentType] = CFG_CONTENT_ENTRIES
            } else {
                cfg_set_nested_array(section, iBlockEntry, iCurrentLevel - 1, aSubEntries)
            }
        }
        new subEntry[SubEntryStruct]
        copy(subEntry[se_szKey], MAX_KEY_LEN, szKey)
        subEntry[se_eEntryType] = CFG_ENTRY_SIMPLE
        subEntry[se_eContentType] = CFG_CONTENT_STRINGS
        subEntry[se_aValues] = ArrayCreate(MAX_VALUE_LEN)
        cfg_split_values(szValue, subEntry[se_aValues])
        subEntry[se_iValueCount] = ArraySize(subEntry[se_aValues])
        subEntry[se_iLevel] = iCurrentLevel
        subEntry[se_aComments] = cfg_take_pending_comments()
        ArrayPushArray(aSubEntries, subEntry)
        if (iCurrentLevel == 1) {
            g_SectionData[_:section][iEntry][v_iValueCount] = ArraySize(aSubEntries)
        } else {
            cfg_update_nested_count(section, iBlockEntry, iCurrentLevel - 1, ArraySize(aSubEntries))
        }
    } else {
        if (g_iValueCount[_:section] >= MAX_VALUES) {
            #if DEBUG == 1
                log_amx("ERROR: Max values limit (%d) reached for section %d", MAX_VALUES, _:section)
            #endif
            return
        }
        iEntry = g_iValueCount[_:section]++;
        g_SectionData[_:section][iEntry][v_bActive] = true
        copy(g_SectionData[_:section][iEntry][v_szKey], MAX_KEY_LEN, szKey)
        g_SectionData[_:section][iEntry][v_eEntryType] = CFG_ENTRY_SIMPLE
        g_SectionData[_:section][iEntry][v_eContentType] = CFG_CONTENT_STRINGS
        g_SectionData[_:section][iEntry][v_aValues] = ArrayCreate(MAX_VALUE_LEN)
        cfg_split_values(szValue, g_SectionData[_:section][iEntry][v_aValues])
        g_SectionData[_:section][iEntry][v_iValueCount] = ArraySize(g_SectionData[_:section][iEntry][v_aValues])
        g_SectionData[_:section][iEntry][v_iLevel] = iCurrentLevel
        g_SectionData[_:section][iEntry][v_aComments] = cfg_take_pending_comments()
    }
}

stock cfg_parse_quoted_line_full(const szLine[], Array:aValues) {
    new iPos = 0, iValueCount = 0, szTemp[MAX_VALUE_LEN]
    while (szLine[iPos]) {
        if (szLine[iPos] == '"') {
            iPos++
            iPos += copyc(szTemp, charsmax(szTemp), szLine[iPos], '"')
            trim(szTemp)
            ArrayPushString(aValues, szTemp) // Push even an empty string
            iValueCount++
            iPos++
            while (szLine[iPos] == ' ') iPos++
        } else {
            break
        }
    }
    return iValueCount
}

stock ConfigSection:cfg_register_section(const szName[]) {
    if (g_iSectionCount >= MAX_SECTIONS) {
        log_amx("ERROR: Max sections limit (%d) reached, cannot register section '%s'", MAX_SECTIONS, szName)
        return CFG_SECTION_INVALID
    }
    new ConfigSection:section = ConfigSection:g_iSectionCount
    new szTrieKey[128]
    formatex(szTrieKey, charsmax(szTrieKey), "%d_%s", _:g_iCurrentLoadingFile, szName)
    TrieSetCell(g_tSections, szTrieKey, _:section)
    copy(g_SectionNames[_:section], charsmax(g_SectionNames[]), szName)
    g_SectionComments[_:section] = cfg_take_pending_comments()  // header/comments before this "[section]"
    g_iSectionCount++
    return section
}


/* ============================================================================================== */
/*                                   [ CORE - READING VALUES ]                                    */
/* ============================================================================================== */

public ConfigSection:cfg_get_section(ConfigFile:config, const szName[]) {
    new szTrieKey[128]
    formatex(szTrieKey, charsmax(szTrieKey), "%d_%s", _:config, szName)
    new any:section
    if (TrieGetCell(g_tSections, szTrieKey, section)) {
        return ConfigSection:section
    }
    return CFG_SECTION_INVALID
}

public bool:cfg_get_value(ConfigSection:section, const szKey[], szValue[], iLen, iIndex) {
    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount) {
        #if DEBUG == 1
            log_amx("cfg_get_value: Invalid section %d (max %d)", _:section, g_iSectionCount)
        #endif
        return false
    }

    for (new i = 0; i < g_iValueCount[_:section]; i++) {
        if (!g_SectionData[_:section][i][v_bActive] || !equali(g_SectionData[_:section][i][v_szKey], szKey)) continue

        if (g_SectionData[_:section][i][v_eEntryType] != CFG_ENTRY_SIMPLE) {
            #if DEBUG == 1
                log_amx("cfg_get_value: Key '%s' is not a simple entry (type=%d)", szKey, g_SectionData[_:section][i][v_eEntryType])
            #endif
            return false
        }

        new Array:aValues = g_SectionData[_:section][i][v_aValues]
        if (iIndex >= g_SectionData[_:section][i][v_iValueCount]) {
            #if DEBUG == 1
                log_amx("cfg_get_value: Index %d out of bounds for '%s' (count=%d)", iIndex, szKey, g_SectionData[_:section][i][v_iValueCount])
            #endif
            return false
        }

        new szTemp[MAX_VALUE_LEN]
        ArrayGetString(aValues, iIndex, szTemp, charsmax(szTemp))
        trim_quotes(szTemp, szValue, iLen)
        return true
    }
    return false
}

stock bool:cfg_get_value_by_path(ConfigSection:section, const szPath[], szValue[], iLen, iIndex = 0, iLineIndex = 0) {
    if (!cfg_valid_section(section)) return false

    new szPathParts[MAX_PATH_PARTS][MAX_KEY_LEN]
    new iPartCount = cfg_split_path(szPath, szPathParts, MAX_PATH_PARTS)
    if (iPartCount <= 0) return false

    new iMatchCount = cfg_count_entries(section, szPathParts[0])
    if (iMatchCount == 0) return false

    new iTargetLine = iLineIndex
    new iTargetString = iIndex
    new iOccurrence = iLineIndex

    if (iMatchCount > 1 && iLineIndex == 0) {
        iOccurrence = iIndex
        iTargetLine = 0
    } else if (iMatchCount == 1) {
        iOccurrence = 0
    }

    new iEntry = -1, iFound = 0

    // Check cache
    if (g_lastPathSection == section && equali(g_szLastPath, szPathParts[0])) {
        iEntry = g_iLastPathEntry
    } else {
        for (new i = 0; i < g_iValueCount[_:section]; i++) {
            if (g_SectionData[_:section][i][v_bActive] && equali(g_SectionData[_:section][i][v_szKey], szPathParts[0])) {
                if (iFound == iOccurrence) {
                    iEntry = i
                    // Update cache
                    copy(g_szLastPath, charsmax(g_szLastPath), szPathParts[0])
                    g_lastPathSection = section
                    g_iLastPathEntry = iEntry
                    break
                }
                iFound++
            }
        }
    }
    if (iEntry == -1) return false

    new Array:aValues = g_SectionData[_:section][iEntry][v_aValues]
    new subEntry[SubEntryStruct], iSize

    if (iPartCount > 1) {
        if (!cfg_search_in_sub_entries(aValues, szPathParts, iPartCount, 1, subEntry, iTargetLine)) return false
        if (subEntry[se_eEntryType] == CFG_ENTRY_BRACKET) {
            aValues = subEntry[se_aValues]
            iSize = ArraySize(aValues)
            if (iSize == 0 || iTargetLine >= iSize) return false
            ArrayGetArray(aValues, iTargetLine, subEntry)
            if (subEntry[se_eEntryType] == CFG_ENTRY_SIMPLE) {
                aValues = subEntry[se_aValues]
                if (ArraySize(aValues) == 0 || iTargetString >= ArraySize(aValues)) return false
                ArrayGetString(aValues, iTargetString, szValue, iLen)
                trim_quotes(szValue, szValue, iLen)
                return true
            }
            return false
        } else if (subEntry[se_eEntryType] == CFG_ENTRY_SIMPLE) {
            aValues = subEntry[se_aValues]
            iSize = ArraySize(aValues)
            if (iSize == 0 || iTargetString >= iSize) return false
            ArrayGetString(aValues, iTargetString, szValue, iLen)
            trim_quotes(szValue, szValue, iLen)
            return true
        }
    } else {
        if (g_SectionData[_:section][iEntry][v_eEntryType] == CFG_ENTRY_BRACKET) {
            iSize = ArraySize(aValues)
            if (iSize == 0 || iTargetLine >= iSize) return false
            ArrayGetArray(aValues, iTargetLine, subEntry)
            if (subEntry[se_eEntryType] == CFG_ENTRY_SIMPLE) {
                aValues = subEntry[se_aValues]
                if (ArraySize(aValues) == 0 || iTargetString >= ArraySize(aValues)) return false
                ArrayGetString(aValues, iTargetString, szValue, iLen)
                trim_quotes(szValue, szValue, iLen)
                return true
            }
            return false
        } else if (g_SectionData[_:section][iEntry][v_eEntryType] == CFG_ENTRY_SIMPLE) {
            if (iTargetString >= g_SectionData[_:section][iEntry][v_iValueCount]) return false
            ArrayGetString(aValues, iTargetString, szValue, iLen)
            trim_quotes(szValue, szValue, iLen)
            return true
        }
    }
    return false
}

stock Array:cfg_get_value_array_by_path(ConfigSection:section, const szPath[], iIndex = 0, iLineIndex = 0) {
    new szPathParts[MAX_PATH_PARTS][MAX_KEY_LEN]
    new iPartCount = cfg_split_path(szPath, szPathParts, MAX_PATH_PARTS)
    if (iPartCount <= 0) return Invalid_Array

    new iMatchCount = cfg_count_entries(section, szPathParts[0])
    if (iMatchCount == 0) return Invalid_Array

    new iTargetLine = iLineIndex
    new iOccurrence = iLineIndex

    if (iMatchCount > 1 && iLineIndex == 0) {
        iOccurrence = iIndex
        iTargetLine = 0
    } else if (iMatchCount == 1) {
        iOccurrence = 0
    }

    new iEntry = cfg_find_entry(section, szPathParts[0], iOccurrence)
    if (iEntry == -1) return Invalid_Array

    new Array:aValues = g_SectionData[_:section][iEntry][v_aValues]
    new subEntry[SubEntryStruct], iSize

    if (iPartCount > 1) {
        if (!cfg_search_in_sub_entries(aValues, szPathParts, iPartCount, 1, subEntry, iTargetLine)) return Invalid_Array
        if (subEntry[se_eEntryType] == CFG_ENTRY_BRACKET) {
            aValues = subEntry[se_aValues]
            iSize = ArraySize(aValues)
            if (iSize == 0 || iTargetLine >= iSize) return Invalid_Array
            ArrayGetArray(aValues, iTargetLine, subEntry)
            if (subEntry[se_eEntryType] == CFG_ENTRY_SIMPLE) aValues = subEntry[se_aValues]
            else return Invalid_Array
        } else if (subEntry[se_eEntryType] == CFG_ENTRY_SIMPLE) {
            aValues = subEntry[se_aValues]
        } else return Invalid_Array
    } else {
        if (g_SectionData[_:section][iEntry][v_eEntryType] == CFG_ENTRY_BRACKET) {
            iSize = ArraySize(aValues)
            if (iSize == 0 || iTargetLine >= iSize) return Invalid_Array
            ArrayGetArray(aValues, iTargetLine, subEntry)
            if (subEntry[se_eEntryType] == CFG_ENTRY_SIMPLE) aValues = subEntry[se_aValues]
            else return Invalid_Array
        }
    }

    iSize = ArraySize(aValues)
    new Array:aResult = ArrayCreate(MAX_VALUE_LEN)
    for (new i = 0; i < iSize; i++) {
        new szValue[MAX_VALUE_LEN]
        ArrayGetString(aValues, i, szValue, charsmax(szValue))
        ArrayPushString(aResult, szValue)
    }
    return aResult
}

stock Array:cfg_get_section_data(ConfigSection:section) {
    new Array:aKeys = ArrayCreate(MAX_KEY_LEN)
    new Array:aValues = ArrayCreate(1)
    new Array:aSectionData = ArrayCreate(2)

    for (new i = 0; i < g_iValueCount[_:section]; i++) {
        if (!g_SectionData[_:section][i][v_bActive] || g_SectionData[_:section][i][v_iLevel] > 0) continue

        new szKey[MAX_KEY_LEN]
        copy(szKey, charsmax(szKey), g_SectionData[_:section][i][v_szKey])
        ArrayPushString(aKeys, szKey)

        new Array:aEntryValues
        if (g_SectionData[_:section][i][v_eEntryType] == CFG_ENTRY_SIMPLE) {
            aEntryValues = ArrayClone(g_SectionData[_:section][i][v_aValues])
        } else {
            aEntryValues = ArrayCreate(MAX_VALUE_LEN)
            ArrayPushString(aEntryValues, "{block}")
        }

        ArrayPushCell(aValues, aEntryValues)
        new pair[2]
        pair[0] = ArraySize(aKeys) - 1
        pair[1] = ArraySize(aValues) - 1
        ArrayPushArray(aSectionData, pair)
    }

    if (ArraySize(aSectionData) == 0) {
        ArrayDestroy(aKeys)
        ArrayDestroy(aValues)
        ArrayDestroy(aSectionData)
        return Invalid_Array
    }

    new Array:aResult = ArrayCreate(1, 3)
    ArrayPushCell(aResult, aKeys)
    ArrayPushCell(aResult, aValues)
    ArrayPushCell(aResult, aSectionData)
    return aResult
}

stock Array:cfg_get_top_level_keys(ConfigSection:section) {
    new Array:aKeys = ArrayCreate(MAX_KEY_LEN)
    for (new i = 0; i < g_iValueCount[_:section]; i++) {
        if (!g_SectionData[_:section][i][v_bActive] || g_SectionData[_:section][i][v_iLevel] > 0) continue
        new szKey[MAX_KEY_LEN]
        copy(szKey, charsmax(szKey), g_SectionData[_:section][i][v_szKey])
        ArrayPushString(aKeys, szKey)
    }
    if (ArraySize(aKeys) == 0) {
        ArrayDestroy(aKeys)
        return Invalid_Array
    }
    return aKeys
}

stock cfg_get_array_size(ConfigSection:section, const szKey[]) {
    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount) {
        #if DEBUG == 1
            log_amx("cfg_get_array_size: Invalid section %d (max %d)", _:section, g_iSectionCount)
        #endif
        return 0
    }

    new szPathParts[MAX_PATH_PARTS][MAX_KEY_LEN]
    new iPartCount = cfg_split_path(szKey, szPathParts, MAX_PATH_PARTS)
    if (iPartCount <= 0) {
        #if DEBUG == 1
            log_amx("cfg_get_array_size: Invalid path '%s'", szKey)
        #endif
        return 0
    }

    new iEntry = -1, iTopCount = 0

    // Check cache
    if (g_lastPathSection == section && equali(g_szLastPath, szPathParts[0])) {
        iEntry = g_iLastPathEntry
        // We still need iTopCount for the logic below if iPartCount == 1
        if (iPartCount == 1) {
            for (new i = 0; i < g_iValueCount[_:section]; i++) {
                if (g_SectionData[_:section][i][v_bActive] && equali(g_SectionData[_:section][i][v_szKey], szPathParts[0])) iTopCount++
            }
        }
    } else {
        for (new i = 0; i < g_iValueCount[_:section]; i++) {
            if (g_SectionData[_:section][i][v_bActive] && equali(g_SectionData[_:section][i][v_szKey], szPathParts[0])) {
                if (iEntry == -1) {
                    iEntry = i
                    // Update cache
                    copy(g_szLastPath, charsmax(g_szLastPath), szPathParts[0])
                    g_lastPathSection = section
                    g_iLastPathEntry = iEntry
                }
                iTopCount++
            }
        }
    }

    if (iEntry == -1) {
        #if DEBUG == 1
            log_amx("cfg_get_array_size: Key '%s' not found", szPathParts[0])
        #endif
        return 0
    }

    if (iPartCount == 1) {
        if (iTopCount > 1) return iTopCount
        return g_SectionData[_:section][iEntry][v_iValueCount]
    }

    new Array:aValues = g_SectionData[_:section][iEntry][v_aValues]
    new subEntry[SubEntryStruct], iTarget = 0
    if (!cfg_search_in_sub_entries(aValues, szPathParts, iPartCount, 1, subEntry, iTarget)) {
        #if DEBUG == 1
            log_amx("cfg_get_array_size: Sub-entry not found for path '%s'", szKey)
        #endif
        return 0
    }

    return subEntry[se_iValueCount]
}

stock bool:cfg_has_key(ConfigSection:section, const szKey[]) {
    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount) {
        #if DEBUG == 1
            log_amx("cfg_has_key: Invalid section %d (max %d)", _:section, g_iSectionCount)
        #endif
        return false
    }

    for (new i = 0; i < g_iValueCount[_:section]; i++) {
        if (!g_SectionData[_:section][i][v_bActive] || !equali(g_SectionData[_:section][i][v_szKey], szKey)) continue
        return true
    }
    return false
}


/* ============================================================================================== */
/*                                  [ CORE - WRITING & SAVING ]                                   */
/* ============================================================================================== */

public bool:cfg_write_file(ConfigFile:cfg, const szFileName[], const szSection[]) {
    new szFullFileName[64]
    cfg_ensure_ini(szFileName, szFullFileName, charsmax(szFullFileName))

    new szPath[128], szDir[128]
    get_configsdir(szDir, charsmax(szDir))
    formatex(szPath, charsmax(szPath), "%s/%s/%s", szDir, g_szConfigDir, szFullFileName)

    // Extract the file's directory path so it can be created if missing
    copy(szDir, charsmax(szDir), szPath)
    new iPos = strlen(szDir) - 1
    while (iPos >= 0 && szDir[iPos] != 47 && szDir[iPos] != 92) iPos--
    if (iPos >= 0) szDir[iPos] = 0

    new ConfigSection:section = CFG_SECTION_INVALID

    if (cfg != CFG_FILE_INVALID) {
        section = cfg_get_section(cfg, szSection)
    } else {
        // Fallback: search all files if no handle was provided
        for (new ConfigFile:i = ConfigFile:0; _:i < g_iFileCount; i++) {
            section = cfg_get_section(i, szSection)
            if (section != CFG_SECTION_INVALID) break
        }
    }

    if (section == CFG_SECTION_INVALID) return false

    if (!dir_exists(szDir)) {
        cfg_create_directory(szDir)
    }

    new File = fopen(szPath, "wt")
    if (!File) return false

    cfg_write_comments(File, g_SectionComments[_:section], "")
    fprintf(File, "[%s]^n", szSection)
    for (new i = 0; i < g_iValueCount[_:section]; i++) {
        if (g_SectionData[_:section][i][v_bActive] && g_SectionData[_:section][i][v_iLevel] == 0) {
            cfg_write_entry(File, section, i, 0)
        }
    }
    fprintf(File, "^n")

    fclose(File)
    return true
}

stock cfg_write_entry(File, ConfigSection:section, iEntry, iIndentLevel) {
    new entry[ValueStruct]
    cfg_copy_entry(entry, g_SectionData[_:section][iEntry])
    new szIndent[32]
    cfg_make_indent(szIndent, charsmax(szIndent), iIndentLevel)

    cfg_write_comments(File, entry[v_aComments], szIndent)

    if (entry[v_eEntryType] == CFG_ENTRY_SIMPLE) {
        new szFullValue[MAX_VALUE_LEN + 32]
        cfg_join_plain(entry[v_aValues], entry[v_iValueCount], szFullValue, charsmax(szFullValue))
        fprintf(File, "%s%s = %s^n", szIndent, entry[v_szKey], szFullValue)
    } else if (entry[v_eEntryType] == CFG_ENTRY_BRACKET) {
        fprintf(File, "%s%s = {^n", szIndent, entry[v_szKey])
        if (entry[v_eContentType] == ContentType:CFG_CONTENT_STRINGS) {
            new szLine[1024]
            cfg_join_quoted(entry[v_aValues], entry[v_iValueCount], szLine, charsmax(szLine))
            fprintf(File, "%s^t%s^n", szIndent, szLine)
        } else if (entry[v_eContentType] == CFG_CONTENT_ENTRIES) {
            new Array:aSubEntries = entry[v_aValues]
            new subEntry[SubEntryStruct]
            for (new j = 0; j < entry[v_iValueCount]; j++) {
                ArrayGetArray(aSubEntries, j, subEntry)
                cfg_write_sub_entry(File, subEntry, iIndentLevel + 1)
            }
        }
        fprintf(File, "%s}^n", szIndent)
    }
}

stock cfg_write_sub_entry(File, subEntry[SubEntryStruct], iIndentLevel) {
    new szIndent[32]
    cfg_make_indent(szIndent, charsmax(szIndent), iIndentLevel)

    cfg_write_comments(File, subEntry[se_aComments], szIndent)

    if (subEntry[se_eEntryType] == CFG_ENTRY_SIMPLE) {
        new szFullValue[1024]
        if (subEntry[se_szKey][0] == 0) {
            // Keyless row -> bare quoted values
            cfg_join_quoted(subEntry[se_aValues], subEntry[se_iValueCount], szFullValue, charsmax(szFullValue))
            fprintf(File, "%s%s^n", szIndent, szFullValue)
        } else {
            cfg_join_plain(subEntry[se_aValues], subEntry[se_iValueCount], szFullValue, charsmax(szFullValue))
            fprintf(File, "%s%s = %s^n", szIndent, subEntry[se_szKey], szFullValue)
        }
    } else if (subEntry[se_eEntryType] == CFG_ENTRY_BRACKET) {
        fprintf(File, "%s%s = {^n", szIndent, subEntry[se_szKey])
        if (subEntry[se_eContentType] == ContentType:CFG_CONTENT_STRINGS) {
            new szLine[1024]
            cfg_join_quoted(subEntry[se_aValues], subEntry[se_iValueCount], szLine, charsmax(szLine))
            fprintf(File, "%s%s^n", szIndent, szLine)
        } else if (subEntry[se_eContentType] == CFG_CONTENT_ENTRIES) {
            new Array:aNestedEntries = subEntry[se_aValues]
            new nestedEntry[SubEntryStruct]
            for (new j = 0; j < subEntry[se_iValueCount]; j++) {
                ArrayGetArray(aNestedEntries, j, nestedEntry)
                cfg_write_sub_entry(File, nestedEntry, iIndentLevel + 1)
            }
        }
        fprintf(File, "%s}^n", szIndent)
    }
}


/* ============================================================================================== */
/*                                   [ CORE - VALUE MUTATION ]                                    */
/* ============================================================================================== */

stock bool:cfg_set_value(ConfigSection:section, const szKey[], const szValue[], iIndex = 0, iLineIndex = 0) {
    if (!cfg_valid_section(section)) return false

    new szParts[MAX_NESTED_LEVELS][MAX_KEY_LEN]
    new iCount = cfg_split_path(szKey, szParts, MAX_NESTED_LEVELS)
    if (iCount <= 0) return false

    if (iCount == 1) {
        new iEntry = -1, iFound = 0
        for (new i = 0; i < g_iValueCount[_:section]; i++) {
            if (!g_SectionData[_:section][i][v_bActive] || !equali(g_SectionData[_:section][i][v_szKey], szParts[0])) continue

            // A block entry is the single target for this key
            if (g_SectionData[_:section][i][v_eEntryType] == CFG_ENTRY_BRACKET) {
                iEntry = i
                break
            }

            if (iFound == iIndex) {
                iEntry = i
                break
            }
            iFound++
        }

        if (iEntry == -1) {
            // Index not found: create a new entry for it
            if (g_iValueCount[_:section] >= MAX_VALUES) return false
            iEntry = g_iValueCount[_:section]++
            g_SectionData[_:section][iEntry][v_bActive] = true
            copy(g_SectionData[_:section][iEntry][v_szKey], MAX_KEY_LEN, szParts[0])
            g_SectionData[_:section][iEntry][v_eEntryType] = CFG_ENTRY_SIMPLE
            g_SectionData[_:section][iEntry][v_eContentType] = CFG_CONTENT_STRINGS
            g_SectionData[_:section][iEntry][v_aValues] = ArrayCreate(MAX_VALUE_LEN)
            g_SectionData[_:section][iEntry][v_iLevel] = 0
        }

        if (g_SectionData[_:section][iEntry][v_eEntryType] == CFG_ENTRY_BRACKET) {
            if (g_SectionData[_:section][iEntry][v_eContentType] == CFG_CONTENT_ENTRIES) {
                new Array:aSubEntries = g_SectionData[_:section][iEntry][v_aValues]
                if (iLineIndex >= ArraySize(aSubEntries)) {
                    for (new i = ArraySize(aSubEntries); i <= iLineIndex; i++) {
                        new subEntry[SubEntryStruct]
                        subEntry[se_eEntryType] = CFG_ENTRY_SIMPLE
                        subEntry[se_eContentType] = CFG_CONTENT_STRINGS
                        subEntry[se_aValues] = ArrayCreate(MAX_VALUE_LEN)
                        subEntry[se_iLevel] = 1
                        ArrayPushArray(aSubEntries, subEntry)
                    }
                }
                new subEntry[SubEntryStruct]
                ArrayGetArray(aSubEntries, iLineIndex, subEntry)
                new Array:aSubValues = subEntry[se_aValues]
                if (iIndex >= ArraySize(aSubValues)) {
                    for (new i = ArraySize(aSubValues); i <= iIndex; i++) ArrayPushString(aSubValues, "")
                }
                ArraySetString(aSubValues, iIndex, szValue)
                subEntry[se_iValueCount] = ArraySize(aSubValues)
                ArraySetArray(aSubEntries, iLineIndex, subEntry)
                g_SectionData[_:section][iEntry][v_iValueCount] = ArraySize(aSubEntries)
                return true
            } else if (g_SectionData[_:section][iEntry][v_eContentType] != CFG_CONTENT_STRINGS) {
                return false
            }
        } else if (g_SectionData[_:section][iEntry][v_eEntryType] != CFG_ENTRY_SIMPLE) {
            return false
        }

        new Array:aValues = g_SectionData[_:section][iEntry][v_aValues]
        if (iIndex >= ArraySize(aValues)) {
            for (new i = ArraySize(aValues); i <= iIndex; i++) ArrayPushString(aValues, "")
        }
        ArraySetString(aValues, iIndex, szValue)
        g_SectionData[_:section][iEntry][v_iValueCount] = ArraySize(aValues)
        return true
    }

    // Nested path
    new iEntry = -1, iFound = 0
    for (new i = 0; i < g_iValueCount[_:section]; i++) {
        if (!g_SectionData[_:section][i][v_bActive] || !equali(g_SectionData[_:section][i][v_szKey], szParts[0])) continue
        if (iFound == iIndex) {
            iEntry = i
            break
        }
        iFound++
    }

    if (iEntry == -1) {
        if (g_iValueCount[_:section] >= MAX_VALUES) return false
        iEntry = g_iValueCount[_:section]++
        g_SectionData[_:section][iEntry][v_bActive] = true
        copy(g_SectionData[_:section][iEntry][v_szKey], MAX_KEY_LEN, szParts[0])
        g_SectionData[_:section][iEntry][v_eEntryType] = CFG_ENTRY_BRACKET
        g_SectionData[_:section][iEntry][v_eContentType] = CFG_CONTENT_ENTRIES
        g_SectionData[_:section][iEntry][v_aValues] = ArrayCreate(SubEntryStruct)
        g_SectionData[_:section][iEntry][v_iLevel] = 0
    }

    if (g_SectionData[_:section][iEntry][v_eEntryType] != CFG_ENTRY_BRACKET) return false

    new Array:aEntries = g_SectionData[_:section][iEntry][v_aValues]
    for (new iLevel = 1; iLevel < iCount; iLevel++) {
        new bool:bLast = (iLevel == iCount - 1)
        new iSub = -1
        new sub[SubEntryStruct], iSize = ArraySize(aEntries)

        new iFoundCount = 0
        for (new i = 0; i < iSize; i++) {
            ArrayGetArray(aEntries, i, sub)
            if (equali(sub[se_szKey], szParts[iLevel])) {
                if (iFoundCount == iIndex) {
                    iSub = i
                    break
                }
                iFoundCount++
            }
        }

        if (iSub == -1) {
            copy(sub[se_szKey], MAX_KEY_LEN, szParts[iLevel])
            sub[se_iLevel] = iLevel
            if (bLast) {
                sub[se_eEntryType] = CFG_ENTRY_SIMPLE
                sub[se_eContentType] = CFG_CONTENT_STRINGS
                sub[se_aValues] = ArrayCreate(MAX_VALUE_LEN)
                sub[se_iValueCount] = 0
            } else {
                sub[se_eEntryType] = CFG_ENTRY_BRACKET
                sub[se_eContentType] = CFG_CONTENT_ENTRIES
                sub[se_aValues] = ArrayCreate(SubEntryStruct)
                sub[se_iValueCount] = 0
            }
            ArrayPushArray(aEntries, sub)
            iSub = ArraySize(aEntries) - 1
            if (iLevel == 1) g_SectionData[_:section][iEntry][v_iValueCount] = ArraySize(aEntries)
        } else {
            ArrayGetArray(aEntries, iSub, sub)
        }

        if (bLast) {
            if (sub[se_eEntryType] != CFG_ENTRY_SIMPLE) return false
            new Array:aVals = sub[se_aValues]
            if (iIndex >= ArraySize(aVals)) {
                for (new i = ArraySize(aVals); i <= iIndex; i++) ArrayPushString(aVals, "")
            }
            ArraySetString(aVals, iIndex, szValue)
            sub[se_iValueCount] = ArraySize(aVals)
            ArraySetArray(aEntries, iSub, sub)
            return true
        } else {
            if (sub[se_eEntryType] != CFG_ENTRY_BRACKET) return false
            aEntries = sub[se_aValues]
        }
    }
    return true
}

stock bool:cfg_delete_key(ConfigSection:section, const szKey[]) {
    if (section == CFG_SECTION_INVALID || _:section >= g_iSectionCount) {
        #if DEBUG == 1
            log_amx("cfg_delete_key: Invalid section %d (max %d)", _:section, g_iSectionCount)
        #endif
        return false
    }

    new bool:bDeleted = false
    for (new i = 0; i < g_iValueCount[_:section]; i++) {
        if (!g_SectionData[_:section][i][v_bActive] || !equali(g_SectionData[_:section][i][v_szKey], szKey)) continue

        if (g_SectionData[_:section][i][v_aValues] != Invalid_Array) {
            ArrayDestroy(g_SectionData[_:section][i][v_aValues])
        }
        g_SectionData[_:section][i][v_bActive] = false
        bDeleted = true
    }
    // A deleted entry may be the cached one -> drop the cache to avoid pointing
    // at an inactive slot on the next path lookup.
    if (bDeleted) cfg_invalidate_cache()
    return bDeleted
}


/* ============================================================================================== */
/*                               [ INTERNAL - HELPERS & UTILITIES ]                               */
/* ============================================================================================== */

// Validity check shared by ~20 natives/stocks.
stock bool:cfg_valid_section(ConfigSection:section) {
    return section != CFG_SECTION_INVALID && _:section >= 0 && _:section < g_iSectionCount
}

// Returns the array index of the iOccurrence-th active top-level entry whose
// key == szKey, or -1. Centralizes the lookup duplicated across many call sites.
stock cfg_find_entry(ConfigSection:section, const szKey[], iOccurrence = 0) {
    new iFound = 0
    for (new i = 0; i < g_iValueCount[_:section]; i++) {
        if (g_SectionData[_:section][i][v_bActive] && equali(g_SectionData[_:section][i][v_szKey], szKey)) {
            if (iFound == iOccurrence) return i
            iFound++
        }
    }
    return -1
}

// Counts active top-level entries whose key == szKey (duplicate-key occurrences).
stock cfg_count_entries(ConfigSection:section, const szKey[]) {
    new n = 0
    for (new i = 0; i < g_iValueCount[_:section]; i++) {
        if (g_SectionData[_:section][i][v_bActive] && equali(g_SectionData[_:section][i][v_szKey], szKey)) n++
    }
    return n
}

// Resolves a flat ("key") or nested ("a/b/c") key to its raw string value.
stock bool:cfg_resolve_value(ConfigSection:section, const szKey[], szValue[], iLen, iIndex) {
    if (containi(szKey, "/") != -1)
        return cfg_get_value_by_path(section, szKey, szValue, iLen, iIndex, 0)
    return cfg_get_value(section, szKey, szValue, iLen, iIndex)
}

// Epsilon nudge for small magnitudes (avoids 0.01 -> 0.009999 style drift).
stock Float:cfg_apply_epsilon(Float:f) {
    if (f > 0.0 && f < 1.0) return f + 0.0000001
    if (f < 0.0 && f > -1.0) return f - 0.0000001
    return f
}

// Appends ".ini" to szIn if absent, writing the result into szOut.
stock cfg_ensure_ini(const szIn[], szOut[], iOutLen) {
    if (contain(szIn, ".ini") == -1) formatex(szOut, iOutLen, "%s.ini", szIn)
    else copy(szOut, iOutLen, szIn)
}

// Invalidates the single-entry path cache. Must be called after structural
// mutations (delete / entry-type change) that can move or deactivate the
// cached entry, otherwise the cache may point at a v_bActive == false slot.
stock cfg_invalidate_cache() {
    g_lastPathSection = CFG_SECTION_INVALID
    g_szLastPath[0] = 0
    g_iLastPathEntry = -1
}

// Joins raw values with single spaces: a b c
stock cfg_join_plain(Array:aValues, iCount, szOut[], iOutLen) {
    szOut[0] = 0
    new szValue[MAX_VALUE_LEN]
    for (new j = 0; j < iCount; j++) {
        ArrayGetString(aValues, j, szValue, charsmax(szValue))
        if (j > 0) strcat(szOut, " ", iOutLen)
        strcat(szOut, szValue, iOutLen)
    }
}

// Joins values each wrapped in quotes: "a" "b" "c"
stock cfg_join_quoted(Array:aValues, iCount, szOut[], iOutLen) {
    szOut[0] = 0
    new szValue[MAX_VALUE_LEN], szQ[MAX_VALUE_LEN + 2]
    for (new j = 0; j < iCount; j++) {
        ArrayGetString(aValues, j, szValue, charsmax(szValue))
        if (j > 0) strcat(szOut, " ", iOutLen)
        formatex(szQ, charsmax(szQ), "^"%s^"", szValue)
        strcat(szOut, szQ, iOutLen)
    }
}

// Walks iBlockEntry[] down to iLevel and loads the leaf subEntry into `out`.
// Returns the Array that directly contains the leaf (so callers can
// ArraySetArray() back after mutating `out`); iLeafIdx receives the leaf index.
stock Array:cfg_nested_leaf(ConfigSection:section, iBlockEntry[], iLevel, out[SubEntryStruct], &iLeafIdx) {
    new Array:aCur = g_SectionData[_:section][iBlockEntry[0]][v_aValues]
    new tmp[SubEntryStruct]
    for (new i = 1; i < iLevel; i++) {
        ArrayGetArray(aCur, iBlockEntry[i], tmp)
        aCur = tmp[se_aValues]
    }
    iLeafIdx = iBlockEntry[iLevel]
    ArrayGetArray(aCur, iLeafIdx, out)
    return aCur
}

stock Array:cfg_get_nested_array(ConfigSection:section, iBlockEntry[], iLevel) {
    new subEntry[SubEntryStruct], iLeafIdx
    cfg_nested_leaf(section, iBlockEntry, iLevel, subEntry, iLeafIdx)
    return subEntry[se_aValues]
}

stock cfg_set_nested_array(ConfigSection:section, iBlockEntry[], iLevel, Array:aSubEntries) {
    new subEntry[SubEntryStruct], iLeafIdx
    new Array:aCurrent = cfg_nested_leaf(section, iBlockEntry, iLevel, subEntry, iLeafIdx)
    subEntry[se_aValues] = aSubEntries
    subEntry[se_eContentType] = CFG_CONTENT_ENTRIES
    ArraySetArray(aCurrent, iLeafIdx, subEntry)
}

stock cfg_update_nested_count(ConfigSection:section, iBlockEntry[], iLevel, iCount) {
    new subEntry[SubEntryStruct], iLeafIdx
    new Array:aCurrent = cfg_nested_leaf(section, iBlockEntry, iLevel, subEntry, iLeafIdx)
    subEntry[se_iValueCount] = iCount
    ArraySetArray(aCurrent, iLeafIdx, subEntry)
}

// Helper: split a space-separated string into an array
stock Array:cfg_split_to_array(const szValue[]) {
    new Array:aResult = ArrayCreate(MAX_VALUE_LEN)
    new szTemp[MAX_VALUE_LEN], iPos = 0
    while (szValue[iPos]) {
        iPos += copyc(szTemp, charsmax(szTemp), szValue[iPos], ' ')
        trim(szTemp)
        if (szTemp[0]) {
            ArrayPushString(aResult, szTemp)
            #if DEBUG == 1
                log_amx("cfg_split_to_array: Added element '%s'", szTemp)
            #endif
        }
        while (szValue[iPos] == ' ') iPos++
    }
    if (ArraySize(aResult) == 0) {
        ArrayDestroy(aResult)
        return Invalid_Array;
    }
    return aResult;
}

// Helper: strip surrounding quotes from a string
stock trim_quotes(const szSource[], szDest[], iDestLen) {
    new iLen = strlen(szSource);
    if (iLen >= 2 && szSource[0] == '"' && szSource[iLen - 1] == '"') {
        new iCopyLen = min(iLen - 2, iDestLen - 1);
        if (iCopyLen > 0) {
            copy(szDest, iCopyLen + 1, szSource[1]);
        }
        szDest[iCopyLen] = EOS;
    } else {
        copy(szDest, iDestLen, szSource);
    }
}

stock cfg_split_values(const szValue[], Array:aValues) {
    new szTemp[MAX_VALUE_LEN], iPos = 0, iLen = strlen(szValue);

    while (iPos < iLen) {
        // Skip spaces and tabs
        while (iPos < iLen && (szValue[iPos] <= ' ')) iPos++;
        if (iPos >= iLen) break;

        new iStart, iCount;
        if (szValue[iPos] == '"') {
            iPos++;
            iStart = iPos;
            while (iPos < iLen && szValue[iPos] != '"') iPos++;
            iCount = iPos - iStart;
            if (iPos < iLen) iPos++;
        } else {
            iStart = iPos;
            while (iPos < iLen && szValue[iPos] > ' ') iPos++;
            iCount = iPos - iStart;
        }

        if (iCount > 0) {
            new iCopyLen = min(iCount, charsmax(szTemp));
            for (new j = 0; j < iCopyLen; j++) {
                szTemp[j] = szValue[iStart + j];
            }
            szTemp[iCopyLen] = EOS;
            ArrayPushString(aValues, szTemp);
        }
    }
}

stock cfg_get_key_value(const szLine[], szKey[], iKeyLen, szValue[], iValueLen) {
    new iPos = contain(szLine, "=")
    if (iPos == -1) {
        szKey[0] = 0
        copy(szValue, iValueLen, szLine)
        // Strip comments
        new iCommentPos = contain(szValue, ";")
        if (iCommentPos != -1) {
            szValue[iCommentPos] = 0
        }
        trim(szValue)
        return
    }
    copyc(szKey, iKeyLen, szLine, '=')
    trim(szKey)
    copy(szValue, iValueLen, szLine[iPos + 1])
    // Strip comments from value
    new iCommentPos = contain(szValue, ";")
    if (iCommentPos != -1) {
        szValue[iCommentPos] = 0
    }
    trim(szValue)
}

stock cfg_parse_section(const szLine[], szOutput[], iLen) {
    new szTemp[64]
    copyc(szTemp, charsmax(szTemp), szLine[1], ']')
    copy(szOutput, iLen, szTemp)
}

stock cfg_create_directory(const szPath[]) {
    new szDir[128], iPos = 0
    if (szPath[1] == ':') iPos = 3 // Skip C:/ on Windows

    while (szPath[iPos]) {
        if (szPath[iPos] == 47 || szPath[iPos] == 92) {
            copy(szDir, iPos, szPath)
            if (!dir_exists(szDir)) mkdir(szDir)
        }
        iPos++
    }
    if (!dir_exists(szPath)) mkdir(szPath)
}

stock cfg_make_indent(szIndent[], iMaxLen, iLevel) {
    if (iLevel >= iMaxLen) iLevel = iMaxLen - 1

    for (new i = 0; i < iLevel; i++) {
        szIndent[i] = '^t'
    }
    szIndent[iLevel] = 0
}

// Returns the accumulated leading-comment block and clears the parse-time buffer.
// Ownership of the Array transfers to the caller (stored on the next element).
stock Array:cfg_take_pending_comments() {
    new Array:a = g_aPendingComments
    g_aPendingComments = Invalid_Array
    return a
}

// Re-emits stored leading trivia. Comment lines get szIndent; blank lines ("")
// are emitted as a bare newline (no indent => no trailing whitespace). No-op if none.
stock cfg_write_comments(File, Array:aComments, const szIndent[]) {
    if (aComments == Invalid_Array) return
    new szC[256], n = ArraySize(aComments)
    for (new i = 0; i < n; i++) {
        ArrayGetString(aComments, i, szC, charsmax(szC))
        if (szC[0]) fprintf(File, "%s%s^n", szIndent, szC)
        else        fprintf(File, "^n")
    }
}

stock cfg_copy_entry(dest[ValueStruct], const src[ValueStruct]) {
    dest[v_bActive] = src[v_bActive]
    copy(dest[v_szKey], MAX_KEY_LEN, src[v_szKey])
    dest[v_eEntryType] = src[v_eEntryType]
    dest[v_eContentType] = src[v_eContentType]
    dest[v_aValues] = src[v_aValues]
    dest[v_iValueCount] = src[v_iValueCount]
    dest[v_iLevel] = src[v_iLevel]
    dest[v_aComments] = src[v_aComments]
}

stock bool:cfg_search_in_sub_entries(Array:aEntries, szPathParts[][MAX_KEY_LEN], iPartCount, iPartIndex, subEntry[SubEntryStruct], &iTargetIndex) {
    if (aEntries == Invalid_Array || iPartIndex >= iPartCount) return false

    new iSize = ArraySize(aEntries)
    new iMatchCount = 0
    for (new i = 0; i < iSize; i++) {
        ArrayGetArray(aEntries, i, subEntry)
        if (equali(subEntry[se_szKey], szPathParts[iPartIndex])) iMatchCount++
    }
    if (iMatchCount == 0) return false

    new iFound = 0
    for (new i = 0; i < iSize; i++) {
        ArrayGetArray(aEntries, i, subEntry)
        if (equali(subEntry[se_szKey], szPathParts[iPartIndex])) {
            if (iMatchCount > 1) {
                if (iFound == iTargetIndex) {
                    iTargetIndex = 0
                    if (iPartIndex == iPartCount - 1) return true
                    return cfg_search_in_sub_entries(subEntry[se_aValues], szPathParts, iPartCount, iPartIndex + 1, subEntry, iTargetIndex)
                }
                iFound++
            } else {
                if (iPartIndex == iPartCount - 1) return true
                return cfg_search_in_sub_entries(subEntry[se_aValues], szPathParts, iPartCount, iPartIndex + 1, subEntry, iTargetIndex)
            }
        }
    }
    return false
}

stock cfg_split_path(const szPath[], szPathParts[][MAX_KEY_LEN], iMaxParts) {
    new iPartCount = 0, iPos = 0, iLastPos = 0, szTemp[MAX_KEY_LEN]
    new iLen = strlen(szPath)
    while (iPos <= iLen) {
        if (szPath[iPos] == '/' || szPath[iPos] == 0) {
            if (iPartCount >= iMaxParts) break
            copyc(szTemp, charsmax(szTemp), szPath[iLastPos], '/')
            trim(szTemp)
            if (szTemp[0]) {
                copy(szPathParts[iPartCount], MAX_KEY_LEN, szTemp)
                iPartCount++
            }
            iLastPos = iPos + 1
        }
        iPos++
    }
    return iPartCount
}


/* ============================================================================================== */
/*                                    [ DEBUG - CONFIG DUMP ]                                     */
/* ============================================================================================== */

public cmd_dump_config(id, level, cid) {
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED
    console_print(id, "Current Configuration Dump:")
    for (new ConfigSection:sec = ConfigSection:0; _:sec < g_iSectionCount; sec++) {
        console_print(id, "Section %d: %s", _:sec, g_SectionNames[_:sec])
        for (new i = 0; i < g_iValueCount[_:sec]; i++) {
            if (g_SectionData[_:sec][i][v_bActive]) cfg_dump_entry(sec, i, 0)
        }
    }
    return PLUGIN_HANDLED
}

stock cfg_dump_entry(ConfigSection:section, iEntry, iIndentLevel) {
    new entry[ValueStruct]
    cfg_copy_entry(entry, g_SectionData[_:section][iEntry])
    new szIndent[32]
    cfg_make_indent(szIndent, charsmax(szIndent), iIndentLevel)

    if (entry[v_eEntryType] == CFG_ENTRY_SIMPLE) {
        new szFullValue[256]
        cfg_join_plain(entry[v_aValues], entry[v_iValueCount], szFullValue, charsmax(szFullValue))
        console_print(0, "%s%s = %s", szIndent, entry[v_szKey], szFullValue)
    } else if (entry[v_eEntryType] == CFG_ENTRY_BRACKET) {
        console_print(0, "%s%s = {", szIndent, entry[v_szKey])
        if (entry[v_eContentType] == CFG_CONTENT_STRINGS) {
            new szFullValue[256]
            cfg_join_plain(entry[v_aValues], entry[v_iValueCount], szFullValue, charsmax(szFullValue))
            console_print(0, "%s    %s", szIndent, szFullValue)
        } else if (entry[v_eContentType] == CFG_CONTENT_ENTRIES) {
            new subEntry[SubEntryStruct]
            new Array:aSubEntries = entry[v_aValues]
            for (new j = 0; j < entry[v_iValueCount]; j++) {
                ArrayGetArray(aSubEntries, j, subEntry)
                cfg_dump_sub_entry(subEntry, iIndentLevel + 1)
            }
        }
        console_print(0, "%s}", szIndent)
    }
}

stock cfg_dump_sub_entry(subEntry[SubEntryStruct], iIndentLevel) {
    new szIndent[32]
    cfg_make_indent(szIndent, charsmax(szIndent), iIndentLevel)

    if (subEntry[se_eEntryType] == CFG_ENTRY_SIMPLE) {
        new szFullValue[256]
        cfg_join_plain(subEntry[se_aValues], subEntry[se_iValueCount], szFullValue, charsmax(szFullValue))
        console_print(0, "%s%s = %s", szIndent, subEntry[se_szKey], szFullValue)
    } else if (subEntry[se_eEntryType] == CFG_ENTRY_BRACKET) {
        console_print(0, "%s%s = {", szIndent, subEntry[se_szKey])
        if (subEntry[se_eContentType] == CFG_CONTENT_STRINGS) {
            new szFullValue[256]
            cfg_join_plain(subEntry[se_aValues], subEntry[se_iValueCount], szFullValue, charsmax(szFullValue))
            console_print(0, "%s    %s", szIndent, szFullValue)
        }
        console_print(0, "%s}", szIndent)
    }
}


/* ============================================================================================== */
/*                                [ CLEANUP & MEMORY MANAGEMENT ]                                 */
/* ============================================================================================== */

public plugin_end() {
    // Do not destroy the system here: other plugins may still save their state in their own plugin_end()
}

stock cfg_destroy_sub_entry_recursive(Array:aSubEntries) {
    if (aSubEntries == Invalid_Array) return;

    new subEntry[SubEntryStruct], iSize = ArraySize(aSubEntries);
    for (new i = 0; i < iSize; i++) {
        ArrayGetArray(aSubEntries, i, subEntry);
        if (subEntry[se_aValues] != Invalid_Array) {
            if (subEntry[se_eEntryType] == CFG_ENTRY_BRACKET &&
                subEntry[se_eContentType] == CFG_CONTENT_ENTRIES) {
                cfg_destroy_sub_entry_recursive(subEntry[se_aValues]);
            }
            ArrayDestroy(subEntry[se_aValues]);
        }
        if (subEntry[se_aComments] != Invalid_Array) ArrayDestroy(subEntry[se_aComments]);
    }
}

stock cfg_destroy_system() {
    for (new ConfigSection:sec = ConfigSection:0; _:sec < g_iSectionCount; sec++) {
        for (new i = 0; i < g_iValueCount[_:sec]; i++) {
            if (g_SectionData[_:sec][i][v_bActive] && g_SectionData[_:sec][i][v_aValues] != Invalid_Array) {
                if (g_SectionData[_:sec][i][v_eEntryType] == CFG_ENTRY_BRACKET &&
                    g_SectionData[_:sec][i][v_eContentType] == CFG_CONTENT_ENTRIES) {
                    cfg_destroy_sub_entry_recursive(g_SectionData[_:sec][i][v_aValues]);
                }
                ArrayDestroy(g_SectionData[_:sec][i][v_aValues]);
            }
            if (g_SectionData[_:sec][i][v_aComments] != Invalid_Array) ArrayDestroy(g_SectionData[_:sec][i][v_aComments]);
        }
        if (g_SectionComments[_:sec] != Invalid_Array) ArrayDestroy(g_SectionComments[_:sec]);
    }
    TrieDestroy(g_tSections);
}

