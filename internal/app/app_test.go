package app

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"minimalist/internal/runtime"
)

type commandCall struct {
	name string
	args []string
}

type fakeRunner struct {
	runFn    func(name string, args ...string) error
	outputFn func(name string, args ...string) (string, string, error)
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}

func (f fakeRunner) Run(name string, args ...string) error {
	if f.runFn != nil {
		return f.runFn(name, args...)
	}
	return nil
}

func (f fakeRunner) Output(name string, args ...string) (string, string, error) {
	if f.outputFn != nil {
		return f.outputFn(name, args...)
	}
	return "", "", nil
}

func newTestApp(t *testing.T) (*App, string) {
	t.Helper()
	root := t.TempDir()
	app := &App{
		Paths: runtime.Paths{
			ConfigDir:   filepath.Join(root, "etc"),
			DataDir:     filepath.Join(root, "var"),
			RuntimeDir:  filepath.Join(root, "runtime"),
			InstallDir:  filepath.Join(root, "install"),
			BinPath:     filepath.Join(root, "bin", "minimalist"),
			ServiceUnit: filepath.Join(root, "systemd", "minimalist.service"),
			SysctlPath:  filepath.Join(root, "sysctl", "99-minimalist-router.conf"),
		},
		Runner: fakeRunner{
			runFn: func(name string, args ...string) error {
				if name == "systemctl" && len(args) >= 2 && args[0] == "is-active" {
					return errors.New("inactive")
				}
				if name == "systemctl" && len(args) >= 2 && args[0] == "is-enabled" {
					return errors.New("disabled")
				}
				return nil
			},
			outputFn: func(name string, args ...string) (string, string, error) {
				if name == "journalctl" {
					return "", "", nil
				}
				return "", "", errors.New("unavailable")
			},
		},
		Client: &http.Client{
			Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
				return nil, errors.New("unavailable")
			}),
		},
		Stdout: &bytes.Buffer{},
		Stderr: &bytes.Buffer{},
	}
	return app, root
}

