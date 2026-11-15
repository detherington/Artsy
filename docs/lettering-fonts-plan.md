# Drawn lettering fonts

A letterer's own hand as a font: each character drawn once on guides in a Font Studio,
kept in a library of as many fonts as the artist likes, set in balloons like any face,
and exported as a TrueType file for any other app. Etchy's handwriting font (its
`HandwritingFont` and handwriting sheets) is the model: strokes traced into outlines,
merged with Core Graphics, written as TrueType that Core Text reads from memory.

## What the artist does

- Opens the **Font Studio**: "font studio" in the lettering panel, Window ▸ Font Studio…
  on the Mac, ⇧⌘L on an iPad keyboard. On the Mac it is a window of its own, as the
  Brush Studio is; on iPad a large sheet over the canvas.
- Makes a font (new, duplicate, rename, delete in the list of fonts), and draws its
  characters one at a time on a square sheet with the guides: baseline, cap height,
  x-height (dashed) and descender, the character printed faintly behind to draw over.
  Capitals first, as comics are lettered, then figures, punctuation (with ♥ and ♪), then
  small letters if wanted.
- Draws with a **marker** (round, one width), a **brush** (round, wider with pressure) or
  a **chisel** (a broad nib at an angle), at a weight. Strokes settle a little smoother
  when the pen lifts. Undo, redo, clear the character, previous and next; on the Mac,
  typing a character turns to it.
- Sees each character in the grid as drawn, a sample line set in the font as it stands,
  and its spacing, with a slider for the room either side of every letter.
- **Exports** the font as a `.ttf` (the save panel on the Mac, Save to Files on iPad),
  which Font Book installs and any app can use.
- In the **lettering panel**, picks a drawn font under the system faces for the balloon in
  hand or the next one, as it picks a face.

## How it is built

- **`DrawnFont`** (engine, `Lettering/DrawnFont.swift`): a value, Codable: id, name,
  spacing, and a glyph for each character drawn; a glyph is strokes, a stroke its pen,
  weight and points (x, y, pressure) in font units (an em of 1,000, y up, the baseline at
  0), written compactly as numbers in a row.
- **`GlyphOutline`**: a stroke's pieces are the convex hull of the pen's shape at each
  pair of neighbouring points (a disc for round pens, a thin bar for the chisel), all
  wound one way; the pad fills them as they are, the font takes their union
  (`normalized(using: .winding)`), flattened, simplified (Douglas–Peucker, 1.2 units),
  rounded and wound as TrueType wants, holes the other way.
- **`DrawnFontFile`**: the TrueType bytes (Etchy's ten tables: glyphs of straight-sided
  outlines, no hinting). A letter drawn only as a capital or only small answers for both;
  curly quotes take the straight ones, the en dash the hyphen. Lines are 1.1 em
  (ascender 900, descender 200), so capitals sit in the middle of a line as comics want.
  Fonts made for use carry a digest in their PostScript name, so Core Text never mixes up
  two versions; an exported one is named for the font.
- **`DrawnFontLibrary`** (engine, shared): the fonts, each a `.artsyfont` file (JSON) and
  its compiled `.ttf` beside it in Application Support/Artsy/Fonts. A change is saved at
  once and compiled off the main thread, glyph outlines kept so only the changed glyph is
  traced again; the compiled font goes into **`DrawnFonts`**, a registry by id that
  `BalloonLayout` reads, and a notification tells the open canvases.
- **Balloons** keep an optional `drawnFont` id beside their face, which stays as the
  fallback: characters a font lacks are set in the face (a cascade list), and a balloon
  whose font is gone is set in its face. Older builds ignore the id.
- **Canvases** redraw the balloons set in a font when it changes, each where it was and
  is (with room for the letters having grown).
- **Documents** carry the drawn fonts their balloons use (`fonts` in `document.json`), so
  a page opened on another device, or after the font is deleted, still sets its words;
  fonts a document brings that the library lacks join the library.

## Kerning, versions, the family and imports (the second slice)

- **Kerning**: pairs of characters set closer or apart, in font units, kept by the font
  (`kerning`, "AV" → −120) and written as a classic `kern` table between every version
  of the two letters, which Core Text applies to balloons and any app to the exported
  file. The studio's **kerning** page lists the pairs kerned and the usual pairs whose
  letters are drawn (AV, LT, TO…), sets the pair in hand large between two Hs straight
  from the strokes so the kerning shows as it moves, and has a slider, closer and apart by
  fives, a **suggestion** from the outlines (`DrawnFontKerning`: the gap between the two
  letters averaged over the rows where both have ink, open rows counted as no more than
  three even gaps, brought 60% of the way to the even gap of two straight letters, never
  touching), and every usual pair kerned as suggested in one step. A drag is one step.
- **Versions**: a character can be drawn three times (`alternates`). The second and third
  are glyphs of their own, answering to private-use characters (U+E000 on, four to a
  character), and balloons rotate through them, counted through the whole balloon
  (`DrawnFonts.vary`), so no letter repeats exactly; small letters rotate with their
  capitals. An exported file also carries `calt` rules (GSUB chaining contextual lookups)
  that set a letter repeated next to itself in its next version, which Core Text and any
  OpenType app apply by themselves. In the studio, the version row chooses which is drawn
  on, the first shown faintly behind a second or third; clearing the first lets the second
  take its place; the grid marks characters with versions.
