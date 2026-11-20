#!/usr/bin/env bash
# Shadowsocks 2022 install helpers.

generate_ss2022_password() {
    local method="$1"
    local bytes="32"
    [[ "$method" == "2022-blake3-aes-128-gcm" ]] && bytes="16"
    openssl rand -base64 "$bytes"
}

configure_ss2022() {
    local listen_mode="${1:-ipv4}"

    echo -e "\n${YELLOW}[配置] Shadowsocks 2022 加密协议:${PLAIN}"
    echo -e "  1) 2022-blake3-aes-128-gcm ${GREEN}(推荐，兼容性好)${PLAIN}"
    echo "  2) 2022-blake3-aes-256-gcm"
    echo "  3) 2022-blake3-chacha20-poly1305"
    read -r -p "选项 (默认: 1): " M_OPT || return 1

    case "${M_OPT:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        3) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        *) SS_METHOD="2022-blake3-aes-128-gcm" ;;
    esac

    ask_port "SS2022 端口" "9000" SS_PORT || {
        err "[失败] [SS2022] 端口配置失败。"
        return 1
    }
    SS_PASSWORD="$(generate_ss2022_password "$SS_METHOD")"
    if [[ -z "$SS_PASSWORD" ]]; then
        err "[失败] [SS2022] 密码生成失败。"
        return 1
    fi

    case "$listen_mode" in
        ipv4) SS_LISTEN="0.0.0.0" ;;
        ipv6) SS_LISTEN="::" ;;
        *)
            err "[失败] [SS2022] 未知监听模式: $listen_mode"
            return 1
            ;;
    esac

    info "[SS2022] 监听模式: ${listen_mode} (${SS_LISTEN})"
    return 0
}

state_set_ss2022() {
    init_state || return 1
    local tmp listen_scope

    listen_scope="$(protocol_listen_scope "${SS_LISTEN:-}")"
    tmp="$(state_temp_file)" || return 1
    if ! jq --arg tag "$SS_TAG" \
        --arg port "$SS_PORT" \
        --arg listen "${SS_LISTEN:-}" \
        --arg listen_scope "$listen_scope" '
        .ss2022 = {
          "tag": $tag,
          "port": ($port|tonumber),
          "listen": $listen,
          "listen_scope": $listen_scope
        }
       ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[状态] 生成 SS2022 状态失败。"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[状态] 写入 SS2022 状态失败。"
        return 1
    fi
    ensure_config_security || return 1
}

install_ss2022() {
    info "[SS2022] 正在生成配置..."
    if ! install_or_update_xray; then
        err "[失败] [SS2022] Xray 安装/更新失败。"
        return 1
    fi

    if ! backup_config; then
        err "[失败] [SS2022] 配置备份失败。"
        return 1
    fi

    local tmp
    tmp="$(config_temp_file)" || {
        err "[失败] [SS2022] 创建临时文件失败。"
        return 1
    }

    info "[SS2022] 正在写入 config.json..."
    if ! jq --arg tag "$SS_TAG" \
        --arg listen "$SS_LISTEN" \
        --arg port "$SS_PORT" \
        --arg method "$SS_METHOD" \
        --arg pass "$SS_PASSWORD" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [{
          "tag": $tag,
          "listen": $listen,
          "port": ($port|tonumber),
          "protocol": "shadowsocks",
          "settings": {
            "network": "tcp,udp",
            "method": $method,
            "password": $pass,
            "level": 0
          }
        }]
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [SS2022] jq 生成配置失败。"
        return 1
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [SS2022] 写入 $CONFIG_FILE 失败。"
        return 1
    fi

    if ! apply_config "SS2022"; then
        err "[失败] [SS2022] 应用配置失败。"
        return 1
    fi
    if ! state_set_ss2022; then
        rollback_config_after_state_failure "SS2022"
        return 1
    fi
    state_set_meta_action "安装 SS2022" || err "[状态] 最近变更记录失败。"
    ok "[完成] SS2022 已写入 Xray 配置。"
    view_config
}
