import Foundation

enum EditorLayoutMode: String, CaseIterable, Equatable {
    case sourcePreview
    case sourceOnly
    case wysiwyg

    var showsPreview: Bool {
        self == .sourcePreview
    }

    var usesWYSIWYGPresentation: Bool {
        self == .wysiwyg
    }

    func next(isWYSIWYGAvailable: Bool) -> EditorLayoutMode {
        switch self {
        case .sourcePreview:
            .sourceOnly
        case .sourceOnly:
            isWYSIWYGAvailable ? .wysiwyg : .sourcePreview
        case .wysiwyg:
            .sourcePreview
        }
    }
}
