import Foundation

@main
struct ProjectionTests {
  @MainActor static func main() async throws {
    let id = UUID()
    let terminal = SystemConversation()
    var buffer = TerminalConversationProjection<SystemConversation>()
    let first = buffer.publishTerminal(terminal, id: id)
    precondition(buffer.project(current: [:])[id] === terminal,
      "A real terminal delegate object remains projectable after the manager removes it")
    precondition(buffer.remove(id, generation: first))
    precondition(buffer.project(current: [:]).isEmpty, "Next-turn cleanup leaves no call history")
    let firstLife = SystemConversation()
    let secondLife = SystemConversation()
    let oldCleanup = buffer.publishTerminal(firstLife, id: id)
    let newCleanup = buffer.publishTerminal(secondLife, id: id)
    precondition(!buffer.remove(id, generation: oldCleanup), "An older cleanup cannot remove a newer terminal generation")
    precondition(buffer.project(current: [:])[id] === secondLife)
    precondition(buffer.remove(id, generation: newCleanup))
    let obsoleteCleanup = buffer.publishTerminal(firstLife, id: id)
    precondition(buffer.project(current: [id: secondLife])[id] === secondLife,
      "A new authoritative manager object wins over an older terminal object")
    precondition(!buffer.remove(id, generation: obsoleteCleanup) && buffer.project(current: [:]).isEmpty,
      "Invalidated terminal history cannot reappear after a reused UUID disappears")
    let listedTerminal = buffer.publishTerminal(terminal, id: id)
    precondition(buffer.remove(id, generation: listedTerminal))
    precondition(buffer.project(current: [id: terminal])[id] === terminal,
      "Cleanup must not hide a terminal object that the manager still lists")
    var cancellationSideEffects = 0
    let rejected = TerminalConversationProjection<SystemConversation>.acceptingTerminal(firstLife, current: secondLife) {
      cancellationSideEffects += 1
      return buffer.publishTerminal(firstLife, id: id)
    }
    precondition(rejected == nil && cancellationSideEffects == 0 && buffer.object(for: id) == nil,
      "An obsolete terminal delegate cannot publish or cancel a new UUID lifetime")
    let admitted = TerminalConversationProjection<SystemConversation>.acceptingTerminal(terminal, current: nil) {
      cancellationSideEffects += 1
      return buffer.publishTerminal(terminal, id: id)
    }
    precondition(admitted != nil && cancellationSideEffects == 1)
    if let admitted { buffer.remove(id, generation: admitted) }
    print("Terminal projection tests passed; incoming intake concurrency has its own suite")
  }
}
final class SystemConversation {}
