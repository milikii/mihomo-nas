#!/usr/bin/env bash

set -euo pipefail

SCRIPT_VERSION="${SCRIPT_VERSION:-0.5.0}"

APP_ROOT="${APP_ROOT:-/usr/local/lib/mihomo-manager}"
STATECTL="${STATECTL:-${APP_ROOT}/scripts/statectl.py}"

MIHOMO_DIR="${MIHOMO_DIR:-/etc/mihomo}"
MIHOMO_BIN="${MIHOMO_BIN:-/usr/local/bin/mihomo-core}"
MIHOMO_USER="${MIHOMO_USER:-mihomo}"
MANAGER_BIN="${MANAGER_BIN:-/usr/local/bin/mihomo}"
COMPAT_MANAGER_BIN="${COMPAT_MANAGER_BIN:-/usr/local/bin/mihomo-sidecar.sh}"

ROUTER_ENV="${ROUTER_ENV:-${MIHOMO_DIR}/router.env}"
SETTINGS_ENV="${SETTINGS_ENV:-${MIHOMO_DIR}/settings.env}"
CONFIG_FILE="${CONFIG_FILE:-${MIHOMO_DIR}/config.yaml}"
RULES_DIR="${RULES_DIR:-${MIHOMO_DIR}/ruleset}"
PROVIDER_DIR="${PROVIDER_DIR:-${MIHOMO_DIR}/proxy_providers}"
UI_DIR="${UI_DIR:-${MIHOMO_DIR}/ui}"
COUNTRY_MMDB="${COUNTRY_MMDB:-${MIHOMO_DIR}/Country.mmdb}"
STATE_DIR="${STATE_DIR:-${MIHOMO_DIR}/state}"
NODES_STATE_FILE="${NODES_STATE_FILE:-${STATE_DIR}/nodes.json}"
RULES_STATE_FILE="${RULES_STATE_FILE:-${STATE_DIR}/rules.json}"
ACL_STATE_FILE="${ACL_STATE_FILE:-${STATE_DIR}/acl.json}"
SUBSCRIPTIONS_STATE_FILE="${SUBSCRIPTIONS_STATE_FILE:-${STATE_DIR}/subscriptions.json}"
PROVIDER_FILE="${PROVIDER_FILE:-${PROVIDER_DIR}/manual.txt}"
RENDERED_RULES_FILE="${RENDERED_RULES_FILE:-${RULES_DIR}/custom.rules}"
ACL_RENDERED_RULES_FILE="${ACL_RENDERED_RULES_FILE:-${RULES_DIR}/acl.rules}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-${STATE_DIR}/snapshots}"

