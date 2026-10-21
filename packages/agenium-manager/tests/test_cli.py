from importlib.metadata import version

import agenium_sdk
import pytest

import agenium_manager
from agenium_manager.cli import main


def test_version_matches_distribution():
    assert agenium_manager.__version__ == version("agenium-manager")


def test_version_flag_names_manager_sdk_and_contract(capsys):
    with pytest.raises(SystemExit) as exit_info:
        main(["--version"])
    assert exit_info.value.code == 0
    assert capsys.readouterr().out.strip() == (
        f"agenium-manager {agenium_manager.__version__} "
        f"(agenium-sdk {agenium_sdk.__version__}, contract {agenium_sdk.CONTRACT_VERSION})"
    )


def test_no_arguments_prints_help(capsys):
    assert main([]) == 0
    assert capsys.readouterr().out.startswith("usage: agenium-manager")


def test_unknown_argument_is_refused(capsys):
    with pytest.raises(SystemExit) as exit_info:
        main(["install"])
    assert exit_info.value.code == 2
