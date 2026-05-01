package app

import (
	"errors"
	"net/http"
	"os"
	"strings"
	"testing"
)

func TestStatusSnapshotUsesLocalStateOnly(t *testing.T) {
	app := newTestAppWithEnabledManualNode(t)
	app.Client = &http.Client{
		Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			t.Fatalf("statusSnapshot should not call controller: %s", req.URL.String())
			return nil, nil
		}),
	}
	app.Runner = fakeRunner{
		runFn: func(name string, args ...string) error {
			return nil
		},
		outputFn: func(name string, args ...string) (string, string, error) {
			if name == "systemctl" && len(args) == 2 && args[0] == "is-active" {
				return "active", "", nil
			}
			return "", "", errors.New("unavailable")
		},
	}

	snapshot, err := app.statusSnapshot()
	if err != nil {
		t.Fatalf("statusSnapshot: %v", err)
	}
	if snapshot.ServiceState != "running" {
		t.Fatalf("unexpected service state: %+v", snapshot)
	}
	if snapshot.NodeState != "ready" {
		t.Fatalf("unexpected node state: %+v", snapshot)
	}
	if snapshot.HostProxyState != "off" {
		t.Fatalf("unexpected host proxy state: %+v", snapshot)
	}
}

func TestStatusSnapshotReportsPartialManualReadiness(t *testing.T) {
	app, _ := newTestApp(t)
	app.Stdin = strings.NewReader(strings.Join([]string{
		"trojan://password@example.org:443?security=tls#node-a",
		"vless://12345678-1234-1234-1234-123456789012@example.net:443?encryption=none&security=tls&sni=example.net&type=tcp#node-b",
	}, "\n"))
	if err := app.ImportLinks(); err != nil {
		t.Fatalf("import links: %v", err)
	}
	if err := app.SetNodeEnabled(1, true); err != nil {
		t.Fatalf("enable node: %v", err)
	}
	snapshot, err := app.statusSnapshot()
	if err != nil {
		t.Fatalf("statusSnapshot: %v", err)
	}
	if snapshot.NodeState != "partial" || snapshot.ManualEnabled != 1 || snapshot.ManualTotal != 2 {
		t.Fatalf("unexpected snapshot: %+v", snapshot)
	}
}

func TestRenderStatusHeaderReportsUnknownWhenLocalStateUnavailable(t *testing.T) {
	app, _ := newTestApp(t)
	oldGeteuid := geteuid
	geteuid = func() int { return 0 }
	defer func() { geteuid = oldGeteuid }()

	if err := os.WriteFile(app.Paths.ConfigDir, []byte("blocked"), 0o640); err != nil {
		t.Fatalf("write blocking config dir: %v", err)
	}
	got := app.renderStatusHeader()
	if got != "=== minimalist | 服务: unknown | 节点: unknown | 宿主机: unknown ===" {
		t.Fatalf("unexpected fallback header: %q", got)
	}
}
