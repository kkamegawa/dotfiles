# Homebrew package handling

## Self-updating macOS casks

The macOS bootstrap installs Homebrew formulae first, then Homebrew casks.

Some cask applications update themselves outside Homebrew. When those apps are already present, running `brew install --cask` again can make Homebrew compare its recorded cask version against an app that has already self-updated. That work is redundant during dotfiles bootstrap.

For casks marked `auto_updates` in Homebrew metadata, the bootstrap now skips the cask when either of these is true:

- Homebrew already lists the cask as installed.
- The application bundle declared by the cask already exists in `/Applications` or `~/Applications`.

This keeps first-time setup behavior intact for new machines while avoiding repeated Homebrew work for apps that manage their own updates. Casks that are not marked `auto_updates` continue to use the normal `brew install --cask` path.
