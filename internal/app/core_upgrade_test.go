package app

import (
	"strings"
	"testing"
)

func TestSelectLatestAlphaAssetChoosesFirstMatchingLinuxAsset(t *testing.T) {
	releases := []githubRelease{
		{
			TagName:    "v1.19.23",
			Name:       "v1.19.23",
			Prerelease: false,
			Assets: []githubReleaseAsset{
				{Name: "mihomo-linux-amd64-v1.19.23.gz", BrowserDownloadURL: "https://example.com/stable.gz"},
			},
		},
		{
			TagName:    "Prerelease",
			Name:       "Nightly Build",
			Prerelease: true,
			Assets: []githubReleaseAsset{
				{Name: "mihomo-linux-amd64-nightly.gz", BrowserDownloadURL: "https://example.com/nightly.gz"},
			},
		},
		{
			TagName:    "Prerelease-Alpha",
			Name:       "Prerelease-Alpha",
			Prerelease: true,
			Assets: []githubReleaseAsset{
				{Name: "mihomo-darwin-amd64-v1.19.23.gz", BrowserDownloadURL: "https://example.com/darwin.gz"},
				{Name: "mihomo-linux-amd64-v1.19.23.gz", BrowserDownloadURL: "https://example.com/linux.gz"},
			},
		},
	}

	release, asset, err := selectLatestAlphaAsset(releases, "linux", "amd64")
	if err != nil {
		t.Fatalf("select latest alpha asset: %v", err)
	}
	if release.TagName != "Prerelease-Alpha" {
		t.Fatalf("expected alpha release, got %+v", release)
	}
	if asset.Name != "mihomo-linux-amd64-v1.19.23.gz" {
		t.Fatalf("expected linux amd64 asset, got %+v", asset)
	}
}

func TestSelectLatestAlphaAssetChoosesArm64Asset(t *testing.T) {
	releases := []githubRelease{
		{
			TagName:    "v1.19.23-alpha-1",
			Name:       "v1.19.23 alpha 1",
			Prerelease: true,
			Assets: []githubReleaseAsset{
				{Name: "mihomo-linux-arm64-v1.19.23.gz", BrowserDownloadURL: "https://example.com/linux-arm64.gz"},
			},
		},
	}

	_, asset, err := selectLatestAlphaAsset(releases, "linux", "arm64")
	if err != nil {
		t.Fatalf("select latest alpha arm64 asset: %v", err)
	}
	if asset.Name != "mihomo-linux-arm64-v1.19.23.gz" {
		t.Fatalf("expected linux arm64 asset, got %+v", asset)
	}
}

func TestSelectLatestAlphaAssetRejectsUnsupportedArch(t *testing.T) {
	releases := []githubRelease{
		{
			TagName:    "Prerelease-Alpha",
			Name:       "Prerelease-Alpha",
			Prerelease: true,
			Assets: []githubReleaseAsset{
				{Name: "mihomo-linux-amd64-v1.19.23.gz", BrowserDownloadURL: "https://example.com/linux.gz"},
			},
		},
	}

	_, _, err := selectLatestAlphaAsset(releases, "linux", "mips64")
	if err == nil || !strings.Contains(err.Error(), "unsupported linux arch") {
		t.Fatalf("expected unsupported arch error, got %v", err)
	}
}
