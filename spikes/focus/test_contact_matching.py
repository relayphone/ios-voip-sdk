"""Exercise the Contacts phone comparison without accessing an address book."""
from pathlib import Path
import subprocess
import tempfile
import unittest


class ContactPhoneMatchingTests(unittest.TestCase):
    def test_conservative_normalization_and_ambiguous_inputs(self):
        source = Path(__file__).parent / "App" / "ContactPhoneMatch.swift"
        with tempfile.TemporaryDirectory() as directory:
            main = Path(directory) / "main.swift"
            main.write_text('''
let candidate = "447700900123"
precondition(contactPhoneMatch(candidate: candidate, raw: "+44 7700 900123") == true)
precondition(contactPhoneMatch(candidate: candidate, raw: "07700 900123") == true)
precondition(contactPhoneMatch(candidate: candidate, raw: "+44 7700 900123.42") == nil)
precondition(contactPhoneMatch(candidate: candidate, raw: "+1 555 555 0199") == false)
precondition(contactPhoneMatch(candidate: candidate, raw: "1-800-FLOWERS") == nil)
precondition(contactPhoneMatch(candidate: candidate, raw: "900123.42") == nil)
precondition(contactPhoneMatch(candidate: candidate, raw: "+44 7700 900123;123") == nil)
precondition(contactPhoneMatch(candidate: candidate, raw: "+44 7700 900123#123") == nil)
precondition(contactPhoneMatch(candidate: candidate, raw: "123") == nil)
precondition(contactPhoneMatch(candidate: candidate, raw: "１２３４") == nil)
var empty = OwnedContactAudit(candidate: candidate)
empty.record(nameMatches: false, numbers: ["+1 555 555 0199"])
precondition(empty.result == "absent")
var renamed = OwnedContactAudit(candidate: candidate)
renamed.record(nameMatches: false, numbers: ["+44 7700 900123"])
precondition(renamed.result == "unavailable")
var owned = OwnedContactAudit(candidate: candidate)
owned.record(nameMatches: true, numbers: ["7700900123"])
precondition(owned.result == "present")
owned.record(nameMatches: false, numbers: ["+44 7700 900123"])
precondition(owned.result == "unavailable")
var duplicate = OwnedContactAudit(candidate: candidate)
duplicate.record(nameMatches: true, numbers: ["+44 7700 900123"])
duplicate.record(nameMatches: true, numbers: ["+44 7700 900123"])
precondition(duplicate.result == "unavailable")
var unreadable = OwnedContactAudit(candidate: candidate)
unreadable.record(nameMatches: false, numbers: ["900123.42"])
precondition(unreadable.result == "unavailable")
''')
            output = Path(directory) / "test"
            subprocess.run(["xcrun", "swiftc", str(source), str(main), "-o", str(output)],
                           check=True, timeout=45, capture_output=True)
            subprocess.run([str(output)], check=True, timeout=10, capture_output=True)
