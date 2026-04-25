# Homebrew package handling

## Self-updating macOS casks

The macOS bootstrap installs Homebrew formulae first, then Homebrew casks.

Some cask applications update themselves outside Homebrew. When those apps are already present, running `brew install --cask` again can make Homebrew compare its recorded cask version against an app that has already self-updated. That work is redundant during dotfiles bootstrap.

The bootstrap treats casks as install-only during dotfiles setup. It skips a cask when Homebrew already lists that cask as installed, so `brew install --cask` does not trigger an implicit upgrade during bootstrap.

For casks marked `auto_updates` in Homebrew metadata, the bootstrap treats the first successful install as the only Homebrew-managed install. Later runs skip the cask when Homebrew metadata records it as installed. If the cask was installed outside Homebrew, the bootstrap also skips it when an application bundle declared by the cask exists in `/Applications`, `~/Applications`, or an absolute `.app` path listed by the cask metadata.

This keeps first-time setup behavior intact for new machines while avoiding repeated Homebrew work for apps that manage their own updates. Casks that are missing continue to use the normal `brew install --cask` path.

## Sudo handling for casks

Formula installation does not keep sudo alive. Immediately before cask installation starts, the bootstrap runs `sudo -v` once and keeps that sudo timestamp active only while the cask batch is running. This avoids repeated password prompts from cask installers without leaving a long-lived sudo keepalive process after the bootstrap finishes.
