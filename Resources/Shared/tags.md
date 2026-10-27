# Navi's tag grammar

Claude's replies are plain text with tags in square brackets. The tags say what to draw, where Navi's light goes, what to type, and a little about the reply itself. The user never sees a tag.

This is the reference for a second implementation (the Windows shell, or anything else that reads replies). The Swift reference is `TagParser` in `Sources/NaviCore/Tags.swift`. The self-tests in `CoreSelfTest.swift` are the executable version of this page: a new parser should pass the same cases.

## Coordinates and screens

- Every coordinate is in the **pixels of one screenshot**, origin at the top left, x to the right, y down. Numbers are decimal: `120`, `50.5` and `-3` all parse. Claude is asked for integers.
- Each turn sends one screenshot per display, labelled "Screen 1 of 2", "Screen 2 of 2" and so on (or "Screen 1" when there is one display). The label says which screen has the cursor.
- Any drawing tag (and `TYPE`) may end with a **screen suffix**, `:screenN` with N ≥ 1, matched case-insensitively, with optional spaces (`:screen2`, `:Screen 2`). It names the screenshot the coordinates belong to.
- With no suffix the screen is **0, meaning "the screen with the cursor"**. A suffix that doesn't parse as a whole number ≥ 1 is not a suffix: it stays part of the label.

## Drawing tags

A drawing tag is `[KIND:body]`, where KIND is one of the seven below (the errand tags, which share the same brackets, are further down). KIND is **case-insensitive** (`[point:5,6]` works). The body runs to the first `]` and can't contain a newline.

The body is split on every `:` into segments, and each segment is trimmed of spaces. Empty segments are kept (they matter for the label rule). Then the screen suffix, if the last segment is one, is taken off.

A list of numbers is one segment split on `,`, each part trimmed. If any part isn't a number, the whole list is invalid.

A **label** is the remaining segments joined with single spaces and trimmed; an empty label is no label. Labels are meant to be 1 to 4 words with no colons.

| Tag | Body | Meaning | Valid when |
|---|---|---|---|
| `POINT` | `x,y[:label]` | A dot on one exact control, at its centre. | 2 numbers. `[POINT:none]` (any case) draws nothing. |
| `SHAPE` | `kind:x1,y1;x2,y2[;…][:label]` | A mark through the points. `kind` is `line`, `arrow`, `circle`, `curve` or `polygon` (case-insensitive). | At least 2 segments after the screen suffix. Points are split on `;`; each must be exactly 2 numbers, and invalid points are dropped. At least 2 valid points, 3 for `polygon`. |
| `TARGET` | `x,y[,r]:label` | The next thing to click in a lesson. `r` is a radius in pixels, 74 if left out. | A second segment must exist, though it may be empty (`[TARGET:7,8:]` is valid; `[TARGET:1,2]` is not). 2 or 3 numbers; an `r` that isn't positive means the default. A `:screenN` suffix counts as the second segment. |
| `HOVER` | `x,y[,r]:label` | Like `TARGET`, for something to rest the pointer on. | As `TARGET`. |
| `QUIZ` | `x,y[,r]:label` | A practice question: "click the …". Nothing is drawn and the light doesn't go there; the app grades the click. | As `TARGET`. |
| `HIGHLIGHT` | `x,y,w,h:label` | A work area: top-left corner, then width and height. | A second segment must exist. 4 numbers. Width and height below 1 become 1. |
| `WRITE` | `x,y:text` | Handwritten text (a formula, a worked number, a short note), top left at x,y. | 2 numbers and non-empty text. The text is every segment after the first **joined with `:`**, so colons survive (`[WRITE:10,20:ratio 1:2]` writes "ratio 1:2"). It's cut to 80 characters. |

Shape geometry:

- `circle`: the first point is the centre and the second a point just past the thing's edge, so the radius is the distance between them.
- `line`, `arrow`, `curve`, `polygon`: the points in order. An arrow points from the first to the last. A curve passes smoothly near its middle points; with only two, it bows gently to one side. A polygon closes itself.

A tag that isn't valid is **ignored**: it draws nothing, and it's still removed from the text.

`TARGET`, `HOVER` and `QUIZ` are **steps**: they advance a lesson when the user acts on them.

## Typing: `TYPE`

```
[TYPE]<<<text>>>
[TYPE:x,y]<<<text>>>
[TYPE:x,y:screen2]<<<text>>>
```

Text Claude wants typed into a field (never a password). The pattern is `[TYPE` with an optional `:header`, then `]`, optional whitespace, `<<<`, the text, `>>>`. `TYPE` is case-insensitive. The text may span lines; whitespace just inside `<<<` and `>>>` is trimmed. The header's segments follow the drawing rules: a screen suffix, then `x,y` (2 numbers) as the field to aim at. A bad or missing point means "the focused field". Only the **first** TYPE block counts, and it must have text.

