"""Persistent private work and recovery state for the Focus probe."""
import hashlib
import json
from pathlib import Path
import re

LEGACY_FILES = ("restore-state.json", "morning-checkpoint.json")
LEGACY_RECEIPT = "legacy-archive-receipt.json"
LEGACY_RESTORE_RECEIPT = "legacy-journal-restore-receipt.json"


def journal_restore_binding(device, journal_hash):
    """Detect accidental receipt edits; this is not an authentication boundary."""
    return hashlib.sha256(("FocusProbe124:journal-restore:v1:" + device + ":" + journal_hash).encode()).hexdigest()


def legacy_dir():
    return Path(__file__).resolve().parent / "out"


def validate_clean_journal(journal):
    """Reject unknown or pending Settings/ownership restoration markers."""
    if journal is not None:
        try:
            value = json.loads(journal)
        except (ValueError, UnicodeDecodeError) as error:
            raise ValueError("Legacy journal is malformed") from error
        known = {"focusName", "contactName", "captured", "initialFocus", "ownsFocus", "caller", "ownsContact",
                 "requiresProbeUninstall", "autoLock", "autoAnswer", "autoAnswerDelay", "dndAppAllowed", "dndCalls",
                 "dndRepeated", "ownsFavorite", "liveActivitiesEnabled", "liveActivitiesFrequent", "activityPreview",
                 "activityWiFi", "activityCellularData", "ringerVolumePercent"}
        pending = ("autoLock", "autoAnswer", "autoAnswerDelay", "dndAppAllowed", "dndCalls", "dndRepeated",
                   "liveActivitiesEnabled", "liveActivitiesFrequent", "activityPreview", "activityWiFi",
                   "activityCellularData", "ringerVolumePercent")
        if (not isinstance(value, dict) or set(value) - known or value.get("captured") is not False
                or value.get("ownsFocus") is not False or value.get("ownsContact") is not False
                or value.get("requiresProbeUninstall", False) is not False
                or (value.get("ownsFavorite") is not None and value.get("ownsFavorite") is not False)
                or any(value.get(key) is not None for key in pending)):
            raise ValueError("Legacy restore journal still has pending or unknown state")


def legacy_snapshot(legacy):
    """Validate a fully restored old batch and return its exact file contents."""
    contents = {}
    for name in (*LEGACY_FILES, LEGACY_RESTORE_RECEIPT):
        path = legacy / name
        if path.is_symlink():
            raise ValueError("Legacy state cannot be a symlink")
        contents[name] = path.read_bytes() if path.exists() else None
    checkpoint = contents["morning-checkpoint.json"]
    journal = contents["restore-state.json"]
    validate_clean_journal(journal)
    if checkpoint is None:
        # Only supervised_restore writes this binding after successful device
        # restoration; a clean-looking unbound journal is not enough.
        try:
            receipt = json.loads(contents[LEGACY_RESTORE_RECEIPT])
        except (TypeError, ValueError, UnicodeDecodeError) as error:
            raise ValueError("Journal-only archive needs a supervised restore receipt") from error
        if (journal is None or not isinstance(receipt, dict) or receipt.get("version") != 1
                or not isinstance(receipt.get("device"), str)
                or not re.fullmatch(r"[A-F0-9]{8}-[A-F0-9]{16}", receipt["device"])
                or receipt.get("journalHash") != hashlib.sha256(journal).hexdigest()
                or receipt.get("binding") != journal_restore_binding(receipt["device"], receipt["journalHash"])):
            raise ValueError("Journal-only restore receipt does not match")
        state = {"device": receipt["device"]}
    else:
        try:
            state = json.loads(checkpoint)
        except (ValueError, UnicodeDecodeError) as error:
            raise ValueError("Legacy checkpoint is malformed") from error
        if (not isinstance(state, dict) or state.get("version") != 1 or state.get("dirty") is not False
                or state.get("inFlight") is not None or state.get("inFlightAttempt") is not None
                or not isinstance(state.get("completed"), dict)
                or not isinstance(state.get("planHash"), str) or not re.fullmatch(r"[a-f0-9]{64}", state["planHash"])
                or not isinstance(state.get("device"), str) or not re.fullmatch(r"[A-F0-9]{8}-[A-F0-9]{16}", state["device"])):
            raise ValueError("Legacy checkpoint is dirty or incomplete")
    return state, contents


def legacy_hashes(contents):
    return {name: hashlib.sha256(data).hexdigest() if data is not None else None for name, data in contents.items()}


def default_work():
    """Keep build products, checkpoints and restore journal across Mac reboots.

    An explicit archive is needed before leaving an old default checkout-local
    run. A receipt is valid only while its restored source files remain unchanged.
    """
    legacy = legacy_dir()
    if any((legacy / name).exists() or (legacy / name).is_symlink() for name in LEGACY_FILES):
        try:
            state, contents = legacy_snapshot(legacy)
            receipt_path = legacy / LEGACY_RECEIPT
            if receipt_path.is_symlink():
                raise ValueError("Legacy archive receipt cannot be a symlink")
            receipt = json.loads(receipt_path.read_text())
            if (not isinstance(receipt, dict) or receipt.get("version") != 1
                    or receipt.get("device") != state["device"] or receipt.get("files") != legacy_hashes(contents)):
                raise ValueError("Legacy archive receipt does not match")
            archive_name = receipt.get("archive")
            if not isinstance(archive_name, str) or not re.fullmatch(r"[a-f0-9]{32}", archive_name):
                raise ValueError("Legacy archive path is invalid")
            archive = legacy / "legacy-archives" / archive_name
            if archive.is_symlink() or not archive.is_dir():
                raise ValueError("Legacy archive unavailable")
            for name, data in contents.items():
                archived = archive / name
                if archived.is_symlink() or (data is None and archived.exists()) or (data is not None and archived.read_bytes() != data):
                    raise ValueError("Legacy archive contents do not match")
        except (OSError, ValueError, TypeError, UnicodeDecodeError) as error:
            raise ValueError("Prior Focus work detected; set FOCUS_WORK to " + str(legacy) +
                             " to resume or restore, then run morning-batch --archive-legacy") from error
    return Path.home() / "Library" / "Application Support" / "FocusProbe124"
