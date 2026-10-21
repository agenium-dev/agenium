"""Agenium SDK: the runtime library an Agenium app is built on."""

__version__ = "0.0.1"

# The version of the contract between apps and the manager that this SDK carries.
# 0 means no contract is defined yet; the first published contract is version 1.
CONTRACT_VERSION = 0

__all__ = ["CONTRACT_VERSION", "__version__"]