ROUTER_SYSCTL="${ROUTER_SYSCTL:-/etc/sysctl.d/99-mihomo-router.conf}"
SYSTEMD_UNIT="${SYSTEMD_UNIT:-/etc/systemd/system/mihomo.service}"
RESTART_SERVICE_UNIT="${RESTART_SERVICE_UNIT:-/etc/systemd/system/mihomo-restart.service}"
RESTART_TIMER_UNIT="${RESTART_TIMER_UNIT:-/etc/systemd/system/mihomo-restart.timer}"
UPDATE_SERVICE_UNIT="${UPDATE_SERVICE_UNIT:-/etc/systemd/system/mihomo-alpha-update.service}"
UPDATE_TIMER_UNIT="${UPDATE_TIMER_UNIT:-/etc/systemd/system/mihomo-alpha-update.timer}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[i]${NC} $*"; }
ok() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die() { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

user_exists() {
  id "$1" >/dev/null 2>&1
}

systemctl_cmd() {
  if [[ -n "${SYSTEMCTL_BIN:-}" ]]; then
    "$SYSTEMCTL_BIN" "$@"
  else
    systemctl "$@"
  fi
}

journalctl_cmd() {
  if [[ -n "${JOURNALCTL_BIN:-}" ]]; then
    "$JOURNALCTL_BIN" "$@"
  else
    journalctl "$@"
  fi
}

ss_cmd() {
  if [[ -n "${SS_BIN:-}" ]]; then
    "$SS_BIN" "$@"
  else
    ss "$@"
  fi
}

curl_cmd() {
  if [[ -n "${CURL_BIN:-}" ]]; then
    "$CURL_BIN" "$@"
  else
    curl "$@"
  fi
}

git_cmd() {
  if [[ -n "${GIT_BIN:-}" ]]; then
    "$GIT_BIN" "$@"
  else
    git "$@"
  fi
}

systemctl_show_value() {
  local unit="$1"
  local prop="$2"
  systemctl_cmd show "$unit" -p "$prop" --value 2>/dev/null || true
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请用 root 运行: sudo mihomo"
}

require_statectl() {
  [[ -x "$STATECTL" ]] || die "未找到状态工具: $STATECTL"
}

ensure_state_files() {
  require_statectl
  python3 "$STATECTL" ensure-nodes-state "$NODES_STATE_FILE" "$PROVIDER_FILE" >/dev/null
  python3 "$STATECTL" ensure-rules-state "$RULES_STATE_FILE" "$RENDERED_RULES_FILE" >/dev/null
  python3 "$STATECTL" ensure-rules-state "$ACL_STATE_FILE" >/dev/null
  python3 "$STATECTL" ensure-subscriptions-state "$SUBSCRIPTIONS_STATE_FILE" >/dev/null
}

iptables_cmd() {
  if [[ -n "${IPTABLES_BIN:-}" ]]; then
    "$IPTABLES_BIN" "$@"
  else
    iptables "$@"
  fi
}

ipt() {
  iptables_cmd -w 5 "$@"
}

controller_scope_summary() {
  CONTROLLER_HOST="${CONTROLLER_BIND_ADDRESS:-127.0.0.1}"
  CONTROLLER_SCOPE="仅宿主机"
  if [[ "$CONTROLLER_HOST" == "0.0.0.0" || "$CONTROLLER_HOST" == "*" ]]; then
    CONTROLLER_HOST="$(detect_iface_ip "${PROXY_INGRESS_INTERFACES%% *}" 2>/dev/null || echo 127.0.0.1)"
    CONTROLLER_SCOPE="局域网可访问(高风险)"
  fi
}

random_secret() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-24
}

cidr_network() {
  local cidr="$1"
  [[ -n "$cidr" ]] || return 1
  python3 - "$cidr" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
}

detect_default_iface() {
  ip -o route get 1.1.1.1 | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev" && (i + 1) <= NF) {
          print $(i + 1)
          exit
        }
      }
    }
  '
}

detect_iface_cidr() {
  local iface="$1"
  ip -o -4 addr show dev "$iface" scope global | awk 'NR == 1 { print $4 }'
}

detect_iface_ip() {
  local iface="$1"
  detect_iface_cidr "$iface" | cut -d/ -f1
}

detect_iface_networks() {
  local ifaces="$1"
  local iface
  local cidr
  local networks=()

  read -r -a iface_arr <<< "$ifaces"
  for iface in "${iface_arr[@]}"; do
    [[ -n "$iface" ]] || continue
    cidr="$(detect_iface_cidr "$iface" || true)"
    [[ -n "$cidr" ]] || continue
    cidr="$(cidr_network "$cidr" 2>/dev/null || printf '%s' "$cidr")"
    [[ -n "$cidr" ]] && networks+=("$cidr")
  done

  [[ ${#networks[@]} -gt 0 ]] || return 0
  printf '%s
' "${networks[@]}" | sort -u | xargs
}

escape_env_value() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

upsert_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped
  local tmp

  escaped="$(escape_env_value "$value")"
  tmp="$(mktemp)"

  if [[ -f "$file" ]]; then
    awk -v key="$key" '
      $0 ~ "^" key "=" { next }
      { print }
    ' "$file" >"$tmp"
  fi

  printf '%s="%s"\n' "$key" "$escaped" >>"$tmp"
  mv "$tmp" "$file"
}

read_env_var() {
  local file="$1"
  local key="$2"
  local fallback="${3:-}"
  if [[ ! -f "$file" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi
  awk -F= -v key="$key" -v fallback="$fallback" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      found = 1
      exit
    }
    END {
      if (!found) {
        print fallback
      }
    }
  ' "$file"
}

have_global_ipv6() {
  ip -6 route show default 2>/dev/null | grep -q .
}

default_profile_template() {
  if have_global_ipv6; then
    printf '%s\n' "nas-single-lan-dualstack"
  else
    printf '%s\n' "nas-single-lan-v4"
  fi
}

template_exists() {
  case "$1" in
    nas-single-lan-v4|nas-single-lan-dualstack|nas-multi-bridge|nas-explicit-proxy-only) return 0 ;;
    *) return 1 ;;
  esac
}

template_summary() {
  case "$1" in
    nas-single-lan-v4) printf '%s\n' "单 LAN IPv4 旁路由" ;;
    nas-single-lan-dualstack) printf '%s\n' "单 LAN 双栈旁路由" ;;
    nas-multi-bridge) printf '%s\n' "多 bridge/VLAN 旁路由" ;;
    nas-explicit-proxy-only) printf '%s\n' "仅显式代理，不接管 LAN" ;;
    *) printf '%s\n' "未知模板" ;;
  esac
}

