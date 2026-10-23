import Foundation

@main struct HandlerCellTest {
  static func main() async {
    let early = HandlerCell<String>()
    precondition(early.finish("first"))
    precondition(!early.finish("duplicate"), "A terminal cell must reject duplicate completion")
    let earlyValue = await early.wait()
    precondition(earlyValue == "first" && early.stats == [1, 1])
    let racing = HandlerCell<String>()
    async let value = racing.wait()
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<64 { group.addTask { _ = racing.finish(String(index)) } }
    }
    _ = await value
    precondition(racing.stats == [1, 1], "Concurrent finishes must resume exactly once")
    print("handler cell: early, duplicate and 64 competing terminal operations pass")
  }
}
