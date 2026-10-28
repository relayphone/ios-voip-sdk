#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="sdk-caller-tests-") as temporary:
    binary = str(Path(temporary) / "CallerTests")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
        "Sources/VoIPSDK/ConversationModels.swift", "Tests/Caller/CallerTests.swift", "-o", binary], cwd=ROOT, check=True, timeout=60)
    subprocess.run([binary], check=True, timeout=10)

    source = (ROOT / "Sources/VoIPSDK/IncomingReportTransport.swift").read_text()
    source = source.replace("#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))", "#if true", 1)
    source = source.replace("@preconcurrency import LiveCommunicationKit", "", 1)
    transport = Path(temporary) / "IncomingReportTransport.swift"
    transport.write_text(source)
    binary = str(Path(temporary) / "SystemReportTests")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
        "Sources/VoIPSDK/ConversationModels.swift", "Sources/VoIPSDK/PushWire.swift",
        "Sources/VoIPSDK/IncomingIntake.swift", "Sources/VoIPSDK/IncomingInvitationGate.swift",
        str(transport), "Tests/Caller/SystemReportTests.swift", "-o", binary], cwd=ROOT, check=True, timeout=60)
    subprocess.run([binary], check=True, timeout=10)

    binary = str(Path(temporary) / "IntentTests")
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
        "Sources/VoIPSDK/ConversationModels.swift", "Sources/VoIPSDK/Caller+Intents.swift",
        "Tests/Caller/IntentTests.swift", "-o", binary], cwd=ROOT, check=True, timeout=60)
    subprocess.run([binary], check=True, timeout=10)
