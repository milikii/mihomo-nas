package app

import (
	"fmt"
	"strconv"
	"strings"
)

type LogOptions struct {
	Target string
	Lines  int
	Errors bool
	Since  string
}

func (a *App) Logs(opts LogOptions) error {
	lines := opts.Lines
	if lines <= 0 {
		lines = 50
	}
	args := []string{"-u", "minimalist.service", "-n", strconv.Itoa(lines), "--no-pager"}
	if opts.Since != "" {
		args = append(args, "--since", opts.Since)
	}
	if opts.Errors {
		args = append(args, "-p", "warning")
	}
	if opts.Target == "mihomo" {
		args = append(args, "-t", "mihomo-core")
	}
	stdout, stderr, err := a.Runner.Output("journalctl", args...)
	if err != nil {
		return fmt.Errorf("日志读取失败: %v; 下一步: journalctl %s", err, strings.Join(args, " "))
	}
	if stderr != "" {
		fmt.Fprintln(a.Stdout, stderr)
	}
	if stdout != "" {
		fmt.Fprintln(a.Stdout, stdout)
	}
	return nil
}