func hasRecordedCall(calls []commandCall, name string, want ...string) bool {
	for _, call := range calls {
		if call.name != name {
			continue
		}
		matched := true
		for _, part := range want {
			found := false
			for _, arg := range call.args {
				if arg == part {
					found = true
					break
				}
			}
			if !found {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

func TestImportLinksPersistsManualNode(t *testing.T) {
	app, _ := newTestApp(t)
	app.Stdin = strings.NewReader("trojan://password@example.org:443?security=tls#demo-node\n")
	if err := app.ImportLinks(); err != nil {
		t.Fatalf("import links: %v", err)
	}
	body, err := os.ReadFile(app.Paths.StatePath())
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	text := string(body)
	for _, needle := range []string{`"name": "demo-node"`, `"enabled": false`, `"kind": "manual"`} {
		if !strings.Contains(text, needle) {
			t.Fatalf("missing %q in state:\n%s", needle, text)
		}
	}
}

func TestSetupWithoutProvidersDoesNotEnableService(t *testing.T) {
	app, _ := newTestApp(t)
	var calls []commandCall
	app.Runner = fakeRunner{
		runFn: func(name string, args ...string) error {
			calls = append(calls, commandCall{name: name, args: append([]string{}, args...)})
			if name == "systemctl" && len(args) >= 2 && args[0] == "is-active" {
				return errors.New("inactive")
			}
			if name == "systemctl" && len(args) >= 2 && args[0] == "is-enabled" {
				return errors.New("disabled")
			}
			if name == "iptables" {
				for _, arg := range args {
					if arg == "-C" || arg == "-S" {
						return errors.New("missing")
					}
				}
			}
			if name == "ip" && len(args) >= 4 && args[0] == "-4" && args[1] == "rule" && args[2] == "del" {
				return errors.New("missing")
			}
			return nil
		},
		outputFn: func(name string, args ...string) (string, string, error) {
			return "", "", nil
		},
	}
	if err := app.Setup(); err != nil {
		t.Fatalf("setup without providers: %v", err)
	}
	if hasRecordedCall(calls, "systemctl", "enable", "--now", "minimalist.service") {
		t.Fatalf("service should not be enabled without providers")
	}
	if !hasRecordedCall(calls, "systemctl", "daemon-reload") {
		t.Fatalf("expected daemon-reload call")
	}
	serviceBody, err := os.ReadFile(app.Paths.ServiceUnit)
	if err != nil {
		t.Fatalf("read service unit: %v", err)
	}
	if !strings.Contains(string(serviceBody), "ExecStartPre=+") || !strings.Contains(string(serviceBody), "minimalist apply-rules") {
		t.Fatalf("unexpected service unit:\n%s", string(serviceBody))
	}
	sysctlBody, err := os.ReadFile(app.Paths.SysctlPath)
	if err != nil {
		t.Fatalf("read sysctl: %v", err)
	}
	if !strings.Contains(string(sysctlBody), "net.ipv4.ip_forward = 1") {
		t.Fatalf("unexpected sysctl content:\n%s", string(sysctlBody))
	}
	output := app.Stdout.(*bytes.Buffer).String()
	if !strings.Contains(output, "部署完成，请先 import-links 或 update-subscriptions 后再启动服务") {
		t.Fatalf("unexpected setup output:\n%s", output)
	}
}

func TestRenderConfigWritesRuntimeArtifacts(t *testing.T) {
	app, _ := newTestApp(t)
	app.Stdin = strings.NewReader("trojan://password@example.org:443?security=tls#demo-node\n")
	if err := app.ImportLinks(); err != nil {
		t.Fatalf("import links: %v", err)
	}
	if err := app.SetNodeEnabled(1, true); err != nil {
		t.Fatalf("enable node: %v", err)
	}
	if err := app.RenderConfig(); err != nil {
		t.Fatalf("render config: %v", err)
	}
	raw, err := os.ReadFile(app.Paths.RuntimeConfig())
	if err != nil {
		t.Fatalf("read runtime config: %v", err)
	}
	text := string(raw)
	for _, needle := range []string{
		`mixed-port: 7890`,
		`external-controller: 127.0.0.1:19090`,
		`proxy-providers:`,
		`manual:`,
		`PROCESS-NAME,mihomo,DIRECT`,
	} {
		if !strings.Contains(text, needle) {
			t.Fatalf("missing %q in runtime config:\n%s", needle, text)
		}
	}
}

func TestUpdateSubscriptionsWritesCacheAndNodes(t *testing.T) {
	app, _ := newTestApp(t)
	app.Client = &http.Client{
		Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
			body := io.NopCloser(strings.NewReader("trojan://password@example.org:443?security=tls#sub-node\n"))
			return &http.Response{
				StatusCode: 200,
				Body:       body,
				Header:     make(http.Header),
			}, nil
		}),
	}

	if err := app.AddSubscription("demo-sub", "https://subscription.example.com/sub.txt", true); err != nil {
		t.Fatalf("add subscription: %v", err)
	}
	if err := app.UpdateSubscriptions(); err != nil {
		t.Fatalf("update subscriptions: %v", err)
	}

	stateBody, err := os.ReadFile(app.Paths.StatePath())
	if err != nil {
		t.Fatalf("read state: %v", err)
	}
	stateText := string(stateBody)
	for _, needle := range []string{`"name": "demo-sub"`, `"last_success_at":`, `"last_count": 1`, `"kind": "subscription"`} {
		if !strings.Contains(stateText, needle) {
			t.Fatalf("missing %q in updated state:\n%s", needle, stateText)
		}
	}

	matches, err := filepath.Glob(filepath.Join(app.Paths.SubscriptionDir(), "*.txt"))
	if err != nil {
		t.Fatalf("glob cache files: %v", err)
	}
	if len(matches) != 1 {
		t.Fatalf("expected one provider cache file, got %d", len(matches))
	}
	cacheBody, err := os.ReadFile(matches[0])
	if err != nil {
		t.Fatalf("read provider cache: %v", err)
	}
	if !strings.Contains(string(cacheBody), "trojan://password@example.org:443?security=tls#sub-node") {
		t.Fatalf("unexpected provider cache:\n%s", string(cacheBody))
	}
}
