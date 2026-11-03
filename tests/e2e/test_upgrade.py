"""A real upgrade: an installation of the previous image (``tests/upgrade-from.json``) with data is updated to the
current image, a backup written by the previous version is restored by the new one, and a rollback returns to the
previous image with its data. ``test_update_and_rollback_keep_the_data`` only re-tags one image; this test catches
migrations that fail on data written by an older release.

Built and run by .github/workflows/upgrade.yml; by hand:

    NODESTRO_COMPONENTS=tests/upgrade-from.json scripts/build-image.sh nodestro-local:upgrade-from
    scripts/build-image.sh
    NODESTRO_IMAGE=nodestro-local:upgrade-from NODESTRO_UPGRADE_TO=nodestro-local:dev \\
        python -m pytest tests/e2e/test_upgrade.py -v

Without NODESTRO_UPGRADE_TO the module is skipped (the regular end-to-end run has only one image).
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess

import pytest

UPGRADE_TO = os.environ.get("NODESTRO_UPGRADE_TO", "")
if not UPGRADE_TO:
    pytest.skip("NODESTRO_UPGRADE_TO (the image to upgrade to) is not set", allow_module_level=True)

from test_local_docker import (  # noqa: E402, F401 - `installation` is the autouse fixture that starts NODESTRO_IMAGE
    ENV,
    IMAGE,
    LAUNCHER,
    _names,
    _workflow,
    browser,
    container,
    installation,
    launcher,
)


def test_upgrade_from_the_previous_image_keeps_data_and_old_backups_restore(tmp_path: Path) -> None:
    assert IMAGE != UPGRADE_TO, "NODESTRO_IMAGE must be the previous image"
    client = browser()
    _workflow(client, "Made by the old version")
    old_backup = tmp_path / "old.zip"
    launcher("backup", str(old_backup))
    _workflow(client, "Not in the old backup")

    result = subprocess.run(
        [*LAUNCHER, "update"],
        env={**ENV, "NODESTRO_UPDATE_IMAGE": UPGRADE_TO},
        capture_output=True,
        text=True,
        timeout=900,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert container("nodestro")["Config"]["Image"] == UPGRADE_TO
    names = _names(browser())
    assert "Made by the old version" in names and "Not in the old backup" in names, names
    _workflow(browser(), "Made by the new version")

    # A backup written by the previous version, restored by the new one.
    restored = launcher("restore", str(old_backup), check=False)
    assert restored.returncode == 0, restored.stdout + restored.stderr
    names = _names(browser())
    assert "Made by the old version" in names and "Made by the new version" not in names, names

    # Rollback to the previous image with the data from before the update.
    launcher("rollback")
    assert container("nodestro")["Config"]["Image"] == IMAGE
    names = _names(browser())
    assert "Made by the old version" in names and "Not in the old backup" in names, names
