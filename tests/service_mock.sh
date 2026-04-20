#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
MANAGER="${ROOT}/mihomo"

cleanup() {
  [[ -n "${TMPDIR_CASE:-}" && -d "${TMPDIR_CASE:-}" ]] && rm -rf "$TMPDIR_CASE"
}
trap cleanup EXIT

setup_case() {
  TMPDIR_CASE="$(mktemp -d)"
  mkdir -p "${TMPDIR_CASE}/bin"
  cat > "${TMPDIR_CASE}/router.env" <<'EOF'
LAN_INTERFACES="bridge1"
LAN_CIDRS="192.168.2.0/24"
PROXY_INGRESS_INTERFACES="bridge1"
DNS_HIJACK_ENABLED="1"
DNS_HIJACK_INTERFACES="bridge1"
PROXY_HOST_OUTPUT="1"
BYPASS_CONTAINER_NAMES=""
BYPASS_SRC_CIDRS=""
BYPASS_DST_CIDRS=""
BYPASS_UIDS=""
MIXED_PORT="7890"
TPROXY_PORT="7893"
DNS_PORT="1053"
CONTROLLER_PORT="19090"
ROUTE_MARK="0x2333"
ROUTE_MASK="0xffffffff"
ROUTE_TABLE="233"
ROUTE_PRIORITY="100"
EOF

  cat > "${TMPDIR_CASE}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
case "$1" in
  show)
    unit="$2"
    prop="$4"
    case "$prop" in
      ActiveState) echo "active" ;;
      SubState) echo "running" ;;
      MainPID) echo "12345" ;;
      ActiveEnterTimestamp) echo "Mon 2026-04-20 12:00:00 CST" ;;
      NRestarts) echo "0" ;;
      MemoryCurrent) echo "10485760" ;;
      MemoryPeak) echo "20971520" ;;
      CPUUsageNSec) echo "123456789" ;;
      NextElapseUSecRealtime) echo "Tue 2026-04-21 00:00:00 CST" ;;
      *) echo "" ;;
    esac
    exit 0
    ;;
  is-active|is-enabled)
    case "$2" in
      mihomo) exit 0 ;;
      mihomo-alpha-update.timer) exit 0 ;;
      mihomo-restart.timer) exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${TMPDIR_CASE}/bin/systemctl"

  cat > "${TMPDIR_CASE}/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$*" | grep -q -- "--since 24 hours ago"; then
  case "$*" in
    *"-p warning"*) printf 'warning line\n'; exit 0 ;;
    *"-p err"*) exit 0 ;;
  esac
fi
printf 'journal output\n'
EOF
  chmod +x "${TMPDIR_CASE}/bin/journalctl"

  cat > "${TMPDIR_CASE}/bin/ss" <<'EOF'
#!/usr/bin/env bash
cat <<OUT
tcp LISTEN 0 4096 *:7890 *:* users:(("mihomo-core",pid=12345,fd=10))
tcp LISTEN 0 4096 *:7893 *:* users:(("mihomo-core",pid=12345,fd=7))
tcp LISTEN 0 4096 *:1053 *:* users:(("mihomo-core",pid=12345,fd=11))
tcp LISTEN 0 4096 *:19090 *:* users:(("mihomo-core",pid=12345,fd=6))
OUT
EOF
  chmod +x "${TMPDIR_CASE}/bin/ss"

  cat > "${TMPDIR_CASE}/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '<!doctype html>\n'
EOF
  chmod +x "${TMPDIR_CASE}/bin/curl"
}

env_prefix() {
  printf 'APP_ROOT=%q MIHOMO_DIR=%q SETTINGS_ENV=%q ROUTER_ENV=%q CONFIG_FILE=%q RULES_DIR=%q PROVIDER_DIR=%q UI_DIR=%q STATE_DIR=%q NODES_STATE_FILE=%q RULES_STATE_FILE=%q PROVIDER_FILE=%q RENDERED_RULES_FILE=%q MIHOMO_USER=%q MANAGER_BIN=%q MIHOMO_BIN=%q SYSTEMCTL_BIN=%q JOURNALCTL_BIN=%q SS_BIN=%q CURL_BIN=%q SYSTEMCTL_LOG=%q SYSTEMD_UNIT=%q RESTART_SERVICE_UNIT=%q RESTART_TIMER_UNIT=%q UPDATE_SERVICE_UNIT=%q UPDATE_TIMER_UNIT=%q' \
    "$ROOT" \
    "$TMPDIR_CASE" \
    "$TMPDIR_CASE/settings.env" \
    "$TMPDIR_CASE/router.env" \
    "$TMPDIR_CASE/config.yaml" \
    "$TMPDIR_CASE/ruleset" \
    "$TMPDIR_CASE/proxy_providers" \
    "$TMPDIR_CASE/ui" \
    "$TMPDIR_CASE/state" \
    "$TMPDIR_CASE/state/nodes.json" \
    "$TMPDIR_CASE/state/rules.json" \
    "$TMPDIR_CASE/proxy_providers/manual.txt" \
    "$TMPDIR_CASE/ruleset/custom.rules" \
    root \
    "$TMPDIR_CASE/mihomo" \
    /bin/true \
    "$TMPDIR_CASE/bin/systemctl" \
    "$TMPDIR_CASE/bin/journalctl" \
    "$TMPDIR_CASE/bin/ss" \
    "$TMPDIR_CASE/bin/curl" \
    "$TMPDIR_CASE/systemctl.log" \
    "$TMPDIR_CASE/mihomo.service" \
    "$TMPDIR_CASE/mihomo-restart.service" \
    "$TMPDIR_CASE/mihomo-restart.timer" \
    "$TMPDIR_CASE/mihomo-alpha-update.service" \
    "$TMPDIR_CASE/mihomo-alpha-update.timer"
}

run_manager() {
  local cmd
  cmd="$(env_prefix)"
  # shellcheck disable=SC2086
  eval "$cmd" "$MANAGER" "$@"
}

assert_log_contains() {
  local needle="$1"
  grep -Fq "$needle" "${TMPDIR_CASE}/systemctl.log"
}

test_start_without_nodes_fails_before_systemctl_start() {
  setup_case
  run_manager render-config >/dev/null
  if run_manager start >/tmp/mh-service-start.log 2>&1; then
    echo "start should fail without nodes" >&2
    exit 1
  fi
  grep -q '当前没有启用中的节点' /tmp/mh-service-start.log
  [[ ! -f "${TMPDIR_CASE}/systemctl.log" ]] || ! grep -Fq 'start mihomo' "${TMPDIR_CASE}/systemctl.log"
}

test_configure_restart_enables_timer() {
  setup_case
  run_manager configure-restart 24 >/dev/null
  assert_log_contains 'daemon-reload'
  assert_log_contains 'enable --now mihomo-restart.timer'
}

test_disable_alpha_update_disables_timer() {
  setup_case
  run_manager configure-alpha-update 0 daily >/dev/null
  assert_log_contains 'disable --now mihomo-alpha-update.timer'
}

test_runtime_audit_outputs() {
  setup_case
  run_manager render-config >/dev/null
  output="$(run_manager runtime-audit)"
  grep -q 'active_state: active' <<<"$output"
  grep -q 'warnings_last_24h: 1' <<<"$output"
  grep -q 'alpha_update_next: Tue 2026-04-21 00:00:00 CST' <<<"$output"
}

main() {
  test_start_without_nodes_fails_before_systemctl_start
  test_configure_restart_enables_timer
  test_disable_alpha_update_disables_timer
  test_runtime_audit_outputs
  echo "service-mock: ok"
}

main "$@"
