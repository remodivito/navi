import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The screen moving under what's drawn. When the screen moves
/// (a scroll, another app, another Space) the marks are wrong, so clear them and
/// let the answer carry on. A lesson step is re-placed after a scroll and paused
/// after a switch. The shell reports the moves; the engine decides.
extension Tutor.Engine {
    /// Another app came forward. `display` is where its front window is, if known.
    public func appCameForward(pid: Int32, name: String, display: ScreenID?) {
        // A system dialog (a password or permission prompt) isn't them moving on.
        if let id = ui.bundleID(of: pid), Tutor.systemDialogs.contains(id) {
            trace("\(name) came up (a system dialog): carrying on.")
            return
        }
        // Navi opened it: that's the errand landing, not them moving on. The lesson
        // follows them there, and the look after the errand carries on from it.
        if let until = errandUntil, Date() < until {
            trace("\(name) came forward from an errand: carrying on there.")
            if lesson != nil, pid != ownPID { lessonApp = pid; lessonScreen = display ?? lessonScreen }
            return
        }
        // A lesson waits while they're elsewhere and looks again when they're back.
        if lesson != nil, let home = lessonApp {
            let onLessonScreen = display == nil || lessonScreen == nil || display == lessonScreen
            switch Tutor.reaction(to: .switched, inLessonApp: pid == home, onLessonScreen: onLessonScreen,
                                  paused: lessonPaused, looks: looksThisStep) {
            case .look: lookAgain(pendingLookEvent ?? Tutor.backEvent(stepLabel ?? "the last step"), why: "back in \(name)")
            case .pause: pauseLesson(why: "switched to \(name)")
            case .ignore: if !onLessonScreen { trace("Switched to \(name) on another display: the lesson stays.") }
            }
            return
        }
        guard pid != frontApp()?.pid else { return }
        // An app brought forward on another display doesn't move what's drawn on this one.
        if let display, !showsSomething(on: display) {
            trace("Switched to \(name) on another display: marks stay.")
            return
        }
        if beatsPlaying { stopPlayback("switched to \(name)") }
        screenMoved(reason: "switched to \(name)", pauseLesson: true)
    }

    /// The Space changed. During a lesson: give a full-screen switch a moment, then
    /// see where they are.
    public func spaceChanged() {
        if let until = errandUntil, Date() < until { return }   // the errand's page or app opened in its own Space
        if lesson != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.lesson != nil, !self.lookPending else { return }
                let front = self.ui.frontmostPID()
                switch Tutor.reaction(to: .space, inLessonApp: front != nil && front == self.lessonApp, onLessonScreen: true,
                                      paused: self.lessonPaused, looks: self.looksThisStep) {
                case .look: self.lookAgain(Tutor.spaceEvent(self.stepLabel ?? "the last step"), why: "Space changed")
                case .pause: self.pauseLesson(why: "Space changed")
                case .ignore: break
                }
            }
            return
        }
        if beatsPlaying { stopPlayback("Space changed") }
        screenMoved(reason: "Space changed", pauseLesson: true)
    }

    /// The user scrolled by `amount` points. `anyWindow`: it counts wherever the
    /// pointer is (otherwise only scrolling the app the answer is about moves the drawing).
    public func scrolled(_ amount: CGFloat, anyWindow: Bool = false) {
        if let step = scrollStep {
            guard Date() < step.until else {
                scrollStep = nil
                trace("Scroll step: no scroll in time; waiting for them to ask.")
                return
            }
            // Only scrolling the lesson's app counts, not a chat beside it.
            if !anyWindow, let pid = lessonApp, ui.windowOwner(at: screens.pointerLocation()) != pid { return }
            scrolledBy += abs(amount)
            guard scrolledBy >= Tutor.scrollCounts else { return }
            // Once the scrolling pauses, read the screen for what they're scrolling to.
            if scrollStarted == nil { scrollStarted = Date() }
            rePlaceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rePlaceWork = nil; self?.scrollPaused() }
            rePlaceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Tutor.scrollPause, execute: work)
            return
        }
        guard overlay.hasDrawings || lesson?.armed != nil || rePlaceWork != nil else { return }
        scrolledBy += amount
        guard scrolledBy > 12 else { return }
        // Scrolling a chat or a page in another window beside the app doesn't move what was drawn.
        if !anyWindow, let pid = frontApp()?.pid, ui.windowOwner(at: screens.pointerLocation()) != pid {
            scrolledBy = 0
            return
        }
        if lesson?.armed != nil {
            // Once the scrolling stops, look: only if the step itself moved (a page, not a
            // map zooming under a toolbar) is it re-placed.
            rePlaceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.checkStepAfterScroll() }
            rePlaceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
            return
        } else if rePlaceWork == nil {
            screenMoved(reason: "scrolled", pauseLesson: false)
            scrolledBy = 0
            return
        }
        rePlaceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rePlaceStep() }
        rePlaceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func checkStepAfterScroll() {
        rePlaceWork = nil
        scrolledBy = 0
        guard let step = lesson?.armed else { return }
        Task { @MainActor in
            guard let moved = await self.watch?.stepMoved(step), self.lesson?.armed?.armedAt == step.armedAt else { return }
            if !moved {
                trace("Scrolled, but \"\(step.label)\" didn't move: keeping the step.")
                return
            }
            trace("Scrolled and \"\(step.label)\" moved: re-placing it.")
            self.disarmStep()
            self.overlay.clearSteps()
            self.overlay.fadeDrawings()
            self.light.comeBack()
            self.rePlaceStep()
        }
    }

    /// After a scroll during a lesson: a fresh look, and the same step at its new place.
    func rePlaceStep() {
        rePlaceWork = nil
        scrolledBy = 0
        lookAgain(Tutor.scrolledEvent, why: "scrolled")
    }

    /// The screen moved under the drawing: put the marks away (the words carry on).
    func screenMoved(reason: String, pauseLesson: Bool) {
        guard overlay.hasDrawings || lesson?.armed != nil else { return }
        trace("Clearing marks, narration keeps going (\(reason)).")
        if pauseLesson, lesson?.armed != nil {
            disarmStep()   // the lesson waits for "continue"
            overlay.clearSteps()
        }
        overlay.fadeDrawings()
        light.comeBack()
    }

    /// Whether marks or a lesson step are on `screen`.
    func showsSomething(on screen: ScreenID) -> Bool {
        lesson?.armed?.display == screen || overlay.hasDrawings(on: screen)
    }
}
