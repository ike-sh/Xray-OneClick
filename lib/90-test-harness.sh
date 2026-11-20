#!/usr/bin/env bash
# Offline test-config-generate harness.

setup_test_config_generation_env() {
    local root="${IKE_TEST_ROOT:-}"
    local root_parent
    local detected_xray=""

    if [[ -z "$root" ]]; then
        root_parent="${IKE_TEST_TMP_PARENT:-${PWD:-.}/.tmp}"
        mkdir -p "$root_parent" || return 1
        root="$(mktemp -d "${root_parent}/config-generation.XXXXXX")" || return 1
        IKE_TEST_ROOT="$root"
    fi
    mkdir -p "$root" || return 1

    CONFIG_DIR="${root}/etc/xray"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    ASSET_DIR="${root}/share/xray"
    INSTALLER_DIR="${root}/share/ike"
    INSTALLER_PATH="${INSTALLER_DIR}/install.sh"
    SHORTCUT_PATH="${root}/bin/ike"
    mkdir -p "$CONFIG_DIR" "$ASSET_DIR" "$INSTALLER_DIR" "${root}/bin" || return 1
    mkdir -p "${root}/tmp" || return 1
    export TMPDIR="${root}/tmp"

    if [[ -n "${XRAY_BIN:-}" ]]; then
        BIN_PATH="$XRAY_BIN"
    elif detected_xray="$(command -v xray 2>/dev/null)"; then
        BIN_PATH="$detected_xray"
    else
        BIN_PATH="${root}/bin/xray-missing"
    fi

    IKE_CONFIG_OUT="${IKE_CONFIG_OUT:-${root}/config.json}"
    IKE_TEST_MODE="1"
    REALITY_SKIP_TLS_TEST="1"
    XRAY_ONECLICK_YES="1"
    CURRENT_LINK_VIEW_MODE="ipv4"
    IPV4_HOST="${IPV4_HOST:-203.0.113.10}"
    init_config || return 1
    init_state || return 1
}

run_test_config_generate_command() {
    local profile="${1:-}"
    local port="" defender_port="" path="" sni="www.microsoft.com"
    local finalmask="" finalmask_preset="balanced" fallback_limit="off"
    local kind=""

    [[ -n "$profile" ]] || {
        err "[test] usage: test-config-generate PROFILE [--output FILE]"
        return 1
    }
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                IKE_CONFIG_OUT="${2:-}"
                [[ -n "$IKE_CONFIG_OUT" ]] || {
                    err "[test] --output requires a file path"
                    return 1
                }
                shift; shift
                ;;
            --port)
                port="${2:-}"
                shift; shift
                ;;
            --defender-port)
                defender_port="${2:-}"
                shift; shift
                ;;
            --path)
                path="${2:-}"
                shift; shift
                ;;
            --sni)
                sni="${2:-}"
                shift; shift
                ;;
            --finalmask)
                finalmask="${2:-}"
                shift; shift
                ;;
            --finalmask-preset)
                finalmask_preset="${2:-balanced}"
                shift; shift
                ;;
            --fallback-limit)
                fallback_limit="${2:-off}"
                shift; shift
                ;;
            *)
                err "[test] unknown test-config-generate option: $1"
                return 1
                ;;
        esac
    done

    setup_test_config_generation_env || return 1

    case "$profile" in
        reality)
            REALITY_PORT_REQUEST="${port:-30004}"
            REALITY_DEFENDER_PORT_REQUEST="${defender_port:-40004}"
            REALITY_SNI_REQUEST="$sni"
            REALITY_EMPTY_CLIENTS="false"
            REALITY_ASSUME_YES="true"
            REALITY_FLOW="$REALITY_FLOW_DEFAULT"
            REALITY_DRY_RUN="true"
            configure_reality "dry-run" && install_reality
            ;;
        xhttp-off | xhttp)
            XHTTP_PORT_REQUEST="${port:-30005}"
            XHTTP_PATH_REQUEST="${path:-/api/offline}"
            XHTTP_FINALMASK_REQUEST="${finalmask:-off}"
            FINALMASK_PRESET_REQUEST=""
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            XHTTP_DRY_RUN="true"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            configure_vless_xhttp_finalmask "dry-run" && install_vless_xhttp_finalmask
            ;;
        xhttp-balanced | xhttp-finalmask-balanced)
            XHTTP_PORT_REQUEST="${port:-30005}"
            XHTTP_PATH_REQUEST="${path:-/api/balanced}"
            XHTTP_FINALMASK_REQUEST="${finalmask:-on}"
            FINALMASK_PRESET_REQUEST="${finalmask_preset:-balanced}"
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            XHTTP_DRY_RUN="true"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            configure_vless_xhttp_finalmask "dry-run" && install_vless_xhttp_finalmask
            ;;
        xhttp-reality | enc-reality | fullstack)
            case "$profile" in
                xhttp-reality)
                    kind="xhttp-reality"
                    port="${port:-30006}"
                    path="${path:-/api/xhttp-reality}"
                    finalmask="off"
                    ;;
                enc-reality)
                    kind="enc-reality"
                    port="${port:-30007}"
                    path=""
                    finalmask="off"
                    ;;
                fullstack)
                    kind="fullstack"
                    port="${port:-30008}"
                    path="${path:-/api/fullstack}"
                    finalmask="${finalmask:-off}"
                    ;;
            esac
            ADVANCED_PORT_REQUEST="$port"
            ADVANCED_PATH_REQUEST="$path"
            ADVANCED_SNI_REQUEST="$sni"
            ADVANCED_FINALMASK_REQUEST="$finalmask"
            ADVANCED_FINALMASK_SPECIFIED="true"
            ADVANCED_FLOW="$REALITY_FLOW_NONE"
            ADVANCED_FALLBACK_LIMIT_REQUEST="$fallback_limit"
            FINALMASK_PRESET_REQUEST="${finalmask_preset:-balanced}"
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            ADVANCED_AUTH_SPECIFIED="false"
            ADVANCED_ASSUME_YES="true"
            ADVANCED_DRY_RUN="true"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            configure_advanced_profile "$kind" "dry-run" && install_advanced_profile "$kind"
            ;;
        enc-finalmask | vless-enc-finalmask)
            VLESS_ENC_FM_PORT_REQUEST="${port:-30010}"
            VLESS_ENC_FM_DRY_RUN="true"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            configure_vless_enc_finalmask "dry-run" && install_vless_enc_finalmask
            ;;
        enc-xhttp | vless-enc-xhttp)
            ENC_XHTTP_PORT_REQUEST="${port:-30011}"
            ENC_XHTTP_PATH_REQUEST="${path:-/api/enc-xhttp}"
            ENC_XHTTP_DRY_RUN="true"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            configure_vless_enc_xhttp "dry-run" && install_vless_enc_xhttp
            ;;
        hysteria2 | hy2)
            HY2_PORT_REQUEST="${port:-30012}"
            HY2_SNI_REQUEST="$sni"
            install_hysteria2 dry-run
            ;;
        *)
            err "[test] unknown profile: $profile"
            return 1
            ;;
    esac

    [[ -s "$IKE_CONFIG_OUT" ]] || {
        err "[test] offline config was not written: $IKE_CONFIG_OUT"
        return 1
    }
}
