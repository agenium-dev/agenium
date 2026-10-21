# Agenium

Agenium gives AI agents their capabilities: the SDK an app is built on, the manager that installs and runs apps, and the apps themselves.

Agenium is at a very early stage. The packages published so far are minimal: they reserve their names, carry their versions, and set up the repository's build and release path. They provide no working capability yet, and nothing in them is stable.

## Packages

Each package lives in its own folder under `packages/` and is versioned and released on its own.

- [`agenium-sdk`](packages/agenium-sdk) - the runtime library an app is built on, carrying the versioned contract between apps and the manager.
- [`agenium-manager`](packages/agenium-manager) - the command-line manager that installs apps into their own environments and runs them.

## Development

The repository is a [uv](https://docs.astral.sh/uv/) workspace.

```sh
uv sync
uv run --package agenium-sdk pytest packages/agenium-sdk
uv run --package agenium-manager pytest packages/agenium-manager
```

## Releasing

A package is released by pushing a tag named `<package>/v<version>`, for example `agenium-sdk/v0.0.1`, on a commit whose package version matches it. The `publish.yml` workflow builds that package and publishes it to PyPI through Trusted Publishing from the package's own environment.
