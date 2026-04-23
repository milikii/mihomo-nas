#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
MANAGER="${ROOT}/mihomo"
STATECTL="${ROOT}/scripts/statectl.py"

cleanup() {
  [[ -n "${TMPDIR_CASE:-}" && -d "${TMPDIR_CASE:-}" ]] && rm -rf "$TMPDIR_CASE"
}
trap cleanup EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'assert_contains failed: expected [%s] in output\n' "$needle" >&2
    exit 1
  fi
}

setup_case() {
  TMPDIR_CASE="$(mktemp -d)"
  mkdir -p "${TMPDIR_CASE}/state" "${TMPDIR_CASE}/ruleset" "${TMPDIR_CASE}/proxy_providers" "${TMPDIR_CASE}/ui"
  cat > "${TMPDIR_CASE}/router.env" <<'EOF'
TEMPLATE_NAME="nas-single-lan-v4"
ENABLE_IPV6="0"
LAN_INTERFACES="bridge1"
LAN_CIDRS="192.168.2.0/24"
PROXY_INGRESS_INTERFACES="bridge1"
DNS_HIJACK_ENABLED="1"
DNS_HIJACK_INTERFACES="bridge1"
PROXY_HOST_OUTPUT="0"
BYPASS_CONTAINER_NAMES=""
BYPASS_SRC_CIDRS=""
BYPASS_DST_CIDRS=""
BYPASS_UIDS=""
MIXED_PORT="7890"
TPROXY_PORT="7893"
DNS_PORT="1053"
CONTROLLER_PORT="19090"
CONTROLLER_BIND_ADDRESS="127.0.0.1"
ROUTE_MARK="0x2333"
ROUTE_MASK="0xffffffff"
ROUTE_TABLE="233"
ROUTE_PRIORITY="100"
EOF
}

env_prefix() {
  printf 'APP_ROOT=%q MIHOMO_DIR=%q SETTINGS_ENV=%q ROUTER_ENV=%q CONFIG_FILE=%q RULES_DIR=%q PROVIDER_DIR=%q UI_DIR=%q STATE_DIR=%q NODES_STATE_FILE=%q RULES_STATE_FILE=%q ACL_STATE_FILE=%q SUBSCRIPTIONS_STATE_FILE=%q PROVIDER_FILE=%q RENDERED_RULES_FILE=%q ACL_RENDERED_RULES_FILE=%q MIHOMO_USER=%q MANAGER_BIN=%q MIHOMO_BIN=%q' \
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
    "$TMPDIR_CASE/state/acl.json" \
    "$TMPDIR_CASE/state/subscriptions.json" \
    "$TMPDIR_CASE/proxy_providers/manual.txt" \
    "$TMPDIR_CASE/ruleset/custom.rules" \
    "$TMPDIR_CASE/ruleset/acl.rules" \
    root \
    "$TMPDIR_CASE/mihomo" \
    /bin/true
}

run_manager() {
  local cmd
  cmd="$(env_prefix)"
  # shellcheck disable=SC2086
  eval "$cmd" "$MANAGER" "$@"
}

test_syntax() {
  bash -n "${ROOT}/mihomo" "${ROOT}/lib/common.sh" "${ROOT}/lib/render.sh"
  python3 -m py_compile "${STATECTL}"
}

test_render_empty() {
  setup_case
  run_manager render-config >/dev/null
  grep -q '^proxies: \[\]' "${TMPDIR_CASE}/proxy_providers/manual.txt"
  grep -q '^ipv6: false' "${TMPDIR_CASE}/config.yaml"
  grep -q '^  ipv6: false' "${TMPDIR_CASE}/config.yaml"
  grep -q '^  - 192.168.2.0/24' "${TMPDIR_CASE}/config.yaml"
  grep -q '^  - 127.0.0.0/8' "${TMPDIR_CASE}/config.yaml"
  [[ -f "${TMPDIR_CASE}/state/acl.json" ]]
  [[ -f "${TMPDIR_CASE}/state/subscriptions.json" ]]
  [[ -f "${TMPDIR_CASE}/ruleset/acl.rules" ]]
}

test_protocol_renderers() {
  setup_case
  run_manager render-config >/dev/null
  python3 "${STATECTL}" append-node "${TMPDIR_CASE}/state/nodes.json" 'vless://uuid@example.com:443?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBLIC_KEY&sid=abcd&type=tcp#vless-node' vless-node 1 >/dev/null
  python3 "${STATECTL}" append-node "${TMPDIR_CASE}/state/nodes.json" 'trojan://password@example.org:443?security=tls&sni=www.apple.com&type=ws&host=www.apple.com&path=%2Fws#trojan-node' trojan-node 1 >/dev/null
  python3 "${STATECTL}" append-node "${TMPDIR_CASE}/state/nodes.json" 'ss://YWVzLTI1Ni1nY206c2VjcmV0QGV4YW1wbGUubmV0OjQ0Mw==#ss-node' ss-node 1 >/dev/null
  python3 "${STATECTL}" append-node "${TMPDIR_CASE}/state/nodes.json" 'vmess://eyJhZGQiOiJ2bWVzcy5leGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjEyMzQ1Njc4LTEyMzQtMTIzNC0xMjM0LTEyMzQ1Njc4OTBhYiIsImFpZCI6IjAiLCJuZXQiOiJ3cyIsInR5cGUiOiJub25lIiwiaG9zdCI6Ind3dy5naXRodWIuY29tIiwicGF0aCI6Ii92bWVzcyIsInRscyI6InRscyIsInNuaSI6Ind3dy5naXRodWIuY29tIiwicHMiOiJ2bWVzcy1ub2RlIn0=' vmess-node 1 >/dev/null
  run_manager render-config >/dev/null
  grep -q 'type: "vless"' "${TMPDIR_CASE}/proxy_providers/manual.txt"
  grep -q 'type: "trojan"' "${TMPDIR_CASE}/proxy_providers/manual.txt"
  grep -q 'type: "ss"' "${TMPDIR_CASE}/proxy_providers/manual.txt"
  grep -q 'type: "vmess"' "${TMPDIR_CASE}/proxy_providers/manual.txt"
  grep -q 'name: "vmess-node"' "${TMPDIR_CASE}/proxy_providers/manual.txt"
}

