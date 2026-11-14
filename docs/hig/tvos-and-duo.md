# tvOS design language on the unfolded iPhone Duo (Cuven max): HIG digest

## 1. tvOS design language

**Content and tone**

- **T1** Put content first: edge-to-edge artwork, subtle and fluid animation, a cinematic feel that stays legible at a distance. [Designing for tvOS › Best practices] "Deliver beautiful, edge-to-edge artwork, subtle and fluid animations, and engaging audio"
- **T2** tvOS sizes are set for a viewer 8 ft or more away, so they reflect viewing distance and aren't absolute values. [Designing for tvOS › intro: Ergonomics] "people generally remain many feet away from their stationary TV — often 8 feet or more"
- **T3** Focus is how people navigate. It gently highlights and enlarges the one item they are on, so they always know where they are. [Designing for tvOS › Best practices] "gently highlight and expand onscreen items as people move among them, helping them know what to do"
- **T4** Color defers to content: use a limited palette that coordinates with the logo, and never show focus with color alone. Scaling and responsive animation are the focus cues. [Color › tvOS] "Subtle scaling and responsive animation are the primary ways to denote interactivity when an element is in focus."
- **T5** A permanently dark appearance is legitimate for immersive media. It lets the UI recede and keeps attention on the media. [Dark Mode › Best practices] "it can make sense for an app that supports immersive media viewing to use a permanently dark appearance"

**Focus engine**

- **T6** Focus and selection are separate. Moving focus never opens anything; activating the focused item takes a separate gesture (a press). [Focus and selection › intro] "because selecting a focused item opens or activates it, selection requires a separate gesture."
- **T7** tvOS shows focus with parallax depth rather than rings or highlights. The focused item rises to the foreground, is lit, and animates. [Focus and selection › intro] "tvOS generally uses the parallax effect to give the focused item an appearance of depth and liveliness."
- **T8** There are five visually distinct states. Apple's state images show them as follows. Unfocused: small shadow, translucent fill tinted by the content. Focused: larger, deeper shadow, opaque white fill with a black label. Highlighted (pressed): back to unfocused size with a slightly deeper shadow, and it may briefly invert its colors. Selected: unfocused size with a small shadow. Unavailable: no shadow, low-contrast text. [Focus and selection › tvOS · state-image alt text] "It’s larger than an unfocused button, and a drop shadow makes it appear farther away"
- **T9** Focus enlarges items. Ship artwork at the focused size, and add padding so the enlarged item never crowds or overlaps its neighbors. [Focus and selection › tvOS] "you need to supply assets for the larger, focused size to ensure they always look sharp"
- **T10** Never move focus without the person's input. If the focused item disappears and the input isn't directional, hide the indicator instead of jumping it elsewhere. [Focus and selection › Best practices] "Avoid changing focus without people’s interaction."
- **T11** Full-screen content shows no focus, and gestures act on the content. [Focus and selection › tvOS] "When an item displays in full screen, it doesn’t show focus"
- **T12** Remote semantics:
  - swipe moves focus with inertia ("starts fast and then slows down")
  - press activates an item or goes one level deeper
  - Back opens the parent screen, which isn't necessarily the previous one
  - Play/Pause controls playback
  - there is no pointer (Focus and selection › tvOS)

  [Remotes › Best practices] "always moving focus in the same direction as the gesture."
- **T13** Prefer the system focus effects. Build custom ones only when absolutely necessary. [Focus and selection › Best practices] "Consider creating custom focus effects only if it’s absolutely necessary."
- **T14** In tvOS 26, focused buttons and image views take on Liquid Glass (Apple TV 4K 2nd generation and later). Navigation and Top Shelf use Liquid Glass too. [Materials › tvOS] "Certain interface elements, like image views and buttons, adopt Liquid Glass when they gain focus."

**Parallax, layered images, light**

- **T15** Parallax: on focus, an item elevates, sways gently, and its surface shines. After a period of inactivity, unfocused content dims and the focused item expands; no timing is published. Parallax requires layered images. [Images › tvOS › Parallax effect] "gently swaying it while applying illumination that makes the element’s surface appear to shine"
- **T16** Parallax follows the finger on the remote's touch surface. The tvOS app icon is an 800×480 px rounded rectangle with 2–5 layers ("Layered (Parallax)"). [App icons › Layer design; Specifications] "elevates to the foreground in response to someone’s finger movement on their remote"
- **T17** A layered image has 2–5 layers: foreground for prominent elements and text, middle for secondary content and shadows, and an opaque background. Keep the depth subtle. [Images › tvOS › Layered images] "Parallax is designed to be almost unnoticeable. Excessive 3D effects can appear unrealistic and jarring."
- **T18** Safe zone: layers get cropped as the image scales and moves, and foreground layers are cropped more than background ones (App icons › tvOS). Keep text and essential content inside the safe zone. [Images › tvOS › Layered images] "When focused, content on some layers may be cropped as the layered image scales and moves."
- **T19** The system draws specular highlights and shadows. Don't bake highlights, shadows, bevels, blurs or glows into the artwork, and don't pre-mask its corners. [App icons › Icon shape] "Providing layers with pre-defined masking negatively impacts specular highlight effects and makes edges look jagged."