current_profile_template() {
  if [[ -f "$ROUTER_ENV" ]]; then
    read_env_var "$ROUTER_ENV" "TEMPLATE_NAME" "$(read_env_var "$SETTINGS_ENV" "PROFILE_TEMPLATE" "$(default_profile_template)")"
  else
    read_env_var "$SETTINGS_ENV" "PROFILE_TEMPLATE" "$(default_profile_template)"
  fi
}

write_router_env_from_template() {
  local template_name="$1"
  template_exists "$template_name" || die "未知模板: ${template_name}"

  local existing_mixed_port="7890"
  local existing_tproxy_port="7893"
  local existing_dns_port="1053"
  local existing_controller_port="19090"
  local existing_controller_bind="127.0.0.1"
  local existing_route_mark="0x2333"
  local existing_route_mask="0xffffffff"
  local existing_route_table="233"
  local existing_route_priority="100"
  local existing_host_output="0"
  local existing_bypass_src=""
  local existing_bypass_dst=""
  local existing_bypass_uids=""

  if [[ -f "$ROUTER_ENV" ]]; then
    existing_mixed_port="$(read_env_var "$ROUTER_ENV" "MIXED_PORT" "$existing_mixed_port")"
    existing_tproxy_port="$(read_env_var "$ROUTER_ENV" "TPROXY_PORT" "$existing_tproxy_port")"
    existing_dns_port="$(read_env_var "$ROUTER_ENV" "DNS_PORT" "$existing_dns_port")"
    existing_controller_port="$(read_env_var "$ROUTER_ENV" "CONTROLLER_PORT" "$existing_controller_port")"
    existing_controller_bind="$(read_env_var "$ROUTER_ENV" "CONTROLLER_BIND_ADDRESS" "$existing_controller_bind")"
    existing_route_mark="$(read_env_var "$ROUTER_ENV" "ROUTE_MARK" "$existing_route_mark")"
    existing_route_mask="$(read_env_var "$ROUTER_ENV" "ROUTE_MASK" "$existing_route_mask")"
    existing_route_table="$(read_env_var "$ROUTER_ENV" "ROUTE_TABLE" "$existing_route_table")"
    existing_route_priority="$(read_env_var "$ROUTER_ENV" "ROUTE_PRIORITY" "$existing_route_priority")"
    existing_host_output="$(read_env_var "$ROUTER_ENV" "PROXY_HOST_OUTPUT" "$existing_host_output")"
    existing_bypass_src="$(read_env_var "$ROUTER_ENV" "BYPASS_SRC_CIDRS" "$existing_bypass_src")"
    existing_bypass_dst="$(read_env_var "$ROUTER_ENV" "BYPASS_DST_CIDRS" "$existing_bypass_dst")"
    existing_bypass_uids="$(read_env_var "$ROUTER_ENV" "BYPASS_UIDS" "$existing_bypass_uids")"
  fi

  local lan_iface
  local lan_cidr
  local enable_ipv6="0"
  local dns_hijack_enabled="1"
  local proxy_ingress_ifaces
  local dns_hijack_ifaces
  local bypass_containers=""

  lan_iface="$(detect_default_iface || true)"
  lan_cidr="$(detect_iface_cidr "${lan_iface:-}" || true)"
  lan_cidr="$(cidr_network "${lan_cidr:-}" 2>/dev/null || printf '%s' "${lan_cidr:-}")"
  proxy_ingress_ifaces="${lan_iface:-bridge1}"
  dns_hijack_ifaces="${lan_iface:-bridge1}"

  case "$template_name" in
    nas-single-lan-v4)
      enable_ipv6="0"
      ;;
    nas-single-lan-dualstack)
      enable_ipv6="1"
      ;;
    nas-multi-bridge)
      if have_global_ipv6; then
        enable_ipv6="1"
      fi
      ;;
    nas-explicit-proxy-only)
      if have_global_ipv6; then
        enable_ipv6="1"
      fi
      dns_hijack_enabled="0"
      proxy_ingress_ifaces=""
      dns_hijack_ifaces=""
      ;;
  esac

  mkdir -p "$MIHOMO_DIR"
  cat >"$ROUTER_ENV" <<EOF
