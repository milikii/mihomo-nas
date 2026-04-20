#!/usr/bin/env python3

import argparse
import base64
import json
import sys
import urllib.parse
import uuid
from datetime import datetime, timezone
from pathlib import Path


NODE_VERSION = 1
RULE_VERSION = 1
DISABLED_PREFIX = "#DISABLED#"


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def decode_subscription_lines(text: str) -> list[str]:
    raw_lines = [line.strip() for line in text.splitlines() if line.strip()]
    if any("://" in line for line in raw_lines):
        return raw_lines
    collapsed = "".join(raw_lines)
    if not collapsed:
        return []
    try:
        decoded = base64.b64decode(collapsed + "=" * (-len(collapsed) % 4)).decode("utf-8", errors="ignore")
    except Exception:
        return raw_lines
    return [line.strip() for line in decoded.splitlines() if line.strip()]


def normalize_uri(uri: str) -> str:
    return uri.strip()


def uri_base_key(uri: str) -> str:
    parsed = urllib.parse.urlsplit(normalize_uri(uri))
    return urllib.parse.urlunsplit(parsed._replace(fragment=""))


def guess_name(uri: str) -> str:
    parsed = urllib.parse.urlsplit(normalize_uri(uri))
    if parsed.fragment:
        return urllib.parse.unquote(parsed.fragment)
    query = urllib.parse.parse_qs(parsed.query)
    host = parsed.hostname or "node"
    network = (query.get("type", ["tcp"])[0] or "tcp").lower()
    return f"{network}-{host}"


def rename_uri(uri: str, new_name: str) -> str:
    parsed = urllib.parse.urlsplit(normalize_uri(uri))
    fragment = urllib.parse.quote(new_name, safe="")
    return urllib.parse.urlunsplit(parsed._replace(fragment=fragment))


def uri_info(uri: str) -> dict:
    parsed = urllib.parse.urlsplit(normalize_uri(uri))
    query = urllib.parse.parse_qs(parsed.query)
    return {
        "name": guess_name(uri),
        "server": parsed.hostname or "",
        "port": str(parsed.port or ""),
        "network": (query.get("type", ["tcp"])[0] or "tcp").lower(),
        "security": (query.get("security", [""])[0] or "").lower(),
    }


def load_json(path: Path, fallback: dict) -> dict:
    if not path.exists():
        return json.loads(json.dumps(fallback))
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, dict):
        return data
    raise SystemExit(f"invalid json state: {path}")


def save_json(path: Path, data: dict) -> None:
    ensure_parent(path)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def empty_nodes_state() -> dict:
    return {"version": NODE_VERSION, "nodes": []}


def empty_rules_state() -> dict:
    return {"version": RULE_VERSION, "rules": []}


def migrate_nodes_from_legacy(legacy_path: Path) -> dict:
    state = empty_nodes_state()
    if not legacy_path.exists():
        return state
    for raw in legacy_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        enabled = True
        if line.startswith(DISABLED_PREFIX):
            enabled = False
            line = line[len(DISABLED_PREFIX):].strip()
        if not line or (line.startswith("#") and not line.startswith(DISABLED_PREFIX)) or "://" not in line:
            continue
        state["nodes"].append(
            {
                "id": str(uuid.uuid4()),
                "name": guess_name(line),
                "enabled": enabled,
                "uri": normalize_uri(line),
                "imported_at": now_iso(),
            }
        )
    return state


def migrate_rules_from_legacy(legacy_path: Path) -> dict:
    kind_map = {"DOMAIN": "domain", "DOMAIN-SUFFIX": "suffix", "DOMAIN-KEYWORD": "keyword"}
    state = empty_rules_state()
    if not legacy_path.exists():
        return state
    for raw in legacy_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [part.strip() for part in line.split(",")]
        if len(parts) != 3 or parts[0] not in kind_map:
            continue
        state["rules"].append(
            {
                "id": str(uuid.uuid4()),
                "kind": kind_map[parts[0]],
                "pattern": parts[1],
                "target": parts[2],
            }
        )
    return state