**Lockups**

- **T20** A lockup is a content view plus a header and a footer, and all three expand and contract together on focus. Posters can be any size that suits their content, and their title and subtitle stay hidden until the poster is focused. [Lockups › Posters] "an optional title and subtitle, which are hidden until the poster comes into focus."
- **T21** Other lockup types:
  - cards, for ratings and reviews
  - monograms, a circular photo plus a name; prefer photos to initials
  - caption buttons, which tilt with the swipe: left/right in a row, up/down in a column, both ways in a grid

  [Lockups › Caption buttons] "caption buttons tilt with the motion that they swipe"
- **T22** Use one lockup size per row or group, with enough room for the focused one to grow. [Lockups › Best practices] "A focused lockup expands in size, so leave enough room between lockups to avoid overlapping or displacing other lockups."

**Shelves, grids, scrolling**

- **T23** Use only the standard horizontal rows and grids, and avoid custom layouts. [Collections › Best practices] "Use the standard row or grid layout whenever possible."
- **T24** Grid: the unfocused item width for 2, 3, 4, 5, 6, 7, 8 or 9 columns is 860, 560, 410, 320, 260, 217, 184 or 160 pt. Horizontal gaps are 40 pt and vertical gaps at least 100 pt. Titled rows need extra space above and below the title. Derived: N·w + (N−1)·40 ≈ 1760 = 1920 − 2·80. [Layout › tvOS › Grids] "Be sure to use appropriate spacing between unfocused rows and columns to prevent overlap when an item comes into focus."
- **T25** Rows show partly visible items at the edge. Apple's grid art shows extra items "partially visible on the right side and bottom edge" (alt text), and partially visible items should be symmetrical. [Layout › tvOS › Grids] "keep partially hidden offscreen content the same width on each side of the screen."
- **T26** A row must be full, with at least one screen-width of items, and should have at least one label. [Top Shelf › Sectioned content row] "load enough images in a sectioned content row to span the full width of the screen."
- **T27** Focus scale and overscan. Sizes in pt as actual / focused (safe zone) / unfocused:

  | Aspect | Actual | Focused | Unfocused |
  |---|---|---|---|
  | Poster 2:3 | 404×608 | 380×570 | 333×570 (as published) |
  | Square | 608×608 | 570×570 | 500×500 |
  | 16:9 | 908×512 | 852×479 | 782×440 |
  | Scrolling inset banner | 1940×692 | 1740×620 | 1740×560 |

  Derived: focused is about 1.09–1.14× the unfocused size, and the actual size is about 6–7% larger than the focused size (about 11–12% for banners), which leaves room for parallax overscan. [Top Shelf › Sectioned content row · diagram alt text] "the middle rectangle represents the visible or safe zone, and the innermost rectangle represents the unfocused size"
- **T28** Mixed aspect ratios in one row are scaled up to the tallest item: a 16:9 image becomes 500 high next to posters or squares. [Top Shelf › Sectioned content row] "images will automatically scale up to match the height of the tallest image if necessary."
- **T29** There are no scroll indicators; the view scrolls itself to keep the focused item visible. Focused list rows highlight, grow slightly and may round their corners, so don't add your own corner masks (Lists and tables › tvOS). [Scroll views › tvOS] "the system automatically scrolls the interface to keep focused items visible."

**Hero (Top Shelf styles)**

- **T30** Full-screen carousel: previews play full screen and people swipe between featured items. The "carousel actions" style has a title, an optional subtitle, Play and More Info. The "carousel details" style adds a summary, cast and metadata, with the title near the top and an attribution line above it. [Top Shelf › Best practices; Carousel actions; Carousel details] "A primary button intended to begin playback and a More Info button"
- **T31** Hero content should be new, featured, personalized or resumable. Show no ads or prices, and nothing already watched. Prefer dynamic, layered imagery. [Top Shelf › Best practices] "avoid promoting content that people have already purchased, rented, or watched."
- **T32** Scrolling inset banner: 3–8 near-full-width images (sizes in T27) that advance automatically on a timer until one is focused, then loop. Text goes inside the artwork and into its accessibility label. [Top Shelf › Scrolling inset banner] "Apple TV automatically scrolls through these banners on a preset timer until people bring one into focus."
- **T33** The static fallback image is 2320×720 pt. The system flips and blurs it to fill the 1920-px 16:9 width, and it must not look interactive. [Top Shelf › Best practices] "tvOS flips and blurs the image, ensuring that it fits into a width of 1920 pixels"

