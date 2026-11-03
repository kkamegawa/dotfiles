# macOS package management with mise

macOS command-line tools, applications, and fonts listed under `[bootstrap.packages]` in `home/dot_config/mise/config.toml.tmpl` are installed by mise's `brew` and `brew-cask` package managers. The `run_once_after_20-mise-install.sh` script applies this configuration after mise itself has been installed. Later `chezmoi apply` and `chezmoi update` runs invoke `run_after_20-mise-upgrade.sh`: it updates global mise tools, configured `brew` formulae, and mise-owned casks through mise, then runs `brew upgrade --cask` when Homebrew is available to update Homebrew-owned casks. Each manager skips packages owned by the other manager. Homebrew's normal upgrade rules remain in effect; the hook does not pass `--greedy`.

Apple Container is an exception to the mise-managed Homebrew packages. A one-time chezmoi hook installs it from Apple's signed package on supported Apple silicon Macs; routine chezmoi runs do not update it.

The package configuration only targets macOS. It does not install Homebrew itself. mise's Homebrew package managers use Homebrew-compatible package metadata and install packages into the standard Homebrew locations.

## Apple Container signed package

Apple Container is installed from Apple's versioned signed installer package by `run_once_after_35-install-apple-container.sh` on Apple silicon running macOS 26 or later. The hook runs once, skips hosts that already have the `com.apple.container-installer` receipt, verifies the release SHA-256 and installer signature before installation, and does not uninstall Docker or Docker Desktop or overwrite another `container` installation. It does not update Apple Container during normal chezmoi runs.

To update an existing Apple Container installation, stop its services with `container system stop`, then run `/usr/local/bin/update-container.sh`. The updater requires administrator privileges and refuses to proceed while services are running. The hook never falls back to the unsigned package.

## Migrating existing Homebrew installations

Adding a package to mise configuration does not transfer ownership of an existing Homebrew installation. Existing formulae and casks are left in place and remain Homebrew-managed. Do not run `mise bootstrap packages prune` as part of migration.

To transfer an existing package to mise management, first inspect the package and any dependent tools. For a cask, uninstall it with Homebrew and then apply the mise configuration:

```sh
brew uninstall --cask <cask-name>
mise bootstrap packages apply --manager brew-cask --dry-run
mise bootstrap packages apply --manager brew-cask
```

For a formula, use the corresponding `brew uninstall <formula>` command and then apply the `brew` manager. Uninstalling a cask may remove application data or affect macOS privacy permissions. Back up or verify important data before proceeding. Migrate packages individually; do not uninstall packages that are dependencies of tools managed outside mise.

## Unsupported packages and Azure CLI preview

The package list is limited to entries mise can resolve from the configured Homebrew formula and cask sources. `azure-cli-preview` comes from a custom tap and may not be supported by mise's cask implementation; if package application reports an unsupported cask or tap feature, keep that package under a separately managed installation method rather than restoring a general Homebrew package-install script.

Review the `--dry-run` output before applying packages. mise does not install packages declared for another operating system.
