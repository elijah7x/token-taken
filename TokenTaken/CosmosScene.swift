import CoreGraphics
import Foundation
import simd
import TokenTakenKit

struct CosmosCategory: Equatable, Identifiable {
    let category: TokenCategory
    let value: Int64
    var share: Double
    var edge: Double

    var id: String { category.rawValue }
}

struct CosmosBody: Equatable, Identifiable {
    let item: Breakdown
    let rank: Int
    var share: Double
    var rate: Double
    let kind: Int
    let seed: UInt32
    var orbit: Double
    var radius: Double
    var angle: Double
    let inclination: Double
    let node: Double
    let tilt: Double
    let mainlyFrom: String?

    var id: String { item.id }
    var name: String { item.name }
    var tokens: Int64 { item.counts.total }
    var counts: TokenCounts { item.counts }
}

struct CosmosScene: Equatable {
    static let categoryOrder: [TokenCategory] = [.cacheRead, .input, .cacheWrite, .output, .reasoning]
    static let inner = 1.02
    static let outer = 4.0
    static let shadow = 2.598 * 0.34
    static let bodySpeed = 1.5e-8
    static let referenceSize = CGSize(width: 926, height: 718)
    static let referenceFocal = 900.0
    static let baseCamera = SIMD3<Double>(0, 3.18, 14.65)
    static let cameraDistance = sqrt(3.18 * 3.18 + 14.65 * 14.65)

    let dimension: BreakdownDimension
    let total: Int64
    var categories: [CosmosCategory]
    var bodies: [CosmosBody]
    let restCount: Int
    let restTotal: Int64
    let dustCount: Int
    let elapsedHours: Int
    let tokensPerHour: Double
    var particleShares: [Double]

    init(summary: UsageSummary, dimension: BreakdownDimension) {
        self.dimension = dimension
        total = summary.total.total
        let denominator = total == 0 ? 1.0 : Double(total)
        var cursor = Self.inner
        categories = Self.categoryOrder.map { category in
            let value = summary.total[category]
            let share = Double(value) / denominator
            cursor += (Self.outer - Self.inner) * share
            return CosmosCategory(category: category, value: value, share: share, edge: cursor)
        }
        particleShares = categories.map(\.share)

        let hours = Self.elapsedHours(for: summary)
        elapsedHours = hours
        tokensPerHour = Double(total) / Double(hours)
        let sourceItems = dimension == .sources ? summary.bySource : summary.byModel
        let items = sourceItems.sorted { lhs, rhs in
            lhs.counts.total == rhs.counts.total ? lhs.id < rhs.id : lhs.counts.total > rhs.counts.total
        }
        let activeSources = summary.bySource.filter { $0.counts.total > 0 }
        let soleSourceName = activeSources.count == 1 ? activeSources[0].name : nil
        if total > 0 {
            let top = Array(items.prefix(6))
            let topShare = top.first.map { Double($0.counts.total) / denominator } ?? 1
            let phases = [0.12, 1.02, 1.95, 3.02, 0.68, 5.2]
            bodies = top.enumerated().map { rank, item in
                let hash = Self.hash(item.id)
                let share = Double(item.counts.total) / denominator
                let orbit = 4.85 + 0.08 * Double(rank)
                let relativeShare = share / (topShare == 0 ? 1 : topShare)
                return CosmosBody(
                    item: item,
                    rank: rank,
                    share: share,
                    rate: Double(item.counts.total) / Double(hours),
                    kind: Int(hash % 6),
                    seed: hash,
                    orbit: orbit,
                    radius: 34 * (Self.cameraDistance - 4.85) / Self.referenceFocal * pow(relativeShare, 0.78),
                    angle: phases[rank],
                    inclination: -0.15 + Double(rank) * 0.012,
                    node: (Double((hash >> 8) % 100) / 100 - 0.5) * 0.05,
                    tilt: (Double((hash >> 12) % 100) / 100 - 0.5) * 1.15,
                    mainlyFrom: dimension == .models ? soleSourceName : nil
                )
            }
        } else {
            bodies = []
        }
        let rest = total > 0 ? Array(items.dropFirst(6)) : []
        restCount = rest.count
        restTotal = rest.reduce(0) { $0 + $1.counts.total }
        dustCount = rest.isEmpty ? 0 : min(420, max(140, rest.count * 24))
    }