def ensure_nodes_state(path: Path, legacy_path: Path | None = None) -> dict:
    if path.exists():
        return load_json(path, empty_nodes_state())
    state = migrate_nodes_from_legacy(legacy_path) if legacy_path else empty_nodes_state()
    save_json(path, state)
    return state


def ensure_rules_state(path: Path, legacy_path: Path | None = None) -> dict:
    if path.exists():
        return load_json(path, empty_rules_state())
    state = migrate_rules_from_legacy(legacy_path) if legacy_path else empty_rules_state()
    save_json(path, state)
    return state


def save_nodes_state(path: Path, state: dict) -> None:
    save_json(path, state)


def save_rules_state(path: Path, state: dict) -> None:
    save_json(path, state)


def ensure_unique_name(nodes: list[dict], name: str, ignore_id: str | None = None) -> None:
    for node in nodes:
        if ignore_id and node["id"] == ignore_id:
            continue
        if node["name"] == name:
            raise SystemExit(f"duplicate node name: {name}")


def iter_enabled_names(nodes: list[dict]) -> list[str]:
    return [node["name"] for node in nodes if node.get("enabled")]


def render_provider(path: Path, nodes: list[dict]) -> None:
    ensure_parent(path)
    enabled = [node["uri"] for node in nodes if node.get("enabled")]
    if not enabled:
        path.write_text("proxies: []\n", encoding="utf-8")
        return
    path.write_text("\n".join(enabled) + "\n", encoding="utf-8")


def render_rules(path: Path, rules: list[dict]) -> None:
    kind_map = {"domain": "DOMAIN", "suffix": "DOMAIN-SUFFIX", "keyword": "DOMAIN-KEYWORD"}
    ensure_parent(path)
    lines = [f"{kind_map[rule['kind']]},{rule['pattern']},{rule['target']}" for rule in rules]
    path.write_text(("\n".join(lines) + "\n") if lines else "", encoding="utf-8")


def cmd_scan_uris(args: argparse.Namespace) -> int:
    text = Path(args.input_file).read_text(encoding="utf-8", errors="ignore")
    for line in decode_subscription_lines(text):
        uri = normalize_uri(line)
        if "://" not in uri:
            continue
        info = uri_info(uri)
        print("\t".join([uri, info["name"], info["server"], info["port"], info["network"], info["security"]]))
    return 0


def cmd_ensure_nodes_state(args: argparse.Namespace) -> int:
    ensure_nodes_state(Path(args.state_file), Path(args.legacy_file) if args.legacy_file else None)
    return 0


def cmd_ensure_rules_state(args: argparse.Namespace) -> int:
    ensure_rules_state(Path(args.state_file), Path(args.legacy_file) if args.legacy_file else None)
    return 0


def cmd_list_nodes(args: argparse.Namespace) -> int:
    state = ensure_nodes_state(Path(args.state_file))
    for idx, node in enumerate(state["nodes"], start=1):
        info = uri_info(node["uri"])
        print(
            "\t".join(
                [
                    str(idx),
                    "1" if node.get("enabled") else "0",
                    node["name"],
                    info["server"],
                    info["port"],
                    info["network"],
                    info["security"],
                    node["id"],
                ]
            )
        )
    return 0


def cmd_append_node(args: argparse.Namespace) -> int:
    path = Path(args.state_file)
    state = ensure_nodes_state(path)
    uri = normalize_uri(args.uri)
    name = args.name or guess_name(uri)
    enabled = args.enabled == "1"
    base_key = uri_base_key(uri)

    for node in state["nodes"]:
        if uri_base_key(node["uri"]) == base_key:
            ensure_unique_name(state["nodes"], name, ignore_id=node["id"])
            node["name"] = name
            node["enabled"] = enabled
            node["uri"] = rename_uri(uri, name)
            save_nodes_state(path, state)
            print("updated")
            return 0

    ensure_unique_name(state["nodes"], name)
    state["nodes"].append(
        {
            "id": str(uuid.uuid4()),
            "name": name,
            "enabled": enabled,
            "uri": rename_uri(uri, name),
            "imported_at": now_iso(),
        }
    )
    save_nodes_state(path, state)
    print("added")
    return 0


