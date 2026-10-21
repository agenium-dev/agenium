# agenium-sdk

The runtime library an Agenium app is built on. It will carry the versioned contract between apps and the Agenium manager: a core that every app implements and named features an app may add.

This package is at a very early stage. The contract is not defined yet, so this release carries only the package version and the contract version, which is `0` until the first contract is published.

```python
import agenium_sdk

agenium_sdk.__version__       # "0.0.1"
agenium_sdk.CONTRACT_VERSION  # 0 - no contract defined yet
```

Part of [Agenium](https://github.com/agenium-dev/agenium).
