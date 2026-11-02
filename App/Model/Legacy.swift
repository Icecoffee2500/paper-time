import Foundation

/// What 1.0 set aside. Decided on 2026-11-02 (`Docs/Decisions-1.0.md`): the
/// code and the files stay — a map written in 0.9 still opens, a journal from
/// another device is still read — but the places that *make* these things
/// (menus, buttons, settings sections, sidebar rows) are gone until 2.0
/// takes them up again. One flag per feature, all off, so bringing one back
/// is one line and not an archaeology.
///
/// The Portable build keeps the same list in `shared/legacy.ts`.
enum Legacy {
    /// «Restore Original Text…» in the inspector's File section. Files this
    /// app rewrote before incremental saving (P1) could be repaired from the
    /// imported original; from 1.0 the app never rewrites a file, so the case
    /// stops arising.
    static let restoreOriginalText = false
    /// The handwriting model (Qwen3.5 on MLX): the Settings → Reading
    /// section, the download, and the lasso's route into it. The MLX and
    /// Tokenizers packages are out of `project.yml` with it; the reader is
    /// behind `canImport(MLXVLM)` and simply is not compiled.
    static let handwriting = false
    /// Maps, drafts and resonance — the slip-box's own structures. Existing
    /// maps and drafts still open and the files are untouched; only making
    /// new ones, filing notes onto them, and the «speaks first» echoes go.
    static let slipBoxStructures = false
    /// Settings → Library → «Notes Without a Paper»: choosing a folder for
    /// the notes that belong to no paper. The notes stay (in the app's own
    /// folder) and a folder chosen in 0.9 is still honoured; only the control
    /// is away until 2.0 brings maps and drafts back with it.
    static let looseNotesFolder = false
    /// The paper graph: its sidebar row.
    static let graph = false
    /// What the empty search palette offers (continue, because you read,
    /// revisit, new this week).
    static let emptySearchSuggestions = false
}
