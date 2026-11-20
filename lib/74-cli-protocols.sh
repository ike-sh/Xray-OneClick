#!/usr/bin/env bash
# Protocol install CLI: reality, xhttp, advanced.

show_reality_usage() {
    cat <<'EOF'
用法:
  ike reality install [--port PORT] [--defender-port PORT] [--sni DOMAIN] [--flow vision|none] [--dry-run] [--yes] [--empty-clients]
  ike reality show
  ike reality remove
  ike view reality
EOF
}

show_xray_usage() {
    cat <<'EOF'
用法:
  ike xray version
  ike xray upgrade [--version vX.Y.Z] [--xray-channel stable|prerelease] [--dry-run] [--restart]

环境变量:
  XRAY_VERSION=vX.Y.Z
  XRAY_CHANNEL=stable|prerelease
EOF
}

show_xhttp_usage() {
    cat <<'EOF'
用法:
  ike xhttp install [--port PORT] [--path /path] [--finalmask on|off] [--finalmask-preset conservative|balanced|aggressive] [--fm-length 100-200] [--fm-delay 10-20] [--fm-max-split 3-6] [--finalmask-json JSON] [--dry-run] [--auth x25519|mlkem768]
  ike xhttp show
  ike xhttp remove
  ike view xhttp
EOF
}

run_reality_command() {
    local action="${1:-show}"

    case "$action" in
        help | -h | --help)
            show_reality_usage
            ;;
        install)
            shift
            REALITY_PORT_REQUEST=""
            REALITY_DEFENDER_PORT_REQUEST=""
            REALITY_SNI_REQUEST=""
            REALITY_EMPTY_CLIENTS="false"
            REALITY_ASSUME_YES="false"
            REALITY_FLOW="$REALITY_FLOW_DEFAULT"
            REALITY_DRY_RUN="false"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        REALITY_PORT_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --defender-port)
                        REALITY_DEFENDER_PORT_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --sni)
                        REALITY_SNI_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --flow)
                        if [[ -z "${2:-}" ]] || ! REALITY_FLOW="$(normalize_reality_flow "$2")"; then
                            err "[Reality] --flow 仅支持 none 或 vision。"
                            return 1
                        fi
                        shift; shift
                        ;;
                    --empty-clients)
                        REALITY_EMPTY_CLIENTS="true"
                        shift
                        ;;
                    --yes | -y)
                        REALITY_ASSUME_YES="true"
                        shift
                        ;;
                    --dry-run)
                        REALITY_DRY_RUN="true"
                        REALITY_SKIP_TLS_TEST="${REALITY_SKIP_TLS_TEST:-1}"
                        shift
                        ;;
                    help | -h | --help)
                        show_reality_usage
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 reality install 参数: $1"
                        show_reality_usage
                        return 1
                        ;;
                esac
            done
            if [[ "$REALITY_DRY_RUN" == "true" ]]; then
                configure_reality "dry-run" && install_reality
            else
                prepare_system || return 1
                configure_reality "cli" && install_reality
            fi
            ;;
        show | "")
            init_state || return 1
            print_reality_result "show"
            ;;
        remove | delete | del)
            prepare_system || return 1
            remove_reality_config
            ;;
        *)
            err "[失败] 未知 reality 参数: $action"
            show_reality_usage
            return 1
            ;;
    esac
}

