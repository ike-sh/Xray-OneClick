#!/usr/bin/env bash
# Xray-OneClick config.json lifecycle: init, backup, validate, apply.

validate_json_object() {
    if [[ ! -f "$1" ]] || ! jq -es 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1; then
        err "[配置] 无法读取有效的 JSON 对象，原文件已保留: $1"
        return 1
    fi
}

init_config() {
    local tmp

    mkdir -p "$CONFIG_DIR" || {
        err "[配置] 创建配置目录失败: $CONFIG_DIR"
        return 1
    }
    command -v jq >/dev/null 2>&1 || {
        err "[配置] 缺少 jq，无法初始化配置。"
        return 1
    }

    if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
        validate_json_object "$CONFIG_FILE" && ensure_config_security
        return
    fi

    tmp="$(config_temp_file)" || return 1
    if ! cat >"$tmp" <<'JSON'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
JSON
    then
        rm -f "$tmp"
        err "[配置] 创建基础配置失败: $CONFIG_FILE"
        return 1
    fi
    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[配置] 提交基础配置失败: $CONFIG_FILE"
        return 1
    fi
    ensure_default_safety_blocks || return 1
    ensure_config_security || return 1
}

backup_config() {
    local backup_path

    CONFIG_BACKUP_PATH=""
    [[ -f "$CONFIG_FILE" ]] || return 0
    backup_path="$(mktemp "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S).XXXXXX")" || return 1
    if ! cp -a "$CONFIG_FILE" "$backup_path"; then
        rm -f "$backup_path"
        return 1
    fi
    CONFIG_BACKUP_PATH="$backup_path"
}

restore_config_backup() {
    local latest_backup candidate

    latest_backup="${CONFIG_BACKUP_PATH:-}"
    if [[ -z "$latest_backup" || ! -f "$latest_backup" ]]; then
        err "[回滚] 本次操作没有可恢复的配置备份: ${CONFIG_FILE}.bak.*"
        return 1
    fi

    info "[回滚] 正在恢复本次备份: $latest_backup"
    candidate="$(config_temp_file)" || return 1
    if ! cp -a "$latest_backup" "$candidate" || ! mv -f "$candidate" "$CONFIG_FILE"; then
        rm -f "$candidate"
        err "[回滚] 恢复配置文件失败。"
        return 1
    fi
    ensure_config_security || return 1

    if ! validate_config_file; then
        err "[回滚] 恢复失败：备份配置校验未通过。"
        return 1
    fi

    ok "[回滚] 恢复成功，备份配置校验通过。"
}

rollback_config_after_state_failure() {
    local context="${1:-配置状态}"

    err "[失败] [${context}] 配置已生效，但状态写入失败。"
    err "[回滚] 正在恢复安装前配置。"
    if restore_config_backup && restart_service; then
        ok "[回滚] 配置与服务已恢复。"
    else
        err "[回滚] 自动恢复失败，请检查 $CONFIG_FILE 和 ${CONFIG_FILE}.bak.*。"
    fi
    return 1
}

export_current_config_backup() {
    local timestamp config_backup state_backup

    [[ -f "$CONFIG_FILE" ]] || {
        err "[失败] 未找到配置文件: $CONFIG_FILE"
        return 1
    }

    timestamp="$(date +%Y%m%d%H%M%S)"
    config_backup="$(mktemp "/root/xray-config-backup-${timestamp}.json.XXXXXX")" || return 1

    if ! cp -a "$CONFIG_FILE" "$config_backup"; then
        err "[失败] 导出配置备份失败: $config_backup"
        return 1
    fi
    chmod 600 "$config_backup" 2>/dev/null || true

    ok "[备份] config.json: $config_backup"

    if [[ -f "$STATE_FILE" ]]; then
        state_set_meta_action "导出配置备份" || err "[状态] 记录备份动作失败，配置备份已继续导出。"
        state_backup="$(mktemp "/root/xray-state-backup-${timestamp}.json.XXXXXX")" || return 1
        if ! cp -a "$STATE_FILE" "$state_backup"; then
            err "[失败] 导出状态备份失败: $state_backup"
            return 1
        fi
        chmod 600 "$state_backup" 2>/dev/null || true
        ok "[备份] installer-state.json: $state_backup"
    else
        info "[备份] 未找到状态文件，已跳过: $STATE_FILE"
    fi
}

validate_config_file() {
    local config="${1:-$CONFIG_FILE}" binary="${2:-$BIN_PATH}" assets="${3:-$ASSET_DIR}"
    validate_json_object "$config" || return 1
    if [[ ! -x "$binary" ]]; then
        err "[核心] Xray 二进制不存在或不可执行: $binary"
        return 1
    fi
    if ! XRAY_LOCATION_ASSET="$assets" timeout 30 "$binary" run -test -c "$config" >/dev/null 2>&1; then
        err "[配置] Xray run -test 校验失败: $config"
        return 1
    fi
}

# Work on private copies and restore only files touched by this operation.
run_deployment_transaction() (
    local DEPLOYMENT_DIR
    local -a DEPLOYMENT_FILES=()
    local DEPLOYMENT_CREATED_SERVICE=false DEPLOYMENT_RESTARTED=false DEPLOYMENT_WAS_ACTIVE=false
    local DEPLOYMENT_REPLACED_BINARY=false
    local DEPLOYMENT_CORE_CHANGED=false DEPLOYMENT_BINARY="$BIN_PATH" DEPLOYMENT_ASSETS="$ASSET_DIR"
    local XRAY_REPLACED_BACKUP_PATH="" XRAY_REPLACED_HAD_ORIGINAL=false

    umask 077
    DEPLOYMENT_DIR="$(mktemp -d)" || return 1
    trap 'finish_deployment_transaction "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@"
)

