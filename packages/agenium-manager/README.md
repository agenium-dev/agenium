# agenium-manager

The command-line manager for Agenium. It will install each Agenium app into its own isolated environment from recorded versions, update, lock and roll it back, and run it from that ready environment.

This package is at a very early stage. This release has no app management yet: the `agenium-manager` command prints its version, the SDK and contract version it understands, and its help.

```sh
uv tool install agenium-manager
agenium-manager --version
agenium-manager --help
```

Part of [Agenium](https://github.com/agenium-dev/agenium).
