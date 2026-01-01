class Ocdc < Formula
  desc "OpenCode DevContainers - Run multiple devcontainer instances with auto-assigned ports"
  homepage "https://github.com/athal7/ocdc"
  url "https://github.com/athal7/ocdc/archive/refs/tags/v2.2.0.tar.gz"
  # SHA256 will be calculated after tagging v2.2.0 release
  # Calculate with: curl -L https://github.com/athal7/ocdc/archive/refs/tags/v2.2.0.tar.gz | shasum -a 256
  # For testing before release, use: brew install --HEAD athal7/tap/ocdc
  sha256 "" # TODO: Fill after release is created
  license "MIT"
  head "https://github.com/athal7/ocdc.git", branch: "main"

  depends_on "jq"
  depends_on "tmux"

  def install
    # Install everything to prefix to maintain relative paths
    prefix.install Dir["bin", "lib", "plugin", "share"]
    
    # Symlink main executable to bin
    bin.install_symlink prefix/"bin/ocdc"
  end

  def caveats
    <<~EOS
      To enable automatic polling of GitHub issues and PRs:
      
      1. Configure your poll settings:
         mkdir -p ~/.config/ocdc/polls
         cp "$(brew --prefix ocdc)/share/ocdc/examples/github-issues.yaml" ~/.config/ocdc/polls/
         # Edit ~/.config/ocdc/polls/github-issues.yaml with your repos
      
      2. Start the polling service:
         brew services start ocdc
      
      The polling service runs every 5 minutes and automatically creates
      devcontainer sessions for new issues/PRs with the configured label.
      
      View logs:
         tail -f "$(brew --prefix)/var/log/ocdc-poll.log"
      
      Note: The service runs in your user context and has access to:
      - Your home directory (~/.config/ocdc/)
      - GitHub CLI authentication (if configured with 'gh auth login')
      - Environment variables from your shell profile
    EOS
  end

  service do
    run [opt_bin/"ocdc", "poll", "--once"]
    run_type :interval
    interval 300
    keep_alive false
    log_path var/"log/ocdc-poll.log"
    error_log_path var/"log/ocdc-poll.log"
    environment_variables PATH: std_service_path_env,
                          HOME: ENV["HOME"]
    # Service runs in user context and inherits:
    # - ~/.config/ocdc/polls/ configurations
    # - gh CLI authentication (if configured)
    # - opencode CLI (if installed globally)
  end

  test do
    # Test main executable and version
    assert_match "ocdc v#{version}", shell_output("#{bin}/ocdc version")
    
    # Test that help works (verifies lib files are accessible)
    assert_match "OpenCode DevContainers", shell_output("#{bin}/ocdc help")
    
    # Test that subcommands are registered
    help_output = shell_output("#{bin}/ocdc help")
    assert_match "poll", help_output
    assert_match "up", help_output
    assert_match "down", help_output
  end
end