snapshot_deployment_file() {
    local target="$1" index="${#DEPLOYMENT_FILES[@]}"
    if [[ -e "$target" || -L "$target" ]]; then
        if [[ ! -f "$target" && ! -L "$target" ]] || ! cp -a -- "$target" "$DEPLOYMENT_DIR/original.$index"; then
            err "[事务] 无法备份 $target"
            return 1
        fi
    fi
    DEPLOYMENT_FILES+=("$target")
}

publish_deployment_file() {
    local source="$1" target="$2" mode="$3" temporary
    if [[ -d "$target" ]]; then
        err "[事务] 目标是目录，无法提交文件: $target"
        return 1
    fi
    temporary="$(mktemp "${target}.new.XXXXXX")" || return 1
    if ! install -m "$mode" -- "$source" "$temporary" || ! snapshot_deployment_file "$target" ||
        ! mv -f -- "$temporary" "$target"; then
        rm -f -- "$temporary"
        err "[事务] 写入失败: $target"
        return 1
    fi
}

restore_deployment_file() {
    local target="$1" original="$2" temporary
    [[ ! -d "$target" ]] || return 1
    if [[ ! -e "$original" && ! -L "$original" ]]; then
        rm -f -- "$target"
        return
    fi
    temporary="$(mktemp "${target}.restore.XXXXXX")" || return 1
    if ! rm -f -- "$temporary" || ! cp -a -- "$original" "$temporary" || ! mv -f -- "$temporary" "$target"; then
        rm -f -- "$temporary"
        return 1
    fi
}

finish_deployment_transaction() {
    local result="$1" failed=false index unit
    trap - EXIT
    if ((result != 0)); then
        if [[ "$DEPLOYMENT_RESTARTED" == "true" && "$DEPLOYMENT_WAS_ACTIVE" == "false" ]]; then
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                systemctl stop "$SERVICE_NAME" || { err "[回滚] 未能恢复 Xray 服务的停止状态。"; failed=true; }
            else
                stop_service || { err "[回滚] 未能恢复 Xray 服务的停止状态。"; failed=true; }
            fi
        fi
        if [[ "$DEPLOYMENT_CREATED_SERVICE" == "true" ]]; then
            disable_new_xray_service || { err "[回滚] 未能撤销 Xray 服务的开机启动。"; failed=true; }
        fi
        for ((index = ${#DEPLOYMENT_FILES[@]} - 1; index >= 0; index--)); do
            unit="${DEPLOYMENT_FILES[index]}"
            if ! restore_deployment_file "$unit" "$DEPLOYMENT_DIR/original.$index"; then
                err "[回滚] 未能恢复文件: $unit"
                failed=true
            fi
        done
        if [[ "$DEPLOYMENT_REPLACED_BINARY" == "true" ]] &&
            ! rollback_xray_binary_replacement "$XRAY_REPLACED_BACKUP_PATH" "$XRAY_REPLACED_HAD_ORIGINAL"; then
            failed=true
        fi
        if [[ "$DEPLOYMENT_CREATED_SERVICE" == "true" && "$INIT_SYSTEM" == "systemd" ]] && ! systemctl daemon-reload; then
            err "[回滚] 未能重新加载 systemd 服务定义。"
            failed=true
        fi
        if [[ "$DEPLOYMENT_RESTARTED" == "true" && "$DEPLOYMENT_WAS_ACTIVE" == "true" ]]; then
            if [[ "$failed" == "true" ]] || ! restart_service; then
                err "[回滚] 未能恢复原 Xray 服务。"
                failed=true
            fi
        fi
        if [[ "$failed" == "true" ]]; then
            err "[回滚] 自动恢复不完整，操作快照保存在 $DEPLOYMENT_DIR"
            exit "$result"
        fi
    fi
    rm -rf -- "$DEPLOYMENT_DIR"
    exit "$result"
}

stage_initial_xray_files() {
    local target_assets="$1" staged_dir="$DEPLOYMENT_DIR/config"
    mkdir -m 700 "$staged_dir" || return 1
    if [[ -e "$CONFIG_FILE" || -L "$CONFIG_FILE" ]]; then
        validate_json_object "$CONFIG_FILE" && cp -- "$CONFIG_FILE" "$staged_dir/config.json" || return 1
    fi
    if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
        validate_json_object "$STATE_FILE" && cp -- "$STATE_FILE" "$staged_dir/installer-state.json" || return 1
    fi
    (
        local CONFIG_DIR="$staged_dir" CONFIG_FILE="$staged_dir/config.json" STATE_FILE="$staged_dir/installer-state.json"
        local ASSET_DIR="$DEPLOYMENT_DIR/base-assets"
        mkdir -m 700 "$ASSET_DIR" || return 1
        if [[ -f "$target_assets/geoip.dat" ]]; then
            ln -s "$target_assets/geoip.dat" "$ASSET_DIR/geoip.dat" || return 1
        fi
        [[ -f "$CONFIG_FILE" ]] || init_config || return 1
        [[ -f "$STATE_FILE" ]] || init_state || return 1
    )
}
