#!/bin/bash
# shellcheck disable=SC2015

set -o pipefail

IKE_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IKE_SCRIPT_PATH="${IKE_INSTALLER_DIR}/${BASH_SOURCE[0]##*/}"
if [[ "$IKE_SCRIPT_PATH" == */ ]]; then IKE_SCRIPT_PATH+="install.sh"; fi
IKE_REPOSITORY="${XRAY_ONECLICK_REPO:-ike-sh/Xray-OneClick}"
IKE_REF="${XRAY_ONECLICK_REF:-main}"
IKE_LIB_RAW_BASE="${IKE_LIB_RAW_BASE:-https://raw.githubusercontent.com/${IKE_REPOSITORY}/${IKE_REF}/lib}"
IKE_LIB_MODULES=(
    "00-bootstrap.sh"
    "01-constants.sh"
    "02-output.sh"
    "03-installer.sh"
    "03-system.sh"
    "20-paths.sh"
    "40-network.sh"
    "41-safety.sh"
    "21-config-base.sh"
    "22-state.sh"
    "31-service.sh"
    "30-xray-core.sh"
    "50-vless-common.sh"
    "54-ss2022.sh"
    "50-vless-enc.sh"
    "51-reality.sh"
    "52-xhttp.sh"
    "53-advanced.sh"
    "55-socks.sh"
    "56-tunnel.sh"
    "57-hysteria2.sh"
    "70-view.sh"
    "71-cli-view.sh"
    "80-menu.sh"
    "63-diag.sh"
    "60-doctor.sh"
    "61-smoke.sh"
    "62-export.sh"
    "73-cli-migrate.sh"
    "72-cli-core.sh"
    "72-cli-admin.sh"
    "74-cli-protocols.sh"
    "90-test-harness.sh"
    "81-help.sh"
)

ike_ensure_lib_modules() {
    local root_dir="$1"
    local lib_dir="${root_dir}/lib"
    local module tmp_module missing=()

    mkdir -p "$lib_dir" || return 1
    for module in "${IKE_LIB_MODULES[@]}"; do
        [[ -s "${lib_dir}/${module}" ]] || missing+=("$module")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "Xray-OneClick: 缺少 lib/ 模块且无法下载（需要 curl 或 wget）。" >&2
        echo "请从完整仓库安装，或将 lib/ 目录与 install.sh 放在同一目录。" >&2
        return 1
    fi

    for module in "${missing[@]}"; do
        tmp_module="$(mktemp "${lib_dir}/.${module}.XXXXXX")" || return 1
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 10 --max-time 30 --retry 1 "${IKE_LIB_RAW_BASE}/${module}" -o "$tmp_module" || {
                rm -f "$tmp_module"
                return 1
            }
        else
            wget -q -T 20 -O "$tmp_module" "${IKE_LIB_RAW_BASE}/${module}" || {
                rm -f "$tmp_module"
                return 1
            }
        fi
        if [[ ! -s "$tmp_module" ]] || ! bash -n "$tmp_module"; then
            rm -f "$tmp_module"
            echo "Xray-OneClick: 下载的模块无效: ${module}" >&2
            return 1
        fi
        mv "$tmp_module" "${lib_dir}/${module}" || {
            rm -f "$tmp_module"
            return 1
        }
    done
}

for ike_module in "${IKE_LIB_MODULES[@]}"; do
    [[ -s "$IKE_INSTALLER_DIR/lib/$ike_module" ]] && continue
    # Standalone installers and previews fetch a private, consistent module set.
    IKE_MODULE_STAGE="$(mktemp -d)" || exit 1
    trap 'rm -rf -- "$IKE_MODULE_STAGE"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ike_ensure_lib_modules "$IKE_MODULE_STAGE" || exit 1
    IKE_INSTALLER_DIR="$IKE_MODULE_STAGE"
    break
done
unset ike_module

# shellcheck source=lib/00-bootstrap.sh disable=SC1091
source "${IKE_INSTALLER_DIR}/lib/00-bootstrap.sh"