**Tab bar, typography, safe area, sizes**

- **T34** The tab bar sits at the top:
  - fixed at 68 pt tall, with its top edge 46 pt below the top of the screen
  - translucent, with only the selected tab opaque, and that tab gets a shadow when the bar has focus
  - scrolls away on tabs with a single main view, and stays pinned over split views
  - Menu always returns focus to it
  - Search is a dedicated tab (Searching)

  [Tab bars › tvOS] "The height of a tab bar is 68 points, and its top edge is 46 points"
- **T35** Text: the default size is 29 pt and the minimum 23 pt. The system font is SF Pro, and New York is allowed. Avoid Ultralight, Thin and Light weights. [Typography › Ensuring legibility] "| tvOS | 29 pt | 23 pt |"
- **T36** tvOS text styles, as size/leading in pt: Title 1 76/96, Title 2 57/66, Title 3 48/56, Headline 38/46, Subtitle 1 38/46, Callout 31/38, Body 29/36, Caption 1 25/32, Caption 2 23/30. All are Medium weight except Subtitle 1 (Regular), and the emphasized weight is Bold. [Typography › Specifications › tvOS built-in text styles] "| Body | Medium | 29 | 36 | Bold |"
- **T37** Safe area: inset primary content 60 pt at the top and bottom and 80 pt at the sides. Leave padding between focusable elements. [Layout › tvOS] "Inset primary content 60 points from the top and bottom of the screen, and 80 points from the sides."
- **T38** Controls are 66×66 pt by default, with a 56×56 pt minimum. [Accessibility › Mobility] "| tvOS | 66x66 pt | 56x56 pt |"

**Motion, timing, playback**

- **T39** There are no tvOS-specific motion rules. In general, motion should be purposeful, brief and cancelable. The only published timings are:
  - wait at least 0.5 s before pausing playback for an interactive overlay
  - show a black loading screen with a centered spinner only if loading takes more than 2 s
  - banners advance on a "preset timer" whose length isn't given

  No duration or easing curve is published for the focus animation. [Playing video › tvOS] "implement a minimum delay of 0.5 seconds to pause playing media, and display an interactive overlay."
- **T40** Playback: use the system player, which on tvOS has transport controls and Info, Episodes and Chapters tabs. Keep logos and overlays small and translucent, in SDR. When playback ends, show that title's detail view with a Resume option. [Playing video › Exiting playback] "display a detail view for the content the viewer was just watching and include an option to resume playback."

## 2. iPhone Duo constraints

- **D1** It's still an iPhone, so iOS patterns apply. Standard components in a resizable layout adapt to the device's poses automatically. [Designing for iPhone Duo › intro] "you’re still designing for iPhone"
- **D2** Build one layout that grows, not one per pose: compact width on the outer display and regular width on the inner one. [… › Device poses] "Don’t reinvent your app when it resizes; allow the existing layout to expand based on the available space instead."
- **D3** Keep the same functionality and element state on both displays. The inner display may show one extra level of hierarchy, as Mail does with the list and the message side by side. [… › Best practices] "Keep functionality and the state of elements the same between displays."
- **D4** Build to resize with size classes, layout margins and safe-area insets. [… › Best practices] "Avoid fixed widths and display-specific dependencies."
- **D5** Bars move to the side on the outer display and in landscape on the inner display. Only the inner display in portrait keeps standard horizontal bars. [… › Vertical controls] "The exception is the inner display in portrait, which has enough vertical space to keep standard horizontal bars."
- **D6** The side column holds the Dynamic Island, status bar, toolbar and tab bar, from top to bottom; Apple's outer-display diagram shows it on the trailing edge (alt text). It's aligned to the hardware and stays on the same side in right-to-left languages. [… › Vertical controls] "the Dynamic Island, the status bar, the toolbar (including navigation buttons), and the tab bar"
- **D7** Don't override the default bar placement; vertical controls are a core Duo pattern. [… › Vertical controls] "In general, don’t override the default bar placement."
- **D8** The content area is asymmetric. Use safe areas so side controls never cover content, including another app's controls on the opposite edge in Split View. [… › Vertical controls] "Because controls sit along one edge, the space for content is asymmetrical."
- **D9** Views without bars may span the full width if they are immersive, don't scroll, and don't conflict with the Dynamic Island or status bar (Calculator does this). Alternatively, a background or header can span the full width while scrolling content stays inset. [… › Vertical controls] "letting a background image or header span the full width while scrollable content stays inset."
- **D10** Reserved regions:
  - outer camera: always present, and expands into the Dynamic Island
  - inner camera: present only while active, and the UI moves aside
  - folding region: present only when the device is partially open, and excludes the center

  [… › Dynamic layouts › Reserved regions] "When the device is partially open, the folding region divides the inner display into multiple usable regions"
