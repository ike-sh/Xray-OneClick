#!/usr/bin/env bash
# Xray-OneClick terminal output helpers.

info() { echo -e "${YELLOW}$*${PLAIN}"; }
ok() { echo -e "${GREEN}$*${PLAIN}"; }
err() { echo -e "${RED}$*${PLAIN}" >&2; }

die() {
    err "$*"
    exit 1
}

env_truthy() {
    local value="${1:-}"

    case "${value,,}" in
        1 | true | yes | y | on) return 0 ;;
        *) return 1 ;;
    esac
}
