#!/usr/bin/env bash
# ike export command implementations.

render_export_report() {
    local tags ports xray_version

    [[ -n "${INIT_SYSTEM:-}" ]] || check_os
    echo "Xray-OneClick 脱敏诊断报告"
    echo "----------------------------------------"
    echo "SCRIPT_VERSION: ${SCRIPT_VERSION}"
    if [[ -x "$BIN_PATH" ]]; then
        xray_version="$("$BIN_PATH" version 2>/dev/null | head -n 1 || true)"
        echo "xray version: ${xray_version:-读取失败}"
    else
        echo "xray version: 未安装"
    fi
    echo "service status: $(xray_service_status)"
    echo "config test: $(xray_config_test_status)"
    echo "installed protocols: $(installed_protocols_summary)"
    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
        tags="$(jq -r '[.inbounds[]?.tag] | join(", ")' "$CONFIG_FILE" 2>/dev/null)"
        ports="$(jq -r '[.inbounds[]? | select(.port != null) | (.tag + ":" + (.port|tostring))] | join(", ")' "$CONFIG_FILE" 2>/dev/null)"
        echo "inbound tags: ${tags:-无}"
        echo "listen ports: ${ports:-无}"
    fi
    echo
    echo "Reality 摘要:"
    if inbound_exists "$REALITY_TAG"; then
        jq -r --arg tag "$REALITY_TAG" '.inbounds[]? | select(.tag == $tag) | "  port=\(.port) sni=\(.streamSettings.realitySettings.serverNames[0] // "") flow=\(.settings.clients[0].flow // "")"' "$CONFIG_FILE"
        jq -r ".${REALITY_STATE_KEY} // {} | \"  state=present client_credentials=***REDACTED***\"" "$STATE_FILE" 2>/dev/null
    else
        echo "  未安装"
    fi
    echo
    echo "XHTTP-FinalMask 摘要:"
    if inbound_exists "$VLESS_XHTTP_FM_TAG"; then
        jq -r --arg tag "$VLESS_XHTTP_FM_TAG" '.inbounds[]? | select(.tag == $tag) | "  port=\(.port) path=\(.streamSettings.xhttpSettings.path // "") finalmask=\(.streamSettings | has("finalmask"))"' "$CONFIG_FILE"
        jq -r ".${VLESS_XHTTP_FM_STATE_KEY} // {} | \"  finalmask_enabled=\(.finalmask_enabled // false) mode=\(.finalmask_mode // \"off\") preset=\(.finalmask_preset // \"none\") summary=\(.finalmask_summary // \"\") client_credentials=***REDACTED***\"" "$STATE_FILE" 2>/dev/null
    else
        echo "  未安装"
    fi
    echo
    echo "ENC-FinalMask (sudoku) 摘要:"
    if inbound_exists "$VLESS_ENC_FM_TAG"; then
        jq -r --arg tag "$VLESS_ENC_FM_TAG" '.inbounds[]? | select(.tag == $tag) | "  port=\(.port) network=\(.streamSettings.network) finalmask=\(.streamSettings.finalmask.tcp[0].type // "")"' "$CONFIG_FILE"
        jq -r ".${VLESS_ENC_FM_STATE_KEY} // {} | \"  auth_mode=\(.auth // \"\") client_credentials=***REDACTED***\"" "$STATE_FILE" 2>/dev/null
    else
        echo "  未安装"
    fi
    echo
    echo "ENC-XHTTP 摘要:"
    if inbound_exists "$VLESS_ENC_XHTTP_TAG"; then
        jq -r --arg tag "$VLESS_ENC_XHTTP_TAG" '.inbounds[]? | select(.tag == $tag) | "  port=\(.port) network=\(.streamSettings.network) path=\(.streamSettings.xhttpSettings.path // "")"' "$CONFIG_FILE"
        jq -r ".${VLESS_ENC_XHTTP_STATE_KEY} // {} | \"  auth_mode=\(.auth // \"\") client_credentials=***REDACTED***\"" "$STATE_FILE" 2>/dev/null
    else
        echo "  未安装"
    fi
    echo
    echo "Hysteria2 摘要:"
    if inbound_exists "$HY2_TAG"; then
        jq -r --arg tag "$HY2_TAG" '.inbounds[]? | select(.tag == $tag) | "  port=\(.port) protocol=\(.protocol) obfs=\(.streamSettings.finalmask.udp[0].type // "")"' "$CONFIG_FILE"
        jq -r ".${HY2_STATE_KEY} // {} | \"  sni=\(.sni // \"\") client_credentials=***REDACTED***\"" "$STATE_FILE" 2>/dev/null
    else
        echo "  未安装"
    fi
    echo
    echo "高级协议组合摘要:"
    if inbound_exists "$VLESS_XHTTP_REALITY_TAG"; then
        jq -r --arg tag "$VLESS_XHTTP_REALITY_TAG" '.inbounds[]? | select(.tag == $tag) | "  XHTTP-Reality port=\(.port) path=\(.streamSettings.xhttpSettings.path // "") sni=\(.streamSettings.realitySettings.serverNames[0] // "") flow=\(.settings.clients[0].flow // "none")"' "$CONFIG_FILE"
        jq -r ".${VLESS_XHTTP_REALITY_STATE_KEY} // {} | \"    publicKey=\(.public_key // \"\") flow=\(.flow // \"none\")\"" "$STATE_FILE" 2>/dev/null
    else
        echo "  XHTTP-Reality: 未安装"
    fi
    if inbound_exists "$VLESS_ENC_REALITY_TAG"; then
        jq -r --arg tag "$VLESS_ENC_REALITY_TAG" '.inbounds[]? | select(.tag == $tag) | "  Enc-Reality port=\(.port) sni=\(.streamSettings.realitySettings.serverNames[0] // "") flow=\(.settings.clients[0].flow // "none")"' "$CONFIG_FILE"
        jq -r ".${VLESS_ENC_REALITY_STATE_KEY} // {} | \"    publicKey=\(.public_key // \"\") flow=\(.flow // \"none\")\"" "$STATE_FILE" 2>/dev/null
    else
        echo "  Enc-Reality: 未安装"
    fi
    if inbound_exists "$VLESS_FULLSTACK_TAG"; then
        jq -r --arg tag "$VLESS_FULLSTACK_TAG" '.inbounds[]? | select(.tag == $tag) | "  FullStack port=\(.port) path=\(.streamSettings.xhttpSettings.path // "") sni=\(.streamSettings.realitySettings.serverNames[0] // "") flow=\(.settings.clients[0].flow // "none") finalmask=\(.streamSettings | has("finalmask"))"' "$CONFIG_FILE"
        jq -r ".${VLESS_FULLSTACK_STATE_KEY} // {} | \"    publicKey=\(.public_key // \"\") flow=\(.flow // \"none\") finalmask_enabled=\(.finalmask_enabled // false) mode=\(.finalmask_mode // \"off\") preset=\(.finalmask_preset // \"none\") summary=\(.finalmask_summary // \"\")\"" "$STATE_FILE" 2>/dev/null
    else
        echo "  FullStack: 未安装"
    fi
    echo
    echo "最近日志摘要:"
    if [[ "${INIT_SYSTEM:-}" == "openrc" ]]; then
        tail_xray_service_logs 20 || echo "  OpenRC 日志文件尚未生成"
    elif command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null | redact_sensitive_stream || true
    else
        echo "  journalctl 不可用"
    fi
    echo
    echo "脱敏 config 摘要:"
    redact_config_json || true
}