- **D11** When the device folds, prefer containers that adapt on their own, use an even number of grid columns, and use `ReservedRegion` to keep important elements off the center. Alerts, menus and sheets already move away from the fold. [… › Reserved regions] "In a grid-style layout, prefer an even number of columns so content divides cleanly."
- **D12** Don't rearrange the layout dramatically when the device folds. [… › Reserved regions] "Move only what’s necessary to keep elements visible and easy to tap."
- **D13** A split view expands on the inner display and collapses to one pane on the outer. Arrangement views (split or overlay) reorganize two views by size, orientation and fold. In an overlay, the secondary view fills the area and a smaller, bottom-aligned primary view sits on top (alt text). [… › Arrangement views] "When the display is partially folded, the views move to occupy each side"
- **D14** Keep navigation containers (tab views, navigation split views) outside arrangement views. [… › Arrangement views] "Keep navigation outside of arrangement views."
- **D15** In the side column, put Back or Close at the top, then prominent actions such as Done. Keep item groups intact and let the system space them rather than adding spacing by hand. [… › Vertical controls] "Reserve the top of the vertical axis for primary navigation controls, like Back or Close"
- **D16** Give every bar item both a title and a symbol, and keep text-only buttons to a minimum. [… › Vertical controls] "Labels that include text stay in a horizontal bar, so prefer a symbol wherever one works."
- **D17** When space runs out, navigation-focused views keep the tab bar and move toolbar items to overflow, which is the default. Task-focused views minimize the tab bar. Use the system overflow menu. [… › Vertical controls] "In navigation-focused experiences, move toolbar items into the overflow menu so the tab bar and primary destinations remain accessible."
- **D18** Keep the relative positions of controls stable across poses, and keep controls for a pane with that pane. [… › Vertical controls] "keep controls’ relative positions as similar as possible so people don’t have to relearn where actions live"

**2b. Other iOS rules the translation must follow (not Duo-specific)**

- **I1** On iPhone the viewing distance is 1–2 ft. Input is Multi-Touch plus the gyroscope and accelerometer, and people expect to swipe to go back. [Designing for iOS › intro: Ergonomics] "their viewing distance tends to be no more than a foot or two."
- **I2** iOS has no focus system, so any focus look on iPhone is a custom effect. [Focus and selection › Platform considerations] "Not supported in iOS or watchOS."
- **I3** iOS text: the default size is 17 pt and the minimum 11 pt. The default (Large) styles are Large Title 34, Title 1 28, Title 2 22, Title 3 20, Headline 17, Body 17, Callout 16, Subhead 15, Footnote 13, Caption 1 12 and Caption 2 11. Support Dynamic Type. [Typography › Ensuring legibility; Specifications] "| iOS, iPadOS | 17 pt | 11 pt |"
- **I4** Touch targets are 44×44 pt (minimum 28×28). Leave about 12 pt of padding around bezeled controls and about 24 pt around unbezeled ones. [Accessibility › Mobility] "add about 12 points of padding around elements that include a bezel"
- **I5** In a collection, tap selects, touch-and-hold edits (context menu), and swipe scrolls. Avoid changing the layout while people interact with it. [Collections › Best practices] "people can tap to select, touch and hold to edit, and swipe to scroll."
- **I6** Liquid Glass belongs to bars and controls, not content. Over media, use the clear variant with a 35% dark dimming layer if the content is bright. [Materials › Liquid Glass] "Don’t use Liquid Glass in the content layer."
- **I7** Full-bleed art runs under bars. Where bars cover the art, flip and blur it with a background extension effect. Scale art to fill the area and never change its aspect ratio. [Layout › Visual hierarchy; Adaptability] "use a background extension effect to flip and blur the image, mirroring it beneath adjacent components"
- **I8** The iOS tab bar floats at the bottom on Liquid Glass and must stay visible. It can minimize on scroll when it has an accessory such as a MiniPlayer, and Search can be a dedicated tab at the trailing end. [Tab bars › Best practices; iOS] "Make sure the tab bar is visible when people navigate to different sections of your app."
- **I9** With Reduce Motion on, cut zooming, scaling and peripheral motion. Tighten springs, track gestures directly, don't animate depth changes, and prefer fades. [Accessibility › Cognitive] "reducing automatic and repetitive animations, including zooming, scaling, and peripheral motion."
- **I10** Don't autoplay without controls to start and stop it. Respect the system autoplay setting, and minimize interface elements that run on a timer. [Accessibility › Cognitive] "Avoid autoplaying audio and video content without also providing controls to start and stop it."
- **I11** Keep the same idiom when the size class changes: the amount of visible content may change, but the functionality may not. [Layout › Size classes] "keep the layout recognizable and familiar to the platform even when resizing."
- **I12** Add little motion to frequent interactions, and let people cancel motion. [Motion › Providing feedback] "In apps, generally avoid adding motion to UI interactions that occur frequently."
- **I13** Show partial content at an edge to signal that more is available. [Scroll views › Best practices] "displaying partial content at the edge of a view indicates that there’s more content in that direction."
- **I14** Don't offer an in-app appearance setting. Keep contrast at 4.5:1 or more, and aim for 7:1 with custom colors (Dark Mode › Dark Mode colors). [Dark Mode › Best practices] "Avoid offering an app-specific appearance setting."