TEMPLATE_NAME="${template_name}"
ENABLE_IPV6="${enable_ipv6}"
LAN_INTERFACES="${lan_iface:-bridge1}"
LAN_CIDRS="${lan_cidr:-192.168.2.0/24}"
PROXY_INGRESS_INTERFACES="${proxy_ingress_ifaces}"
DNS_HIJACK_ENABLED="${dns_hijack_enabled}"
DNS_HIJACK_INTERFACES="${dns_hijack_ifaces}"
PROXY_HOST_OUTPUT="${existing_host_output}"
BYPASS_CONTAINER_NAMES="${bypass_containers}"
BYPASS_SRC_CIDRS="${existing_bypass_src}"
BYPASS_DST_CIDRS="${existing_bypass_dst}"
BYPASS_UIDS="${existing_bypass_uids}"
MIXED_PORT="${existing_mixed_port}"
TPROXY_PORT="${existing_tproxy_port}"
DNS_PORT="${existing_dns_port}"
CONTROLLER_PORT="${existing_controller_port}"
CONTROLLER_BIND_ADDRESS="${existing_controller_bind}"
ROUTE_MARK="${existing_route_mark}"
ROUTE_MASK="${existing_route_mask}"
ROUTE_TABLE="${existing_route_table}"
ROUTE_PRIORITY="${existing_route_priority}"
EOF
  chmod 640 "$ROUTER_ENV"
}

ensure_settings() {
  mkdir -p "$MIHOMO_DIR"
  [[ -f "$SETTINGS_ENV" ]] || cat >"$SETTINGS_ENV" <<'EOF'
CONFIG_MODE="rule"
CORE_CHANNEL="alpha"
ALPHA_AUTO_UPDATE="0"
ALPHA_UPDATE_ONCALENDAR="daily"
RESTART_INTERVAL_HOURS="0"
RULES_AUTO_SYNC="1"
RULES_REPO_DIR="/home/projects/mihomo-rules"
EOF
  local template_name
  template_name="$(read_env_var "$SETTINGS_ENV" "PROFILE_TEMPLATE" "")"
  if ! template_exists "$template_name"; then
    upsert_env_var "$SETTINGS_ENV" "PROFILE_TEMPLATE" "$(default_profile_template)"
  fi
  chmod 640 "$SETTINGS_ENV"
}

ensure_router_env() {
  mkdir -p "$MIHOMO_DIR"
  if [[ ! -f "$ROUTER_ENV" ]]; then
    write_router_env_from_template "$(read_env_var "$SETTINGS_ENV" "PROFILE_TEMPLATE" "$(default_profile_template)")"
  fi
}

load_settings() {
  ensure_settings
  local env_rules_auto_sync="${RULES_AUTO_SYNC:-}"
  local env_rules_repo_dir="${RULES_REPO_DIR:-}"
  local env_profile_template="${PROFILE_TEMPLATE:-}"
  # shellcheck disable=SC1090
  source "$SETTINGS_ENV"
  RULES_AUTO_SYNC="${env_rules_auto_sync:-${RULES_AUTO_SYNC:-1}}"
  RULES_REPO_DIR="${env_rules_repo_dir:-${RULES_REPO_DIR:-/home/projects/mihomo-rules}}"
  PROFILE_TEMPLATE="${env_profile_template:-${PROFILE_TEMPLATE:-$(default_profile_template)}}"
}

