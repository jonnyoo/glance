//
//  MinimalUnlockView.swift
//  glance
//
//  Content for `UnlockAnimationStyle.minimal` — the variant that never does
//  the full-panel expansion. The silhouette only *widens*, and this fills
//  that widened strip:
//
//      [ lock ][ · · · gap · · · ][ video ]
//
//  The same layout serves both silhouettes, for different reasons:
//
//  - `.notch` — the gap IS the physical notch cutout, which has no display
//    behind it. Widening the panel creates black flanks on either side of
//    it, and these two regions are exactly those flanks; anything drawn in
//    the gap would be invisible.
//  - `.pill` — there's no cutout, so the gap is just negative space and
//    this reads as a lock and a video at opposite ends of a capsule.
//
//  The middle `Spacer` is what makes one layout cover both: it absorbs
//  whatever the panel's width happens to be (which differs per style, and
//  grows further on hover) without this view needing to know any of it.
//
//  The media is `ScanAnimationView` unchanged — it already maps `.idle` to
//  the still and `.success`/`.failure` to their videos, and holds the final
//  frame. The assets are 432x432 on solid black and aspect-fit, so they
//  letterbox invisibly against the black panel at this much smaller size.
//

import SwiftUI

struct MinimalUnlockView: View {
    let media: ScanMedia
    /// Drives the lock → unlock symbol transition. Owned by the caller
    /// (which applies `minimalLockUnlockDelay`) rather than derived from
    /// `media` here, so the glyph and the video can be offset from each
    /// other.
    let isUnlocked: Bool
    /// Inset from the silhouette's left/right edges. The caller adds the
    /// notch's flare allowance into this where it applies.
    let edgeInset: CGFloat
    /// The scan "breathing" pulse — applied to the video only, not the lock
    /// icon or the panel as a whole. Both default to identity so callers
    /// outside `.scanning` (or previews) don't need to pass anything.
    var pulseScale: CGFloat = 1
    var pulseOpacity: Double = 1

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: isUnlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: NotchGeometry.minimalLockIconSize, weight: .semibold))
                .foregroundStyle(GlanceTheme.textPrimary)
                // Magic replace morphs the shackle between the two glyphs
                // instead of cross-fading them. It only animates if the
                // change is inside an animation transaction, and the phase
                // change that flips `isUnlocked` isn't wrapped in one — so
                // the explicit `.animation` below is doing real work, not
                // decorating.
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                .animation(
                    .smooth(duration: NotchGeometry.minimalLockAnimationDuration),
                    value: isUnlocked
                )
                .frame(width: NotchGeometry.minimalMediaWidth)

            Spacer(minLength: 0)

            ScanAnimationView(media: media)
                .padding(.vertical, NotchGeometry.minimalMediaVerticalInset + 4)
                .frame(width: NotchGeometry.minimalMediaWidth)
                // Scoped to the video alone — the lock icon on the left
                // must stay steady while this breathes.
                .scaleEffect(pulseScale)
                .opacity(pulseOpacity)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, edgeInset)
    }
}