test_acl_rules_are_rendered() {
  setup_case
  run_manager render-config >/dev/null
  python3 "${STATECTL}" append-node "${TMPDIR_CASE}/state/nodes.json" 'vless://uuid@example.com:443?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBLIC_KEY&sid=abcd&type=tcp#Proxy-Node' Proxy-Node 1 >/dev/null
  python3 "${STATECTL}" add-rule "${TMPDIR_CASE}/state/acl.json" geosite netflix AUTO >/dev/null
  python3 "${STATECTL}" add-rule "${TMPDIR_CASE}/state/acl.json" port 443 Proxy-Node >/dev/null
  run_manager render-config >/dev/null
  grep -q 'GEOSITE,netflix,AUTO' "${TMPDIR_CASE}/ruleset/acl.rules"
  grep -q 'DST-PORT,443,Proxy-Node' "${TMPDIR_CASE}/ruleset/acl.rules"
  grep -q 'GEOSITE,netflix,AUTO' "${TMPDIR_CASE}/config.yaml"
}

test_auto_without_node_fails() {
  setup_case
  run_manager render-config >/dev/null
  python3 "${STATECTL}" add-rule "${TMPDIR_CASE}/state/acl.json" geosite netflix AUTO >/dev/null
  if run_manager render-config >/tmp/mh-smoke-auto.log 2>&1; then
    echo "AUTO target should have failed without enabled nodes" >&2
    exit 1
  fi
  grep -q 'ACL 规则存在指向不存在或未启用节点的目标' /tmp/mh-smoke-auto.log
}

test_scan_marks_unsupported_scheme() {
  setup_case
  printf '%s\n' 'hy2://password@example.com:443#unsupported' > "${TMPDIR_CASE}/uris.txt"
  output="$(python3 "${STATECTL}" scan-uris "${TMPDIR_CASE}/uris.txt")"
  assert_contains "$output" $'\t0\thy2\t'
}

test_subscription_state_commands() {
  setup_case
  run_manager add-subscription "test-sub" "https://example.com/sub.txt" 1 >/dev/null
  output="$(run_manager subscriptions)"
  assert_contains "$output" 'test-sub'
  assert_contains "$output" 'https://example.com/sub.txt'
}

test_status_readonly() {
  setup_case
  output="$(run_manager status)"
  assert_contains "$output" '模板: nas-single-lan-v4 (单 LAN IPv4 旁路由)'
  assert_contains "$output" 'IPv6: 关闭'
  assert_contains "$output" '节点: 启用 0 / 总计 0'
  assert_contains "$output" '订阅: 启用 0 / 总计 0'
  assert_contains "$output" '宿主机流量: 默认直连；按需显式代理 http://127.0.0.1:7890'
  assert_contains "$output" '控制面密钥: 已隐藏；如需查看执行: mihomo show-secret'
}

test_status_warns_on_host_output_proxy() {
  setup_case
  sed -i 's/PROXY_HOST_OUTPUT="0"/PROXY_HOST_OUTPUT="1"/' "${TMPDIR_CASE}/router.env"
  output="$(run_manager status)"
  assert_contains "$output" '宿主机流量: 透明接管(高风险)'
  assert_contains "$output" 'tailscaled、cloudflared'
}

test_usage_mentions_new_commands() {
  output="$(run_manager help)"
  assert_contains "$output" 'repair'
  assert_contains "$output" 'templates'
  assert_contains "$output" 'update-subscriptions'
  assert_contains "$output" 'rollback-config'
  assert_contains "$output" '兼容命令:'
}

test_menu_mentions_new_buckets() {
  grep -q 'echo "3) 节点与订阅"' "${ROOT}/mihomo"
  grep -q 'echo "4) 网络入口与模板"' "${ROOT}/mihomo"
  grep -q 'echo "5) 访问控制 ACL"' "${ROOT}/mihomo"
  grep -q 'echo "8) 回滚与诊断"' "${ROOT}/mihomo"
}

main() {
  test_syntax
  test_render_empty
  test_protocol_renderers
  test_acl_rules_are_rendered
  test_auto_without_node_fails
  test_scan_marks_unsupported_scheme
  test_subscription_state_commands
  test_status_readonly
  test_status_warns_on_host_output_proxy
  test_usage_mentions_new_commands
  test_menu_mentions_new_buckets
  echo "smoke: ok"
}

main "$@"
