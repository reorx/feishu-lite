#!/bin/bash
# Render from the exact published artifact; no network or repository mutations.
set -euo pipefail
version=${1:?Usage: render-cask.sh VERSION SHA256 BACKEND_COMMIT}
sha256=${2:?Usage: render-cask.sh VERSION SHA256 BACKEND_COMMIT}
revision=${3:?Usage: render-cask.sh VERSION SHA256 BACKEND_COMMIT}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid release version' >&2; exit 1; }
[[ "$sha256" =~ ^[a-f0-9]{64}$ ]] || { echo 'Invalid SHA256' >&2; exit 1; }
[[ "$revision" =~ ^[a-f0-9]{40}$ ]] || { echo 'Backend must be pinned to a full commit SHA' >&2; exit 1; }
cat <<RUBY
cask "feishu-lite" do
  version "$version"
  sha256 "$sha256"

  url "https://github.com/reorx/feishu-lite/releases/download/v#{version}/FeishuChat-#{version}.dmg"
  name "FeishuChat"
  desc "Lightweight Feishu chat client"
  homepage "https://github.com/reorx/feishu-lite"

  depends_on macos: :sonoma
  depends_on formula: "uv"
  depends_on formula: "git"

  app "FeishuChat.app"

  # Third-party tap Ruby hook: also runs on upgrade. Keep the Finder-visible path
  # stable even when a shell config customizes UV_TOOL_BIN_DIR.
  postflight do
    system_command "#{HOMEBREW_PREFIX}/opt/uv/bin/uv",
                   args: ["tool", "install", "--force", "--python", "3.12", "--",
                          "git+https://github.com/reorx/feishu-lite.git@$revision#subdirectory=backend"],
                   env: { "UV_TOOL_BIN_DIR" => File.expand_path("~/.local/bin") },
                   must_succeed: true
  end

  caveats <<~EOS
    The Python backend is installed for the current user using uv.
    Installation and upgrades require access to GitHub and Python package sources.
    Quit FeishuChat before upgrading, then reopen it.
    Uninstalling the cask preserves your login, messages, mail and uv backend.
    To remove the backend separately: uv tool uninstall feishu-lite-backend
  EOS
end
RUBY