run_xhttp_command() {
    local action="${1:-show}"

    case "$action" in
        help | -h | --help)
            show_xhttp_usage
            ;;
        install)
            shift
            XHTTP_PORT_REQUEST=""
            XHTTP_PATH_REQUEST=""
            XHTTP_FINALMASK_REQUEST="false"
            FINALMASK_PRESET_REQUEST=""
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            XHTTP_DRY_RUN="false"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        XHTTP_PORT_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --path)
                        XHTTP_PATH_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --finalmask)
                        XHTTP_FINALMASK_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --finalmask-preset | --fm-packets | --fm-length | --fm-delay | --fm-max-split | --finalmask-json)
                        if ! parse_finalmask_args "$1" "${2:-}"; then
                            return 1
                        fi
                        shift "$FINALMASK_ARG_SHIFT"
                        ;;
                    --auth)
                        VLESS_AUTH="${2:-}"
                        shift; shift
                        ;;
                    --enc-method)
                        VLESS_ENC_METHOD="${2:-}"
                        VLESS_MODE="advanced"
                        shift; shift
                        ;;
                    --rtt)
                        VLESS_CLIENT_RTT="${2:-}"
                        VLESS_MODE="advanced"
                        shift; shift
                        ;;
                    --ticket)
                        VLESS_SERVER_TICKET="${2:-}"
                        VLESS_MODE="advanced"
                        shift; shift
                        ;;
                    --dry-run)
                        XHTTP_DRY_RUN="true"
                        shift
                        ;;
                    help | -h | --help)
                        show_xhttp_usage
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 xhttp install 参数: $1"
                        show_xhttp_usage
                        return 1
                        ;;
                esac
            done
            case "$VLESS_AUTH" in
                x25519 | mlkem768) ;;
                *)
                    err "[XHTTP] --auth 仅支持 x25519 或 mlkem768。"
                    return 1
                    ;;
            esac
            if [[ "$XHTTP_DRY_RUN" == "true" ]]; then
                configure_vless_xhttp_finalmask "dry-run" && install_vless_xhttp_finalmask
            else
                prepare_system || return 1
                configure_vless_xhttp_finalmask "cli" && install_vless_xhttp_finalmask
            fi
            ;;
        show | "")
            init_state || return 1
            print_vless_xhttp_finalmask_result "show"
            ;;
        remove | delete | del)
            prepare_system || return 1
            remove_vless_xhttp_finalmask_config
            ;;
        *)
            err "[失败] 未知 xhttp 参数: $action"
            show_xhttp_usage
            return 1
            ;;
    esac
}

show_enc_finalmask_usage() {
    cat <<'EOF'
用法: ike enc-finalmask <install|show|remove> [选项]

  install              安装 VLESS Encryption + FinalMask (sudoku, TCP)
    --port N           指定端口 (默认 8444)
    --auth TYPE        x25519 (默认) 或 mlkem768
    --dry-run          仅生成配置预览，不写入真实配置
  show                 查看当前配置与分享链接
  remove               删除该协议入站

说明: FinalMask(sudoku) 需要较新的 Xray-core 支持。
EOF
}

run_enc_finalmask_command() {
    local action="${1:-show}"

    case "$action" in
        help | -h | --help)
            show_enc_finalmask_usage
            ;;
        install)
            shift
            VLESS_ENC_FM_PORT_REQUEST=""
            VLESS_AUTH="x25519"
            VLESS_ENC_FM_DRY_RUN="false"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        VLESS_ENC_FM_PORT_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --auth)
                        VLESS_AUTH="${2:-}"
                        shift; shift
                        ;;
                    --dry-run)
                        VLESS_ENC_FM_DRY_RUN="true"
                        shift
                        ;;
                    help | -h | --help)
                        show_enc_finalmask_usage
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 enc-finalmask install 参数: $1"
                        show_enc_finalmask_usage
                        return 1
                        ;;
                esac
            done
            case "$VLESS_AUTH" in
                x25519 | mlkem768) ;;
                *)
                    err "[ENC-FinalMask] --auth 仅支持 x25519 或 mlkem768。"
                    return 1
                    ;;
            esac
            if [[ "$VLESS_ENC_FM_DRY_RUN" == "true" ]]; then
                configure_vless_enc_finalmask "dry-run" && install_vless_enc_finalmask
            else
                prepare_system || return 1
                configure_vless_enc_finalmask "cli" && install_vless_enc_finalmask
            fi
            ;;
        show | "")
            init_state || return 1
            print_vless_enc_finalmask_result "show"
            ;;
        remove | delete | del)
            prepare_system || return 1
            remove_simple_inbound_config "$VLESS_ENC_FM_TAG" "$VLESS_ENC_FM_STATE_KEY" "VLESS Encryption + FinalMask"
            ;;
        *)
            err "[失败] 未知 enc-finalmask 参数: $action"
            show_enc_finalmask_usage
            return 1
            ;;
    esac
}

