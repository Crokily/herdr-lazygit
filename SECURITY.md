# Security Policy

## Supported versions

Only the latest release receives security fixes. Update with
`herdr plugin install crokily/herdr-lazygit` (optionally `--ref <tag>` for a
pinned release).

## Trust model

- Herdr plugins run with your user privileges; there is no sandbox. Install
  this plugin only from a source you trust.
- The build step downloads pinned lazygit and fzf release archives and
  verifies them against SHA-256 digests stored in this repository, so a
  compromised download host or mirror cannot substitute binaries. Nothing is
  installed globally and `sudo` is never invoked.
- The only network access the plugin itself performs is that runtime download
  at install/build time. The optional AI commit feature sends a bounded sample
  of your staged diff to the AI CLI you select (see "AI data disclosure" in
  the README); the plugin has no telemetry.
- Pane launchers, config generation, and the settings UI operate only on
  files under the plugin's managed checkout and its herdr-provided config
  directory.

## Reporting a vulnerability

Please use GitHub private vulnerability reporting:
<https://github.com/Crokily/herdr-lazygit/security/advisories/new>.
Do not open a public issue for security reports. You can expect an initial
response within a few days.
