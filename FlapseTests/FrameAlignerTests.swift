import XCTest
import UIKit
@testable import Flapse

final class FrameAlignerTests: XCTestCase {

    private func pattern(offsetX: CGFloat, offsetY: CGFloat) -> Data {
        let size = CGSize(width: 480, height: 640)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            let c = ctx.cgContext
            UIColor.white.setFill()
            c.fill(CGRect(x: 210 + offsetX, y: 210 + offsetY, width: 60, height: 60))
            UIColor(white: 0.55, alpha: 1).setFill()
            c.fillEllipse(in: CGRect(x: 140 + offsetX, y: 330 + offsetY, width: 60, height: 60))
            UIColor.white.setFill()
            c.fill(CGRect(x: 300 + offsetX, y: 380 + offsetY, width: 34, height: 110))
        }
        return image.jpegData(compressionQuality: 0.95)!
    }

    func test_translationOffset_detectsKnownShift_withConsistentSign() {
        let reference = pattern(offsetX: 0, offsetY: 0)
        let target = pattern(offsetX: 48, offsetY: 64)

        guard let offset = FrameAligner.translationOffset(targetData: target, referenceData: reference) else {
            return XCTFail("Kayıt (registration) bir öteleme döndürmeliydi")
        }

        XCTAssertEqual(offset.width, -0.1, accuracy: 0.035)
        XCTAssertEqual(offset.height, 0.1, accuracy: 0.035)
    }

    func test_translationOffset_identicalFrames_isNearZero() {
        let reference = pattern(offsetX: 0, offsetY: 0)

        guard let offset = FrameAligner.translationOffset(targetData: reference, referenceData: reference) else {
            return XCTFail("Aynı kare için öteleme sıfıra yakın olmalı")
        }

        XCTAssertEqual(offset.width, 0, accuracy: 0.02)
        XCTAssertEqual(offset.height, 0, accuracy: 0.02)
    }

    func testSceneTransformDetectsKnownShiftInUIKitCoordinates() {
        let reference = pattern(offsetX: 0, offsetY: 0)
        let target = pattern(offsetX: 48, offsetY: 64)

        guard let transform = FrameAligner.sceneTransform(
            targetData: target,
            referenceData: reference
        ) else {
            return XCTFail("Sahne eşleşmesi bir dönüşüm üretmeliydi")
        }

        XCTAssertEqual(transform.tx, -0.1, accuracy: 0.04)
        XCTAssertEqual(transform.ty, -0.1, accuracy: 0.04)
        XCTAssertEqual(hypot(transform.a, transform.b), 1, accuracy: 0.08)
        XCTAssertEqual(hypot(transform.c, transform.d), 1, accuracy: 0.08)
    }

    func testNormalizedSceneShiftDoesNotGrowWhenCanvasAspectChanges() {
        let normalized = CGAffineTransform(translationX: -0.1, y: 0.08)
        let portrait = FrameAligner.canvasTransform(
            from: normalized,
            canvas: CGSize(width: 1080, height: 1920)
        )
        let landscape = FrameAligner.canvasTransform(
            from: normalized,
            canvas: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(portrait.tx, -108, accuracy: 0.001)
        XCTAssertEqual(portrait.ty, 153.6, accuracy: 0.001)
        XCTAssertEqual(landscape.tx, -192, accuracy: 0.001)
        XCTAssertEqual(landscape.ty, 86.4, accuracy: 0.001)
    }

    func testCoupleMatchingMirrorsOnlyWhenCrossedIdentityCostIsLower() {
        XCTAssertTrue(FrameAligner.shouldMirror(sameDistance: 1.2, mirroredDistance: 0.3))
        XCTAssertFalse(FrameAligner.shouldMirror(sameDistance: 0.3, mirroredDistance: 1.2))
        XCTAssertFalse(FrameAligner.shouldMirror(sameDistance: 0.31, mirroredDistance: 0.30))
    }

    func testCoupleModeDoesNotProduceGeometricAnchor() {
        XCTAssertNil(FrameAligner.anchor(in: pattern(offsetX: 0, offsetY: 0), subject: .group))
    }

    func testSceneModeUsesRegistrationInsteadOfSubjectAnchor() {
        XCTAssertNil(FrameAligner.anchor(in: pattern(offsetX: 0, offsetY: 0), subject: .scene))
    }

    func testStabilizationUsesThreeFrameMedianAndKeepsMissingDetectionsMissing() {
        let anchors: [FrameAnchor?] = [
            FrameAnchor(center: CGPoint(x: 0.2, y: 0.4), height: 0.2, roll: 0.1, confidence: 0.6),
            FrameAnchor(center: CGPoint(x: 0.8, y: 0.5), height: 0.8, roll: 0.3, confidence: 0.9),
            FrameAnchor(center: CGPoint(x: 0.4, y: 0.6), height: 0.4, roll: 0.2, confidence: 0.7),
            nil
        ]

        let stabilized = FrameAligner.stabilized(anchors)

        guard let middle = stabilized[1] else {
            return XCTFail("Median smoothing should preserve a detected anchor")
        }
        XCTAssertEqual(middle.center.x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(middle.center.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(middle.height, 0.4, accuracy: 0.0001)
        XCTAssertEqual(middle.roll, 0.2, accuracy: 0.0001)
        XCTAssertNil(stabilized[3])
    }

    func testBestReferenceChoosesHighestConfidenceDetection() {
        let low = FrameAnchor(center: .zero, height: 0.2, roll: 0, confidence: 0.3)
        let high = FrameAnchor(center: CGPoint(x: 0.5, y: 0.5), height: 0.4, roll: 0.1, confidence: 0.95)
        XCTAssertEqual(FrameAligner.bestReference(in: [low, nil, high]), high)
    }

    func testAnimalHeadHeightUsesLandmarkScaleInsteadOfWholeBodyScale() {
        let height = FrameAligner.animalHeadHeight(
            points: [
                CGPoint(x: 0.42, y: 0.30),
                CGPoint(x: 0.58, y: 0.31),
                CGPoint(x: 0.50, y: 0.39)
            ],
            imageSize: CGSize(width: 1200, height: 1600),
            bodyBox: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.75)
        )

        XCTAssertEqual(height, 0.135, accuracy: 0.001)
        XCTAssertLessThan(height, 0.75)
    }

    func testAnimalHeadHeightIsBoundedWhenLandmarksAreNoisy() {
        let body = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.50)
        let tooSmall = FrameAligner.animalHeadHeight(
            points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.501, y: 0.501)],
            imageSize: CGSize(width: 1000, height: 1000),
            bodyBox: body
        )
        let tooLarge = FrameAligner.animalHeadHeight(
            points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)],
            imageSize: CGSize(width: 1000, height: 1000),
            bodyBox: body
        )

        XCTAssertEqual(tooSmall, 0.09, accuracy: 0.001)
        XCTAssertEqual(tooLarge, 0.275, accuracy: 0.001)
    }

    func testSceneTransformsTrackGradualMotionBeyondFirstFrameOverlap() {
        let frames = (0..<5).map { pattern(offsetX: CGFloat($0 * 24), offsetY: 0) }
        let transforms = FrameAligner.sceneTransforms(for: frames, keyframeInterval: 2)

        XCTAssertEqual(transforms.count, frames.count)
        XCTAssertEqual(transforms[0]?.tx ?? 1, 0, accuracy: 0.001)
        XCTAssertNotNil(transforms[4])
        XCTAssertLessThan(transforms[4]?.tx ?? 0, -0.12)
        XCTAssertLessThanOrEqual(abs(transforms[4]?.ty ?? 1), 0.05)
    }

    func testPropagatedAnimalAnchorPreservesSemanticScaleAcrossTranslation() {
        let reference = FrameAnchor(
            center: CGPoint(x: 0.45, y: 0.40),
            height: 0.16,
            roll: 0.05,
            confidence: 0.9
        )
        let recovered = FrameAligner.propagatedAnchor(
            reference,
            targetToReference: CGAffineTransform(translationX: -0.10, y: 0.04)
        )

        XCTAssertEqual(recovered?.center.x ?? 0, 0.55, accuracy: 0.001)
        XCTAssertEqual(recovered?.center.y ?? 0, 0.36, accuracy: 0.001)
        XCTAssertEqual(recovered?.height ?? 0, 0.16, accuracy: 0.001)
        XCTAssertEqual(recovered?.roll ?? 0, 0.05, accuracy: 0.001)
        XCTAssertEqual(recovered?.confidence ?? 0, 0.585, accuracy: 0.001)
    }

    func testPropagatedAnimalAnchorAccountsForScaleAndRotation() {
        let reference = FrameAnchor(
            center: CGPoint(x: 0.5, y: 0.5),
            height: 0.20,
            roll: 0.10,
            confidence: 1
        )
        let transform = CGAffineTransform(rotationAngle: 0.08).scaledBy(x: 0.8, y: 0.8)
        let recovered = FrameAligner.propagatedAnchor(reference, targetToReference: transform)

        XCTAssertEqual(recovered?.height ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(recovered?.roll ?? 0, 0.02, accuracy: 0.001)
    }
}
