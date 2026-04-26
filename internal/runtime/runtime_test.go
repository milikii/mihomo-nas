package runtime

import (
	"strings"
	"testing"

	"minimalist/internal/config"
	"minimalist/internal/state"
)

func TestBuildRuntimeConfigFallsBackToDefaultSecret(t *testing.T) {
	paths := Paths{
		ConfigDir:  t.TempDir(),
		DataDir:    t.TempDir(),
		RuntimeDir: t.TempDir(),
	}
	cfg := config.Default()
	cfg.Controller.Secret = ""
	text, err := buildRuntimeConfig(paths, cfg, state.Empty(), nil)
	if err != nil {
		t.Fatalf("build runtime config: %v", err)
	}
	if !strings.Contains(text, `secret: "minimalist-secret"`) {
		t.Fatalf("expected fallback secret in runtime config:\n%s", text)
	}
}

func TestBuildRuntimeConfigIncludesExternalUIAndNameserverPolicy(t *testing.T) {
	paths := Paths{
		ConfigDir:  t.TempDir(),
		DataDir:    t.TempDir(),
		RuntimeDir: t.TempDir(),
	}
	cfg := config.Default()
	text, err := buildRuntimeConfig(paths, cfg, state.Empty(), nil)
	if err != nil {
		t.Fatalf("build runtime config: %v", err)
	}
	for _, needle := range []string{
		"external-ui: " + paths.UIPath(),
		"nameserver-policy:",
		`"geosite:private,cn":`,
		`"+.arpa":`,
	} {
		if !strings.Contains(text, needle) {
			t.Fatalf("missing %q in runtime config:\n%s", needle, text)
		}
	}
}

func TestBuildRuntimeConfigIncludesDNSDefaults(t *testing.T) {
	paths := Paths{
		ConfigDir:  t.TempDir(),
		DataDir:    t.TempDir(),
		RuntimeDir: t.TempDir(),
	}
	cfg := config.Default()
	text, err := buildRuntimeConfig(paths, cfg, state.Empty(), nil)
	if err != nil {
		t.Fatalf("build runtime config: %v", err)
	}
	for _, needle := range []string{
		"default-nameserver:",
		"    - 223.5.5.5",
		"    - 119.29.29.29",
		"direct-nameserver:",
		"    - https://dns.alidns.com/dns-query",
		"    - https://doh.pub/dns-query",
		"  direct-nameserver-follow-policy: true",
		`    - "*.lan"`,
		`    - "connectivitycheck.gstatic.com"`,
	} {
		if !strings.Contains(text, needle) {
			t.Fatalf("missing %q in runtime config:\n%s", needle, text)
		}
	}
}
