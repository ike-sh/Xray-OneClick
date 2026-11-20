#!/usr/bin/env bash
# Installer self-deployment: ike shortcut and lib/ sync.

install_shortcut() {
    local script_source="${IKE_SCRIPT_PATH:-${IKE_INSTALLER_DIR}/install.sh}"
    local source_lib destination_lib tmp_installer tmp_shortcut tmp_lib old_lib module

    script_source="$(readlink -f "$script_source" 2>/dev/null || printf '%s' "$script_source")"

    mkdir -p "$(dirname "$SHORTCUT_PATH")" "$INSTALLER_DIR" || return 1

    if [[ -d "${IKE_INSTALLER_DIR}/lib" ]]; then
        mkdir -p "${INSTALLER_DIR}/lib" || return 1
        source_lib="$(readlink -f "${IKE_INSTALLER_DIR}/lib" 2>/dev/null || printf '%s' "${IKE_INSTALLER_DIR}/lib")"
        destination_lib="$(readlink -f "${INSTALLER_DIR}/lib" 2>/dev/null || printf '%s' "${INSTALLER_DIR}/lib")"
        if [[ "$source_lib" != "$destination_lib" ]] && ! diff -qr "$source_lib" "$destination_lib" >/dev/null; then
            tmp_lib="$(mktemp -d "${INSTALLER_DIR}/lib.new.XXXXXX")" || return 1
            if ! cp -a "${source_lib}/." "$tmp_lib/"; then
                remove_managed_tree "$tmp_lib" >/dev/null 2>&1 || true
                return 1
            fi
            for module in "$tmp_lib"/*.sh; do
                [[ -f "$module" ]] || continue
                if ! bash -n "$module"; then
                    remove_managed_tree "$tmp_lib" >/dev/null 2>&1 || true
                    return 1
                fi
            done
            old_lib="$(mktemp -d "${INSTALLER_DIR}/lib.old.XXXXXX")" || {
                remove_managed_tree "$tmp_lib" >/dev/null 2>&1 || true
                return 1
            }
            if ! rmdir "$old_lib"; then
                remove_managed_tree "$tmp_lib" >/dev/null 2>&1 || true
                remove_managed_tree "$old_lib" >/dev/null 2>&1 || true
                return 1
            fi
            if ! mv "$destination_lib" "$old_lib"; then
                remove_managed_tree "$tmp_lib" >/dev/null 2>&1 || true
                return 1
            fi
            if ! mv "$tmp_lib" "$destination_lib"; then
                mv "$old_lib" "$destination_lib" >/dev/null 2>&1 || true
                remove_managed_tree "$tmp_lib" >/dev/null 2>&1 || true
                return 1
            fi
            remove_managed_tree "$old_lib" >/dev/null 2>&1 || true
        fi
    fi

    if [[ -f "$script_source" && -r "$script_source" ]]; then
        if [[ "$script_source" != "$INSTALLER_PATH" ]] && ! cmp -s "$script_source" "$INSTALLER_PATH"; then
            tmp_installer="$(mktemp "${INSTALLER_PATH}.tmp.XXXXXX")" || return 1
            cp "$script_source" "$tmp_installer" || {
                rm -f "$tmp_installer"
                return 1
            }
            chmod 755 "$tmp_installer" || {
                rm -f "$tmp_installer"
                return 1
            }
            mv "$tmp_installer" "$INSTALLER_PATH" || {
                rm -f "$tmp_installer"
                return 1
            }
        fi
        chmod +x "$INSTALLER_PATH" || return 1
    else
        tmp_installer="$(mktemp "${INSTALLER_PATH}.tmp.XXXXXX")" || return 1
        if ! download_one_url "https://raw.githubusercontent.com/${IKE_REPOSITORY}/${IKE_REF}/install.sh" "$tmp_installer" ||
            [[ ! -s "$tmp_installer" ]] || ! bash -n "$tmp_installer" ||
            ! chmod 755 "$tmp_installer" || ! mv "$tmp_installer" "$INSTALLER_PATH"; then
            rm -f "$tmp_installer"
            err "[系统] 无法保存当前 ref 的安装器文件。"
            return 1
        fi
    fi

    tmp_shortcut="$(mktemp "${SHORTCUT_PATH}.tmp.XXXXXX")" || return 1
    if ! cat >"$tmp_shortcut" <<EOF
#!/bin/bash
if [[ ! -f "$INSTALLER_PATH" ]]; then
    echo "未找到安装器脚本 $INSTALLER_PATH，请重新上传 install.sh 并执行安装。" >&2
    exit 1
fi
exec bash "$INSTALLER_PATH" "\$@"
EOF
    then
        rm -f "$tmp_shortcut"
        return 1
    fi
    chmod 755 "$tmp_shortcut" || {
        rm -f "$tmp_shortcut"
        return 1
    }
    if [[ -x "$SHORTCUT_PATH" ]] && cmp -s "$tmp_shortcut" "$SHORTCUT_PATH"; then
        rm -f "$tmp_shortcut"
        return
    fi
    mv "$tmp_shortcut" "$SHORTCUT_PATH" || {
        rm -f "$tmp_shortcut"
        return 1
    }
}