show_enc_xhttp_usage() {
    cat <<'EOF'
用法: ike enc-xhttp <install|show|remove> [选项]

  install              安装 VLESS Encryption + XHTTP (纯净, 无 FinalMask/REALITY)
    --port N           指定入口端口 (默认随机 20000-50000)
    --path P           指定 XHTTP path (默认随机)
    --auth TYPE        x25519 (默认) 或 mlkem768
    --dry-run          仅生成配置预览，不写入真实配置
  show                 查看当前配置与分享链接
  remove               删除该协议入站
EOF
}

run_enc_xhttp_command() {
    local action="${1:-show}"

    case "$action" in
        help | -h | --help)
            show_enc_xhttp_usage
            ;;
        install)
            shift
            ENC_XHTTP_PORT_REQUEST=""
            ENC_XHTTP_PATH_REQUEST=""
            VLESS_AUTH="x25519"
            ENC_XHTTP_DRY_RUN="false"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        ENC_XHTTP_PORT_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --path)
                        ENC_XHTTP_PATH_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --auth)
                        VLESS_AUTH="${2:-}"
                        shift; shift
                        ;;
                    --dry-run)
                        ENC_XHTTP_DRY_RUN="true"
                        shift
                        ;;
                    help | -h | --help)
                        show_enc_xhttp_usage
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 enc-xhttp install 参数: $1"
                        show_enc_xhttp_usage
                        return 1
                        ;;
                esac
            done
            case "$VLESS_AUTH" in
                x25519 | mlkem768) ;;
                *)
                    err "[ENC-XHTTP] --auth 仅支持 x25519 或 mlkem768。"
                    return 1
                    ;;
            esac
            if [[ "$ENC_XHTTP_DRY_RUN" == "true" ]]; then
                configure_vless_enc_xhttp "dry-run" && install_vless_enc_xhttp
            else
                prepare_system || return 1
                configure_vless_enc_xhttp "cli" && install_vless_enc_xhttp
            fi
            ;;
        show | "")
            init_state || return 1
            print_vless_enc_xhttp_result "show"
            ;;
        remove | delete | del)
            prepare_system || return 1
            remove_simple_inbound_config "$VLESS_ENC_XHTTP_TAG" "$VLESS_ENC_XHTTP_STATE_KEY" "VLESS Encryption + XHTTP"
            ;;
        *)
            err "[失败] 未知 enc-xhttp 参数: $action"
            show_enc_xhttp_usage
            return 1
            ;;
    esac
}

show_hysteria2_usage() {
    cat <<'EOF'
用法: ike hysteria2 <install|show|remove|rotate-cert|rotate-credentials> [选项]

  install              安装 Hysteria2 (QUIC/TLS 自签证书 + Salamander obfs)
    --port N           指定 UDP 端口 (首装默认 443)
    --sni DOMAIN       自签证书域名或 IPv4 (首装默认 localhost)
    --dry-run          仅生成配置预览，不写入真实配置
  show                 查看当前配置与分享链接
  remove               删除该协议入站及自签证书
  rotate-cert --yes [--sni DOMAIN]
                       轮换自签证书及私钥
  rotate-credentials --yes
                       轮换认证和 Salamander 密码

说明: 安装时会验证 Xray 的 Hysteria2 能力。兼容分享链接的 insecure=1 会跳过证书校验。
EOF
}