## Errands and things to keep

These share the drawing tags' brackets and case rules, but `OPEN` and `DOWNLOAD` take their body whole (URLs and paths have colons of their own), so neither takes a `:screenN` suffix or a label. They are removed from the text like any tag.

| Tag | Body | Meaning | Valid when |
|---|---|---|---|
| `OPEN` | `target[\|app]` | Open a web page, an app, or a file (in `app` if named). The body is split once on `\|`; both halves are trimmed. | A non-empty target. |
| `DOWNLOAD` | `url` | Offer a file to download; the app asks first. | The target starts with `http://` or `https://` (any case). |
| `SHOWME` | `x1,y1;x2,y2[;…][:label][:screenN]` | A ghost pointer acts out a drag through the points; nothing is clicked. This one follows the drawing rules: a label and a screen suffix. | At least 2 valid points (bad points are dropped). |

Blocks to keep use the `TYPE` shape, `[KIND]` or `[KIND:detail]`, then `<<<text>>>`, and every block counts (not only the first):

| Tag | Meaning |
|---|---|
| `[COPY]<<<text>>>` | Put the text on the clipboard. |
| `[NOTE:title]<<<body>>>` | Save a note; the title is optional. |
| `[REMIND:when]<<<what>>>` | Set a reminder; `when` is optional and kept as written. |

A block with empty text is ignored. While streaming, an unfinished block (no `>>>` yet) is hidden like an unfinished `TYPE`.

## Reply-level tags

These say something about the reply and are never shown. Unlike the drawing tags they are **case-sensitive**, and each is removed together with the whitespace that follows it.

| Tag | Pattern | Meaning |
|---|---|---|
| `TOPIC` | `[TOPIC:name]` (anything but `]` and newline) | Names what the conversation is about, for the topic pill ("Pythagoras", "QGIS: first project"; a colon inside is fine). The first one counts. Trimmed, cut to 40 characters; empty means none. Quick answers have none. |
| `OUTLINE` | `[OUTLINE:step \| step \| …]` (anything but `]` and newline) | A lesson's rough plan, steps split on `\|`, each trimmed and cut to 80 characters, at most 30. The first one in a reply counts; a later reply's replaces it. The pill shows "step n of m", and a lesson put down partway keeps it in its bookmark. |
| `RESUME` | `[RESUME:id]` (letters and digits) | Picks up a kept lesson (a bookmark) whose id the turn listed; lowercased. Read only on a question outside a lesson. An id that isn't kept is ignored. |
| `MOOD` | `[MOOD:word]` (letters only) | A pinch of tone for the owl, lowercased. The app accepts only `wow`, `love`, `proud` and `confused` (anything else is ignored), and `wow` or `love` at most once every two minutes. |
| `SKILL` | `[SKILL:task \| how]` (anything but `]` and newline) | Something a lesson step showed about the app: a task in a few words, then where it's done by the app's own labels (`[SKILL:Export a PDF \| File > Export as PDF…]`). Split once on `\|`, both halves trimmed and non-empty; at most two per reply count. Kept only on the reply right after a step the user clicked or rested on (the prompt asks for it only then), and only if it passes the check in `Skills.vetted`: each half at most 120 characters, no quotes, links, email addresses, runs of 4+ digits or words aimed at the assistant. The app writes it into its own file in the Skills folder for the app (or the site, in a browser), tagged with the app's version. |
| `TRY` | `[TRY:move]` (letters and spaces) | Starts the practice line; the move is lowercased and trimmed (`predict`, `your turn`, `point`, `gap`, `mistake`, `say it`, `new numbers`). Everything from this tag on is **practice**: see beats. The app remembers the last four moves used and lists them in later turns, so Claude varies them. |

## Tour anchors: `[@x,y]`

Inside a sentence, right before a word: `Each strip has [@97,80]gain at the top, [@97,114] pan below it.` As the word is read, Navi's light glides to that point (in the beat's screenshot) and pulses. No ink is drawn.

- Pattern: `[@`, a number, `,`, a number, `]`, with optional spaces around the numbers (`-?\d+(\.\d+)?`).
- The beat's text is split on single spaces into tokens. An anchor attached to a word (`[@97,80]gain`) belongs to that word. A token that is only an anchor (`[@97,114] pan`) belongs to the next word. If a token holds more than one anchor, the last one wins.
- Words are numbered from 0 in the cleaned sentence, so the example gives stops at word 3 ("gain") and word 7 ("pan").
- Anchors are always removed from the shown text.
- Claude is told to use at most 4 per sentence, and never instead of a `TARGET`.

