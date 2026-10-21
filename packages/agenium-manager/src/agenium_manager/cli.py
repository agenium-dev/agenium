"""The agenium-manager command line."""

import argparse

import agenium_sdk

from agenium_manager import __version__


def version_line() -> str:
    return (
        f"agenium-manager {__version__} "
        f"(agenium-sdk {agenium_sdk.__version__}, contract {agenium_sdk.CONTRACT_VERSION})"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="agenium-manager",
        description=(
            "The Agenium manager. Early stage: it does not manage apps yet, "
            "and reports only its version and the contract it understands."
        ),
    )
    parser.add_argument("--version", action="version", version=version_line())
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    parser.parse_args(argv)
    parser.print_help()
    return 0