## 3. Translating tvOS to touch on the unfolded Duo

[INFERENCE] marks anything not stated in the docs.

- **S1. One design that grows, not a separate mode** (D2, D3, D12, I11)
  - The tvOS look (hero, shelves, emphasized card, parallax) is the app's base design on both displays.
  - Unfolding makes it bigger: a larger hero, more cards per row, more room for parallax, and one extra level of hierarchy.
  - Scroll positions, the hero page, the emphasized card and playback carry over between folded and unfolded.
  - [INFERENCE] A UI that exists only when unfolded would go against D2 and I11.
- **S2. Native controls, tvOS content** (T1, T14, D5, D7, D15, I6, I11)
  - Controls stay standard iOS/Duo: system `TabView`, toolbars, the side column with Back at its top, Liquid Glass.
  - The tvOS language lives in the content: full-bleed art, shelves, lockups, the emphasized card, parallax.
  - Don't put Liquid Glass on cards, even though tvOS 26 applies it to focused items.
  - [INFERENCE] The split itself; each rule it relies on is documented.
- **S3. Scaling** (T2, T24, T33, T35, T37, I1, I3, D4) [INFERENCE]
  - Layout sizes scale by s = usable width ÷ 1920 pt. The 1920 pt tvOS canvas width is inferred from T33 and the T24 arithmetic.
  - Portrait: s ≈ 669/1920 ≈ 0.35. Landscape: s ≤ 951/1920 ≈ 0.50, less the side-column inset (read it from the safe-area insets; its width isn't documented).
  - Apply s to margins, gutters, card sizes, row gaps and parallax travel, so each shelf keeps the same proportions as on a TV.
  - Don't apply s to text or touch targets. Scaling Body 29 pt by s gives about 10 pt, below the iOS minimum of 11 pt. The viewing-distance difference (8 ft vs 1–2 ft) is already built into each platform's sizes (29/23 vs 17/11).
- **S4. Type mapping, role for role, with Dynamic Type on** (T35, T36, I3) [INFERENCE: the mapping and the weights]

  | tvOS style | iOS style |
  |---|---|
  | Title 1 76 | Large Title 34 |
  | Title 2 57 | Title 1 28 |
  | Title 3 48 | Title 2 22 |
  | Headline 38 | Title 3 20 |
  | Callout 31 | Callout 16 |
  | Body 29 | Body 17 |
  | Caption 1 25 | Footnote 13 |
  | Caption 2 23 | Caption 1 12 (never below 11) |

  - tvOS styles are Medium weight, so Medium on titles and body echoes the TV look; avoid light weights.
  - At accessibility text sizes, show fewer cards per row and always show captions (Typography › Supporting Dynamic Type).
- **S5. Spacing derived from S3** (T22, T24, T37, D4) [INFERENCE: scaled values]
  - Portrait:
    - side inset 80·s ≈ 28 pt (take the larger of this and the system margin plus safe area)
    - top/bottom 60·s ≈ 21 pt
    - gutter 40·s ≈ 14 pt
    - row gap at least 100·s ≈ 35 pt, plus a slot for the caption
  - Landscape at the full 951 pt: about 40 pt side inset, 30 pt top/bottom, 20 pt gutters and 50 pt row gaps.
  - Compute these from the live width on every layout pass.
- **S6. Cards per row: w = (W − 2·80s − (N−1)·40s) ÷ N** (T22, T24, T26, T28, D2, D11) [INFERENCE: the values of N]
  - Inner portrait: posters with N=4 are about 143×214 pt; 16:9 cards with N=2 are about 300×169 pt.
  - Inner landscape at 951 pt: posters with N=6 are about 129×193 pt; 16:9 cards with N=4 are about 203×114 pt. Both get smaller once the side-column inset is subtracted.
  - Use an even N on the inner display.
  - The outer display and Split View show the same rows with fewer cards.
  - Use one aspect ratio per row; in a mixed row, match the tallest card. Each row has a title and at least one screen-width of items.
- **S7. Pseudo-focus** (T3, T6, T10, T13, I2, I5) [INFERENCE]
  - Exactly one card on screen is emphasized, in the row the person last scrolled or touched; every other card renders unfocused.
  - The emphasis moves only because the person scrolled, never programmatically. When that row scrolls off screen, clear the emphasis instead of moving it to another row (T10).
  - A tap opens any card, emphasized or not. Never require one tap to focus and a second to open.
  - When the screen first appears, the hero is the emphasized element.
- **S8. Position the emphasis at a leading keyline, not the center** (T12, T24, T25, D10, D11, D12) [INFERENCE]
  - Rows snap so a card rests on the leading-inset keyline, which matches tvOS rows starting at the safe margin. That card is the emphasized one.
  - With the margin at twice the gutter, the partly visible cards are equal on both sides mid-row (about 14 pt in portrait), which satisfies T25 automatically. At rest only the trailing card shows, as in Apple's grid art.
  - With an even N, the center of the inner display falls in a gutter, which is where the fold sits when the device is partially open.
  - Center snapping suits only single-page pagers (hero, inset banner).
  - The owner's "card nearest the center" idea needs an odd N, which puts the emphasized card on the fold when the device is partially open. The fold's direction in each orientation isn't documented, so check it in Device Hub.
  - SwiftUI: view-aligned scroll targets plus horizontal content margins.
- **S9. The emphasized look** (T4, T8, T9, T20, T22, T27, I5) [INFERENCE: numbers derived from T27]
  - Scale 1.14× for posters and squares and 1.09× for 16:9, anchored at the center.
  - Never let the growth on one side exceed the gutter. A portrait poster grows 10 pt per side against a 14 pt gutter, and a 300 pt 16:9 card grows 13.5 pt per side.
  - Add a larger, softer shadow so the card reads as "farther away", and brighten it slightly.
  - The caption fades in inside a reserved slot, so the row height never jumps. A poster grows about 15 pt vertically, which leaves about 20 pt for one line at Footnote or Caption 1 size.
  - Header and footer scale with the artwork.
  - Pressed (tvOS "highlighted"): back to unfocused size with a slightly deeper shadow.
  - Unavailable, for example not yet released: no shadow, dimmed art, low-contrast text.
- **S10. Motion that tracks the finger** (T15, T39, I9, I12) [INFERENCE: durations, haptics, idle timing]
  - Interpolate scale, shadow and caption opacity continuously from each card's distance to the keyline, driven by scroll position with no timers, so the emphasis follows the drag and lands with the snap.
  - Use a short spring with little bounce (about 0.25–0.35 s; no value is documented) only for settling and tap feedback, and keep it interruptible.
  - Optional: a light selection haptic when a new card settles on the keyline.
  - Optional tvOS idle cue: after a few still seconds, slightly dim the other cards in the active row. Dim only, with no extra scaling.
- **S11. Tilt with the swipe**, the touch version of caption-button tilt (T12, T17, T21, I5, I9) [INFERENCE: the angle]
  - While a row scrolls, rotate the emphasized card about its vertical axis toward the drag direction, in proportion to velocity, and return it flat as it settles. Keep the angle within about 3–4°; T17 calls for parallax that is almost unnoticeable.
  - Never use touch-and-hold for tilt, because it's reserved for context menus.
  - Never use drag-to-tilt on scrolling rows, because it collides with scrolling.
- **S12. Parallax layers and travel** (T9, T15, T17, T18, T27, T32) [INFERENCE: applying the Top Shelf ratios]
  - Build the hero and featured art from 2–3 layers: an opaque background plate, an optional shadow layer, and the foreground title or logo on top. The foreground moves more than the background.
  - Keep all layer movement and scaling inside the overscan that Top Shelf builds in. That is about 3% per side for row items ((404 − 380)/2 = 12 pt of 380) and about 6% for banners ((1940 − 1740)/2 = 100 of 1740). On a 143 pt poster, that's about 4–5 pt.
  - Ship art at the overscan size, at @2x and @3x (Images › Resolution).
  - Keep text and faces inside the safe zone.
- **S13. Specular sheen** (T7, T14, T15, T19, I6) [INFERENCE]
  - Imitate the tvOS illumination with a soft, low-opacity highlight gradient over the emphasized card, drawn in code and moving opposite to the tilt.
  - Never bake it into the artwork. Clip it to the card's rounded corners and don't pre-mask the art.
  - Don't use Liquid Glass for this; the cards are content.
- **S14. Finger-driven parallax where nothing scrolls** (T16, T17, I1, I9) [INFERENCE]
  - On static artwork, such as the detail-page key art and poster or the now-playing art, map the touch position to tilt and layer offset, and spring back on release. This is the literal equivalent of the remote's touch surface.
  - Optional gyroscope parallax for the hero only, with a tiny amplitude. Turn it off when Reduce Motion is on.
- **S15. Hero A: full-bleed carousel, the default** (T30, T31, T33, D9, D10, D13, I7, I13) [INFERENCE: heights, use of the arrangement view]
  - 3–8 featured titles in a paged hero.
  - Landscape: 16:9 art at full width, about 951×535 pt. Extend it under the side column with the background extension effect, the same way tvOS flips and blurs Top Shelf art. The remaining ~134 pt shows the first shelf's title and the tops of its cards.
  - Portrait: about 65–75% of the height (669×620–710 pt). Use square or portrait key art, or an aspect-fill crop around a focal point; never letterbox or stretch. The first shelf shows below it.
  - Build it as an overlay arrangement view. The secondary view is the art or preview. The primary view is a bottom-aligned info block: attribution line, title or logo, one line of metadata, Play/Resume and More Info. When the device is partially folded, the system puts the two on either side of the fold, like a TV screen above a remote.
  - "Carousel details" variant: add a 2–3-line summary and the cast, with the title near the top.
- **S16. Hero B: inset banner, for a Featured row** (T25, T32) [INFERENCE: scaled sizes]
  - 3–8 pages at the banner's 1740:560 ratio (about 3.1:1): about 606×195 pt in portrait and 862×277 pt in landscape, roughly 90% of the width.
  - Snap pages to the center, with equal slivers of the neighbors visible on each side.
  - Text goes inside the artwork and into its accessibility label.
  - Put a page control centered at the bottom, with no more than about 10 dots (Page controls › Best practices).
- **S17. Hero behavior** (T8, T11, T30, T31, T32, I4, I6, I9, I10) [INFERENCE: the interval, button styling]
  - Auto-advance only while the hero is visible and untouched, and stop for good on the first touch or drag, the way the tvOS banner stops once one is focused. Never auto-advance with Reduce Motion or VoiceOver on. The interval isn't documented; about 6–8 s is a reasonable start.
  - Swiping pages the hero, so the hero gets no card-style emphasis.
  - Preview video is muted, plays only if the system autoplay setting allows it, and has visible pause and mute controls.
  - Play resumes an in-progress title automatically without asking (Playing video › Integrating with the TV app).
  - Show nothing already watched, and no ads or prices.
  - The hero buttons are controls in the content, not Liquid Glass. Play is an opaque white capsule with a black label, like a focused tvOS button. More Info uses a translucent standard material, like an unfocused tvOS button. Both are at least 44 pt tall and about 12 pt apart.
  - Add a bottom scrim so the text has enough contrast.
- **S18. Tabs** (T34, D5, D6, D7, D15, D17, I8) [INFERENCE: where the bar sits in inner portrait]
  - The tvOS top tabs become the system `TabView`: single-word labels, filled SF Symbols, Search as a dedicated trailing tab, and few enough tabs that no More tab appears.
  - Keep the bar monochrome over colorful art (Tab bars › Best practices).
  - Let the system place it: a standard horizontal bar in inner portrait, and the side column, with Back/Close at its top, in inner landscape and on the outer display.
  - Don't build a custom top bar; that overrides the default placement (D7). If inner portrait already puts the bar near the top, as iPadOS does, you get the tvOS look for free; check this in Device Hub.
  - tvOS lets the bar scroll away; on iPhone keep it visible. In portrait, minimize it on scroll only if it has an accessory, such as a Continue Watching or Now Playing accessory. In landscape the column costs no height, so leave it as is.
- **S19. Content under the side column** (D6, D8, D9, I7, T33)
  - Hero art and horizontally scrolling shelves run beneath the Liquid Glass side column to the screen edge.
  - Resting insets, titles and buttons stay inside the safe area, away from the end of the column that holds the Dynamic Island and status bar.
- **S20. Folding** (D10, D11, D12, D13) [INFERENCE: what to move]
  - Fully open, use the normal layout.
  - Partially open, use `ReservedRegion` to keep the hero info block, the emphasized card's caption and the row titles off the folding region.
  - An even N puts a gutter on the fold, and the overlay arrangement splits the hero art from its info.
  - Move nothing else, and test every pose.
- **S21. An extra level of hierarchy when unfolded** (D3, D13, D14, T20, T21) [INFERENCE: applying the Mail pattern]
  - In landscape, tapping a card can open its detail page as the secondary side of a split arrangement next to the shelves, as Mail does. When folded or in portrait, push the detail page instead.
  - Keep `NavigationStack` and `TabView` outside the arrangement view.
  - The detail page uses tvOS lockups: monograms for the cast (photos rather than initials), cards for ratings and reviews, posters for related titles, and an episode list whose rows highlight.
- **S22. Full screen and playback** (T11, T39, T40, D9) [INFERENCE: how the iOS player maps]
  - Trailers and playback use the system player full screen, with no bars and no emphasis effects; gestures act on the content.
  - The system chooses aspect-fill or aspect-fit. Never pad the video (Playing video › Best practices).
  - Info, Episodes and Chapters tabs are a tvOS/visionOS player feature, so on iPhone that content goes on the detail page.
  - Show a black screen with a centered spinner only if loading takes more than 2 s.
  - When playback ends, show the title's detail view with Resume.
  - Keep overlays small and translucent.
- **S23. Remote-to-touch mapping** (T6, T12, D15, I1, I5) [INFERENCE]

  | Remote | Touch |
  |---|---|
  | Swipe | Scroll; system inertia already starts fast and then slows, and the emphasis moves in the direction of the swipe |
  | Press | Tap, to open or play |
  | Back | Go to the parent screen, using Back at the top of the side column or an edge swipe |
  | Play/Pause | The hero's Play/Resume button and the player controls |

  - Touch-and-hold opens a context menu (Add to Up Next, Mark as Watched).
  - Tapping the selected tab to return to the top would mirror tvOS's Menu button returning to the tab bar, but that's an iOS convention these pages don't cover.
- **S24. Color, dark appearance and accessibility** (T4, T5, T32, D3, I9, I14) [INFERENCE: the Reduce Motion substitutes]
  - Use one permanent dark appearance for the whole app on both displays (the immersive-media exception). It is not a look that appears only when unfolded, and not an in-app toggle.
  - Use a limited brand palette, and never show emphasis with color alone.
  - Put scrims under text on artwork, with contrast of at least 4.5:1 and 7:1 for small custom text.
  - With Reduce Motion on, drop scaling, tilt, parallax and auto-advance. The emphasis becomes a static shadow plus the caption, and hero changes become crossfades.
  - Every card's accessibility label includes its title, even while the caption is hidden.

## 4. Gaps and caveats

- The pages give no duration or easing curve for the focus animation and no explicit focus scale. The scale values here are derived from the Top Shelf image sizes (T27).
- The Top Shelf poster's unfocused size is published as 333×570 pt. That isn't 2:3, and it contradicts the same page's example that "a 16:9 image scales to 500 pixels high". It is probably 333×500; check Apple's Top Shelf templates before relying on it.
- The tvOS canvas width of 1920 pt is inferred from T33 and the T24 grid arithmetic. The tvOS pages never state the screen size.
- The iPhone Duo page gives no point dimensions and no side-column width. The 669×951 pt figure comes from the owner's spec, so read the safe-area insets at runtime.
- The text doesn't say whether the inner-portrait horizontal tab bar sits at the top or the bottom. The fold's direction in each orientation is also not stated; the images show it splitting leading and trailing panes. Check both in Device Hub.
- Focus, lockups, Top Shelf and remotes are not supported in iOS. Everything in section 3 is a custom SwiftUI imitation, and T13 asks for custom focus effects only when they're truly necessary.
- Details marked "alt text" come from the image descriptions in Apple's JSON exports, not from the body text.
- Notes on SwiftUI APIs (view-aligned scrolling, content margins) are implementation hints, not HIG content.
