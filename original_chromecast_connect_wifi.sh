#!/usr/bin/env bash

## Used https://emcot.world/How_To_Connect_a_Gen_1_H2G2_42_Chromecast_Without_Google_Home
## as reference.
## Used OpenAI GPT-5.6 Sol for assistance.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --ssid SSID

Options:
    --firmware <old|new>   Firmware generation
                           old: http://192.168.255.249:8008
                           new: https://192.168.255.249:8443

    --ssid SSID            Wi-Fi SSID to connect to

    -h, --help             Show this help message

Assumptions:
    Chromecast has been factory reset.

The Wi-Fi password will be requested interactively and will not be echoed.
EOF
}

error() {
  printf 'ERROR: %s\n' "$*" >&2
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Required command not found: $1"
    exit 1
  fi
}

main() {
  local firmware=""
  local ssid=""
  local wifi_password=""
  local base_url=""

  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --firmware)
      if [[ $# -lt 2 ]]; then
        error "--firmware requires a value"
        exit 1
      fi

      firmware="$2"
      shift 2
      ;;
    --ssid)
      if [[ $# -lt 2 ]]; then
        error "--ssid requires a value"
        exit 1
      fi

      ssid="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      error "Unknown argument: $1"
      usage >&2
      exit 1
      ;;
    esac
  done

  if [[ -z "${firmware}" ]]; then
    error "--firmware is required"
    usage >&2
    exit 1
  fi

  if [[ -z "${ssid}" ]]; then
    error "--ssid is required"
    usage >&2
    exit 1
  fi

  case "${firmware}" in
  old)
    base_url="http://192.168.255.249:8008"
    ;;
  new)
    base_url="https://192.168.255.249:8443"
    ;;
  *)
    error "Invalid firmware: ${firmware}"
    error "Expected 'old' or 'new'"
    exit 1
    ;;
  esac

  require_command curl
  require_command jq
  require_command openssl

  read -r -s -p "Wi-Fi password: " wifi_password
  printf '\n'

  if [[ -z "${wifi_password}" ]]; then
    error "Wi-Fi password cannot be empty"
    exit 1
  fi

  echo "Get device RSA public key..."
  local public_key
  public_key="$(
    curl -kfsS --tlsv1.2 --tls-max 1.2 \
      "${base_url}/setup/eureka_info" |
      jq -er '.public_key'
  )"
  echo "Success"

  echo "Scan for Wi-Fi networks..."
  curl -kfsS --tlsv1.2 --tls-max 1.2 \
    "${base_url}/setup/scan_wifi" \
    >/dev/null || true

  sleep 3
  echo "Success"

  echo "Find the requested SSID and extract its authentication settings..."
  local wpa_auth
  local wpa_cipher

  read -r wpa_auth wpa_cipher < <(
    curl -kfsS --tlsv1.2 --tls-max 1.2 \
      "${base_url}/setup/scan_results" |
      jq -er --arg ssid "${ssid}" '
            .[]
            | select(.ssid == $ssid)
            | [.wpa_auth, .wpa_cipher]
            | @tsv
        '
  )
  echo "Success"

  echo "Encrypt the Wi-Fi password using the device's RSA public key..."
  local public_key_pem
  public_key_pem="$(
    printf '%s\n%s\n%s\n' \
      '-----BEGIN RSA PUBLIC KEY-----' \
      "${public_key}" \
      '-----END RSA PUBLIC KEY-----'
  )"

  local encrypted_password
  encrypted_password="$(
    openssl pkeyutl \
      -encrypt \
      -pubin \
      -inkey <(printf '%s' "${public_key_pem}") \
      -pkeyopt rsa_padding_mode:pkcs1 \
      -in <(printf '%s' "${wifi_password}") |
      openssl base64 -A
  )"
  echo "Success"

  echo "Send Wi-Fi configuration to the device..."
  local connect_payload
  connect_payload="$(
    jq -n \
      --arg ssid "${ssid}" \
      --arg enc_passwd "${encrypted_password}" \
      --argjson wpa_auth "${wpa_auth}" \
      --argjson wpa_cipher "${wpa_cipher}" \
      '{
                ssid: $ssid,
                wpa_auth: $wpa_auth,
                wpa_cipher: $wpa_cipher,
                enc_passwd: $enc_passwd
            }'
  )"

  curl -kfsS --tlsv1.2 --tls-max 1.2 \
    -H "content-type: application/json" \
    -d "${connect_payload}" \
    "${base_url}/setup/connect_wifi"
  echo "Success"

  echo "Commit the Wi-Fi configuration..."
  curl -kfsS --tlsv1.2 --tls-max 1.2 \
    -H "content-type: application/json" \
    -d '{"keep_hotspot_until_connected": true}' \
    "${base_url}/setup/save_wifi"
  printf '\n'
  echo "Success"
}

main "$@"
