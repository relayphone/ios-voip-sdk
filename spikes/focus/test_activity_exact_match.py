"""Host test for the Swift UI's exact synthetic cadence label matcher."""
import pathlib
import subprocess
import tempfile
import unittest


class ExactCadenceMatchTest(unittest.TestCase):
    def test_full_unambiguous_visible_label_only(self):
        source = pathlib.Path(__file__).resolve().parent / "UITests" / "ActivityExactMatch.swift"
        program = r'''
import Foundation
let id = "12345678-1234-1234-1234-123456789abc"
let expected = "Synthetic cadence \(id) revision 7"
func check(_ expectedResult: Bool, _ id: String, _ revision: Int, _ all: [String], _ visible: [String]) {
  precondition(exactCadenceMatch(observationID: id, revision: revision, allLabels: all, visibleLabels: visible) == expectedResult)
}
check(true, id, 7, ["Revision 7", expected], [expected])
check(false, id, 7, ["Revision 7", String(expected.dropLast())], [String(expected.dropLast())])
check(false, id, 7, ["Revision 7", expected, expected], [expected, expected])
check(false, id, 7, ["Revision 7", expected], [])
check(false, id, 7, ["Revision 07", expected], [expected])
check(false, id.uppercased(), 7, ["Revision 7", expected], [expected])
check(false, "not-a-uuid", 7, ["Revision 7", expected], [expected])
check(false, id, 0, ["Revision 0", expected], [expected])
check(false, id, 1_000_001, ["Revision 1000001", expected], [expected])
check(false, id, 7, ["Revision 7", "Updates delayed"], ["Updates delayed"])
'''
        with tempfile.TemporaryDirectory() as directory:
            main = pathlib.Path(directory) / "main.swift"
            main.write_text(program)
            binary = pathlib.Path(directory) / "match-test"
            subprocess.run(["swiftc", str(source), str(main), "-o", str(binary)], check=True, capture_output=True)
            subprocess.run([str(binary)], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
