from importlib.metadata import version

import agenium_sdk


def test_version_matches_distribution():
    assert agenium_sdk.__version__ == version("agenium-sdk")


def test_contract_version_is_undefined_before_first_contract():
    assert agenium_sdk.CONTRACT_VERSION == 0