    func frame(
        from previous: CosmosScene,
        transitionStart: Double,
        timestamp: Double,
        orbitTime: Double,
        flowTime: Double,
        motionTime: Double,
        reveal: Double,
        size: CGSize,
        compact: Bool = false,
        reduceMotion: Bool,
        hoverCategory: Int = -1
    ) -> CosmosFrame {
        guard size.width > 1, size.height > 1 else {
            let safeSize = CGSize(
                width: max(size.width.isFinite ? size.width : 1, 1),
                height: max(size.height.isFinite ? size.height : 1, 1)
            )
            let cameraSetup = Self.camera(at: motionTime, size: safeSize, compact: compact, reduceMotion: true)
            return CosmosFrame(
                scene: self,
                target: self,
                size: size,
                center: cameraSetup.center,
                focal: cameraSetup.focal,
                camera: cameraSetup.camera,
                time: 0,
                clock: 0,
                reveal: reduceMotion ? 1 : reveal,
                disk: total > 0 ? 1 : 0,
                hoverCategory: hoverCategory,
                placements: []
            )
        }
        let progress = reduceMotion ? 1 : Self.clamp((timestamp - transitionStart) / 0.9, 0, 1)
        let eased = 1 - pow(1 - progress, 3)
        let current = interpolated(from: previous, progress: eased, orbitTime: orbitTime)
        let cameraSetup = Self.camera(at: motionTime, size: size, compact: compact, reduceMotion: reduceMotion)
        let placements = current.bodies.map { body in
            var placement = Self.bodyPlacement(
                body,
                world: Self.orbitPoint(body, body.angle),
                camera: cameraSetup.camera,
                center: cameraSetup.center,
                focal: cameraSetup.focal,
                size: size
            )
            if let point = placement.point {
                let hidden = point.y < -placement.outer || point.y > Double(size.height) + placement.outer
                    || Self.holeOccluded(placement.world, radius: placement.radius, camera: cameraSetup.camera)
                placement.isVisible = !hidden
                if !hidden {
                    let extent = body.kind == 3 ? placement.outer : placement.screenRadius * 1.25
                    let hitSize = max(30, extent * 2 + 12)
                    placement.hitFrame = CGRect(
                        x: point.x - hitSize / 2,
                        y: point.y - hitSize / 2,
                        width: hitSize,
                        height: hitSize
                    )
                }
            }
            return placement
        }
        return CosmosFrame(
            scene: current,
            target: self,
            size: size,
            center: cameraSetup.center,
            focal: cameraSetup.focal,
            camera: cameraSetup.camera,
            time: reduceMotion ? 0 : flowTime,
            clock: reduceMotion ? 0 : motionTime,
            reveal: reduceMotion ? 1 : reveal,
            disk: total > 0 ? 1 : 0,
            hoverCategory: hoverCategory,
            placements: placements
        )
    }

    func stillFrame(size: CGSize, compact: Bool = false, hoverCategory: Int = -1) -> CosmosFrame {
        guard size.width > 1, size.height > 1 else {
            return frame(
                from: self,
                transitionStart: 0,
                timestamp: 0,
                orbitTime: 0,
                flowTime: 0,
                motionTime: 0,
                reveal: 1,
                size: size,
                compact: compact,
                reduceMotion: true,
                hoverCategory: hoverCategory
            )
        }
        return frame(
            from: self,
            transitionStart: 0,
            timestamp: 0,
            orbitTime: 0,
            flowTime: 0,
            motionTime: 0,
            reveal: 1,
            size: size,
            compact: compact,
            reduceMotion: true,
            hoverCategory: hoverCategory
        )
    }

    private func interpolated(from previous: CosmosScene, progress: Double, orbitTime: Double) -> CosmosScene {
        var result = self
        result.categories = categories.map { category in
            let old = previous.categories.first(where: { $0.id == category.id })
            var interpolated = category
            interpolated.share = Self.lerp(old?.share ?? 0, category.share, progress)
            return interpolated
        }
        var cursor = Self.inner
        for index in result.categories.indices {
            cursor += (Self.outer - Self.inner) * result.categories[index].share
            result.categories[index].edge = cursor
        }
        result.bodies = bodies.map { body in
            let old = previous.bodies.first(where: { $0.id == body.id })
            var interpolated = body
            interpolated.share = Self.lerp(old?.share ?? 0, body.share, progress)
            interpolated.orbit = Self.lerp(old?.orbit ?? body.orbit * 1.08, body.orbit, progress)
            interpolated.radius = Self.lerp(old?.radius ?? 0, body.radius, progress)
            interpolated.rate = Self.lerp(old?.rate ?? body.rate, body.rate, progress)
            interpolated.angle = Self.lerp(old?.angle ?? body.angle, body.angle, progress)
                + orbitTime * interpolated.rate * Self.bodySpeed
            return interpolated
        }
        Self.spreadAngles(&result.bodies)
        result.particleShares = particleShares
        return result
    }

    private static func elapsedHours(for summary: UsageSummary) -> Int {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let lastInstant = max(summary.start, summary.end.addingTimeInterval(-1))
        let todayStart = calendar.startOfDay(for: lastInstant)
        let dayHours: Int
        if summary.period == .day {
            dayHours = summary.series.filter { !$0.isFuture }.count
        } else {
            dayHours = max(1, (calendar.dateComponents([.hour], from: todayStart, to: lastInstant).hour ?? 22) + 1)
        }
        let effectiveDayHours = dayHours == 0 ? 23 : dayHours
        switch summary.period {
        case .day:
            return effectiveDayHours
        case .week, .month:
            let elapsedBuckets = max(1, summary.series.filter { !$0.isFuture }.count)
            return max(1, (elapsedBuckets - 1) * 24 + effectiveDayHours)
        case .year, .all:
            let precedingHours = Int(((todayStart.timeIntervalSince(summary.start)) / 3_600).rounded())
            return max(1, precedingHours + effectiveDayHours)
        }
    }

    private static func hash(_ string: String) -> UInt32 {
        var hash = UInt32(2_166_136_261)
        for codeUnit in string.utf16 {
            hash = (hash ^ UInt32(codeUnit)) &* 16_777_619
        }
        return hash
    }

    private static func camera(
        at time: Double,
        size: CGSize,
        compact: Bool,
        reduceMotion: Bool
    ) -> (camera: CosmosCamera, center: CGPoint, focal: Double) {
        let angle = reduceMotion ? 0 : sin(time * 2 * Double.pi / 60) * 1.5 * Double.pi / 180
        let cosine = cos(angle), sine = sin(angle)
        let position = SIMD3<Double>(baseCamera.z * sine, baseCamera.y, baseCamera.z * cosine)
        let forward = normalize(-position)
        let right = normalize(cross(forward, SIMD3<Double>(0, 1, 0)))
        let up = cross(right, forward)
        let width = size.width.isFinite ? Double(size.width) : 1
        let height = size.height.isFinite ? Double(size.height) : 1
        let scale = max(0.01, min(width / referenceSize.width, height / referenceSize.height))
        let center = compact
            ? CGPoint(x: width * 0.52, y: height * 0.48)
            : CGPoint(x: width * 0.60, y: height * 0.46)
        return (CosmosCamera(position: position, forward: forward, right: right, up: up), center, referenceFocal * scale)
    }

    static func orbitPoint(_ body: CosmosBody, _ angle: Double) -> SIMD3<Double> {
        let x = body.orbit * cos(angle), z0 = body.orbit * sin(angle)
        let y = z0 * sin(body.inclination), z = z0 * cos(body.inclination)
        return SIMD3(
            x * cos(body.node) - z * sin(body.node),
            y,
            x * sin(body.node) + z * cos(body.node)
        )
    }

    static func spreadAngles(_ bodies: inout [CosmosBody]) {
        let count = bodies.count
        guard count >= 2 else { return }
        let tau = 2 * Double.pi
        let gap = min(0.62, tau / Double(count) * 0.9)
        var list = bodies.indices.map { index in
            let angle = bodies[index].angle.truncatingRemainder(dividingBy: tau)
            return (index: index, angle: angle < 0 ? angle + tau : angle)
        }
        list.sort { lhs, rhs in
            lhs.angle == rhs.angle ? bodies[lhs.index].rank < bodies[rhs.index].rank : lhs.angle < rhs.angle
        }
        var start = 0, widest = -1.0
        for index in 0..<count {
            var difference = (list[(index + 1) % count].angle - list[index].angle).truncatingRemainder(dividingBy: tau)
            if difference < 0 { difference += tau }
            if difference > widest {
                widest = difference
                start = (index + 1) % count
            }
        }
        var previous = list[start].angle
        for step in 1..<count {
            let item = list[(start + step) % count]
            var angle = item.angle
            while angle < previous { angle += tau }
            if angle - previous < gap { angle = previous + gap }
            bodies[item.index].angle = angle
            previous = angle
        }
    }

    static func project(
        _ world: SIMD3<Double>,
        camera: CosmosCamera,
        center: CGPoint,
        focal: Double
    ) -> CosmosProjectedPoint? {
        let value = world - camera.position, depth = dot(value, camera.forward)
        if depth < 0.5 { return nil }
        return CosmosProjectedPoint(
            x: Double(center.x) + focal * dot(value, camera.right) / depth,
            y: Double(center.y) - focal * dot(value, camera.up) / depth,
            depth: depth,
            scale: focal / depth
        )
    }

    static func apparentProject(
        _ world: SIMD3<Double>,
        camera: CosmosCamera,
        center: CGPoint,
        focal: Double
    ) -> CosmosProjectedPoint? {
        guard let projected = project(world, camera: camera, center: center, focal: focal) else { return nil }
        if dot(world, camera.forward) <= 0 { return projected }
        let value = world - camera.position
        let time = clamp(-dot(camera.position, value) / dot(value, value), 0, 1)
        let near = camera.position + value * time
        let impact = length(near)
        if impact < shadow { return projected }
        let shift = focal * tan(min(0.18, 0.68 / (impact * impact)))
        let dx = projected.x - Double(center.x), dy = projected.y - Double(center.y)
        let distance = sqrt(dx * dx + dy * dy)
        let divisor = distance == 0 ? 1 : distance
        var result = projected
        result.x += dx / divisor * shift
        result.y += dy / divisor * shift
        return result
    }

    static func bodyPlacement(
        _ body: CosmosBody,
        world initialWorld: SIMD3<Double>,
        camera: CosmosCamera,
        center: CGPoint,
        focal: Double,
        size: CGSize
    ) -> CosmosBodyPlacement {
        var world = initialWorld
        var direct = project(world, camera: camera, center: center, focal: focal)
        let radius = max(body.radius, 13 / max(0.001, direct?.scale ?? focal / cameraDistance))
        guard direct != nil else {
            return CosmosBodyPlacement(body: body, world: world, point: nil, radius: radius, screenRadius: 0, outer: 0)
        }
        for _ in 0..<3 {
            let outer = radius * direct!.scale * (body.kind == 3 ? 2.3 : 1)
            let margin = outer * 1.2 + 30
            let x = clamp(direct!.x, margin, Double(size.width) - margin)
            if abs(x - direct!.x) < 0.01 { break }
            world += camera.right * ((x - direct!.x) * direct!.depth / focal)
            direct = project(world, camera: camera, center: center, focal: focal)
            if direct == nil {
                return CosmosBodyPlacement(body: body, world: world, point: nil, radius: radius, screenRadius: 0, outer: 0)
            }
        }
        let apparent = apparentProject(world, camera: camera, center: center, focal: focal) ?? direct!
        let screenRadius = radius * direct!.scale
        return CosmosBodyPlacement(
            body: body,
            world: world,
            point: apparent,
            radius: radius,
            screenRadius: screenRadius,
            outer: screenRadius * (body.kind == 3 ? 2.3 : 1)
        )
    }

    static func holeOccluded(_ world: SIMD3<Double>, radius: Double, camera: CosmosCamera) -> Bool {
        let value = world - camera.position, squared = dot(value, value)
        let time = clamp(-dot(camera.position, value) / squared, 0, 1)
        let near = camera.position + value * time
        return dot(world, camera.forward) > 0 && length(near) < shadow + radius * 0.45
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        max(lower, min(upper, value))
    }

    private static func lerp(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        from + (to - from) * amount
    }

    /// SwiftUI asks for the scene several times per displayed frame (hover, focus, label layout),
    /// and building it sorts breakdowns, hashes ids and reads the calendar. Rebuild only when the
    /// summary, the dimension or `summary.end` (which drives `elapsedHours`) changes.
    @MainActor
    static func cached(summary: UsageSummary, dimension: BreakdownDimension) -> CosmosScene {
        CosmosSceneCache.scene(summary: summary, dimension: dimension)
    }
}

@MainActor
private enum CosmosSceneCache {
    private struct Key: Equatable {
        let dimension: BreakdownDimension
        let period: Period
        let start: Date
        let end: Date
        let total: TokenCounts
        let bySource: [Breakdown]
        let byModel: [Breakdown]
        let bucketCount: Int
        let elapsedBuckets: Int
    }

    private static var entries: [(key: Key, scene: CosmosScene)] = []

    static func scene(summary: UsageSummary, dimension: BreakdownDimension) -> CosmosScene {
        let key = Key(
            dimension: dimension,
            period: summary.period,
            start: summary.start,
            end: summary.end,
            total: summary.total,
            bySource: summary.bySource,
            byModel: summary.byModel,
            bucketCount: summary.series.count,
            elapsedBuckets: summary.series.lazy.filter { !$0.isFuture }.count
        )
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let hit = entries.remove(at: index)
            entries.insert(hit, at: 0)
            return hit.scene
        }
        let scene = CosmosScene(summary: summary, dimension: dimension)
        entries.insert((key, scene), at: 0)
        if entries.count > 4 { entries.removeLast(entries.count - 4) }
        return scene
    }
}

struct CosmosCamera: Equatable {
    let position: SIMD3<Double>
    let forward: SIMD3<Double>
    let right: SIMD3<Double>
    let up: SIMD3<Double>
}

struct CosmosProjectedPoint: Equatable {
    var x: Double
    var y: Double
    let depth: Double
    let scale: Double

    var point: CGPoint { CGPoint(x: x, y: y) }
}

struct CosmosBodyPlacement: Equatable, Identifiable {
    let body: CosmosBody
    let world: SIMD3<Double>
    let point: CosmosProjectedPoint?
    let radius: Double
    let screenRadius: Double
    let outer: Double
    var isVisible = false
    var hitFrame = CGRect.zero
    var labelFrame: CGRect?
    var labelSide = 1

    var id: String { body.id }
    var extent: Double { body.kind == 3 ? outer : screenRadius * 1.25 }
}

struct CosmosFrame {
    let scene: CosmosScene
    let target: CosmosScene
    let size: CGSize
    let center: CGPoint
    let focal: Double
    let camera: CosmosCamera
    let time: Double
    let clock: Double
    let reveal: Double
    let disk: Double
    let hoverCategory: Int
    var placements: [CosmosBodyPlacement]

    func project(_ world: SIMD3<Double>) -> CosmosProjectedPoint? {
        CosmosScene.project(world, camera: camera, center: center, focal: focal)
    }

    func diskHit(at point: CGPoint) -> (index: Int, world: SIMD3<Double>)? {
        let direction = normalize(
            camera.forward * focal
                + camera.right * (Double(point.x) - Double(center.x))
                + camera.up * (Double(center.y) - Double(point.y))
        )
        if direction.y >= -0.0001 { return nil }
        let world = camera.position + direction * (-camera.position.y / direction.y)
        let radius = sqrt(world.x * world.x + world.z * world.z)
        if radius < CosmosScene.inner || radius > CosmosScene.outer { return nil }
        for (index, category) in scene.categories.enumerated() where radius <= category.edge {
            return (index, world)
        }
        return nil
    }

    func categoryAnchor(index: Int, direct: SIMD3<Double>? = nil) -> CosmosProjectedPoint? {
        guard scene.categories.indices.contains(index) else { return nil }
        let world: SIMD3<Double>
        if let direct {
            world = direct
        } else {
            let lower = index == 0 ? CosmosScene.inner : scene.categories[index - 1].edge
            let radius = lower + (scene.categories[index].edge - lower) * 0.5
            world = SIMD3(radius * cos(-0.18), 0, radius * sin(-0.18))
        }
        return project(world)
    }

