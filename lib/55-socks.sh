#!/usr/bin/env bash
# SOCKS5 proxy install.

state_set_socks5() {
    init_state || return 1
    local tmp

    tmp="$(state_temp_file)" || return 1
    if ! jq --arg tag "$SOCKS_TAG" \
        --arg port "$S_PORT" \
        --arg listen "0.0.0.0" \
        --arg listen_scope "ipv4" '
        .socks5 = {
          "tag": $tag,
          "port": ($port|tonumber),
          "listen": $listen,
          "listen_scope": $listen_scope
        }
       ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [SOCKS5] 写入状态文件失败。"
        return 1
    fi
    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [SOCKS5] 更新状态文件失败。"
        return 1
    fi
    ensure_config_security || return 1
}

install_socks5() {
    echo -e "\n${YELLOW}[配置] SOCKS5 参数:${PLAIN}"
    ask_port "SOCKS5 端口" "1080" S_PORT || return 1
    read -r -p "用户 (默认: admin): " S_USER || return 1
    S_USER="${S_USER:-admin}"
    read -r -p "密码 (默认: 随机): " S_PASS || return 1
    S_PASS="${S_PASS:-$(openssl rand -hex 8)}"
    [[ -n "$S_PASS" ]] || S_PASS="$(generate_uuid | tr -d '-')"
    [[ -n "$S_PASS" ]] || return 1

    install_or_update_xray || return 1
    backup_config || {
        err "[失败] [SOCKS5] 配置备份失败。"
        return 1
    }

    local tmp
    tmp="$(config_temp_file)" || {
        err "[失败] [SOCKS5] 创建临时文件失败。"
        return 1
    }
    if ! jq --arg tag "$SOCKS_TAG" \
        --arg port "$S_PORT" \
        --arg user "$S_USER" \
        --arg pass "$S_PASS" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [{
          "tag": $tag,
          "listen": "0.0.0.0",
          "port": ($port|tonumber),
          "protocol": "socks",
          "settings": {
            "auth": "password",
            "accounts": [{"user": $user, "pass": $pass}],
            "udp": true
          }
        }]
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [SOCKS5] 生成配置失败。"
        return 1
    fi
    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [SOCKS5] 写入 $CONFIG_FILE 失败。"
        return 1
    fi

    apply_config || return 1
    if ! state_set_socks5; then
        rollback_config_after_state_failure "SOCKS5"
        return 1
    fi
    state_set_meta_action "安装 SOCKS5" || err "[状态] 最近变更记录失败。"
    ok "[完成] SOCKS5 已写入 Xray 配置。"
    view_config
}
