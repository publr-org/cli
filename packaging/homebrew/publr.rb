# The formula in publr-org/homebrew-tap, written from this template by the Release workflow
# (@VERSION@ and the checksums filled in). `brew install publr-org/tap/publr`.
class Publr < Formula
  desc "Make, run, clone and deploy Publr sites"
  homepage "https://publr.dev"
  version "@VERSION@"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/publr-org/cli/releases/download/v@VERSION@/publr-macos-aarch64"
      sha256 "@MACOS_AARCH64@"
    end
    on_intel do
      url "https://github.com/publr-org/cli/releases/download/v@VERSION@/publr-macos-x86_64"
      sha256 "@MACOS_X86_64@"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/publr-org/cli/releases/download/v@VERSION@/publr-linux-aarch64"
      sha256 "@LINUX_AARCH64@"
    end
    on_intel do
      url "https://github.com/publr-org/cli/releases/download/v@VERSION@/publr-linux-x86_64"
      sha256 "@LINUX_X86_64@"
    end
  end

  def install
    bin.install Dir["publr-*"].first => "publr"
  end

  test do
    assert_match "publr #{version}", shell_output("#{bin}/publr --version")
  end
end