def cmd_rename_node(args: argparse.Namespace) -> int:
    path = Path(args.state_file)
    state = ensure_nodes_state(path)
    index = int(args.index) - 1
    if index < 0 or index >= len(state["nodes"]):
        raise SystemExit("node index out of range")
    node = state["nodes"][index]
    ensure_unique_name(state["nodes"], args.new_name, ignore_id=node["id"])
    old_name = node["name"]
    node["name"] = args.new_name
    node["uri"] = rename_uri(node["uri"], args.new_name)
    save_nodes_state(path, state)
    if args.rules_state:
        rules_path = Path(args.rules_state)
        rules_state = ensure_rules_state(rules_path)
        for rule in rules_state["rules"]:
            if rule["target"] == old_name:
                rule["target"] = args.new_name
        save_rules_state(rules_path, rules_state)
    return 0


def cmd_set_node_enabled(args: argparse.Namespace) -> int:
    path = Path(args.state_file)
    state = ensure_nodes_state(path)
    index = int(args.index) - 1
    if index < 0 or index >= len(state["nodes"]):
        raise SystemExit("node index out of range")
    state["nodes"][index]["enabled"] = args.enabled == "1"
    save_nodes_state(path, state)
    return 0


def cmd_enabled_count(args: argparse.Namespace) -> int:
    state = ensure_nodes_state(Path(args.state_file))
    print(sum(1 for node in state["nodes"] if node.get("enabled")))
    return 0


def cmd_enabled_names(args: argparse.Namespace) -> int:
    state = ensure_nodes_state(Path(args.state_file))
    for name in iter_enabled_names(state["nodes"]):
        print(name)
    return 0


def cmd_all_names(args: argparse.Namespace) -> int:
    state = ensure_nodes_state(Path(args.state_file))
    for node in state["nodes"]:
        print(node["name"])
    return 0


def cmd_add_rule(args: argparse.Namespace) -> int:
    path = Path(args.state_file)
    state = ensure_rules_state(path)
    rule = {"id": str(uuid.uuid4()), "kind": args.kind, "pattern": args.pattern, "target": args.target}
    if not any(r["kind"] == rule["kind"] and r["pattern"] == rule["pattern"] and r["target"] == rule["target"] for r in state["rules"]):
        state["rules"].append(rule)
        save_rules_state(path, state)
    return 0


def cmd_list_rules(args: argparse.Namespace) -> int:
    state = ensure_rules_state(Path(args.state_file))
    kind_map = {"domain": "DOMAIN", "suffix": "DOMAIN-SUFFIX", "keyword": "DOMAIN-KEYWORD"}
    for idx, rule in enumerate(state["rules"], start=1):
        print(f"{idx}\t{kind_map[rule['kind']]},{rule['pattern']},{rule['target']}")
    return 0


def cmd_remove_rule(args: argparse.Namespace) -> int:
    path = Path(args.state_file)
    state = ensure_rules_state(path)
    index = int(args.index) - 1
    if index < 0 or index >= len(state["rules"]):
        raise SystemExit("rule index out of range")
    del state["rules"][index]
    save_rules_state(path, state)
    return 0


def cmd_render_provider(args: argparse.Namespace) -> int:
    state = ensure_nodes_state(Path(args.state_file))
    render_provider(Path(args.output_file), state["nodes"])
    return 0


def cmd_render_rules(args: argparse.Namespace) -> int:
    state = ensure_rules_state(Path(args.state_file))
    render_rules(Path(args.output_file), state["rules"])
    return 0


