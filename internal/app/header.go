package app

import (
	"fmt"

	"minimalist/internal/state"
)

type statusSnapshot struct {
	ServiceState   string
	NodeState      string
	HostProxyState string
	ManualEnabled  int
	ManualTotal    int
}

func (a *App) statusSnapshot() (statusSnapshot, error) {
	cfg, st, err := a.ensureAll()
	if err != nil {
		return statusSnapshot{}, err
	}
	total, enabled := a.manualNodeCounts(st)
	hostProxyState := "off"
	if cfg.Network.ProxyHostOutput {
		hostProxyState = "on"
	}
	return statusSnapshot{
		ServiceState:   a.serviceState(),
		NodeState:      nodeState(total, enabled),
		HostProxyState: hostProxyState,
		ManualEnabled:  enabled,
		ManualTotal:    total,
	}, nil
}

func (a *App) renderStatusHeader() string {
	snapshot, err := a.statusSnapshot()
	if err != nil {
		return "=== minimalist | 服务: unknown | 节点: unknown | 宿主机: unknown ==="
	}
	return fmt.Sprintf(
		"=== minimalist | 服务: %s | 节点: %s (%d/%d) | 宿主机: %s ===",
		snapshot.ServiceState,
		snapshot.NodeState,
		snapshot.ManualEnabled,
		snapshot.ManualTotal,
		snapshot.HostProxyState,
	)
}

func (a *App) serviceState() string {
	stdout, _, err := a.Runner.Output("systemctl", "is-active", "minimalist.service")
	switch stdout {
	case "active":
		return "running"
	case "inactive", "failed", "dead", "deactivating":
		return "stopped"
	}
	if err != nil {
		return "unknown"
	}
	return "unknown"
}

func (a *App) manualNodeCounts(st state.State) (total int, enabled int) {
	for _, node := range st.Nodes {
		if node.Source.Kind != "manual" {
			continue
		}
		total++
		if node.Enabled {
			enabled++
		}
	}
	return total, enabled
}

func nodeState(total, enabled int) string {
	switch {
	case total == 0 || enabled == 0:
		return "none"
	case enabled < total:
		return "partial"
	default:
		return "ready"
	}
}