main() {
    case "${1:-}" in
        help | -h | --help)
            show_help
            return 0
            ;;
        version | --version)
            show_version
            return 0
            ;;
        "" | preflight | view | doctor | smoke | export | xray | migrate | uninstall | update | backup | endpoint | config | service | logs | cnblock | safety | tunnel | forward | reality | xhttp | enc-finalmask | enc-xhttp | hysteria2 | xhttp-reality | enc-reality | fullstack | bootstrap | test-config-generate) ;;
        *)
            err "[失败] 未知命令: $1"
            echo "运行 ike help 查看可用命令。"
            return 1
            ;;
    esac

    if [[ "${1:-}" == "preflight" ]]; then
        shift
        run_preflight_command "$@"
        return $?
    fi

    if [[ "${1:-}" == "test-config-generate" ]]; then
        shift
        run_test_config_generate_command "$@"
        return $?
    fi

    ensure_root
    check_os
    detect_arch
    if [[ $# -eq 0 ]]; then
        # bootstrap via a pipe needs its controlling terminal for the menu.
        local menu_tty
        if [[ ! -t 0 ]] && { exec {menu_tty}</dev/tty; } 2>/dev/null; then
            exec <&"$menu_tty"
            exec {menu_tty}<&-
        fi
        show_menu
        return
    fi

    case "$1:${2:-}" in
        view:* | doctor:* | smoke:* | export:* | logs:* | xray:version | xray: | hysteria2:*)
            run_installer_action "$@"
            return
            ;;
        migrate:* | uninstall:* | xray:upgrade | reality:install | xhttp:install | enc-finalmask:install | \
        enc-xhttp:install | xhttp-reality:install | enc-reality:install | fullstack:install)
            local arg
            for arg in "$@"; do
                if [[ "$arg" == "--dry-run" ]]; then
                    run_installer_action "$@"
                    return
                fi
            done
            ;;
    esac
    with_xray_lock run_installer_action "$@"
}

run_installer_action() {
    case "${1:-}" in
        view)
            shift
            run_view_command "$@"
            ;;
        xray)
            shift
            run_xray_command "$@"
            ;;
        migrate)
            shift
            run_migrate_command "$@"
            ;;
        uninstall)
            shift
            run_uninstall_command "$@"
            ;;
        doctor)
            shift
            run_doctor_command "$@"
            ;;
        smoke)
            shift
            run_smoke_command "$@"
            ;;
        export)
            shift
            run_export_command "$@"
            ;;
        update)
            shift
            [[ $# -eq 0 ]] || {
                err "[失败] update 不接受额外参数；如需选择版本请使用 ike xray upgrade。"
                return 1
            }
            update_xray_core
            ;;
        backup)
            shift
            [[ $# -eq 0 ]] || {
                err "[失败] backup 不接受额外参数。"
                return 1
            }
            export_current_config_backup
            ;;
        endpoint)
            shift
            run_endpoint_command "$@"
            ;;
        config)
            shift
            run_config_command "$@"
            ;;
        service)
            shift
            run_service_command "$@"
            ;;
        logs)
            shift
            run_logs_command "$@"
            ;;
        cnblock)
            shift
            run_cnblock_command "$@"
            ;;
        safety)
            shift
            run_safety_command "$@"
            ;;
        tunnel)
            shift
            run_tunnel_command "$@"
            ;;
        forward)
            shift
            run_forward_command "$@"
            ;;
        reality)
            shift
            run_reality_command "$@"
            ;;
        xhttp)
            shift
            run_xhttp_command "$@"
            ;;
        enc-finalmask)
            shift
            run_enc_finalmask_command "$@"
            ;;
        enc-xhttp)
            shift
            run_enc_xhttp_command "$@"
            ;;
        hysteria2)
            shift
            run_hysteria2_command "$@"
            ;;
        xhttp-reality)
            run_advanced_profile_command "xhttp-reality" "${2:-show}" "${@:3}"
            ;;
        enc-reality)
            run_advanced_profile_command "enc-reality" "${2:-show}" "${@:3}"
            ;;
        fullstack)
            run_advanced_profile_command "fullstack" "${2:-show}" "${@:3}"
            ;;
        bootstrap)
            shift
            run_bootstrap_command "$@"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi


