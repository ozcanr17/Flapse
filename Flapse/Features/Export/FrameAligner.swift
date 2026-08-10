import Vision
import UIKit
import simd

/// Bir karedeki hizalama çıpası: öznenin normalize (0…1, origin sol-üst) merkezi,
/// karakteristik yüksekliği ve dönüş açısı (roll, radyan).
struct FrameAnchor: Equatable {
    let center: CGPoint
    let height: CGFloat
    let roll: CGFloat
    let confidence: Float

    init(center: CGPoint, height: CGFloat, roll: CGFloat, confidence: Float = 1) {
        self.center = center
        self.height = height
        self.roll = roll
        self.confidence = confidence
    }
}

enum AlignmentSubject: String, Equatable {
    case auto
    case group
    case body
    case belly
    case animal
    case foreground
    case scene
}

enum FrameAligner {

    private struct CoupleFacePair {
        let left: VNFeaturePrintObservation
        let right: VNFeaturePrintObservation
    }

    static func coupleMirrorFlags(for frames: [Data]) -> [Bool] {
        let pairs = frames.map(coupleFacePair)
        guard let reference = pairs.compactMap({ $0 }).first else {
            return Array(repeating: false, count: frames.count)
        }
        return pairs.map { pair in
            guard let pair,
                  let leftToLeft = featureDistance(reference.left, pair.left),
                  let rightToRight = featureDistance(reference.right, pair.right),
                  let leftToRight = featureDistance(reference.left, pair.right),
                  let rightToLeft = featureDistance(reference.right, pair.left)
            else { return false }
            return shouldMirror(
                sameDistance: leftToLeft + rightToRight,
                mirroredDistance: leftToRight + rightToLeft
            )
        }
    }

    static func shouldMirror(sameDistance: Float, mirroredDistance: Float) -> Bool {
        mirroredDistance + 0.02 < sameDistance
    }