- **The family**: regular, bold, italic and bold italic, each a TrueType file of its own:
  the bold traced from the same strokes with a pen heavier by the font's **boldness**
  (×1.5), the italic its outlines slanted by its **slant** (12°), each named, flagged
  (macStyle, fsSelection, weight class, italic angle, caret slope) and style-linked so
  Font Book installs the four as one family. The studio's **family** page sets the two
  and shows the four. In the lettering panel a balloon has **bold** and **italic**
  switches, and words between asterisks are **stressed**, set in bold italic as comics
  stress a word (a lone asterisk stays). The system faces are bold cuts already: bold
  draws them heavier still (fill and stroke); italic is the face's own where it has one,
  else slanted. Export offers the regular or the whole family, a folder of four files.
- **Importing**: a font file brought in through the studio's import. One Artsy exported
  comes back as drawn, editable, with its versions and kerning: exported files carry the
  drawing itself, compressed, in a private `ARTS` table; it keeps its id, so documents set
  in it find it, unless the library has a different font by that id, when it comes as a
  copy. Any other TrueType or OpenType font is set as it is (`imported`), named for its
  family and style, read but not drawn on; its maker's embedding bits (OS/2 fsType) decide
  whether it travels inside documents. Collections and files that are not fonts are
  turned away with a reason.

## Later

- Kerning classes (all round letters at once) and kerning in the bold drawn apart.
- Drawing a bold or italic letter by hand where the traced one is not right.
- Ligatures for doubled letters; the crossbar I.
- Sharing fonts between devices through iCloud.

## Status (2026-11-15, branch `lettering-fonts`)

- Built for the Mac and iPad, on its own branch off main in a worktree
  (`.claude/worktrees/lettering-fonts`), leaving `flats-clipping` as it was.
- `DrawnFontTests` (13): a stroke's pieces cover its pen's width with round ends; a
  letter with a hole winds it the other way, traced in milliseconds; the brush follows
  pressure and the chisel its nib; smoothing evens a shaky stroke and keeps its ends;
  Core Text reads the font and sets the letters as drawn (ink, spacing, cap height, line,
  capitals for small letters and back, a crossbar that stays ink); an exported font named
  for itself and one for use carrying a digest; a compact round trip; the library saving,
  compiling, registering, reloading from the compiled file and deleting; a balloon set in
  a drawn font, a missing character in its face, a gone font falling back; balloons from
  before reading with none; a font change setting its balloons again (a rename does not);
  a document carrying its fonts to a library that lacks them; and on the Mac only, the
  studio drawing, undoing, clearing, turning, renaming, exporting and deleting. The 12
  engine tests pass on the iPad simulator.
- Seen on the iPad simulator: the lettering panel's "draw a font", the studio (full
  screen, so a stroke drawn downward is not taken as a swipe to close the sheet, which it
  was at first), an A, H, I and ! drawn by touch, the grid, sidebar and sample line set in
  them as they compiled, a balloon placed in the font reading "AH! HI! HA!", and the font
  exported through Save to Files as "My Lettering.ttf", which Core Text on the Mac reads
  (PostScript MyLettering-Regular, family My Lettering, six glyphs) and sets.
- Fixed while checking: a stroke begun just as the character changed was dropped when
  SwiftUI's late update cleared the stroke in progress; the pad now keeps a stroke while
  the pen is down.
- Not yet seen on the Mac (it builds); the Mac suite has not run on this branch.

### The second slice (kerning, versions, family, imports)

- `DrawnFontFamilyTests` (14): kerning sets a pair closer in capitals and small letters,
  not the reverse pair; suggestions kern A and V and leave H and H; three versions are three
  glyphs and repeats rotate through them (small letters with capitals), a balloon of two As
  as wide as the first and second; an exported font swaps repeats by itself in Core Text
  (`calt`), round the versions, only for repeats; versions set and taken away; the family's
  bold half as heavy again and its italic leaning by the stroke's height, each named and
  flagged; the library compiling and exporting the four; stressed words out of their
  asterisks; a balloon in bold, a stressed word in bold italic, a face slanted for italic
  and drawn heavier for bold; bold and italic saved, balloons from before reading as
  neither; fonts from before reading with the defaults; an exported font importing as
  drawn (same id, versions, kerning; not doubled; a copy once changed); any other font
  importing as it is, a restricted one staying out of documents, collections and non-fonts
  turned away; and on the Mac only, the studio's versions, clearing, kerning as one step
  and suggestions. The 13 engine tests pass on the iPad simulator.
- Seen on the iPad simulator: the letters, kerning and family pages; a second A drawn over
  the first; V drawn and AV and VA kerned as suggested (−120 each); the four members set
  side by side; a balloon switched to bold with a stressed word in bold italic. The import
  button opens the Files picker, which the simulator's taps don't reach, so the pick
  itself was checked by the tests. Fixed while checking: SwiftUI read the hint "*word*" as
  Markdown (now verbatim); the importer shared a view with the exporter (each file dialog
  now has its own); the kerning preview took the whole height on an upright iPad.