## Text

The shown text is the reply with markdown links reduced to their words, code ticks and `**` removed, a "Sources:" list (a line saying Sources and the bullet lines under it) dropped, and then:

1. `TOPIC`, `MOOD`, `OUTLINE`, `RESUME`, `SKILL` and `TRY` tags removed (with their trailing whitespace);
2. keep blocks and `TYPE` blocks removed, then every drawing and errand tag (valid or not), then anchors;
3. while streaming, the unfinished pieces at the very end removed (below);
4. whitespace and newlines collapsed to single spaces, and any space before `.` `,` `!` `?` `;` or `:` removed.

## Beats

A reply plays as **beats**: one drawing and the sentence said while it appears. Beats are made from the reply like this:

1. Remove `TOPIC`, `MOOD`, `OUTLINE`, `RESUME` and `SKILL`. Replace each `TRY` tag (and the whitespace after it) with an invisible marker (U+2063). The first marker is the **practice point**.
2. Remove `TYPE` blocks, then an unfinished TYPE block or unfinished tag at the end.
3. Walk through the drawing tags in order, with a cursor starting at 0. Skip a tag that starts before the cursor. Before each tag (and before the last beat), if the practice point lies between the cursor and the tag, the text up to the point becomes a beat of its own with no drawing and the cursor moves to the point. Then, for each tag:
   - Its annotation is the parsed tag, or none if invalid (the beat still happens, without a drawing).
   - `pre` is the cleaned text between the cursor and the tag.
   - The tag **leads its line** if only spaces or tabs come between the previous newline, practice marker or start of the reply and the tag.
   - If it leads its line and `pre` isn't empty: `pre` becomes a beat of its own, with no drawing.
   - **Text then tag** (`pre` not empty and the tag doesn't lead its line): `pre` becomes the tag's beat. The cursor moves to the end of the tag.
   - **Tag first** (otherwise): the beat's text runs from the end of the tag to whichever comes first, the next tag or the end of the line. If that's empty (a tag alone on its line), it runs to the next tag instead, across lines. If the practice point lies after the tag, the text also stops there. The cursor moves to where the text ended.
4. Whatever is left after the cursor becomes a last beat with no drawing.
5. Take each beat's anchors out (above). Drop beats with no text and no drawing.

A beat is **practice** if the practice point exists and the beat starts at or after it. A beat starts where its text starts (past leading whitespace), or at its tag for a tag-first beat.

Examples, from the self-tests:

```
[TARGET:120,210,40:add] Click Add Modifier.      → "Click Add Modifier." with the target
[POINT:5,6:knob] Then this knob.                 → "Then this knob." with the point
That's it.                                       → "That's it.", no drawing

Open the File menu [POINT:10,10:File] and pick Export [POINT:40,90:Export].
                                                 → "Open the File menu" + File; "and pick Export" + Export; "."

[HIGHLIGHT:0,38,264,977:sidebar]
On the left is the sidebar.                      → one beat: the highlight and the line below it

[WRITE:1,2:25 = c²]
So c is 5.
[TRY:predict] What if the legs doubled?          → "So c is 5." (not practice); "What if the legs doubled?" (practice)
```

## Streaming

Replies arrive a few characters at a time and are parsed again on each update, so the parser must ignore what hasn't finished:

- an unfinished tag at the very end, `\[[A-Za-z]*(:[^\]\n]*)?$` (so `[TARGET:3,4` is dropped, not shown);
- a TYPE block whose `>>>` hasn't arrived yet, `\[TYPE[^\]\n]*\]\s*<<<(?![\s\S]*>>>)[\s\S]*$`;
- an unfinished anchor at the end of the text or of a word, `\[@[^\]\s]*$`.

A finished tag can be drawn as soon as it closes, even while its sentence is still arriving.

## What the Mac app does with them

These are the app's choices, not the grammar, but a second shell should match them:

- Coordinates are clamped into the screenshot before they're mapped to the screen.
- A `circle` whose radius is more than a third of the screenshot's shorter side, with a positive second point, is read as a mistake: the second point was a width and height. It's drawn as that box (a `HIGHLIGHT` centred on the first point).
- A step's radius in points is the tag's radius times the screenshot's scale, clamped to 28…180. A click within the radius counts, and never needs to be closer than 44 points. A hover counts after the pointer rests 2 s inside the radius.
- In an explanation, each label gets the next explanation colour (design-tokens.json, `explanation`) and keeps it; a single letter at the end of a label ("leg a", "c") colours that letter in everything written. `WRITE` stays in ink, with its letters coloured.
