# Homebrew package handling

## Self-updating macOS casks

The macOS bootstrap installs Homebrew formulae first, then Homebrew casks.

Some cask applications update themselves outside Homebrew. When those apps are already present, running `brew install --cask` again can make Homebrew compare its recorded cask version against an app that has already self-updated. That work is redundant during dotfiles bootstrap.

The bootstrap treats casks as install-only during dotfiles setup. It skips a cask when Homebrew already lists that cask as installed, so `brew install --cask` does not trigger an implicit upgrade during bootstrap.

For casks marked `auto_updates` in Homebrew metadata, the bootstrap also skips the cask when the application bundle declared by the cask already exists in `/Applications` or `~/Applications`, even if Homebrew does not list that cask as installed.

This keeps first-time setup behavior intact for new machines while avoiding repeated Homebrew work for apps that manage their own updates. Casks that are missing continue to use the normal `brew install --cask` path.
