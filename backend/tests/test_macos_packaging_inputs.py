import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "scripts" / "check-macos-package-inputs.sh"


def run_check(root: Path) -> subprocess.CompletedProcess[str]:
    environment = {**os.environ, "PROMPTMEET_PACKAGE_ROOT": str(root)}
    return subprocess.run(
        ["bash", str(CHECK)],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )


def test_packaging_check_names_every_missing_required_source(tmp_path: Path) -> None:
    result = run_check(tmp_path)

    assert result.returncode == 1
    assert "backend/requirements-desktop.txt" in result.stderr
    assert "desktop-macos/Resources/Info.plist" in result.stderr
    assert "desktop-macos/THIRD_PARTY_NOTICES.md" in result.stderr


def test_repository_contains_every_required_packaging_source() -> None:
    result = run_check(ROOT)

    assert result.returncode == 0, result.stderr


def test_package_requires_audio_input_entitlement() -> None:
    entitlement_path = ROOT / "desktop-macos/Resources/PromptMeet.entitlements"
    assert entitlement_path.is_file()
    entitlement = plistlib.loads(entitlement_path.read_bytes())
    assert entitlement["com.apple.security.device.audio-input"] is True

    build_script = (ROOT / "scripts/build-macos-app.sh").read_text()
    assert (
        '--entitlements "$MACOS_ROOT/Resources/PromptMeet.entitlements"' in build_script
    )
