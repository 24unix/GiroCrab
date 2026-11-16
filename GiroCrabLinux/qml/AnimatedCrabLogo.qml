import QtQuick
import QtQuick.Shapes

// AnimatedCrabLogoView.swift: the animated vector crab (girocrab-icon.svg, 1024×1024 canvas).
// - coin toss (3D flip) and a diagonal shine over the credit card when it appears
// - gentle hover with a matching ground shadow, blinking while idle
// - "unlock hop" when the vault opens (phase "unlocked")
// - a click on the crab plays coin toss and shine again
// Same paths, colours, timings and curves as the Mac. SwiftUI's springs and ease curves run
// through a small tween engine below (FrameAnimation), so springs keep their velocity when
// retargeted, like SwiftUI's.
Item {
    id: crab
    property real size: 160
    /// AnimatedCrabLogoView.Phase: "idle", "unlocking", "unlocked", "failed"
    property string phase: "idle"
    property bool showBackgroundSquircle: true
    /// accessibilityReduceMotion: no hover, blinking, toss or hop. Linux has no system-wide
    /// setting Qt exposes, so callers may set it; off by default.
    property bool reduceMotion: false
    /// Linux only: the vault takes a while to open (keyring, then loading the bookings on the
    /// GUI thread), so while `busy` the crab tosses its coin in a loop. The loop uses Animators,
    /// which run on the scene graph's render thread and keep moving while the GUI thread is busy.
    property bool busy: false
    readonly property bool busyTossing: busy && visible && !reduceMotion
    onBusyTossingChanged: if (!busyTossing) { coinToss.y = 0; coinSpin.rotation = 0 }
    SequentialAnimation {
        running: crab.busyTossing
        loops: Animation.Infinite
        ParallelAnimation {
            SequentialAnimation {
                YAnimator { target: coinToss; from: 0; to: -130; duration: 360; easing.type: Easing.OutQuad }
                YAnimator { target: coinToss; from: -130; to: 0; duration: 360; easing.type: Easing.InQuad }
            }
            RotationAnimator { target: coinSpin; from: 0; to: 720; duration: 720; easing.type: Easing.InOutSine }
        }
        PauseAnimation { duration: 420 }
    }

    implicitWidth: size
    implicitHeight: size

    // Animation state (canvas units of the 1024×1024 artwork)
    property real hoverOffsetY: 0
    property real hopOffsetY: 0
    property real coinOffsetY: 0
    property real coinFlipDegrees: 0
    property real cardTiltDegrees: 0
    property real rightClawDegrees: 0
    property real shimmerProgress: -1.2
    property real eyebrowOffsetY: 0
    property real pupilX: 0
    property real pupilY: 0
    property real eyeScaleY: 1
    property bool isReplaying: false

    Accessible.role: Accessible.Button
    Accessible.name: "GiroCrab"
    Accessible.onPressAction: triggerCoinTossAndShimmer()

    // onAppear / onDisappear: a StackLayout keeps hidden pages alive, so follow the visibility
    Component.onCompleted: if (visible) startAnimations()
    onVisibleChanged: {
        if (visible) startAnimations()
        else { blinkTimer.stop(); blinkOpen.stop() }
    }
    onPhaseChanged: handlePhaseChange(phase)

    // MARK: - Animations

    function startAnimations() {
        if (reduceMotion) return
        // initial coin toss + card shine when appearing
        triggerCoinTossAndShimmer()
        blinkTimer.start()
    }

    function triggerCoinTossAndShimmer() {
        if (reduceMotion || isReplaying) return
        isReplaying = true
        stop("shimmerProgress")
        shimmerProgress = -1.2
        // 1. wind up, throw the coin, tilt the card, look at the coin
        const out = { curve: easeOut, duration: 0.22 }
        animate("coinOffsetY", -95, out)
        animate("rightClawDegrees", -8, out)
        animate("cardTiltDegrees", -7, out)
        animate("eyebrowOffsetY", -16, out)
        animate("pupilX", 8, out)
        animate("pupilY", -9, out)
        const inOut = { curve: easeInOut, duration: 0.48 }
        animate("coinFlipDegrees", coinFlipDegrees + 360, inOut)
        animate("shimmerProgress", 1.4, inOut)
        tossLand.start()
    }

    // 2. the coin lands springily back in the claw
    Timer {
        id: tossLand
        interval: 220
        onTriggered: {
            const spring = { response: 0.38, damping: 0.58 }
            crab.animate("coinOffsetY", 0, spring)
            crab.animate("rightClawDegrees", 0, spring)
            crab.animate("cardTiltDegrees", 3, spring)
            tossSettle.start()
        }
    }
    Timer {
        id: tossSettle
        interval: 180
        onTriggered: {
            const spring = { response: 0.32, damping: 0.7 }
            crab.animate("cardTiltDegrees", 0, spring)
            crab.animate("eyebrowOffsetY", 0, spring)
            crab.animate("pupilX", 0, spring)
            crab.animate("pupilY", 0, spring)
            tossDone.start()
        }
    }
    Timer { id: tossDone; interval: 220; onTriggered: crab.isReplaying = false }

    // periodic blinking while idle
    Timer {
        id: blinkTimer
        interval: 3400
        repeat: true
        running: false
        onTriggered: {
            if (crab.reduceMotion) { stop(); return }
            crab.animate("eyeScaleY", 0.08, { curve: crab.easeIn, duration: 0.07 })
            blinkOpen.start()
        }
    }
    Timer { id: blinkOpen; interval: 85; onTriggered: crab.animate("eyeScaleY", 1, { curve: crab.easeOut, duration: 0.09 }) }

    function handlePhaseChange(newPhase) {
        if (reduceMotion) return
        switch (newPhase) {
        case "idle": {
            const spring = { response: 0.35, damping: 0.75 }
            animate("pupilX", 0, spring); animate("pupilY", 0, spring); animate("eyebrowOffsetY", 0, spring)
            break
        }
        case "unlocking": {
            // looking up at the keyring prompt
            const ease = { curve: easeInOut, duration: 0.25 }
            animate("pupilX", 0, ease); animate("pupilY", -10, ease); animate("eyebrowOffsetY", -8, ease)
            break
        }
        case "unlocked": {
            // "unlock hop"
            const spring = { response: 0.26, damping: 0.52 }
            animate("hopOffsetY", -52, spring)
            animate("cardTiltDegrees", -10, spring)
            animate("rightClawDegrees", 10, spring)
            animate("eyebrowOffsetY", -18, spring)
            animate("pupilX", 0, spring); animate("pupilY", 0, spring)
            hopLand.start()
            break
        }
        case "failed": {
            // questioning look
            const spring = { response: 0.28, damping: 0.55 }
            animate("eyebrowOffsetY", 8, spring)
            animate("pupilX", -6, spring); animate("pupilY", 4, spring)
            break
        }
        }
    }
    Timer {
        id: hopLand
        interval: 210
        onTriggered: {
            const spring = { response: 0.36, damping: 0.62 }
            crab.animate("hopOffsetY", 0, spring)
            crab.animate("cardTiltDegrees", 0, spring)
            crab.animate("rightClawDegrees", 0, spring)
            crab.animate("eyebrowOffsetY", 0, spring)
        }
    }

    // Hover: -14 · (0.5 − 0.5 · cos(2πt / 4.2)), i.e. 0 → -14 → 0 with a sine ease, 4.2 s.
    SequentialAnimation on hoverOffsetY {
        running: !crab.reduceMotion && crab.visible
        loops: Animation.Infinite
        NumberAnimation { from: 0; to: -14; duration: 2100; easing.type: Easing.InOutSine }
        NumberAnimation { from: -14; to: 0; duration: 2100; easing.type: Easing.InOutSine }
    }

    // MARK: - Tween engine (SwiftUI withAnimation equivalents)

    /// SwiftUI's timing curves (cubic Bézier control points).
    readonly property var easeIn: [0.42, 0, 1, 1]
    readonly property var easeOut: [0, 0, 0.58, 1]
    readonly property var easeInOut: [0.42, 0, 0.58, 1]
    /// property name → { to, curve, duration, from, elapsed } or { to, response, damping, velocity }
    property var anims: ({})
    property int animCount: 0
    property var velocities: ({})

    function animate(name, to, spec) {
        const a = { to: to }
        if (spec.curve) {
            a.curve = spec.curve; a.duration = spec.duration; a.from = crab[name]; a.elapsed = 0
            velocities[name] = 0
        } else {
            // .spring(response:dampingFraction:) = mass 1, stiffness (2π/response)², damping 4πζ/response
            a.stiffness = Math.pow(2 * Math.PI / spec.response, 2)
            a.friction = 4 * Math.PI * spec.damping / spec.response
        }
        anims[name] = a
        animCount = Object.keys(anims).length
    }
    function stop(name) {
        delete anims[name]
        velocities[name] = 0
        animCount = Object.keys(anims).length
    }
    function bezier(c, x) {
        // solve x(t) = x for t (Newton, then bisection), return y(t)
        const bx = t => 3 * (1 - t) * (1 - t) * t * c[0] + 3 * (1 - t) * t * t * c[2] + t * t * t
        const by = t => 3 * (1 - t) * (1 - t) * t * c[1] + 3 * (1 - t) * t * t * c[3] + t * t * t
        let lo = 0, hi = 1, t = x
        for (let i = 0; i < 24; i++) {
            const d = bx(t) - x
            if (Math.abs(d) < 1e-5) break
            if (d > 0) hi = t; else lo = t
            t = (lo + hi) / 2
        }
        return by(t)
    }
    function step(dt) {
        const names = Object.keys(anims)
        for (const name of names) {
            const a = anims[name]
            if (a.curve) {
                a.elapsed += dt
                const p = Math.min(1, a.elapsed / a.duration)
                crab[name] = a.from + (a.to - a.from) * bezier(a.curve, p)
                if (p >= 1) delete anims[name]
            } else {
                let x = crab[name], v = velocities[name] || 0
                const n = Math.max(1, Math.ceil(dt * 480))
                const h = dt / n
                for (let i = 0; i < n; i++) {
                    v += (-a.stiffness * (x - a.to) - a.friction * v) * h
                    x += v * h
                }
                if (Math.abs(x - a.to) < 0.005 && Math.abs(v) < 0.05) { x = a.to; v = 0; delete anims[name] }
                velocities[name] = v
                crab[name] = x
            }
        }
        animCount = Object.keys(anims).length
    }
    FrameAnimation {
        running: crab.animCount > 0
        // frameTime is 0 on the first frame; a long stall (busy GUI thread) is capped
        onTriggered: crab.step(Math.min(frameTime, 0.05))
    }

    MouseArea {
        anchors.fill: parent
        onClicked: crab.triggerCoinTossAndShimmer()
    }

    // MARK: - Vector layers (1024×1024 reference system)

    component Fill: ShapePath {
        strokeWidth: -1
        strokeColor: "transparent"
        fillRule: ShapePath.WindingFill
    }
    component Oval: Fill {
        id: oval
        property real cx
        property real cy
        property real rx
        property real ry
        PathAngleArc { centerX: oval.cx; centerY: oval.cy; radiusX: oval.rx; radiusY: oval.ry; startAngle: 0; sweepAngle: 360 }
    }
    component Polygon: Fill {
        id: polygon
        property var points: []
        PathPolyline { path: polygon.points }
    }
    component Vector: Shape {
        preferredRendererType: Shape.CurveRenderer
    }
    component Eye: Item {
        id: eye
        property real centerX
        property real centerY
        transform: Scale { origin.x: eye.centerX; origin.y: eye.centerY; yScale: crab.eyeScaleY }
        // orange eye ring
        Rectangle { x: eye.centerX - 46; y: eye.centerY - 46; width: 92; height: 92; radius: 46; color: "#EA4E1B" }
        // sclera
        Rectangle { x: eye.centerX - 34; y: eye.centerY - 34; width: 68; height: 68; radius: 34; color: "white" }
        // pupil + highlight
        Item {
            x: crab.pupilX
            y: crab.pupilY
            Rectangle { x: eye.centerX - 19; y: eye.centerY - 19; width: 38; height: 38; radius: 19; color: "#1E2836" }
            Rectangle { x: eye.centerX - 7 - 6.5; y: eye.centerY - 7 - 6.5; width: 13; height: 13; radius: 6.5; color: "white" }
        }
    }

    Item {
        id: art
        width: 1024
        height: 1024
        transformOrigin: Item.TopLeft
        scale: crab.size / 1024

        readonly property real lift: Math.max(-40, Math.min(60, -(crab.hoverOffsetY + crab.hopOffsetY)))

        Rectangle {
            visible: crab.showBackgroundSquircle
            anchors.fill: parent
            radius: 220
            color: "#263040"
        }

        // 1. ground shadow (shrinks while the crab lifts off)
        Vector {
            opacity: Math.max(0.18, 0.35 - art.lift / 320)
            transform: Scale {
                origin.x: 512; origin.y: 782
                xScale: Math.max(0.78, 1 - art.lift / 260); yScale: xScale
            }
            Oval { fillColor: "#161D26"; cx: 512; cy: 782; rx: 242; ry: 24 }
        }

        // the crab (hover & hop)
        Item {
            width: 1024
            height: 1024
            y: crab.hoverOffsetY + crab.hopOffsetY

            // 2. left arm + credit card + shine + left claw
            Item {
                width: 1024
                height: 1024
                transform: Rotation { origin.x: 275; origin.y: 470; angle: crab.cardTiltDegrees }

                Vector {
                    Polygon { fillColor: "#C63609"; points: [Qt.point(259, 428), Qt.point(315, 459), Qt.point(325, 508), Qt.point(273, 500)] }
                }

                // credit card (rotated by -30° as in the SVG)
                Item {
                    x: 256
                    y: 310
                    rotation: -30
                    transformOrigin: Item.TopLeft
                    Rectangle { x: -145; y: -92; width: 290; height: 184; radius: 22; color: "#D5DCE6" }
                    // magnetic stripe
                    Rectangle { x: -145; y: -56; width: 290; height: 34; color: "#263040" }
                    // text lines
                    Rectangle { x: -115; y: 18; width: 92; height: 12; radius: 6; color: "#8F9BA8" }
                    Rectangle { x: -115; y: 40; width: 122; height: 12; radius: 6; color: "#8F9BA8" }
                    // two overlapping card circles
                    Rectangle { x: 42; y: 2; width: 46; height: 46; radius: 23; color: "#7E8B9B" }
                    Rectangle { x: 68; y: 2; width: 46; height: 46; radius: 23; color: "#99A5B4" }
                    // diagonal shine: a 70-wide band turned by 20°, drawn as a gradient across
                    // the band so the card outline itself clips it (no clip path in Qt Quick)
                    Vector {
                        id: shine
                        readonly property real centerX: crab.shimmerProgress * 220
                        readonly property real ux: Math.cos(20 * Math.PI / 180)
                        readonly property real uy: Math.sin(20 * Math.PI / 180)
                        visible: crab.shimmerProgress > -1.15 && crab.shimmerProgress < 1.35
                        Fill {
                            fillGradient: LinearGradient {
                                spread: ShapeGradient.PadSpread
                                x1: (shine.centerX - 35) * shine.ux; y1: (shine.centerX - 35) * shine.uy
                                x2: (shine.centerX + 35) * shine.ux; y2: (shine.centerX + 35) * shine.uy
                                GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0) }
                                GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.55) }
                                GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
                            }
                            // the card: rounded rect (-145, -92, 290, 184), radius 22
                            startX: -123; startY: -92
                            PathLine { x: 123; y: -92 }
                            PathArc { x: 145; y: -70; radiusX: 22; radiusY: 22 }
                            PathLine { x: 145; y: 70 }
                            PathArc { x: 123; y: 92; radiusX: 22; radiusY: 22 }
                            PathLine { x: -123; y: 92 }
                            PathArc { x: -145; y: 70; radiusX: 22; radiusY: 22 }
                            PathLine { x: -145; y: -70 }
                            PathArc { x: -123; y: -92; radiusX: 22; radiusY: 22 }
                        }
                    }
                }

                // left claw (in front of the card)
                Vector {
                    Fill {
                        fillColor: "#E64815"
                        startX: 191; startY: 392
                        PathQuad { x: 262; y: 398; controlX: 230; controlY: 408 }
                        PathLine { x: 304; y: 344 }
                        PathQuad { x: 312; y: 462; controlX: 340; controlY: 418 }
                        PathQuad { x: 191; y: 392; controlX: 215; controlY: 486 }
                    }
                }
            }

            // 3. right arm + gold coin (3D flip) + right claw
            Item {
                width: 1024
                height: 1024
                transform: Rotation { origin.x: 715; origin.y: 485; angle: crab.rightClawDegrees }

                // right arm + back claw finger
                Vector {
                    Fill {
                        fillColor: "#C63609"
                        startX: 695; startY: 495
                        PathLine { x: 748; y: 446 }
                        PathQuad { x: 698; y: 365; controlX: 685; controlY: 408 }
                        PathLine { x: 752; y: 375 }
                        PathLine { x: 765; y: 488 }
                        PathLine { x: 710; y: 525 }
                    }
                }

                // gold coin; `coinToss` / `coinSpin` move it in the busy loop (render thread)
                Item {
                    id: coinToss
                    width: 1024
                    height: 1024
                    Item {
                        id: coinSpin
                        x: 726 - 84; y: 310 - 84; width: 168; height: 168   // rotates about the coin's centre
                        Item {
                            x: -(726 - 84); y: -(310 - 84)
                            width: 1024
                            height: 1024
                            transform: [
                                Rotation { origin.x: 726; origin.y: 310; axis { x: 0; y: 1; z: 0.1 } angle: crab.coinFlipDegrees },
                                Translate { y: crab.coinOffsetY }
                            ]
                            Rectangle { x: 726 - 84; y: 310 - 84; width: 168; height: 168; radius: 84; color: "#F3C23A" }
                            Rectangle { x: 726 - 66; y: 310 - 66; width: 132; height: 132; radius: 66; color: "#E5AE27" }
                            // embossed bar, slightly tilted
                            Rectangle { x: 726 - 16; y: 310 - 58; width: 32; height: 116; radius: 8; rotation: -18; color: "#F3C23A" }
                        }
                    }
                }

                Vector {
                    Fill {
                        fillColor: "#E64815"
                        startX: 777; startY: 278
                        PathQuad { x: 822; y: 446; controlX: 862; controlY: 368 }
                        PathQuad { x: 702; y: 442; controlX: 756; controlY: 492 }
                        PathQuad { x: 758; y: 382; controlX: 734; controlY: 416 }
                    }
                    // highlights on the right claw
                    Oval { fillColor: "#F38654"; cx: 804; cy: 393; rx: 6; ry: 11 }
                    Oval { fillColor: "#F38654"; cx: 797.5; cy: 416.5; rx: 4.5; ry: 4.5 }
                }
            }

            // 4. legs, shell and mouth
            Vector {
                // left legs, then mirrored at x = 512
                Polygon { fillColor: "#D93E0E"; points: [Qt.point(254, 528), Qt.point(316, 560), Qt.point(245, 658), Qt.point(162, 716), Qt.point(205, 608)] }
                Polygon { fillColor: "#C63609"; points: [Qt.point(295, 552), Qt.point(356, 576), Qt.point(294, 676), Qt.point(228, 736), Qt.point(258, 634)] }
                Polygon { fillColor: "#B22E06"; points: [Qt.point(342, 575), Qt.point(394, 595), Qt.point(340, 688), Qt.point(277, 735), Qt.point(306, 650)] }
                Polygon { fillColor: "#D93E0E"; points: [Qt.point(770, 528), Qt.point(708, 560), Qt.point(779, 658), Qt.point(862, 716), Qt.point(819, 608)] }
                Polygon { fillColor: "#C63609"; points: [Qt.point(729, 552), Qt.point(668, 576), Qt.point(730, 676), Qt.point(796, 736), Qt.point(766, 634)] }
                Polygon { fillColor: "#B22E06"; points: [Qt.point(682, 575), Qt.point(630, 595), Qt.point(684, 688), Qt.point(747, 735), Qt.point(718, 650)] }

                // shell: upper dome + facets
                Fill {
                    fillColor: "#F0551E"
                    startX: 512; startY: 422
                    PathQuad { x: 296; y: 536; controlX: 350; controlY: 422 }
                    PathLine { x: 382; y: 668 }
                    PathLine { x: 512; y: 668 }
                }
                Fill {
                    fillColor: "#DC4312"
                    startX: 512; startY: 422
                    PathQuad { x: 728; y: 536; controlX: 674; controlY: 422 }
                    PathLine { x: 642; y: 668 }
                    PathLine { x: 512; y: 668 }
                }
                // lower belly facet
                Polygon {
                    fillColor: "#D33B0D"
                    points: [Qt.point(296, 536), Qt.point(512, 492), Qt.point(728, 536), Qt.point(642, 668), Qt.point(382, 668)]
                }
                // laughing mouth
                Fill {
                    fillColor: "#5B1707"
                    startX: 432; startY: 545
                    PathQuad { x: 592; y: 545; controlX: 512; controlY: 562 }
                    PathQuad { x: 512; y: 634; controlX: 576; controlY: 634 }
                    PathQuad { x: 432; y: 545; controlX: 448; controlY: 634 }
                }
                // tongue: ellipse (462, 590, 100×56) clipped to the mouth. The clip is
                // precomputed: upper arc of the ellipse between its two crossings with the
                // mouth's lower edge (t ≈ 0.4701 / 0.5299), then that edge split at the crossings.
                Fill {
                    fillColor: "#EE5C35"
                    startX: 462.432; startY: 614.328
                    PathArc { x: 561.568; y: 614.328; radiusX: 50; radiusY: 28 }
                    PathQuad { x: 512; y: 634; controlX: 542.089; controlY: 634 }
                    PathQuad { x: 462.432; y: 614.328; controlX: 481.911; controlY: 634 }
                }
            }
            // highlights on the left shell side
            Item {
                x: 386
                y: 484
                rotation: -28
                transformOrigin: Item.TopLeft
                Vector {
                    Oval { fillColor: "#F68352"; cx: 0; cy: 0; rx: 18; ry: 8 }
                    Oval { fillColor: "#F68352"; cx: 31; cy: -9; rx: 7; ry: 5 }
                }
            }

            // 5. eyebrows, eyes
            Vector {
                y: crab.eyebrowOffsetY
                ShapePath {
                    strokeColor: "#EA4E1B"; strokeWidth: 14; capStyle: ShapePath.RoundCap; fillColor: "transparent"
                    startX: 398; startY: 356
                    PathQuad { x: 465; y: 352; controlX: 430; controlY: 328 }
                }
                ShapePath {
                    strokeColor: "#EA4E1B"; strokeWidth: 14; capStyle: ShapePath.RoundCap; fillColor: "transparent"
                    startX: 559; startY: 352
                    PathQuad { x: 626; y: 356; controlX: 594; controlY: 328 }
                }
            }
            Eye { centerX: 448; centerY: 404 }
            Eye { centerX: 576; centerY: 404 }
        }
    }
}