    func orbitSegments(for id: String) -> [[CGPoint]] {
        guard let placement = placements.first(where: { $0.id == id }) else { return [] }
        let body = placement.body
        var segments: [[CGPoint]] = [], current: [CGPoint] = []
        for index in 0...128 {
            let world = CosmosScene.orbitPoint(body, Double(index) / 128 * 2 * Double.pi)
            guard let projected = project(world) else {
                if !current.isEmpty { segments.append(current) }
                current = []
                continue
            }
            let x = CosmosScene.clamp(
                projected.x,
                placement.outer + 16,
                Double(size.width) - placement.outer - 16
            )
            current.append(CGPoint(x: x, y: projected.y))
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    func layingOutLabels(sizes: [String: CGSize]) -> CosmosFrame {
        var result = self
        let original = placements
        let shadow = (
            center: CGPoint(x: center.x, y: center.y),
            radius: CosmosScene.shadow * focal / CosmosScene.cameraDistance * 1.6
        )
        var labels: [CGRect] = []
        for index in result.placements.indices {
            result.placements[index].labelFrame = nil
            let item = original[index]
            guard item.isVisible,
                  let point = item.point,
                  point.x.isFinite, point.y.isFinite,
                  item.extent.isFinite else { continue }
            let labelSize = sizes[item.id] ?? CGSize(width: 80, height: 29)
            let width = Double(labelSize.width), height = Double(labelSize.height)
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { continue }
            let clear = item.extent + 10

            func base(_ side: Int) -> CGRect {
                CGRect(
                    x: side > 0 ? point.x + clear : point.x - clear - width,
                    y: point.y - height / 2,
                    width: width,
                    height: height
                )
            }

            let rightHole = Self.rectCircleOverlap(base(1), center: shadow.center, radius: shadow.radius)
            let leftHole = Self.rectCircleOverlap(base(-1), center: shadow.center, radius: shadow.radius)
            var sides = point.x + clear + width > Double(size.width) - 8 ? [-1, 1] : [1, -1]
            if rightHole != leftHole { sides = rightHole ? [-1, 1] : [1, -1] }
            var chosen: CGRect?
            var chosenSide = 1
            for side in sides {
                let offsets = [0.0, -height - 8, height + 8, -2 * (height + 8), 2 * (height + 8), -3 * (height + 8), 3 * (height + 8)]
                for offset in offsets {
                    var rectangle = base(side)
                    rectangle.origin.y = point.y - height / 2 + offset
                    if rectangle.minX < 8 || rectangle.maxX > Double(size.width) - 8
                        || rectangle.minY < 8 || rectangle.maxY > Double(size.height) - 44 { continue }
                    if Self.rectCircleOverlap(rectangle, center: shadow.center, radius: shadow.radius) { continue }
                    var overlapsBody = false
                    for (otherIndex, other) in original.enumerated() where otherIndex != index && other.isVisible {
                        if let otherPoint = other.point,
                           Self.rectCircleOverlap(
                                rectangle,
                                center: otherPoint.point,
                                radius: other.extent + 2
                           ) {
                            overlapsBody = true
                            break
                        }
                    }
                    if overlapsBody { continue }
                    if labels.contains(where: { Self.rectsOverlap(rectangle, $0.insetBy(dx: -4, dy: -4)) }) { continue }
                    chosen = rectangle
                    chosenSide = side
                    break
                }
                if chosen != nil { break }
            }
            if let chosen,
               chosen.origin.x.isFinite, chosen.origin.y.isFinite,
               chosen.size.width.isFinite, chosen.size.height.isFinite {
                result.placements[index].labelFrame = chosen
                result.placements[index].labelSide = chosenSide
                labels.append(chosen)
            }
        }
        return result
    }

    /// True when republishing would not move anything SwiftUI draws or hit-tests by a visible
    /// amount: label anchors, hit targets, disk bands and the camera all stay within `tolerance`
    /// points of `previous`. The camera sway and orbit drift stay below that for several frames.
    func isVisuallySame(as previous: CosmosFrame, tolerance: Double = 0.5) -> Bool {
        guard target == previous.target, size == previous.size, hoverCategory == previous.hoverCategory,
              center == previous.center, focal == previous.focal,
              scene.categories.count == previous.scene.categories.count,
              placements.count == previous.placements.count,
              length(camera.position - previous.camera.position) * focal / CosmosScene.cameraDistance <= tolerance
        else { return false }
        for (lhs, rhs) in zip(scene.categories, previous.scene.categories) {
            if lhs.id != rhs.id || abs(lhs.edge - rhs.edge) > 0.01 { return false }
        }
        for (lhs, rhs) in zip(placements, previous.placements) {
            guard lhs.id == rhs.id, lhs.isVisible == rhs.isVisible,
                  abs(lhs.extent - rhs.extent) <= tolerance else { return false }
            switch (lhs.point, rhs.point) {
            case (nil, nil):
                continue
            case let (lhsPoint?, rhsPoint?):
                if abs(lhsPoint.x - rhsPoint.x) > tolerance || abs(lhsPoint.y - rhsPoint.y) > tolerance {
                    return false
                }
            default:
                return false
            }
        }
        return true
    }

    private static func rectCircleOverlap(_ rectangle: CGRect, center: CGPoint, radius: Double) -> Bool {
        let x = CosmosScene.clamp(Double(center.x), Double(rectangle.minX), Double(rectangle.maxX))
        let y = CosmosScene.clamp(Double(center.y), Double(rectangle.minY), Double(rectangle.maxY))
        let dx = Double(center.x) - x, dy = Double(center.y) - y
        return sqrt(dx * dx + dy * dy) < radius
    }

    private static func rectsOverlap(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.minX < rhs.maxX && lhs.maxX > rhs.minX && lhs.minY < rhs.maxY && lhs.maxY > rhs.minY
    }
}