def cmd_validate_rule_targets(args: argparse.Namespace) -> int:
    rules_state = ensure_rules_state(Path(args.rules_state))
    nodes_state = ensure_nodes_state(Path(args.nodes_state))
    enabled_names = set(iter_enabled_names(nodes_state["nodes"]))
    allowed = {"DIRECT", "PROXY", "REJECT"} | enabled_names
    if enabled_names:
        allowed.add("AUTO")
    invalid = []
    for idx, rule in enumerate(rules_state["rules"], start=1):
        if rule["target"] not in allowed:
            invalid.append(f"{idx}:{rule['target']}")
    if invalid:
        print("\n".join(invalid))
        return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    scan = sub.add_parser("scan-uris")
    scan.add_argument("input_file")
    scan.set_defaults(func=cmd_scan_uris)

    ensure_nodes = sub.add_parser("ensure-nodes-state")
    ensure_nodes.add_argument("state_file")
    ensure_nodes.add_argument("legacy_file", nargs="?")
    ensure_nodes.set_defaults(func=cmd_ensure_nodes_state)

    ensure_rules = sub.add_parser("ensure-rules-state")
    ensure_rules.add_argument("state_file")
    ensure_rules.add_argument("legacy_file", nargs="?")
    ensure_rules.set_defaults(func=cmd_ensure_rules_state)

    list_nodes = sub.add_parser("list-nodes")
    list_nodes.add_argument("state_file")
    list_nodes.set_defaults(func=cmd_list_nodes)

    append_node = sub.add_parser("append-node")
    append_node.add_argument("state_file")
    append_node.add_argument("uri")
    append_node.add_argument("name")
    append_node.add_argument("enabled")
    append_node.set_defaults(func=cmd_append_node)

    rename_node = sub.add_parser("rename-node")
    rename_node.add_argument("state_file")
    rename_node.add_argument("index")
    rename_node.add_argument("new_name")
    rename_node.add_argument("rules_state", nargs="?")
    rename_node.set_defaults(func=cmd_rename_node)

    set_enabled = sub.add_parser("set-node-enabled")
    set_enabled.add_argument("state_file")
    set_enabled.add_argument("index")
    set_enabled.add_argument("enabled")
    set_enabled.set_defaults(func=cmd_set_node_enabled)

    enabled_count = sub.add_parser("enabled-count")
    enabled_count.add_argument("state_file")
    enabled_count.set_defaults(func=cmd_enabled_count)

    enabled_names = sub.add_parser("enabled-names")
    enabled_names.add_argument("state_file")
    enabled_names.set_defaults(func=cmd_enabled_names)

    all_names = sub.add_parser("all-names")
    all_names.add_argument("state_file")
    all_names.set_defaults(func=cmd_all_names)

    add_rule = sub.add_parser("add-rule")
    add_rule.add_argument("state_file")
    add_rule.add_argument("kind", choices=["domain", "suffix", "keyword"])
    add_rule.add_argument("pattern")
    add_rule.add_argument("target")
    add_rule.set_defaults(func=cmd_add_rule)

    list_rules = sub.add_parser("list-rules")
    list_rules.add_argument("state_file")
    list_rules.set_defaults(func=cmd_list_rules)

    remove_rule = sub.add_parser("remove-rule")
    remove_rule.add_argument("state_file")
    remove_rule.add_argument("index")
    remove_rule.set_defaults(func=cmd_remove_rule)

    render_provider_cmd = sub.add_parser("render-provider")
    render_provider_cmd.add_argument("state_file")
    render_provider_cmd.add_argument("output_file")
    render_provider_cmd.set_defaults(func=cmd_render_provider)

    render_rules_cmd = sub.add_parser("render-rules")
    render_rules_cmd.add_argument("state_file")
    render_rules_cmd.add_argument("output_file")
    render_rules_cmd.set_defaults(func=cmd_render_rules)

    validate_targets = sub.add_parser("validate-rule-targets")
    validate_targets.add_argument("rules_state")
    validate_targets.add_argument("nodes_state")
    validate_targets.set_defaults(func=cmd_validate_rule_targets)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
