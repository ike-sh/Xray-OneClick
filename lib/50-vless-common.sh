#!/usr/bin/env bash
# VLESS Encryption pair generation helpers.

xray_supports_vlessenc() {
    timeout 10 "$1" vlessenc 2>/dev/null | grep '"decryption"' >/dev/null
}

ensure_xray_vlessenc() {
    install_or_update_xray false if-active xray_supports_vlessenc
}

generate_vless_encryption_pair() {
    local auth="$1"
    local output dec_line enc_line

    if env_truthy "${IKE_TEST_MODE:-}" && [[ ! -x "$BIN_PATH" ]]; then
        VLESS_DECRYPTION="test-decryption-${auth:-x25519}.native.600s"
        VLESS_ENCRYPTION="test-encryption-${auth:-x25519}.native.0rtt"
        VLESS_ENC_METHOD="${VLESS_ENC_METHOD:-native}"
        VLESS_CLIENT_RTT="${VLESS_CLIENT_RTT:-0rtt}"
        VLESS_SERVER_TICKET="${VLESS_SERVER_TICKET:-600s}"
        return 0
    fi

    output="$("$BIN_PATH" vlessenc 2>/dev/null)" || {
        err "[VLESS] xray vlessenc 执行失败，请确认 Xray 版本支持 VLESS Encryption。"
        return 1
    }

    if [[ "$auth" == "mlkem768" ]]; then
        dec_line="$(echo "$output" | grep '"decryption"' | tail -n 1)"
        enc_line="$(echo "$output" | grep '"encryption"' | tail -n 1)"
    else
        dec_line="$(echo "$output" | grep '"decryption"' | head -n 1)"
        enc_line="$(echo "$output" | grep '"encryption"' | head -n 1)"
    fi

    VLESS_DECRYPTION="$(echo "$dec_line" | sed -n 's/.*"decryption": "\([^"]*\)".*/\1/p')"
    VLESS_ENCRYPTION="$(echo "$enc_line" | sed -n 's/.*"encryption": "\([^"]*\)".*/\1/p')"

    if [[ -z "$VLESS_DECRYPTION" || -z "$VLESS_ENCRYPTION" ]]; then
        err "[VLESS] 无法解析 xray vlessenc 输出。"
        return 1
    fi

    VLESS_ENC_METHOD="${VLESS_ENC_METHOD:-native}"
    VLESS_CLIENT_RTT="${VLESS_CLIENT_RTT:-0rtt}"
    VLESS_SERVER_TICKET="${VLESS_SERVER_TICKET:-600s}"

    VLESS_DECRYPTION="$(rewrite_vlessenc_blocks "server" "$VLESS_DECRYPTION" "$VLESS_ENC_METHOD" "$VLESS_SERVER_TICKET")" || return 1
    VLESS_ENCRYPTION="$(rewrite_vlessenc_blocks "client" "$VLESS_ENCRYPTION" "$VLESS_ENC_METHOD" "$VLESS_CLIENT_RTT")" || return 1
}

rewrite_vlessenc_blocks() {
    local side="$1"
    local value="$2"
    local method="$3"
    local third_block="$4"
    local old_ifs auth_block result i
    local -a VLESS_BLOCKS

    case "$method" in
        native | xorpub | random) ;;
        *)
            err "[VLESS] 不支持的外观混淆方法: $method"
            return 1
            ;;
    esac

    case "$side" in
        server)
            if [[ ! "$third_block" =~ ^[0-9]+s$ && ! "$third_block" =~ ^[0-9]+-[0-9]+s$ ]]; then
                err "[VLESS] 服务端 ticket 有效期格式无效: $third_block"
                return 1
            fi
            ;;
        client)
            if [[ "$third_block" != "0rtt" && "$third_block" != "1rtt" ]]; then
                err "[VLESS] 客户端握手模式无效: $third_block"
                return 1
            fi
            ;;
        *)
            err "[VLESS] 内部错误：未知 VLESS Encryption 侧别: $side"
            return 1
            ;;
    esac

    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        err "[VLESS] vlessenc 字符串包含非法换行。"
        return 1
    fi

    old_ifs="$IFS"
    IFS='.'
    read -r -a VLESS_BLOCKS <<<"$value"
    IFS="$old_ifs"

    if ((${#VLESS_BLOCKS[@]} < 4)); then
        err "[VLESS] vlessenc 字符串 block 数不足，无法安全改写。"
        return 1
    fi

    if [[ "${VLESS_BLOCKS[0]}" != "mlkem768x25519plus" ]]; then
        err "[VLESS] 未识别的握手方法: ${VLESS_BLOCKS[0]}"
        return 1
    fi

    case "${VLESS_BLOCKS[1]}" in
        native | xorpub | random) ;;
        *)
            err "[VLESS] 未识别的原始外观混淆方法: ${VLESS_BLOCKS[1]}"
            return 1
            ;;
    esac

    auth_block="${VLESS_BLOCKS[$((${#VLESS_BLOCKS[@]} - 1))]}"
    if [[ -z "$auth_block" || ! "$auth_block" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "[VLESS] 认证参数 block 无效，已中止改写。"
        return 1
    fi

    VLESS_BLOCKS[1]="$method"
    VLESS_BLOCKS[2]="$third_block"

    result="${VLESS_BLOCKS[0]}"
    for ((i = 1; i < ${#VLESS_BLOCKS[@]}; i++)); do
        result="${result}.${VLESS_BLOCKS[$i]}"
    done

    printf '%s' "$result"
}
