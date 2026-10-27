import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Checks added by the 2026-10-24 audit, one failing check per defect fixed.
/// Kept apart from the older check files so parallel fixes don't collide.
public enum AuditChecksTags {
    @MainActor
    public static func run(_ check: (String, Bool) -> Void) async {
        // A number that isn't a screenshot pixel (nan, inf, 1e30) used to reach the engine,
        // where Int() of it traps (the tour trace, the ring-as-box trace, Sketch.seed).
        let odd = TagParser.parse("[POINT:nan,5:x] [POINT:inf,5:y] [HIGHLIGHT:1,2,nan,inf:z] [SHAPE:circle:1,1;1e30,1e30:w] [TARGET:1e308,2:v] a")
        check("coordinates that aren't finite pixels are refused", odd.annotations.isEmpty && odd.text == "a")
        check("a tour anchor with an absurd number is dropped", TagParser.beats("[@99999999999999999999999,5]word").first?.stops.isEmpty == true
              && TagParser.beats("[@97,80]gain").first?.stops.count == 1)
        check("ordinary numbers still parse", TagParser.parse("[POINT:50.5,-3:x] [TARGET:7680,4320,120:y]").annotations.count == 2)

        // The practice line as the prompt asks for it, after a sentence with no tag: the
        // tag after [TRY:…] leads the line, so the drawing belongs to the question.
        let practice = TagParser.beats("So c is 5.\n[TRY:gap] [WRITE:1,2:3 + ___ = 7] What goes in the blank?")
        check("the practice line's drawing goes with the question", practice.count == 2
              && practice[0] == Beat(text: "So c is 5.", annotation: nil)
              && practice[1] == Beat(text: "What goes in the blank?", annotation: .write(CGPoint(x: 1, y: 2), text: "3 + ___ = 7", screen: 0), practice: true))
        let inlinePractice = TagParser.beats("Nice work. [TRY:gap] [WRITE:1,2:3 + ___] What goes in the blank?")
        check("a practice line that shares its line with the sentence before it still splits there", inlinePractice.count == 2
              && inlinePractice[0] == Beat(text: "Nice work.", annotation: nil) && inlinePractice[1].annotation != nil && inlinePractice[1].practice)

        // A step whose radius is 0 or negative used to vanish, leaving the lesson with
        // nothing to click; it keeps the default radius instead, as a missing one does.
        check("a step with a radius that isn't positive keeps the default", TagParser.parse("[TARGET:1,2,0:x] [HOVER:3,4,-3:y] [QUIZ:5,6,0:z]").annotations
              == [.target(CGPoint(x: 1, y: 2), radius: 74, label: "x", screen: 0), .hover(CGPoint(x: 3, y: 4), radius: 74, label: "y", screen: 0),
                  .quiz(CGPoint(x: 5, y: 6), radius: 74, label: "z", screen: 0)])

        // A practice move with nothing to draw ("say it", "predict") after a sentence with
        // no tag: the reply used to be one beat, not practice, so the answer line never opened.
        let sayIt = TagParser.beats("The hypotenuse is the longest side.\n[TRY:say it] Say why in your own words.")
        check("the practice point splits text with no tags around it", sayIt.count == 2 && !sayIt[0].practice
              && sayIt[1] == Beat(text: "Say why in your own words.", annotation: nil, practice: true))
        let midLine = TagParser.beats("Intro. [TRY:predict] What happens [POINT:1,2:x] here?")
        check("the practice point splits text before an inline tag", midLine.count == 2 && midLine[0] == Beat(text: "Intro.", annotation: nil)
              && midLine[1].text == "What happens here?" && midLine[1].practice && midLine[1].annotation != nil)

        // The Windows prompt said "THE MAC", "Finder" and "/Applications/<name>.app": the older
        // check looked for "Mac" with a capital and missed them.
        let win = Prompt.system(for: .windows).lowercased()
        check("the Windows prompt names no Mac places", !win.contains("mac") && !win.contains("finder") && !win.contains(".app/contents"))
    }
}
