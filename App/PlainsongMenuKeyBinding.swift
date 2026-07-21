import Carbon

/// Layout-independent Carbon binding for ⇧⌘F (Toggle Workspace Search).
enum PlainsongMenuKeyBinding {
    /// Physical ANSI F is stable when Zhuyin/Pinyin change produced characters.
    static let ansiFKeyCode = UInt32(kVK_ANSI_F)
    static let carbonModifiers = UInt32(cmdKey | shiftKey)
}
