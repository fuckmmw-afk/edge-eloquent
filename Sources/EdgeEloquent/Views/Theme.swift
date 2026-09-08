//
//  Theme.swift
//  EdgeEloquent
//
//  Created for Edge Eloquent: On-Device Speech Intelligence.
//  Design tokens, color palettes, and typography matching Google AI Edge Gallery.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Central design system tokens adapted from Google AI Edge Gallery.
public enum Theme {

    // MARK: - Color Palette

    public static let edgeBlue = Color(red: 0.1, green: 0.45, blue: 0.95)
    public static let recordingRed = Color(red: 0.95, green: 0.25, blue: 0.21)
    public static let processingAmber = Color(red: 0.96, green: 0.65, blue: 0.14)
    public static let successGreen = Color(red: 0.15, green: 0.78, blue: 0.48)

    #if canImport(UIKit)
    public static let surfaceBackground = Color(UIColor.systemGroupedBackground)
    public static let cardBackground = Color(UIColor.secondarySystemGroupedBackground)
    public static let elevatedCardBackground = Color(UIColor.tertiarySystemGroupedBackground)
    #else
    public static let surfaceBackground = Color(.windowBackgroundColor)
    public static let cardBackground = Color(.controlBackgroundColor)
    public static let elevatedCardBackground = Color(.controlBackgroundColor)
    #endif

    public static let subtleBorder = Color.primary.opacity(0.08)
    public static let strongBorder = Color.primary.opacity(0.16)

    // MARK: - Layout Dimensions

    public static let cardCornerRadius: CGFloat = 20
    public static let standardCornerRadius: CGFloat = 14
    public static let pillCornerRadius: CGFloat = 100

    public static let standardPadding: CGFloat = 16
    public static let largePadding: CGFloat = 24

    // MARK: - Shadows

    public static let cardShadowColor = Color.black.opacity(0.06)
    public static let cardShadowRadius: CGFloat = 8
    public static let cardShadowY: CGFloat = 4

    // MARK: - Animations

    public static let standardSpring = Animation.spring(response: 0.35, dampingFraction: 0.75)
    public static let gentleSpring = Animation.spring(response: 0.5, dampingFraction: 0.85)
    public static let pulseAnimation = Animation.easeInOut(duration: 0.9).repeatForever(autoreverses: true)
}

// MARK: - View Modifiers

public struct EdgeCardStyle: ViewModifier {
    public var cornerRadius: CGFloat = Theme.cardCornerRadius

    public func body(content: Content) -> some View {
        content
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.subtleBorder, lineWidth: 1)
            )
            .shadow(color: Theme.cardShadowColor, radius: Theme.cardShadowRadius, x: 0, y: Theme.cardShadowY)
    }
}

extension View {
    public func edgeCardStyle(cornerRadius: CGFloat = Theme.cardCornerRadius) -> some View {
        self.modifier(EdgeCardStyle(cornerRadius: cornerRadius))
    }
}
