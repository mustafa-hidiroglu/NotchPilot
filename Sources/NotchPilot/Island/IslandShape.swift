import SwiftUI

/// The island silhouette.
///
/// * Floating (no camera housing): a rounded rectangle, `topRadius == bottomRadius`.
/// * Attached to the housing: square top edge flush with the screen, with concave
///   "shoulders" of `shoulderRadius` that flare outwards so the island reads as a continuation
///   of the hardware rather than a sticker on top of the menu bar.
///
/// The body occupies the rect inset horizontally by `shoulderRadius`; shoulders draw into
/// that inset. All three radii animate, so the corners morph smoothly between presentations.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var shoulderRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), shoulderRadius) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            shoulderRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(shoulderRadius, rect.width / 4, rect.height / 2)
        let body = rect.insetBy(dx: s, dy: 0)
        let bottom = min(bottomRadius, body.width / 2, body.height / 2)
        let top = min(topRadius, body.width / 2, max(0, body.height - bottom))

        var path = Path()
        // Top-left: shoulder flare or rounded corner.
        if s > 0 {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: body.minX, y: rect.minY + s), control: CGPoint(x: body.minX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: body.minX, y: body.minY + top))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + top, y: body.minY), radius: top)
            path.addLine(to: CGPoint(x: body.maxX - top, y: body.minY))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + top), radius: top)
        }

        if s > 0 {
            // Left side down, bottom edge, right side up, then right shoulder back to the top.
            path.addLine(to: CGPoint(x: body.minX, y: body.maxY - bottom))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX + bottom, y: body.maxY), radius: bottom)
            path.addLine(to: CGPoint(x: body.maxX - bottom, y: body.maxY))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX, y: body.maxY - bottom), radius: bottom)
            path.addLine(to: CGPoint(x: body.maxX, y: rect.minY + s))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: body.maxX, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - bottom))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - bottom, y: body.maxY), radius: bottom)
            path.addLine(to: CGPoint(x: body.minX + bottom, y: body.maxY))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - bottom), radius: bottom)
        }
        path.closeSubpath()
        return path
    }
}
