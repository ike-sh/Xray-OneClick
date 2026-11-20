#!/usr/bin/env bash
# ike smoke command implementations.

smoke_reality() {
    local restart="${1:-false}" port defender_port

    echo -e "\n${YELLOW}Reality 烟测辅助${PLAIN}"
    echo "----------------------------------------"
    if ! inbound_exists "$REALITY_TAG"; then
        diag_info "Reality 未安装，跳过 Reality smoke"
        return 0
    fi
    cnblock_reality_risk_notice
    run_xray_config_test_verbose || print_reality_failure_hint
    if [[ "$restart" == "true" ]]; then
        if restart_service; then
            diag_ok "xray restart 成功"
        else
            diag_fail "xray restart 失败，最近日志如下"
            show_journal_recent
            diag_warn "可检查备份并重新部署 Reality，但脚本不会自动删除其它配置。"
        fi
    else
        diag_info "默认不自动 restart；如需重启请执行: ike smoke reality --restart"
    fi
    diag_info "Xray 服务状态: $(xray_service_status)"
    port="$(jq -r --arg tag "$REALITY_TAG" '.inbounds[]? | select(.tag == $tag).port // empty' "$CONFIG_FILE")"
    defender_port="$(jq -r --arg tag "$REALITY_DEFENDER_TAG" '.inbounds[]? | select(.tag == $tag).port // empty' "$CONFIG_FILE")"
    doctor_reality_port "$port" "$defender_port"
    show_journal_recent
}

smoke_xhttp() {
    local restart="${1:-false}" port fm_enabled

    echo -e "\n${YELLOW}XHTTP-FinalMask 烟测辅助${PLAIN}"
    echo "----------------------------------------"
    if ! inbound_exists "$VLESS_XHTTP_FM_TAG"; then
        diag_info "XHTTP-FinalMask 未安装，跳过 XHTTP smoke"
        return 0
    fi
    if ! run_xray_config_test_verbose; then
        fm_enabled="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
        [[ "$fm_enabled" == "true" ]] && print_finalmask_failure_hint
        print_xhttp_failure_hint
    fi
    if [[ "$restart" == "true" ]]; then
        if restart_service; then
            diag_ok "xray restart 成功"
        else
            diag_fail "xray restart 失败，最近日志如下"
            show_journal_recent
        fi
    else
        diag_info "默认不自动 restart；如需重启请执行: ike smoke xhttp --restart"
    fi
    port="$(jq -r --arg tag "$VLESS_XHTTP_FM_TAG" '.inbounds[]? | select(.tag == $tag).port // empty' "$CONFIG_FILE")"
    if port_listening "$port"; then
        diag_ok "XHTTP 端口正在监听: ${port}"
    else
        diag_warn "XHTTP 端口未监听或 ss 不可用: ${port}"
    fi
    diag_info "FinalMask: $(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
}

smoke_advanced_profile() {
    local kind="$1"
    local restart="${2:-false}"
    local tag state_key name port fm_enabled

    tag="$(advanced_profile_tag "$kind")" || return 1
    state_key="$(advanced_profile_state_key "$kind")" || return 1
    name="$(advanced_profile_name "$kind")" || return 1

    echo -e "\n${YELLOW}${name} 烟测辅助${PLAIN}"
    echo "----------------------------------------"
    if ! inbound_exists "$tag"; then
        diag_info "${name} 未安装，跳过 smoke"
        return 0
    fi
    cnblock_reality_risk_notice
    if ! run_xray_config_test_verbose; then
        if advanced_profile_has_finalmask "$kind"; then
            fm_enabled="$(jq -r ".${state_key}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
            [[ "$fm_enabled" == "true" ]] && print_finalmask_failure_hint
        fi
        print_apply_failure_hint "$kind"
    fi
    if [[ "$restart" == "true" ]]; then
        if restart_service; then
            diag_ok "xray restart 成功"
        else
            diag_fail "xray restart 失败，最近日志如下"
            show_journal_recent
        fi
    else
        diag_info "默认不自动 restart；如需重启请执行: ike smoke ${kind} --restart"
    fi
    port="$(jq -r --arg tag "$tag" '.inbounds[]? | select(.tag == $tag).port // empty' "$CONFIG_FILE")"
    if port_listening "$port"; then
        diag_ok "入口端口正在监听: ${port}"
    else
        diag_warn "入口端口未监听或 ss 不可用: ${port}"
    fi
    diag_info "Xray 服务状态: $(xray_service_status)"
    show_journal_recent
}

run_smoke_command() {
    local target="${1:-all}"
    local restart="false"

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restart)
                restart="true"
                ;;
            *)
                err "[失败] 未知 smoke 参数: $1"
                echo "用法: ike smoke reality|xhttp|xhttp-reality|enc-reality|fullstack|all [--restart]"
                return 1
                ;;
        esac
        shift
    done

    if [[ "$restart" == "true" ]]; then
        with_xray_lock run_smoke_target "$target" "$restart"
    else
        run_smoke_target "$target" "$restart"
    fi
}

run_smoke_target() {
    local target="$1" restart="$2"
    case "$target" in
        reality) smoke_reality "$restart" ;;
        xhttp) smoke_xhttp "$restart" ;;
        xhttp-reality) smoke_advanced_profile "xhttp-reality" "$restart" ;;
        enc-reality) smoke_advanced_profile "enc-reality" "$restart" ;;
        fullstack) smoke_advanced_profile "fullstack" "$restart" ;;
        all | "")
            smoke_reality "$restart"
            smoke_xhttp "$restart"
            smoke_advanced_profile "xhttp-reality" "$restart"
            smoke_advanced_profile "enc-reality" "$restart"
            smoke_advanced_profile "fullstack" "$restart"
            doctor_proxy
            ;;
        *)
            err "[失败] 未知 smoke 目标: $target"
            echo "用法: ike smoke reality|xhttp|xhttp-reality|enc-reality|fullstack|all [--restart]"
            return 1
            ;;
    esac
}

redact_config_json() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    jq '
      def redact:
        walk(if type == "object" then
          with_entries(
            if ((.key | test("(?i)(privateKey|private_key|decryption|password|pass|token|secret)")) or
                (.key | test("(?i)^(auth|id|uuid|shortIds|short_ids)$"))) then
              .value = "***REDACTED***"
            else
              .
            end
          )
        else
          .
        end);
      redact
    ' "$CONFIG_FILE" 2>/dev/null
}
