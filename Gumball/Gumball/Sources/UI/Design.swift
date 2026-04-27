import CoreFoundation
import Foundation

/// Centralised design tokens for the Gumball menu bar popover.
///
/// Replaces magic numbers that used to live inline across MenuBarView.swift.
/// Tweak values here once and the popover updates everywhere.
///
/// Not exhaustive — values are migrated as call sites are touched. The aim is to
/// stop *new* magic numbers from being added inline; existing ones move over
/// opportunistically.
enum Design {
    enum Popover {
        /// Total popover width. Drives the divider inset math too.
        static let width: CGFloat = 280
        /// Uniform inset from each panel edge.
        static let inset: CGFloat = 16
        /// Divider lines stop short of the edges by this fraction of the width on each side.
        static let dividerInsetRatio: CGFloat = 0.05
    }

    enum Artwork {
        static let size: CGFloat = 68
        static let cornerRadius: CGFloat = 6
        /// Leading edge where the metadata text starts: inset + artwork + 10pt HStack spacing.
        static let metadataLeading: CGFloat = 94
    }

    enum Hover {
        /// Resting fill behind icon-button hover targets (e.g. action row buttons).
        static let chipFillOpacity: Double = 0.12
        /// Slightly stronger fill on actively-hovered chips that need extra emphasis.
        static let chipFillOpacityActive: Double = 0.18
        /// Faded resting opacity for icon-only badges.
        static let restingIconOpacity: Double = 0.55
        /// A bit brighter resting state for icons where 0.55 felt too shy (e.g. chip icons).
        static let restingIconOpacityStrong: Double = 0.7
        /// For controls that should always read as primary, just slightly dimmed at rest.
        static let primaryRestingOpacity: Double = 0.9
    }

    enum Animation {
        /// Crossfade between current and previous album art on track change.
        static let crossfade: Double = 0.7
        /// Heart icon (love/unlove) tap animation.
        static let love: Double = 0.15
    }

    enum Background {
        /// Slit-scan background opacity in light mode (lower — bright glass already adds contrast).
        static let opacityLight: Double = 0.38
        /// Slit-scan background opacity in dark mode (higher — needs presence against dark glass).
        static let opacityDark: Double = 0.55
    }
}
