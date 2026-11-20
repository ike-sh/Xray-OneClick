#!/usr/bin/env bash
# installer-state.json lifecycle.

init_state() {
    local tmp

    mkdir -p "$CONFIG_DIR" || return 1
    command -v jq >/dev/null 2>&1 || return 1
    if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
        validate_json_object "$STATE_FILE" || return 1
    else
        tmp="$(state_temp_file)" || return 1
        if ! printf '%s\n' '{}' >"$tmp" || ! mv "$tmp" "$STATE_FILE"; then
            rm -f "$tmp"
            return 1
        fi
    fi

    tmp="$(state_temp_file)" || return 1
    if ! jq '
      (if (.vless_encryption? | type) == "object" then
        .vless_encryption |= del(.flow)
      else
        .
      end) |
      .meta = (.meta // {}) |
      .endpoint = (if (.endpoint? | type) == "object" then .endpoint else {} end) |
      .forwards = (if (.forwards? | type) == "array" then .forwards else [] end) |
      .tunnels = (if (.tunnels? | type) == "array" then .tunnels else .forwards end)
    ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        return 1
    fi

    ensure_cnblock_state_defaults || return 1
    ensure_config_security || return 1
}

cnblock_rules_present() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e --arg block "$BLOCK_OUTBOUND_TAG" '
      any(.routing.rules[]?;
        . == {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block} or
        . == {"type": "field", "domain": ["geosite:cn"], "outboundTag": $block}
      )
    ' "$CONFIG_FILE" >/dev/null 2>&1
}

ensure_cnblock_state_defaults() {
    local tmp

    [[ -f "$STATE_FILE" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 1

    if cnblock_rules_present; then
        return 0
    fi
    if jq -e 'has("cnblock_enabled") and has("cnblock_user_set")' "$STATE_FILE" >/dev/null 2>&1; then
        return 0
    fi

    tmp="$(state_temp_file)" || return 1
    if ! jq '
      .cnblock_enabled = (.cnblock_enabled // false) |
      .cnblock_user_set = (.cnblock_user_set // false)
    ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$STATE_FILE" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
    ensure_config_security || return 1
}

state_set_cnblock() {
    init_state || return 1
    local enabled="$1"
    local user_set="$2"
    local tmp

    tmp="$(state_temp_file)" || return 1
    if ! jq --arg enabled "$enabled" --arg user_set "$user_set" '
      .cnblock_enabled = ($enabled == "true") |
      .cnblock_user_set = ($user_set == "true")
    ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$STATE_FILE" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
    ensure_config_security || return 1
}

state_meta_value() {
    [[ -f "$STATE_FILE" ]] || return 0
    jq -r --arg key "$1" '.meta[$key] // empty' "$STATE_FILE" 2>/dev/null
}

state_set_meta_action() {
    local action="$1"
    local timestamp tmp

    [[ -n "$action" ]] || return 0
    command -v jq >/dev/null 2>&1 || {
        err "[失败] [状态] 缺少 jq，无法更新最近变更。"
        return 1
    }
    init_state || return 1
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %z')"
    tmp="$(state_temp_file)" || {
        err "[失败] [状态] 创建临时文件失败。"
        return 1
    }

    if ! jq --arg action "$action" --arg updated_at "$timestamp" '
      .meta = ((.meta // {}) + {
        "last_action": $action,
        "last_updated_at": $updated_at
      })
    ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [状态] 更新 installer-state.json 失败。"
        return 1
    fi
    mv "$tmp" "$STATE_FILE" || {
        rm -f "$tmp"
        err "[失败] [状态] 写入 installer-state.json 失败。"
        return 1
    }
    rm -f "$tmp"
    ensure_config_security || return 1
}

create_state_snapshot() {
    local snapshot

    init_state || return 1
    snapshot="$(mktemp "${STATE_FILE}.rollback.XXXXXX")" || return 1
    if ! cp -a "$STATE_FILE" "$snapshot"; then
        rm -f "$snapshot"
        return 1
    fi
    printf '%s' "$snapshot"
}

restore_state_snapshot() {
    local snapshot="$1"

    [[ -f "$snapshot" ]] || return 1
    cp -a "$snapshot" "$STATE_FILE" || return 1
    ensure_config_security || return 1
}
