package app

import (
	"fmt"
	"strings"
)

const mihomoReleasesAPI = "https://api.github.com/repos/MetaCubeX/mihomo/releases"

type githubRelease struct {
	TagName    string               `json:"tag_name"`
	Name       string               `json:"name"`
	Prerelease bool                 `json:"prerelease"`
	Assets     []githubReleaseAsset `json:"assets"`
}

type githubReleaseAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

func linuxAssetArch(goarch string) (string, error) {
	switch goarch {
	case "amd64":
		return "amd64", nil
	case "arm64":
		return "arm64", nil
	default:
		return "", fmt.Errorf("unsupported linux arch: %s", goarch)
	}
}

func selectLatestAlphaAsset(releases []githubRelease, goos, goarch string) (githubRelease, githubReleaseAsset, error) {
	if goos != "linux" {
		return githubRelease{}, githubReleaseAsset{}, fmt.Errorf("unsupported os: %s", goos)
	}
	arch, err := linuxAssetArch(goarch)
	if err != nil {
		return githubRelease{}, githubReleaseAsset{}, err
	}

	assetPrefix := "mihomo-linux-" + arch + "-"
	for _, release := range releases {
		if !release.Prerelease {
			continue
		}
		label := strings.ToLower(release.TagName + " " + release.Name)
		if !strings.Contains(label, "alpha") {
			continue
		}
		for _, asset := range release.Assets {
			name := strings.ToLower(asset.Name)
			if strings.HasPrefix(name, assetPrefix) && strings.HasSuffix(name, ".gz") {
				return release, asset, nil
			}
		}
	}

	return githubRelease{}, githubReleaseAsset{}, fmt.Errorf("no matching alpha asset for %s/%s", goos, goarch)
}
