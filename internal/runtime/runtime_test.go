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
