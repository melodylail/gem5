"""Shared fixtures and markers for analyzer unit tests."""

import sys

import pytest


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "linux_only: test requires Linux /proc filesystem",
    )


def pytest_collection_modifyitems(config, items):
    skip_linux = pytest.mark.skip(reason="test requires Linux /proc")
    for item in items:
        if "linux_only" in item.keywords and sys.platform != "linux":
            item.add_marker(skip_linux)