    static func anchor(in imageData: Data, subject: AlignmentSubject = .auto) -> FrameAnchor? {
        // Vision does not gain useful alignment precision from a 12–48 MP source.
        // Decode a transformed thumbnail so large projects do not briefly retain a
        // full-resolution bitmap for every face/body/mask analysis.
        guard let image = ImageDownsampler.image(from: imageData, maxPixelSize: 1280),
              let cgImage = image.cgImage else { return nil }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])

        switch subject {
        case .group, .scene:
            return nil
        case .auto:
            return faceBasedAnchor(handler: handler)
                ?? foregroundAnchor(handler: handler)
                ?? saliencyAnchor(handler: handler)
        case .body, .belly:
            return bodyAnchor(handler: handler, mode: subject)
                ?? faceBasedAnchor(handler: handler)
                ?? foregroundAnchor(handler: handler)
                ?? saliencyAnchor(handler: handler)
        case .animal:
            // Do not mix a head landmark anchor with a whole-foreground box. Those
            // represent different physical scales and caused visible zoom jumps
            // whenever Vision missed the animal pose for a single frame.
            return animalAnchor(handler: handler, imageSize: image.size)
        case .foreground:
            return foregroundAnchor(handler: handler)
                ?? saliencyAnchor(handler: handler)
        }
    }

    /// Vision tespitleri tek karede küçük oynamalar yapabildiği için üç karelik
    /// hareketli medyan uygular. Eksik tespitleri uydurmaz; o kareler sahne kaydı
    /// fallback'ine bırakılır.
    static func stabilized(_ anchors: [FrameAnchor?]) -> [FrameAnchor?] {
        guard anchors.count > 1 else { return anchors }
        return anchors.indices.map { index in
            guard anchors[index] != nil else { return nil }
            let lower = max(anchors.startIndex, index - 1)
            let upper = min(anchors.index(before: anchors.endIndex), index + 1)
            let window = anchors[lower...upper].compactMap { $0 }
            guard window.count > 1 else { return anchors[index] }
            return FrameAnchor(
                center: CGPoint(
                    x: median(window.map(\.center.x)),
                    y: median(window.map(\.center.y))
                ),
                height: median(window.map(\.height)),
                roll: median(window.map(\.roll)),
                confidence: window.map(\.confidence).max() ?? 0
            )
        }
    }

    static func bestReference(in anchors: [FrameAnchor?]) -> FrameAnchor? {
        anchors.compactMap { $0 }.max { lhs, rhs in lhs.confidence < rhs.confidence }
    }

    /// Recovers short animal-pose detection gaps from the geometric relationship
    /// between adjacent photos. The propagated value remains a *head* anchor, so a
    /// missed Vision pose cannot switch the renderer to whole-body scale.
    static func recoveredAnimalAnchors(
        _ anchors: [FrameAnchor?],
        frames: [Data],
        maximumGap: Int = 2
    ) -> [FrameAnchor?] {
        guard anchors.count == frames.count, anchors.count > 1 else { return anchors }
        let allowedGap = max(maximumGap, 0)
        guard allowedGap > 0 else { return anchors }
        var result = anchors
        var gap = 0

        for index in 1..<result.count {
            if anchors[index] != nil {
                gap = 0
                continue
            }
            gap += 1
            guard gap <= allowedGap,
                  let previous = result[index - 1],
                  let transform = sceneTransform(
                      targetData: frames[index],
                      referenceData: frames[index - 1]
                  )
            else { continue }
            result[index] = propagatedAnchor(previous, targetToReference: transform)
        }

        // Also recover up to `maximumGap` leading misses from the first reliable
        // detection so projects do not jump into alignment after frame one.
        gap = 0
        guard result.count >= 2 else { return result }
        for index in stride(from: result.count - 2, through: 0, by: -1) {
            if anchors[index] != nil {
                gap = 0
                continue
            }
            gap += 1
            guard gap <= allowedGap,
                  result[index] == nil,
                  let next = result[index + 1],
                  let transform = sceneTransform(
                      targetData: frames[index],
                      referenceData: frames[index + 1]
                  )
            else { continue }
            result[index] = propagatedAnchor(next, targetToReference: transform)
        }
        return result
    }

    static func propagatedAnchor(
        _ reference: FrameAnchor,
        targetToReference transform: CGAffineTransform
    ) -> FrameAnchor? {
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard determinant.isFinite, abs(determinant) > 0.000_001 else { return nil }
        let inverse = transform.inverted()
        let center = reference.center.applying(inverse)
        let scale = sqrt(abs(determinant))
        guard center.x.isFinite, center.y.isFinite, scale.isFinite, scale > 0 else { return nil }
        let rotation = atan2(transform.b, transform.a)
        return FrameAnchor(
            center: CGPoint(
                x: min(max(center.x, 0), 1),
                y: min(max(center.y, 0), 1)
            ),
            height: min(max(reference.height / scale, 0.06), 0.60),
            roll: reference.roll - rotation,
            confidence: reference.confidence * 0.65
        )
    }

    static func translationOffset(targetData: Data, referenceData: Data) -> CGSize? {
        let working = CGSize(width: 480, height: 640)
        guard
            let target = normalized(targetData, size: working),
            let reference = normalized(referenceData, size: working)
        else { return nil }

        return translationOffset(target: target, reference: reference, working: working)
    }

    private static func translationOffset(
        target: CGImage,
        reference: CGImage,
        working: CGSize
    ) -> CGSize? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
        do {
            try VNImageRequestHandler(cgImage: reference, options: [:]).perform([request])
        } catch { return nil }

        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        let transform = observation.alignmentTransform
        return CGSize(width: transform.tx / working.width, height: transform.ty / working.height)
    }

    /// Sabit sahneler için tüm görüntüyü eşler. Vision'ın homografik kaydı küçük
    /// kamera dönüşlerini, ölçek değişimini ve perspektif farkını da tahmin eder.
    /// Renderer affine dönüşüm kullandığı için homografinin görüntü merkezindeki
    /// en iyi affine yaklaşımını üretiriz; aşırı/kararsız sonuçları reddedip güvenli
    /// öteleme kaydına geri döneriz.
    static func sceneTransform(targetData: Data, referenceData: Data) -> CGAffineTransform? {
        let working = CGSize(width: 480, height: 640)
        guard
            let target = normalized(targetData, size: working),
            let reference = normalized(referenceData, size: working)
        else { return nil }

        let fallback = translationOffset(target: target, reference: reference, working: working)
            .map { CGAffineTransform(translationX: $0.width, y: -$0.height) }
            .flatMap { isSafeTranslationFallback($0) ? $0 : nil }

        let request = VNHomographicImageRegistrationRequest(targetedCGImage: target)
        do {
            try VNImageRequestHandler(cgImage: reference, options: [:]).perform([request])
        } catch {
            return fallback
        }

        if let observation = request.results?.first as? VNImageHomographicAlignmentObservation,
           let transform = affineApproximation(of: observation.warpTransform, imageSize: working),
           isSafeSceneTransform(transform) {
            // Two independent estimators disagreeing this much generally means
            // insufficient overlap (a scene cut or a substantially different room
            // angle). Applying either result is more distracting than preserving
            // the original framing. A near-identity homography on a low-texture
            // wall is the one safe exception for a small translation fallback.
            if let fallback {
                let disagreement = hypot(transform.tx - fallback.tx, transform.ty - fallback.ty)
                if disagreement > 0.075 {
                    let homographyMotion = hypot(transform.tx, transform.ty)
                    return homographyMotion < 0.02 ? fallback : nil
                }
            }
            return transform
        }
        return fallback
    }

    /// Registers short sections against a nearby keyframe instead of forcing every
    /// photo to match the first photo in a potentially long project. When overlap is
    /// lost, a new segment starts at identity; unrelated views are never dragged
    /// across the canvas by a guessed transform.
    static func sceneTransforms(for frames: [Data], keyframeInterval: Int = 8) -> [CGAffineTransform?] {
        guard !frames.isEmpty else { return [] }
        guard frames.count > 1 else { return [.identity] }

        let interval = max(keyframeInterval, 2)
        var results: [CGAffineTransform?] = [.identity]
        var keyframeIndex = 0
        var keyframeToSegment = CGAffineTransform.identity
        var previousToSegment = CGAffineTransform.identity

        for index in 1..<frames.count {
            var candidate: CGAffineTransform?

            if let toKeyframe = sceneTransform(
                targetData: frames[index],
                referenceData: frames[keyframeIndex]
            ) {
                let chained = toKeyframe.concatenating(keyframeToSegment)
                if isSafeCumulativeSceneTransform(chained) { candidate = chained }
            }

            // A nearby frame can still overlap when a section's keyframe does not.
            if candidate == nil,
               let toPrevious = sceneTransform(
                   targetData: frames[index],
                   referenceData: frames[index - 1]
               ) {
                let chained = toPrevious.concatenating(previousToSegment)
                if isSafeCumulativeSceneTransform(chained) { candidate = chained }
            }

            guard let resolved = candidate else {
                // Treat this as a scene cut. Starting a fresh segment avoids a bad
                // warp while allowing following photos to align with this new view.
                results.append(.identity)
                keyframeIndex = index
                keyframeToSegment = .identity
                previousToSegment = .identity
                continue
            }

            results.append(resolved)
            previousToSegment = resolved
            if index - keyframeIndex >= interval {
                keyframeIndex = index
                keyframeToSegment = resolved
            }
        }
        return results
    }

    /// Normalize sahne dönüşümünü gerçek render tuvaline taşır. Tuval oranı değişse
    /// bile örneğin %10 yatay düzeltme her zaman tuval genişliğinin %10'u kalır.
    static func canvasTransform(
        from normalized: CGAffineTransform,
        canvas: CGSize
    ) -> CGAffineTransform {
        let width = max(canvas.width, 1)
        let height = max(canvas.height, 1)
        return CGAffineTransform(
            a: normalized.a,
            b: normalized.b * height / width,
            c: normalized.c * width / height,
            d: normalized.d,
            tx: normalized.tx * width,
            ty: normalized.ty * height
        )
    }

    /// Homografiyi görüntü merkezinde örnekleyerek normalize UIKit koordinatlarında
    /// (0…1, origin sol-üst) affine dönüşüme yaklaştırır.
    private static func affineApproximation(
        of matrix: simd_float3x3,
        imageSize: CGSize
    ) -> CGAffineTransform? {
        func projected(_ point: CGPoint) -> CGPoint? {
            let visionPoint = SIMD3<Float>(
                Float(point.x * imageSize.width),
                Float((1 - point.y) * imageSize.height),
                1
            )
            let result = matrix * visionPoint
            guard result.z.isFinite, abs(result.z) > 0.000_001 else { return nil }
            let x = CGFloat(result.x / result.z) / imageSize.width
            let y = 1 - CGFloat(result.y / result.z) / imageSize.height
            guard x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }

        let center = CGPoint(x: 0.5, y: 0.5)
        let step: CGFloat = 0.25
        guard
            let mappedCenter = projected(center),
            let mappedX = projected(CGPoint(x: center.x + step, y: center.y)),
            let mappedY = projected(CGPoint(x: center.x, y: center.y + step))
        else { return nil }

        let a = (mappedX.x - mappedCenter.x) / step
        let b = (mappedX.y - mappedCenter.y) / step
        let c = (mappedY.x - mappedCenter.x) / step
        let d = (mappedY.y - mappedCenter.y) / step
        return CGAffineTransform(
            a: a,
            b: b,
            c: c,
            d: d,
            tx: mappedCenter.x - a * center.x - c * center.y,
            ty: mappedCenter.y - b * center.x - d * center.y
        )
    }

    /// Yanlış görsel eşleşmenin kareyi ekrandan fırlatmasına izin verme. Günlük
    /// çekimde beklenen küçük el hareketleri korunur; büyük perspektif sıçramaları
    /// daha muhafazakâr öteleme fallback'ine bırakılır.
    private static func isSafeSceneTransform(_ transform: CGAffineTransform) -> Bool {
        let scaleX = hypot(transform.a, transform.b)
        let scaleY = hypot(transform.c, transform.d)
        let rotation = atan2(transform.b, transform.a)
        let determinant = transform.a * transform.d - transform.b * transform.c
        return determinant > 0
            && (0.78...1.28).contains(scaleX)
            && (0.78...1.28).contains(scaleY)
            && abs(rotation) <= 18 * .pi / 180
            && abs(transform.tx) <= 0.35
            && abs(transform.ty) <= 0.35
    }

    private static func isSafeTranslationFallback(_ transform: CGAffineTransform) -> Bool {
        abs(transform.tx) <= 0.18 && abs(transform.ty) <= 0.18
    }

    private static func isSafeCumulativeSceneTransform(_ transform: CGAffineTransform) -> Bool {
        let scaleX = hypot(transform.a, transform.b)
        let scaleY = hypot(transform.c, transform.d)
        let rotation = atan2(transform.b, transform.a)
        let determinant = transform.a * transform.d - transform.b * transform.c
        return determinant > 0
            && (0.72...1.38).contains(scaleX)
            && (0.72...1.38).contains(scaleY)
            && abs(rotation) <= 22 * .pi / 180
            && abs(transform.tx) <= 0.42
            && abs(transform.ty) <= 0.42
    }

    private static func faceBasedAnchor(handler: VNImageRequestHandler) -> FrameAnchor? {
        let request = VNDetectFaceLandmarksRequest()
        try? handler.perform([request])
        guard let faces = request.results, !faces.isEmpty else { return nil }

        if faces.count == 1 { return faceAnchor(faces[0]) }
        let prominent = faces.max { lhs, rhs in
            lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
        }
        return prominent.map(faceAnchor)
    }

    /// iOS 17 Vision hayvan pozu; kedi ve köpeklerde göz/burun/ kulak noktalarını
    /// doğrudan verir. Öncelik iki gözün ortasıdır. En az iki baş noktası
    /// bulunmadığında semantik ölçeği değiştirmek yerine sahne kaydı fallback'ine
    /// geçilir; böylece tek karelik Vision kaçırmaları zoom sıçraması yaratmaz.
    private static func animalAnchor(handler: VNImageRequestHandler, imageSize: CGSize) -> FrameAnchor? {
        let poseRequest = VNDetectAnimalBodyPoseRequest()
        let animalRequest = VNRecognizeAnimalsRequest()
        try? handler.perform([poseRequest, animalRequest])

        let animal = animalRequest.results?.max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        let bodyBox = animal?.boundingBox

        if let pose = poseRequest.results?.first {
            func point(_ joint: VNAnimalBodyPoseObservation.JointName) -> VNRecognizedPoint? {
                guard let value = try? pose.recognizedPoint(joint), value.confidence >= 0.2 else { return nil }
                return value
            }
            func normalized(_ point: VNRecognizedPoint) -> CGPoint {
                CGPoint(x: point.location.x, y: 1 - point.location.y)
            }

            let leftEye = point(.leftEye)
            let rightEye = point(.rightEye)
            let nose = point(.nose)
            let leftEar = point(.leftEarTop)
            let rightEar = point(.rightEarTop)
            let headPoints = [leftEye, rightEye, nose, leftEar, rightEar].compactMap { $0 }

            if headPoints.count >= 2 {
                let normalizedPoints = headPoints.map(normalized)
                let center: CGPoint
                let roll: CGFloat
                if let leftEye, let rightEye {
                    let left = normalized(leftEye)
                    let right = normalized(rightEye)
                    center = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
                    // Vision points are normalized independently on each axis.
                    // Compensate for the image aspect ratio before calculating roll.
                    roll = atan2(
                        (right.y - left.y) * imageSize.height,
                        (right.x - left.x) * imageSize.width
                    )
                } else {
                    center = CGPoint(
                        x: normalizedPoints.map(\.x).reduce(0, +) / CGFloat(normalizedPoints.count),
                        y: normalizedPoints.map(\.y).reduce(0, +) / CGFloat(normalizedPoints.count)
                    )
                    if let leftEar, let rightEar {
                        let left = normalized(leftEar)
                        let right = normalized(rightEar)
                        roll = atan2(
                            (right.y - left.y) * imageSize.height,
                            (right.x - left.x) * imageSize.width
                        )
                    } else {
                        roll = 0
                    }
                }
                let confidence = headPoints.map(\.confidence).reduce(0, +) / Float(headPoints.count)
                return FrameAnchor(
                    center: center,
                    height: animalHeadHeight(
                        points: normalizedPoints,
                        imageSize: imageSize,
                        bodyBox: bodyBox
                    ),
                    roll: roll,
                    confidence: confidence
                )
            }
        }
        return nil
    }

    /// Converts eye/ear/nose spread to one consistent head-height unit. The animal
    /// detection box is used only as a broad plausibility bound, never as a full-body
    /// replacement for a head measurement.
    static func animalHeadHeight(
        points: [CGPoint],
        imageSize: CGSize,
        bodyBox: CGRect?
    ) -> CGFloat {
        guard points.count >= 2 else { return max((bodyBox?.height ?? 0.30) * 0.30, 0.08) }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let horizontalAsHeight = ((xs.max() ?? 0) - (xs.min() ?? 0))
            * max(imageSize.width, 1) / max(imageSize.height, 1)
        let vertical = (ys.max() ?? 0) - (ys.min() ?? 0)
        var estimate = max(horizontalAsHeight * 0.95, vertical * 1.30, 0.06)
        if let bodyBox {
            estimate = min(max(estimate, bodyBox.height * 0.18), bodyBox.height * 0.55)
        }
        return min(max(estimate, 0.06), 0.60)
    }

    private static func coupleFacePair(_ imageData: Data) -> CoupleFacePair? {
        guard let image = ImageDownsampler.image(from: imageData, maxPixelSize: 1280),
              let cgImage = image.cgImage else { return nil }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try? handler.perform([request])
        guard let faces = request.results, faces.count >= 2 else { return nil }
        let primaryFaces = faces
            .sorted { lhs, rhs in
                lhs.boundingBox.width * lhs.boundingBox.height > rhs.boundingBox.width * rhs.boundingBox.height
            }
            .prefix(2)
            .sorted { $0.boundingBox.midX < $1.boundingBox.midX }
        guard primaryFaces.count == 2,
              let leftImage = faceCrop(cgImage, box: primaryFaces[0].boundingBox),
              let rightImage = faceCrop(cgImage, box: primaryFaces[1].boundingBox),
              let left = featurePrint(leftImage),
              let right = featurePrint(rightImage)
        else { return nil }
        return CoupleFacePair(left: left, right: right)
    }

    private static func faceCrop(_ image: CGImage, box: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var rect = CGRect(
            x: box.minX * width,
            y: (1 - box.maxY) * height,
            width: box.width * width,
            height: box.height * height
        )
        rect = rect.insetBy(dx: -rect.width * 0.35, dy: -rect.height * 0.35)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 32, rect.height >= 32 else { return nil }
        return image.cropping(to: rect.integral)
    }

    private static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    private static func featureDistance(
        _ reference: VNFeaturePrintObservation,
        _ candidate: VNFeaturePrintObservation
    ) -> Float? {
        var distance: Float = 0
        guard (try? reference.computeDistance(&distance, to: candidate)) != nil else { return nil }
        return distance
    }

    /// Gövde/karın çıpası: insan pozu kilit noktalarından (omuz, kalça, boyun, kök)
    /// gövdeyi bulur. Fitness → gövde ortası; hamilelik → karın (kalçadan omuza doğru
    /// %30). Ölçek referansı gövde boyu olduğundan karın büyürken bile çerçevede kalır.
    private static func bodyAnchor(handler: VNImageRequestHandler, mode: AlignmentSubject) -> FrameAnchor? {
        let request = VNDetectHumanBodyPoseRequest()
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }

        func point(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let recognized = try? observation.recognizedPoint(joint), recognized.confidence > 0.2 else { return nil }
            return CGPoint(x: recognized.location.x, y: 1 - recognized.location.y)
        }

        let leftShoulder = point(.leftShoulder)
        let rightShoulder = point(.rightShoulder)
        let leftHip = point(.leftHip)
        let rightHip = point(.rightHip)

        guard
            let top = midpoint(leftShoulder, rightShoulder) ?? point(.neck),
            let bottom = midpoint(leftHip, rightHip) ?? point(.root)
        else { return nil }

        let torsoHeight = max(hypot(bottom.x - top.x, bottom.y - top.y), 0.05)
        let roll: CGFloat = {
            if let leftShoulder, let rightShoulder {
                return atan2(rightShoulder.y - leftShoulder.y, rightShoulder.x - leftShoulder.x)
            }
            return 0
        }()

        let center: CGPoint
        switch mode {
        case .belly:
            center = CGPoint(x: bottom.x + 0.30 * (top.x - bottom.x), y: bottom.y + 0.30 * (top.y - bottom.y))
        default:
            center = CGPoint(x: (top.x + bottom.x) / 2, y: (top.y + bottom.y) / 2)
        }
        return FrameAnchor(center: center, height: torsoHeight, roll: roll, confidence: observation.confidence)
    }

    /// Bitki ve genel nesnelerde arka plandan ayrılabilen tüm ön plan örneklerinin
    /// birleşik sınırını kullanır. İnsan yüzü veya hayvan pozu gibi semantik bir
    /// hedef bulunmadığında salt dikkat haritasından daha kararlı bir ölçek üretir.
    private static func foregroundAnchor(handler: VNImageRequestHandler) -> FrameAnchor? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        try? handler.perform([request])
        guard
            let observation = request.results?.first,
            !observation.allInstances.isEmpty,
            let mask = try? observation.generateMask(forInstances: observation.allInstances),
            let box = maskBoundingBox(mask)
        else { return nil }
        return FrameAnchor(
            center: CGPoint(x: box.midX, y: box.midY),
            height: max(box.height, 0.05),
            roll: 0,
            confidence: observation.confidence
        )
    }

    private static func maskBoundingBox(_ mask: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask) / MemoryLayout<Float>.stride
        let values = base.assumingMemoryBound(to: Float.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where values[y * stride + x] > 0.25 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
    }

    /// Yüz/gövde bulunamayınca son çare: dikkat-temelli belirginlik (saliency) ile
    /// karedeki en dikkat çeken bölgeyi kilitler.
    private static func saliencyAnchor(handler: VNImageRequestHandler) -> FrameAnchor? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([request])
        guard
            let observation = request.results?.first as? VNSaliencyImageObservation,
            let salient = observation.salientObjects?.max(by: { $0.confidence < $1.confidence })
        else { return nil }
        let box = salient.boundingBox
        return FrameAnchor(
            center: CGPoint(x: box.midX, y: 1 - box.midY),
            height: max(box.height, 0.05),
            roll: 0,
            confidence: salient.confidence
        )
    }

    private static func faceAnchor(_ face: VNFaceObservation) -> FrameAnchor {
        let box = face.boundingBox
        if
            let left = eyeCenter(face.landmarks?.leftEye, box: box),
            let right = eyeCenter(face.landmarks?.rightEye, box: box)
        {
            return FrameAnchor(
                center: CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2),
                height: box.height,
                roll: atan2(right.y - left.y, right.x - left.x),
                confidence: face.confidence
            )
        }
        return FrameAnchor(
            center: CGPoint(x: box.midX, y: 1 - box.midY),
            height: box.height,
            roll: CGFloat(truncating: face.roll ?? 0),
            confidence: face.confidence
        )
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func midpoint(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
        switch (a, b) {
        case let (a?, b?): CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        case let (a?, nil): a
        case let (nil, b?): b
        default: nil
        }
    }

    private static func normalized(_ data: Data, size: CGSize) -> CGImage? {
        guard let image = ImageDownsampler.image(from: data, maxPixelSize: 1280) else { return nil }
        let scale = max(size.width / max(image.size.width, 1), size.height / max(image.size.height, 1))
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return rendered.cgImage
    }

    private static func eyeCenter(_ region: VNFaceLandmarkRegion2D?, box: CGRect) -> CGPoint? {
        guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let count = CGFloat(points.count)
        let inBox = CGPoint(x: sum.x / count, y: sum.y / count)
        let imageBottomLeft = CGPoint(x: box.minX + inBox.x * box.width, y: box.minY + inBox.y * box.height)
        return CGPoint(x: imageBottomLeft.x, y: 1 - imageBottomLeft.y)
    }

    private static func cgOrientation(from orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up:            .up
        case .upMirrored:    .upMirrored
        case .down:          .down
        case .downMirrored:  .downMirrored
        case .left:          .left
        case .leftMirrored:  .leftMirrored
        case .right:         .right
        case .rightMirrored: .rightMirrored
        @unknown default:    .up
        }
    }
}
