import Foundation
import CallKit
private func marker(_ text: String) { FileHandle.standardError.write(Data(("EXPERIMENT " + text + "\n").utf8)) }
@_cdecl("constructSwiftProvider")
func constructSwiftProvider() {
    let provider = CXProvider(configuration: CXProviderConfiguration())
    marker("swift-constructor-returned")
    let description: String = provider.description
    marker("swift-description-returned=" + description)
}