load_settings_readonly() {
  local env_rules_auto_sync="${RULES_AUTO_SYNC:-}"
  local env_rules_repo_dir="${RULES_REPO_DIR:-}"
  local env_profile_template="${PROFILE_TEMPLATE:-}"
  CONFIG_MODE="rule"
  CORE_CHANNEL="alpha"
  ALPHA_AUTO_UPDATE="0"
  ALPHA_UPDATE_ONCALENDAR="daily"
  RESTART_INTERVAL_HOURS="0"
  RULES_AUTO_SYNC="1"
  RULES_REPO_DIR="/home/projects/mihomo-rules"
  PROFILE_TEMPLATE="$(default_profile_template)"
  if [[ -f "$SETTINGS_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$SETTINGS_ENV"
  fi
  RULES_AUTO_SYNC="${env_rules_auto_sync:-${RULES_AUTO_SYNC:-1}}"
  RULES_REPO_DIR="${env_rules_repo_dir:-${RULES_REPO_DIR:-/home/projects/mihomo-rules}}"
  PROFILE_TEMPLATE="${env_profile_template:-${PROFILE_TEMPLATE:-$(default_profile_template)}}"
}

load_router_env() {
  ensure_router_env
  # shellcheck disable=SC1090
  source "$ROUTER_ENV"

  MIXED_PORT="${MIXED_PORT:-7890}"
  TPROXY_PORT="${TPROXY_PORT:-7893}"
  DNS_PORT="${DNS_PORT:-1053}"
  CONTROLLER_PORT="${CONTROLLER_PORT:-19090}"
  CONTROLLER_BIND_ADDRESS="${CONTROLLER_BIND_ADDRESS:-127.0.0.1}"
  TEMPLATE_NAME="${TEMPLATE_NAME:-$(current_profile_template)}"
  ENABLE_IPV6="${ENABLE_IPV6:-0}"
  ROUTE_MARK="${ROUTE_MARK:-0x2333}"
  ROUTE_MASK="${ROUTE_MASK:-0xffffffff}"
  ROUTE_TABLE="${ROUTE_TABLE:-233}"
  ROUTE_PRIORITY="${ROUTE_PRIORITY:-100}"
  PROXY_HOST_OUTPUT="${PROXY_HOST_OUTPUT:-0}"
  DNS_HIJACK_ENABLED="${DNS_HIJACK_ENABLED:-1}"
  LAN_INTERFACES="${LAN_INTERFACES:-}"
  LAN_CIDRS="${LAN_CIDRS:-}"
  PROXY_INGRESS_INTERFACES="${PROXY_INGRESS_INTERFACES:-$LAN_INTERFACES}"
  DNS_HIJACK_INTERFACES="${DNS_HIJACK_INTERFACES:-$LAN_INTERFACES}"
  BYPASS_CONTAINER_NAMES="${BYPASS_CONTAINER_NAMES:-}"
  BYPASS_SRC_CIDRS="${BYPASS_SRC_CIDRS:-}"
  BYPASS_DST_CIDRS="${BYPASS_DST_CIDRS:-}"
  BYPASS_UIDS="${BYPASS_UIDS:-}"

  ROUTE_MARK_DEC=$((ROUTE_MARK))
  read -r -a PROXY_INGRESS_IFACES_ARR <<< "${PROXY_INGRESS_INTERFACES}"
  read -r -a DNS_HIJACK_IFACES_ARR <<< "${DNS_HIJACK_INTERFACES}"
  read -r -a BYPASS_CONTAINER_NAMES_ARR <<< "${BYPASS_CONTAINER_NAMES}"
  read -r -a BYPASS_SRC_CIDRS_ARR <<< "${BYPASS_SRC_CIDRS}"
  read -r -a BYPASS_DST_CIDRS_ARR <<< "${BYPASS_DST_CIDRS}"
  read -r -a BYPASS_UIDS_ARR <<< "${BYPASS_UIDS}"

  RESERVED_DST_CIDRS_ARR=(
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "224.0.0.0/4"
    "240.0.0.0/4"
    "255.255.255.255/32"
  )
}

load_router_env_readonly() {
  MIXED_PORT="7890"
  TPROXY_PORT="7893"
  DNS_PORT="1053"
  CONTROLLER_PORT="19090"
  CONTROLLER_BIND_ADDRESS="127.0.0.1"
  TEMPLATE_NAME="$(current_profile_template)"
  ENABLE_IPV6="0"
  ROUTE_MARK="0x2333"
  ROUTE_MASK="0xffffffff"
  ROUTE_TABLE="233"
  ROUTE_PRIORITY="100"
  PROXY_HOST_OUTPUT="0"
  DNS_HIJACK_ENABLED="1"
  LAN_INTERFACES=""
  LAN_CIDRS=""
  PROXY_INGRESS_INTERFACES=""
  DNS_HIJACK_INTERFACES=""
  BYPASS_CONTAINER_NAMES=""
  BYPASS_SRC_CIDRS=""
  BYPASS_DST_CIDRS=""
  BYPASS_UIDS=""
  if [[ -f "$ROUTER_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$ROUTER_ENV"
  fi
}

ensure_layout() {
  mkdir -p "$MIHOMO_DIR" "$RULES_DIR" "$PROVIDER_DIR" "$UI_DIR" "$STATE_DIR" "$SNAPSHOT_DIR"
  [[ -f "$PROVIDER_FILE" ]] || : >"$PROVIDER_FILE"
  [[ -f "$RENDERED_RULES_FILE" ]] || : >"$RENDERED_RULES_FILE"
  [[ -f "$ACL_RENDERED_RULES_FILE" ]] || : >"$ACL_RENDERED_RULES_FILE"
  ensure_settings
  ensure_router_env
  ensure_state_files
}

copy_file_if_exists() {
  local src="$1"
  local dst="$2"
  [[ -f "$src" ]] || return 0
  install -D -m 0640 "$src" "$dst"
}

snapshot_current_state() {
  ensure_layout
  local label="${1:-manual}"
  local stamp
  local target
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="${SNAPSHOT_DIR}/${stamp}-${label// /-}"
  mkdir -p "$target"
  copy_file_if_exists "$SETTINGS_ENV" "$target/settings.env"
  copy_file_if_exists "$ROUTER_ENV" "$target/router.env"
  copy_file_if_exists "$CONFIG_FILE" "$target/config.yaml"
  copy_file_if_exists "$NODES_STATE_FILE" "$target/nodes.json"
  copy_file_if_exists "$RULES_STATE_FILE" "$target/rules.json"
  copy_file_if_exists "$ACL_STATE_FILE" "$target/acl.json"
  copy_file_if_exists "$SUBSCRIPTIONS_STATE_FILE" "$target/subscriptions.json"
  copy_file_if_exists "$PROVIDER_FILE" "$target/manual.txt"
  copy_file_if_exists "$RENDERED_RULES_FILE" "$target/custom.rules"
  copy_file_if_exists "$ACL_RENDERED_RULES_FILE" "$target/acl.rules"
  if [[ -f "$SYSTEMD_UNIT" ]]; then
    copy_file_if_exists "$SYSTEMD_UNIT" "$target/mihomo.service"
  fi
  rm -rf "${SNAPSHOT_DIR}/latest"
  cp -a "$target" "${SNAPSHOT_DIR}/latest"
  printf '%s\n' "$target"
}

restore_latest_snapshot() {
  local latest="${SNAPSHOT_DIR}/latest"
  [[ -d "$latest" ]] || die "未找到可回滚快照: ${latest}"
  ensure_layout
  copy_file_if_exists "$latest/settings.env" "$SETTINGS_ENV"
  copy_file_if_exists "$latest/router.env" "$ROUTER_ENV"
  copy_file_if_exists "$latest/config.yaml" "$CONFIG_FILE"
  copy_file_if_exists "$latest/nodes.json" "$NODES_STATE_FILE"
  copy_file_if_exists "$latest/rules.json" "$RULES_STATE_FILE"
  copy_file_if_exists "$latest/acl.json" "$ACL_STATE_FILE"
  copy_file_if_exists "$latest/subscriptions.json" "$SUBSCRIPTIONS_STATE_FILE"
  copy_file_if_exists "$latest/manual.txt" "$PROVIDER_FILE"
  copy_file_if_exists "$latest/custom.rules" "$RENDERED_RULES_FILE"
  copy_file_if_exists "$latest/acl.rules" "$ACL_RENDERED_RULES_FILE"
  if [[ -f "$latest/mihomo.service" ]]; then
    copy_file_if_exists "$latest/mihomo.service" "$SYSTEMD_UNIT"
  fi
}

node_enabled_count() {
  require_statectl
  python3 "$STATECTL" enabled-count "$NODES_STATE_FILE"
}

node_list_tsv() {
  require_statectl
  python3 "$STATECTL" list-nodes "$NODES_STATE_FILE"
}

node_enabled_names() {
  require_statectl
  python3 "$STATECTL" enabled-names "$NODES_STATE_FILE"
}

node_all_names() {
  require_statectl
  python3 "$STATECTL" all-names "$NODES_STATE_FILE"
}

acl_list_tsv() {
  require_statectl
  python3 "$STATECTL" list-rules "$ACL_STATE_FILE"
}

subscription_list_tsv() {
  require_statectl
  python3 "$STATECTL" list-subscriptions "$SUBSCRIPTIONS_STATE_FILE"
}

readonly_node_counts() {
  if [[ -f "$NODES_STATE_FILE" ]]; then
    python3 - "$NODES_STATE_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
nodes = data.get("nodes", [])
enabled = sum(1 for n in nodes if n.get("enabled"))
print(f"{enabled}\t{len(nodes)}")
PY
    return 0
  fi

  if [[ -f "$PROVIDER_FILE" ]]; then
    python3 - "$PROVIDER_FILE" <<'PY'
import sys

enabled = 0
total = 0
for raw in open(sys.argv[1], "r", encoding="utf-8"):
    line = raw.strip()
    if not line:
        continue
    if line.startswith("#DISABLED#") and "://" in line:
        total += 1
        continue
    if line.startswith("#"):
        continue
    if "://" in line:
        total += 1
        enabled += 1
print(f"{enabled}\t{total}")
PY
    return 0
  fi

  printf '0\t0\n'
}

ensure_enabled_nodes() {
  ensure_layout
  local enabled_count
  enabled_count="$(node_enabled_count)"
  [[ "$enabled_count" -gt 0 ]] || die "当前没有启用中的节点。先执行 'mihomo import-links' 导入节点，或用 'mihomo toggle-node' 启用已有节点，再启动/接管 mihomo"
}

host_output_proxy_enabled() {
  [[ "${PROXY_HOST_OUTPUT:-0}" == "1" ]]
}

print_host_output_proxy_warning() {
  host_output_proxy_enabled || return 0
  warn "宿主机透明接管已开启：宿主机 root 进程和系统守护进程也会被透明代理。"
  warn "这会影响 tailscaled、cloudflared、反向隧道、备份/同步任务等依赖稳定直连的服务。"
  warn "更安全的默认值是 PROXY_HOST_OUTPUT=0；宿主机应用如需代理，请显式使用 127.0.0.1:${MIXED_PORT}。"
}

unit_is_active() {
  local unit="$1"
  systemctl_cmd is-active --quiet "$unit" >/dev/null 2>&1
}

process_is_active() {
  local name="$1"
  if have pgrep; then
    pgrep -x "$name" >/dev/null 2>&1 && return 0
  fi
  ps -eo comm= 2>/dev/null | grep -Fxq "$name"
}

unit_or_process_is_active() {
  local unit="$1"
  local process_name="$2"
  unit_is_active "$unit" || process_is_active "$process_name"
}

guard_host_output_proxy_conflicts() {
  host_output_proxy_enabled || return 0
  local conflicts=()
  unit_or_process_is_active tailscaled.service tailscaled && conflicts+=("tailscaled")
  unit_or_process_is_active cloudflared.service cloudflared && conflicts+=("cloudflared")
  [[ ${#conflicts[@]} -eq 0 ]] && return 0
  warn "检测到以下宿主机关键服务正在运行: ${conflicts[*]}"
  warn "这些服务依赖宿主机稳定直连，不能和 PROXY_HOST_OUTPUT=1 混用。"
  die "修复: 保持 PROXY_HOST_OUTPUT=0；宿主机应用如需代理，请显式使用 127.0.0.1:${MIXED_PORT}；若你明确知道风险，先停掉 ${conflicts[*]} 再重试。"
}

service_is_active() {
  systemctl_cmd is-active --quiet mihomo >/dev/null 2>&1
}

service_is_enabled() {
  systemctl_cmd is-enabled mihomo >/dev/null 2>&1
}

restart_service_if_active() {
  if service_is_active; then
    ensure_layout
    if [[ "$(node_enabled_count)" -gt 0 ]]; then
      systemctl_cmd restart mihomo
      ok "已重启 mihomo"
    else
      systemctl_cmd stop mihomo
      warn "当前没有启用中的节点，已停止 mihomo 以避免空接管"
    fi
  fi
}

current_mode() {
  if [[ -f "$CONFIG_FILE" ]]; then
    awk '/^mode:/ { print $2; exit }' "$CONFIG_FILE"
  fi
  return 0
}