run_hysteria2_command() {
    local action="${1:-show}"
    local HY2_PORT_REQUEST="" HY2_SNI_REQUEST="" mode=cli confirmed=false

    case "$action" in
        help | -h | --help)
            show_hysteria2_usage
            ;;
        install | rotate-cert | rotate-credentials)
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        if [[ "$action" != "install" ]] || ! validate_port "${2:-}"; then
                            err "[Hysteria2] install --port 需要 1–65535 的端口。"
                            return 1
                        fi
                        HY2_PORT_REQUEST="$2"
                        shift 2
                        ;;
                    --sni)
                        if [[ "$action" == "rotate-credentials" ]] || ! is_valid_endpoint_hostname "${2:-}"; then
                            err "[Hysteria2] --sni 需要有效的域名或 IPv4 地址。"
                            return 1
                        fi
                        HY2_SNI_REQUEST="$2"
                        shift 2
                        ;;
                    --dry-run)
                        mode=dry-run
                        shift
                        ;;
                    --yes)
                        confirmed=true
                        shift
                        ;;
                    help | -h | --help)
                        show_hysteria2_usage
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 hysteria2 $action 参数: $1"
                        show_hysteria2_usage
                        return 1
                        ;;
                esac
            done
            if [[ "$action" != "install" && ( "$confirmed" != "true" || "$mode" == "dry-run" ) ]]; then
                err "[Hysteria2] 轮换会影响客户端，请使用 $action --yes 确认。"
                return 1
            fi
            install_hysteria2 "$mode" "$action"
            ;;
        show | "")
            print_hysteria2_result "show"
            ;;
        remove | delete | del)
            [[ $# -eq 1 ]] || { show_hysteria2_usage; return 1; }
            with_xray_lock remove_managed_hysteria2
            ;;
        *)
            err "[失败] 未知 hysteria2 参数: $action"
            show_hysteria2_usage
            return 1
            ;;
    esac
}

remove_managed_hysteria2() {
    prepare_system && check_xray_service_ownership && remove_hysteria2_config
}

show_advanced_profile_usage() {
    local kind="$1"

    case "$kind" in
        xhttp-reality)
            cat <<'EOF'
用法:
  ike xhttp-reality install [--port PORT] [--path /path] [--sni DOMAIN] [--flow none|vision] [--fallback-limit off|conservative] [--dry-run] [--yes]
  ike xhttp-reality show
  ike xhttp-reality remove
  ike view xhttp-reality
EOF
            ;;
        enc-reality)
            cat <<'EOF'
用法:
  ike enc-reality install [--port PORT] [--sni DOMAIN] [--flow none|vision] [--fallback-limit off|conservative] [--dry-run] [--yes] [--auth x25519|mlkem768]
  ike enc-reality show
  ike enc-reality remove
  ike view enc-reality
EOF
            ;;
        fullstack)
            cat <<'EOF'
用法:
  ike fullstack install [--port PORT] [--path /path] [--sni DOMAIN] [--flow none|vision] [--fallback-limit off|conservative] [--finalmask on|off] [--finalmask-preset conservative|balanced|aggressive] [--fm-length 100-200] [--fm-delay 10-20] [--fm-max-split 3-6] [--finalmask-json JSON] [--dry-run] [--yes] [--auth x25519|mlkem768]
  ike fullstack show
  ike fullstack remove
  ike view fullstack
EOF
            ;;
    esac
}