render_export_clients() {
    echo "Xray-OneClick 客户端参数导出"
    echo "----------------------------------------"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "未找到 config.json"
        return 0
    fi
    init_state || return 1
    view_config dual quick || true
    if [[ -f "$STATE_FILE" ]] && jq -e ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled == true" "$STATE_FILE" >/dev/null 2>&1; then
        echo
        echo "提示: 如客户端无法导入，请手动填写 path/encryption/finalmask。"
    fi
    if [[ -f "$STATE_FILE" ]] && jq -e ".${VLESS_FULLSTACK_STATE_KEY}.finalmask_enabled == true" "$STATE_FILE" >/dev/null 2>&1; then
        echo
        echo "提示: FullStack 链接较长，如客户端无法导入，请手动填写 path/encryption/reality/finalmask。"
    fi
}

write_or_print_export() {
    local output_path="${1:-}"
    local content

    content="$(cat)"
    if [[ -n "$output_path" ]]; then
        printf '%s\n' "$content" >"$output_path" || {
            err "[导出] 写入失败: $output_path"
            return 1
        }
        chmod 600 "$output_path" 2>/dev/null || true
        ok "[导出] 已写入: $output_path"
    else
        printf '%s\n' "$content"
    fi
}

run_export_command() {
    local action="${1:-report}"
    local output=""

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                output="${2:-}"
                [[ -n "$output" ]] || {
                    err "[导出] --output 需要路径"
                    return 1
                }
                shift 2
                ;;
            *)
                err "[失败] 未知 export 参数: $1"
                echo "用法: ike export report|clients [--output PATH]"
                return 1
                ;;
        esac
    done

    case "$action" in
        report)
            render_export_report | write_or_print_export "$output"
            ;;
        clients)
            render_export_clients | write_or_print_export "$output"
            ;;
        *)
            err "[失败] 未知 export 目标: $action"
            echo "用法: ike export report|clients [--output PATH]"
            return 1
            ;;
    esac
}