run_advanced_profile_command() {
    local kind="$1"
    local action="${2:-show}"

    case "$action" in
        help | -h | --help)
            show_advanced_profile_usage "$kind"
            ;;
        install)
            shift 2
            ADVANCED_PORT_REQUEST=""
            ADVANCED_PATH_REQUEST=""
            ADVANCED_SNI_REQUEST=""
            ADVANCED_FINALMASK_REQUEST="false"
            ADVANCED_FINALMASK_SPECIFIED="false"
            ADVANCED_FLOW="$REALITY_FLOW_NONE"
            ADVANCED_FALLBACK_LIMIT_REQUEST="off"
            FINALMASK_PRESET_REQUEST=""
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            ADVANCED_AUTH_SPECIFIED="false"
            ADVANCED_ASSUME_YES="false"
            ADVANCED_DRY_RUN="false"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        ADVANCED_PORT_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --path)
                        ADVANCED_PATH_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --sni)
                        ADVANCED_SNI_REQUEST="${2:-}"
                        shift; shift
                        ;;
                    --flow)
                        if [[ -z "${2:-}" ]] || ! ADVANCED_FLOW="$(normalize_reality_flow "$2")"; then
                            err "[高级组合] --flow 仅支持 none 或 vision。"
                            return 1
                        fi
                        shift; shift
                        ;;
                    --fallback-limit)
                        ADVANCED_FALLBACK_LIMIT_REQUEST="${2:-}"
                        case "${ADVANCED_FALLBACK_LIMIT_REQUEST}" in
                            off | conservative) ;;
                            *)
                                err "[高级组合] --fallback-limit 仅支持 off 或 conservative。"
                                return 1
                                ;;
                        esac
                        shift; shift
                        ;;
                    --finalmask)
                        ADVANCED_FINALMASK_REQUEST="${2:-}"
                        ADVANCED_FINALMASK_SPECIFIED="true"
                        shift; shift
                        ;;
                    --finalmask-preset | --fm-packets | --fm-length | --fm-delay | --fm-max-split | --finalmask-json)
                        if ! parse_finalmask_args "$1" "${2:-}"; then
                            return 1
                        fi
                        ADVANCED_FINALMASK_SPECIFIED="true"
                        shift "$FINALMASK_ARG_SHIFT"
                        ;;
                    --auth)
                        VLESS_AUTH="${2:-}"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift; shift
                        ;;
                    --enc-method)
                        VLESS_ENC_METHOD="${2:-}"
                        VLESS_MODE="advanced"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift; shift
                        ;;
                    --rtt)
                        VLESS_CLIENT_RTT="${2:-}"
                        VLESS_MODE="advanced"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift; shift
                        ;;
                    --ticket)
                        VLESS_SERVER_TICKET="${2:-}"
                        VLESS_MODE="advanced"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift; shift
                        ;;
                    --yes | -y)
                        ADVANCED_ASSUME_YES="true"
                        shift
                        ;;
                    --dry-run)
                        ADVANCED_DRY_RUN="true"
                        REALITY_SKIP_TLS_TEST="${REALITY_SKIP_TLS_TEST:-1}"
                        shift
                        ;;
                    help | -h | --help)
                        show_advanced_profile_usage "$kind"
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 ${kind} install 参数: $1"
                        show_advanced_profile_usage "$kind"
                        return 1
                        ;;
                esac
            done
            if [[ -n "$ADVANCED_PATH_REQUEST" ]] && ! advanced_profile_has_xhttp "$kind"; then
                err "[高级组合] ${kind} 不支持 --path。"
                return 1
            fi
            if [[ "$ADVANCED_FINALMASK_SPECIFIED" == "true" ]] && ! advanced_profile_has_finalmask "$kind"; then
                err "[高级组合] ${kind} 不支持 --finalmask。"
                return 1
            fi
            if [[ "$ADVANCED_AUTH_SPECIFIED" == "true" ]] && ! advanced_profile_has_encryption "$kind"; then
                err "[高级组合] ${kind} 不支持 VLESS Encryption 参数。"
                return 1
            fi
            if advanced_profile_has_encryption "$kind"; then
                case "$VLESS_AUTH" in
                    x25519 | mlkem768) ;;
                    *)
                        err "[高级组合] --auth 仅支持 x25519 或 mlkem768。"
                        return 1
                        ;;
                esac
            fi
            if [[ "$ADVANCED_DRY_RUN" == "true" ]]; then
                configure_advanced_profile "$kind" "dry-run" && install_advanced_profile "$kind"
            else
                prepare_system || return 1
                configure_advanced_profile "$kind" "cli" && install_advanced_profile "$kind"
            fi
            ;;
        show | "")
            init_state || return 1
            print_advanced_profile_result "$kind" "show"
            ;;
        remove | delete | del)
            prepare_system || return 1
            remove_advanced_profile_config "$kind"
            ;;
        *)
            err "[失败] 未知 ${kind} 参数: $action"
            show_advanced_profile_usage "$kind"
            return 1
            ;;
    esac
}

run_forward_command() {
    run_tunnel_command "$@"
}
