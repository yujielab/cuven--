# Cuven max — HIG digest: components & patterns (iOS 26 · dark · iPhone + iPhone Duo)

Each rule: what to do in SwiftUI — [HIG page › section] "exact quote". Later sections cite rules by number. Rules 98–112 (sign-in and data entry) come from Managing accounts, Text fields and Entering data.

## Platform fundamentals (1–2)

1. **Restraint first** — show only the controls a screen's main task needs; keep secondary details and actions one tap away (`Menu`, `.contextMenu`, detail page). [Designing for iOS › Best practices] "Help people concentrate on primary tasks and content by limiting the number of onscreen controls"
2. **Adapt, don't hard-code** — use text styles (`.font(.headline)`), not fixed sizes, so Dynamic Type scales; support rotation; put frequent controls in the middle/bottom; never break swipe-back. [Designing for iOS › Best practices] "Adapt seamlessly to appearance changes — like device orientation, Dark Mode, and Dynamic Type"

## Tab bars (3–10)

3. **Tabs navigate, never act** — `TabView { Tab(…) }` holds sections only; Play, Share and Add live in toolbars or content. [Tab bars › Best practices] "Use a tab bar to support navigation, not to provide actions."
4. **Keep the tab bar on screen** — don't hide it on pushed screens (detail, year, cast, folder); only modals (player, sheets) may cover it. [Tab bars › Best practices] "If you hide the tab bar, people can forget which area of the app they’re in."
5. **Few tabs, weighed by how often people need them** — fewer tabs are easier to use; the HIG's only number (from its iPadOS tab-customization guidance) is a default of ≤ 5 tabs, to keep compact ↔ regular continuity, which matters for Duo fold/unfold. [Tab bars › iPadOS] "aim for a default list of five or fewer to preserve continuity between compact and regular view sizes"
6. **No overflow "More" tab** — check that every tab stays visible at every size and orientation, including the Duo's folded side column. [Tab bars › Best practices] "The More tab makes it harder for people to reach and notice content on tabs that are hidden"
7. **Never disable or hide a tab** — if a section is empty, explain why in place (`ContentUnavailableView`). [Tab bars › Best practices] "Don’t disable or hide tab bar buttons, even when their content is unavailable."
8. **One-word labels + filled SF Symbols** — `Tab("Library", systemImage: "square.stack.fill", value: …)`; let the system place icon and label (stacked in compact, side by side in regular). [Tab bars › Best practices] "Prefer filled symbols or icons for consistency with the platform."
9. **Monochrome bar over colorful art** — keep a monochrome tint (`.tint(.white)`), or an accent clearly distinct from the posters. [Tab bars › Best practices] "prefer a monochromatic appearance for tab bars, or choose an accent color with sufficient visual differentiation"
10. **Tab-bar minimizing** — the HIG describes `.tabBarMinimizeBehavior(.onScrollDown)` for bars with an attached accessory (`.tabViewBottomAccessory`, e.g., a mini player); people restore the bar by tapping a tab or scrolling to the top. [Tab bars › iOS] "you can choose to minimize the tab bar and move the accessory inline with it when a person scrolls down"

## Toolbars & navigation bars (11–17)

11. **Only essentials in the bar** — Back plus the few items the screen truly needs, in at most 3 groups; extra actions go in one More `Menu`, added only if really needed. [Toolbars › iOS] "Prioritize only the most important items for inclusion in the main toolbar area."
12. **Short titles, never the app name** — under 15 characters; don't title Home "Cuven max"; leave the title empty when the content already says it (detail hero) and show it inline once that scrolls away. [Toolbars › Titles] "Don’t title windows with your app name."
13. **Large titles on top-level screens** — `.navigationBarTitleDisplayMode(.large)` for Library, the Search landing page and Settings; the title collapses to inline as people scroll. [Toolbars › iOS] "Use a large title to help people stay oriented as they navigate and scroll."
14. **Standard Back and Close** — use the system back button; modals close with the standard xmark (`Button(role: .close)` on iOS 26), never a "Back" or "Close" text label. [Toolbars › Navigation] "Prefer the standard symbols for each, and don’t use a text label that says Back or Close."
15. **Borderless symbols, not text** — plain SF Symbols (`ellipsis`, not `ellipsis.circle` or other outlined circles); use text only for actions a symbol can't express (Edit). [Toolbars › Actions] "Borders (like outlined circle symbols) aren’t necessary because the section provides a visible container"
16. **One prominent primary action, trailing** — Done/Save as `ToolbarItem(placement: .confirmationAction)` with the `.prominent` treatment (`.buttonStyle(.glassProminent)`); never two. [Toolbars › Actions] "Only specify one primary action, and put it on the trailing side of the toolbar."
17. **No custom bar chrome** — no toolbar backgrounds or tinted controls; let the content layer color the glass; prefer standard components (custom ones must be concentric with the bar's corners). [Toolbars › Best practices] "Reduce the use of toolbar backgrounds and tinted controls."

## Sidebars & wide layouts, e.g. Duo unfolded (18–19)

18. **Tab bar first; adaptive sidebar only if needed** — if an unfolded layout needs more navigation, use `.tabViewStyle(.sidebarAdaptable)`, which adapts to rotation and resizing, not a hand-built sidebar. [Sidebars › iOS, iPadOS] "Consider using a tab bar first. A tab bar provides more space to feature content"
19. **Let artwork run under floating glass** — `.backgroundExtensionEffect()` (or horizontally scrolling content) so hero art continues beneath a floating sidebar. [Sidebars › Best practices] "A background extension effect mirrors adjacent content to give the impression of stretching it under the sidebar."

## Collections: poster rows & grids (20–23)

20. **Standard rows and grids only** — `ScrollView(.horizontal) { LazyHStack }` rows and `LazyVGrid` grids; no novelty layouts; text-heavy content goes in lists. [Collections › Best practices] "Use the standard row or grid layout whenever possible."
21. **Easy to pick** — pad artwork so press effects never overlap neighbors; tap opens, touch-and-hold shows `.contextMenu`, swipe scrolls. [Collections › Best practices] "Use adequate padding around images to keep focus or hover effects easy to see and prevent content from overlapping."
22. **Animate data changes** — wrap inserts, removals and reorders (Up Next, watchlist) in `withAnimation`. [Collections › Best practices] "Consider using animations to provide feedback when people insert, delete, or reorder items."
23. **No layout shifts under the user** — don't reorder or reflow rows on a background refresh while someone is browsing; reflow only on explicit actions (e.g., unfolding the Duo), and keep the change easy to follow. [Collections › iOS, iPadOS] "avoid changing the layout while people are viewing and interacting with it"

## Scroll views & page controls (24–28)

24. **Let the next poster peek** — size cards with `containerRelativeFrame` and `.contentMargins(.horizontal, …, for: .scrollContent)` so part of the next poster shows at the trailing edge; snap with `.scrollTargetBehavior(.viewAligned)`. [Scroll views › Best practices] "displaying partial content at the edge of a view indicates that there’s more content in that direction"
25. **Never nest same-axis scrolling** — horizontal rows inside the vertical Home page are fine; vertical inside vertical is not. [Scroll views › Best practices] "Avoid putting a scroll view inside another scroll view with the same orientation."
26. **Paged hero = page control, no scroll indicator** — `.scrollTargetBehavior(.paging)` plus a page control; `.scrollIndicators(.hidden)` on that axis. [Scroll views › iOS, iPadOS] "If you show a page control with a scroll view, don’t show the scrolling indicator on the same axis"
27. **System scroll edge effect only** — keep the automatic style, one per view, only behind floating bars, and never as decoration (no extra custom scrims). [Scroll views › Scroll edge effects] "Only use a scroll edge effect when a scroll view is behind floating interface elements."
28. **Page control: ordered, centered, about 10 at most** — center it at the bottom of the hero with system-colored indicators; for more than ~10 peers use a row or grid. [Page controls › Best practices] "More than about 10 dots are hard to count at a glance."

## Lists: year list, episodes, settings (29–32)

29. **Text belongs in lists; keep rows short** — leading thumbnail + brief label for year-list and episode rows; long text goes to a detail view. [Lists and tables › Style] "display a small image in the leading end of a row, followed by a brief explanatory label"
30. **Grouped style for settings** — `List { Section { … } header: { … } footer: { … } }.listStyle(.insetGrouped)`. [Lists and tables › Style] "the grouped style uses headers, footers, and additional space to separate groups of data"
31. **Chevrons drill in; checkmarks select** — `NavigationLink` rows (disclosure indicator) navigate; the info button only reveals info; option lists show a checkmark (inline `Picker`). [Lists and tables › iOS, iPadOS, visionOS] "If you need to let people drill into a list or table row’s subviews, use a disclosure indicator accessory control."
32. **No index next to chevrons** — no A–Z or year section index on a list whose rows show trailing disclosure indicators. [Lists and tables › iOS, iPadOS, visionOS] "Avoid adding an index to a table that displays controls — like disclosure indicators — in the trailing ends of its rows."

## Buttons (33–39)

33. **Hit region of at least 44 × 44 pt** for every tappable (icon buttons, poster overlays, hero pause): `.frame(minWidth: 44, minHeight: 44).contentShape(.rect)`. [Buttons › Best practices] "a button needs a hit region of at least 44x44 pt"
34. **Every custom button has a press state** — a `ButtonStyle` that reads `configuration.isPressed`. [Buttons › Best practices] "Always include a press state for a custom button."
35. **One prominent button per view, two at most** — Play = `.glassProminent`/`.borderedProminent`; the rest `.glass`/`.bordered`; labels stay monochrome over colorful art. [Buttons › Style] "Keep the number of prominent buttons to one or two per view."
36. **Style, not size, marks the preferred choice** — sibling buttons share one size; prominence signals the default. [Buttons › Style] "Use style — not size — to visually distinguish the preferred choice among multiple options."
37. **Familiar icons, verb labels** — Share = `square.and.arrow.up` (`ShareLink`), Play = `play.fill`; text labels start with a verb (Play, Resume, Add to Up Next). [Buttons › Content] "Try to associate familiar actions with familiar icons."
38. **Roles carry meaning** — `role: .destructive` (system red) and `.cancel`; never give a destructive action the primary or prominent treatment. [Buttons › Role] "Don’t assign the primary role to a button that performs a destructive action"
39. **Slow action → spinner inside the button** — swap in `ProgressView()` plus an "-ing" label ("Checkout" → "Checking out…") instead of a blocking screen. [Buttons › iOS, iPadOS] "display an activity indicator when you need to provide feedback about an action that doesn’t instantly complete"

## Menus (40–43)

40. **Verb labels; dim, don't hide** — verb phrases, title-style capitalization in English, no articles, a trailing "…" when more input follows; unavailable items stay visible but dimmed (`.disabled`). [Menus › Labels] "label a menu item that initiates an action using a verb or verb phrase that describes the action"
41. **Order and group** — most-used items first; related items in `Section`s (separators); icons on every item in a group or none, with standard symbols for common actions. [Menus › Organization] "Prefer listing important or frequently used menu items first."
42. **One toggling item, not two** — "Add to Up Next" ↔ "Remove from Up Next", or a checkmark via a `Toggle` inside the `Menu`. [Menus › Toggled items] "Consider using a changeable label that describes an item’s current state."
43. **Medium and small layouts** — three frequent actions → a top row with icon + short label (medium); four closely related icon-only actions → small (`ControlGroup` at the top of a `Menu`/`.contextMenu`). [Menus › iOS, iPadOS] "Consider using the medium layout if your app has three important actions that people often want to perform."

## Action sheets (44–48)

44. **Action sheet, not alert, for choices about an action someone started** — sign out, delete, discard changes → `.confirmationDialog`. [Action sheets › Best practices] "Use an action sheet — not an alert — to offer choices related to an intentional action."
45. **Menu vs action sheet** — a control whose job is to reveal options (More, season picker, sort) → `Menu`; an action that needs clarifying choices → action sheet. [Action sheets › iOS, iPadOS] "people expect a menu to appear when they choose to reveal it"
46. **Sparingly, with a one-line title** — add a message only if the title plus context isn't enough. [Action sheets › Best practices] "Aim to keep titles short enough to display on a single line."
47. **Destructive on top, Cancel at the bottom** — `Button(role: .destructive)` first; the SwiftUI dialog supplies Cancel. [Action sheets › Best practices] "place these buttons at the top of the action sheet where they tend to be most noticeable"
48. **Never scrolling** — keep the choices few (the explicit cap of 4 buttons including Cancel is watchOS guidance). [Action sheets › iOS, iPadOS] "Avoid letting an action sheet scroll."

## Sheets & modality (49–56)

49. **Sheets for scoped, related tasks** — cast list, episode info, account; video and long multi-step flows use `.fullScreenCover`. [Sheets › intro] "A sheet helps people perform a scoped task that’s closely related to their current context."
50. **iPhone detents** — `.presentationDetents([.medium, .large])` for progressive disclosure (medium ≈ half height, large = full); large-only when content needs room; medium-only stops the sheet from expanding. [Sheets › iOS, iPadOS] "In an iPhone app, consider supporting the medium detent to allow progressive disclosure of the sheet’s content."
51. **A grabber means "resizable"** — `.presentationDragIndicator(.visible)` on resizable sheets, which is what it tells people (it also works with VoiceOver). [Sheets › iOS, iPadOS] "A grabber shows people that they can drag the sheet to resize it"
52. **Swipe to dismiss; protect unsaved work** — allow swipe-down; if edits would be lost, `.interactiveDismissDisabled(isDirty)` plus an action sheet with Save/Discard. [Sheets › iOS, iPadOS] "People expect to swipe vertically to dismiss a sheet instead of tapping a dismiss button."
53. **Sheet buttons** — Cancel/Close leading, Done trailing; a Done always has a Cancel (or Back) partner; never Cancel + Done + Back together. [Sheets › Best practices; iOS, iPadOS] "If you provide a Done button, always pair it with a Cancel button"
54. **Modal only for a clear benefit, with one path** — short and simple; no navigation hierarchy inside a modal that feels like a second app. [Modality › Best practices] "Take care to avoid creating a modal experience that feels like an app within your app."
55. **Obvious way out** — a top-bar close button or swipe-down on every modal. [Modality › Best practices] "Always give people an obvious way to dismiss a modal view."
56. **One modal at a time** — dismiss before presenting the next (cast → actor: push inside the sheet, don't stack another); never two alerts. [Modality › Best practices] "Let people dismiss a modal view before presenting another one."

## Labels & images (57–59)

57. **System text, system hierarchy** — system fonts with Dynamic Type; `.foregroundStyle(.primary / .secondary / .tertiary / .quaternary)` for importance instead of ad-hoc white opacities. [Labels › Best practices] "Use system-provided label colors to communicate relative importance."
58. **Text on artwork needs help** — a gradient scrim or shadow behind hero titles and metadata. [Image views › Content] "consider ways to make the text object stand out, like adding a text shadow or background layer"
59. **Tappable images are buttons** — wrap artwork in `Button`/`NavigationLink`, not `.onTapGesture` on an `Image`; draw icons with SF Symbols, not bitmaps. [Image views › Best practices] "instead of adding button behaviors to an image view"

## Search (60–65)

60. **Search is its own tab** — `Tab(value: …, role: .search)` at the trailing end, as in Apple TV. [Searching › Best practices] "In apps that use tab bars, like Photos and Apple TV, search is a dedicated tab."
61. **Landing page for discovery** — the standard search-tab style shows genres, years and recent searches before typing (the Apple TV model); the keyboard-first button style is for quick lookups. [Search fields › iOS › Search as a tab] "Choose the standard tab style to provide suggestions, promote discovery, and encourage exploration."
62. **Search as you type, with suggestions** — live results; recent searches before typing, predictive suggestions while typing (`.searchSuggestions`); the prompt text says what can be searched. [Search fields › Best practices] "If possible, start search immediately when a person types."
63. **Best results first, grouped** — most relevant first; group into Movies / Shows / People; an optional scope bar defaults to the broadest scope (`.searchScopes`). [Search fields › Best practices] "Provide the most relevant search results first to minimize the need for someone to scroll"
64. **One global search; local filters sit inline** — app-wide search lives in the tab; a Library filter sits inline above its list (it may pin to the top bar) and names its scope ("Search Library"). [Searching › Best practices] "Aim to make your app’s content searchable through a single location."
65. **History you can clear** — if recent searches are shown, offer Clear. [Searching › Best practices] "If you do show search history, provide a way for people to clear it if they want."

## Loading & progress (66–70)

66. **Never a blank screen** — show placeholders right away (`.redacted(reason: .placeholder)`), replace them as content arrives, and keep the rest of the app usable meanwhile. [Loading › Best practices] "Show something as soon as possible."
67. **Determinate when you can** — `ProgressView(value:total:)` when the duration is known; switch from indeterminate to determinate once it is; never morph a spinner into a bar or back. [Progress indicators › Best practices] "When possible, use a determinate progress indicator."
68. **Honest progress** — advance at the real pace; no pacing that misrepresents how much is done. [Progress indicators › Best practices] "Be as accurate as possible when reporting advancement in a determinate progress indicator."
69. **Specific, short status text** — no vague "Loading…"; if it stalls, say what's wrong and what to do. [Progress indicators › Best practices] "Avoid vague terms like loading or authenticating because they seldom add value."
70. **Refresh** — `.refreshable` plus automatic periodic updates; a refresh title only if it adds information ("Updated 5 min ago"). [Progress indicators › Refresh content controls] "Don’t make people responsible for initiating every update."

## Launching & onboarding (71–77)

71. **Launch screen = first screen minus content** — a solid dark background matching Home; no text, logo or branding. [Launching › Launch screens] "Design a launch screen that’s nearly identical to the first screen of your app or game."
72. **Restore state on relaunch** — selected tab, scroll position and navigation path (`@SceneStorage`). [Launching › Best practices] "Restore the previous state when your app restarts so people can continue where they left off."
73. **Prefer no onboarding** — if there is any: fast, fun, optional, after launch completes, nothing to memorize (the HIG gives no screen count or duration). [Onboarding › intro] "if onboarding is necessary, design a flow that’s fast, fun, and optional"
74. **Teach in context** — TipKit (`TipView`, `.popoverTip`) next to the feature instead of an upfront tour. [Onboarding › Best practices] "Consider providing a collection of context-specific tips instead of a single onboarding flow."
75. **Once, then findable** — don't show a tutorial or welcome again on later launches; keep it reachable from Settings/Help. [Onboarding › Best practices] "don’t present it again on subsequent launches, but make sure it’s easy for people to find"
76. **Splash: brief and glanceable** — at the start of onboarding (or right after launch if there is none), shown just long enough to take in at a glance. [Onboarding › Additional content] "Aim to display your splash screen just long enough for people to absorb the information at a glance"
77. **No legal walls; postpone setup** — let the App Store show agreements; if legally required in-app, integrate it in a balanced, non-disruptive way; defer nonessential setup and rely on good defaults. [Onboarding › Additional content] "Avoid displaying licensing details within your onboarding flow."

## Privacy & permissions (78–82)

78. **Ask at the moment of need** — request a permission when someone first uses the feature that needs it (e.g., notifications when they switch on new-release alerts). [Privacy › Requesting permission] "Ideally, wait to request permission until people actually use an app feature that requires access."
79. **Nothing at launch unless essential** — ask at launch only if the app can't function without the resource, and then fold the request into onboarding with the reason. [Privacy › Requesting permission] "Avoid requesting permission at launch unless the data or resource is required for your app to function."
80. **Purpose strings** — one brief, specific, active-voice, sentence-case sentence ending in a period. [Privacy › Requesting permission] "Aim for a brief, complete sentence that’s straightforward, specific, and easy to understand."
81. **Pre-alert screens: one button** — an optional explainer before a system alert has exactly one button ("Continue"/"Next") that opens the alert; no "Allow", no Close/Cancel, and no other actions unless needed for legal consent. [Privacy › Pre-alert screens] "Include only one button and make it clear that it opens the system alert."
82. **Never steer the choice** — no incentives, imitation requests, alert images or annotations around a system prompt; a consent screen shown before or after the tracking (ATT) alert to comply with local privacy law is allowed. [Privacy › Tracking requests] "Never precede the system-provided alert with a custom screen or window that could confuse or mislead people."

## Feedback (83–85)

83. **Status in place; alerts only when critical** — show freshness and download state inline (row, toolbar); keep alerts for critical, actionable information. [Feedback › Best practices] "Consider integrating status feedback into your interface."
84. **Warn only before unexpected, irreversible loss** — no confirmation for expected results (removing from Up Next); confirm success only for significant tasks. [Feedback › Best practices] "Warn people when they initiate a task that can cause data loss that’s unexpected and irreversible."
85. **Explain what can't be done** — e.g., file unavailable → say why next to Play; pair visual feedback with haptics and VoiceOver. [Feedback › Best practices] "Show people when a command can’t be carried out and help them understand why."

## Video playback & full screen (86–93)

Rules 88–91 come from the HIG's "Integrating with the TV app" guidance, which is written for playback launched from the TV app. They are the HIG's only explicit rules on how playback starts, loads and exits.

86. **System player** — full-screen `AVPlayerViewController` (or `VideoPlayer`) for playback controls, aspect modes and PiP; a custom player must behave the same way. [Playing video › Best practices] "Use the system video player to give people a familiar and convenient experience."
87. **Original aspect ratio; metadata, not overlays** — no letterbox baked into the video; the system picks aspect-fill (2:1–2.40:1) or fit (up to 2:1, and above 2.40:1); title and artwork go in `AVPlayerItem.externalMetadata`, kept off the picture. [Playing video › Best practices] "Always display video content at its original aspect ratio."
88. **Play means play** — go straight from the tap to the content, with no splash, detail screen or intro animation in between. [Playing video › Integrating with the TV app] "avoid displaying splash screens, detail screens, intro animations, or any other barriers that make it take longer to reach content"
89. **Auto-resume, no prompt** — resume from the previous end time without asking "Resume or start over?". [Playing video › Integrating with the TV app] "If playback can be resumed, do so automatically without prompting for confirmation."
90. **Loading screen: black + spinner, only after 2 s** — show nothing if loading is fast; otherwise a black background with a centered `ProgressView()`, no other content and minimal branding, gone as soon as enough has loaded to start. [Playing video › Integrating with the TV app › Loading content] "if loading takes more than two seconds, consider showing a black loading screen with a centered activity spinner"
91. **Exit to context** — on dismiss, land on the title's detail page with Resume (prepare it as soon as playback starts). [Playing video › Integrating with the TV app › Exiting playback] "display a detail view for the content the viewer was just watching and include an option to resume playback"
92. **Controls always within reach** — controls stay visible or reappear on a tap; hidden chrome comes back with a familiar gesture. [Going full screen › Best practices] "a full-screen media experience needs to make playback controls persistently available or easy to reveal"
93. **People decide when to leave** — don't auto-dismiss the player when a movie ends; pause when people switch away and resume where they left off. [Going full screen › Best practices] "Let people choose when to exit full-screen mode."

## Settings (94–97)

94. **Few settings, great defaults** — choose defaults that suit most people and cut whatever isn't needed. [Settings › Best practices] "Minimize the number of settings you offer."
95. **Don't duplicate system settings** — no in-app versions of accessibility, text size, motion or other global options. [Settings › Best practices] "Respect people’s systemwide settings and avoid including redundant versions of them in your custom settings area."
96. **Options live where they act** — sort, filter and show/hide sit on the Library screen (toolbar `Menu`); Settings holds general, rarely changed options. [Settings › Task-specific options] "make these options available in the screens they affect, where they’re discoverable and convenient"
97. **Hand off to system Settings** — for rarely changed or system-level options (e.g., turning notifications back on), give a button that opens Settings (`UIApplication.openNotificationSettingsURLString`). [Settings › System settings] "consider providing a button that opens it directly from your interface"

## Sign-in & data entry (98–112)

98. **Ask for an account only because the core needs it, and say why on the sign-in screen** — Cuven streams a private library, so sign-in stays; the screen carries one short, friendly sentence on what the account is for. [Managing accounts › Best practices] "write a brief, friendly description of the reasons for the requirement and its benefits. Display this message in your sign-in view."
99. **Prefer passkeys; keep passwords only with a second factor** — passkeys or Sign in with Apple are the preferred methods; while passwords remain, a verification code adds the second factor. [Managing accounts › Best practices] "If you need to continue using passwords for authentication, augment security by requiring two-factor authentication"
100. **Name the method on the button** — "使用面容 ID 登录", never a bare "登录" for a biometric sign-in. [Managing accounts › Best practices] "title it using a phrase like “Sign In with Face ID” instead of a generic phrase like “Sign In.”"
101. **Mention only the methods this device has** — read `LABiometryType` and say Face ID, Touch ID or nothing. [Managing accounts › Best practices] "Refer only to authentication methods that are available in the current context."
102. **No in-app opt-in for biometrics** — people turn biometrics on in Settings. [Managing accounts › Best practices] "In general, avoid offering an app-specific setting for opting in to biometric authentication."
103. **Never say "passcode"** — it reads as the device passcode. [Managing accounts › Best practices] "Avoid using the term passcode to refer to account authentication."
104. **If the app creates accounts, it must also delete them** — a clear in-app path, or a direct link to the web page that does it. [Managing accounts › Deleting accounts] "If you help people create an account within your app or game, you must also help them delete it, not just deactivate it."
105. **Placeholder plus a label** — the placeholder disappears as people type, so a separate label keeps the purpose visible. [Text fields › Best practices] "Because placeholder text disappears when people start typing, it can also be useful to include a separate label describing the field to remind people of its purpose."
106. **Secure field for passwords, never prefilled** — `SecureField`; offer biometrics or keychain instead of filling it in. [Text fields › Best practices] "Always use a secure text field when your app asks for sensitive data, such as a password." [Entering data › Best practices] "Never prepopulate a password field."
107. **The right keyboard** — email keyboard for addresses, number pad for codes; `.textContentType` so AutoFill knows the field. [Text fields › Best practices] "display the keyboard that’s appropriate for the type of content people are entering"
108. **Clear button at the trailing end** — [Text fields › iOS, iPadOS] "Display a Clear button in the trailing end of a text field to help people erase their input."
109. **Stack fields, space them evenly, keep widths consistent** — [Text fields › Best practices] "Stack multiple text fields vertically when possible, and use consistent widths to create a more organized layout."
110. **Validate at the right moment; Continue only when the data is there** — check an email when people leave the field, a new password before they leave it; keep Continue disabled until the required data is in. [Text fields › Best practices] "when entering an email address, it’s best to validate when people switch to another field" [Entering data › Best practices] "make the button available only after people enter the data you require."
111. **Let the system fill it in** — password AutoFill, one-time codes from Messages and Mail, saved user names. [Entering data › Best practices] "Don’t ask people to enter information that you can gather automatically"
112. **Accept paste** — a pasted six-digit code fills the whole code at once. [Entering data › Best practices] "let people provide data by dragging and dropping it or by pasting it."

## What this means for our screens

- **Tab bar (Home / Library / Account / Search)** — the white tint matches 9 and the trailing search tab matches 60. Account is a section people use rarely, so weigh whether it earns a tab (5). The app minimizes the bar on scroll with no accessory; the HIG describes minimizing only alongside one (10).
- **Home rows** — standard horizontal poster rows in one vertical scroll (20, 25); the next poster peeks and rows snap (24); targets of at least 44 pt with padding so press effects never collide (21, 33); tap → detail, touch-and-hold → context menu (Play/Resume, Up Next), with the medium top row if there are three frequent actions (43); never reorder rows under the user on refresh, animate inserts instead (22, 23); skeleton rows while loading (66).
- **Home hero** — paged, with a page control centered at the bottom, about 10 items at most, and no same-axis indicator (26, 28); one prominent Play plus one secondary button of the same size (35, 36); a scrim behind title and metadata (58); never the app name as the screen title (12). These pages say nothing for or against auto-advance; the existing 44 pt pause button meets 33.
- **Detail page: one primary action** — a single prominent Play/Resume button that resumes without asking (35, 37, 89). Trailer, Up Next, Share and Copy Link go in one `Menu` behind a borderless `ellipsis` (11, 15, 45). Today "More" opens a custom bottom sheet that repeats Play, and the toolbar uses a rotated, outlined `arrow.up.left.and.arrow.down.right.circle`; both conflict with 1, 15 and 45.
- **Detail page: bar & chrome** — empty title until the hero title scrolls off, then a short inline title (12); Back plus one More item (11); the automatic scroll edge effect instead of a custom status-bar scrim layered on top (27); the tab bar stays visible (4).
- **Detail page: cast & episodes** — cast as a horizontal row (20); "All Cast" opens a `.medium`/`.large` sheet with a grabber (50, 51); tapping an actor pushes inside that sheet, never a second stacked sheet (54, 56); episodes as rows with a leading thumbnail and short label (29); seasons through a `Menu` (45).
- **Library** — large title (13); standard grid or rows (20); sort, filter and view options in a toolbar `Menu` on this screen, not in Settings (96); a local search field inline, scoped to "Search Library" (64); empty states explain themselves (7, 85); layout changes in the cinematic view only on explicit actions (23).
- **Search** — trailing `role: .search` tab with a standard landing page of genres, years and recent searches (60, 61); results as you type, best first, grouped into Movies / Shows / People, with an optional scope bar defaulting to All (62, 63); a Clear option for recent searches (65).
- **Year list** — list rows with a leading poster, a brief label and `NavigationLink` chevrons (29, 31); no section index beside the chevrons (32); title under 15 characters (12).
- **Sign-in screen** — a full screen is right because nothing works without the account (98): one sentence on why, then stacked system text fields with labels (105, 109) and the right keyboards and content types, so AutoFill and Messages codes fill themselves (107, 111, 112). Passwords use `SecureField` and are never prefilled (106). One prominent Continue stays disabled until the field is valid (110, 35). "使用面容 ID 登录" names the method and appears only when the device has it (100, 101). No decorative backgrounds or pulses, the brand stays small (F80), and never "passcode" (103). Account deletion needs a path, which is missing today (104), and the in-app Face ID switch on the account page sits against 102: it also decides whether the password is stored on the device at all, so it stays until that is settled.
- **Settings / Account** — inset-grouped list (30); few settings with strong defaults (94); no copies of system settings, so check whether the in-app Haptics switch duplicates the system one (95); "turn notifications back on" is a button into the app's notification settings (97); when shown as a sheet with nothing to save, close it with the standard xmark on the leading edge rather than a lone Done (14, 53).
- **Welcome screen** — the docs prefer no onboarding (73), a splash shown only briefly at the start (76) and never again (75), and launches that resume where people left off (72). Today the welcome screen shows on every cold launch and blocks until "Continue" is tapped. Show it at most once (e.g., after first sign-in) and keep it glanceable, or drop it; teach features with TipKit instead (74).
- **Privacy consent** — a legal consent screen (privacy rules, cross-border transfer, age) is allowed (81, 82), but keep it out of the onboarding path or integrate it in a balanced, non-disruptive way (77). Move the notification request out of the gate to the moment someone turns on new-release alerts (78, 79). Any explainer before a system prompt gets exactly one "Continue" button (81); keep one prominent "Agree" button (35); show the gate once per policy version, as now. The gate draws a grabber but can't be dragged, and a grabber tells people the sheet resizes (51), so remove it. Rule 55 asks every modal for an obvious exit; whether a legal gate may leave one out is a legal question, not a HIG one.
- **Sheets, action sheets, menus** — a `Menu` for anything people open on purpose (More, seasons, sort) (45); `.confirmationDialog` to confirm or clarify an action: sign out (already correct), delete, discard (44, 47). Replace the custom `WebActionSheet` with one of these, so Cancel placement, destructive styling and no-scroll come built in (47, 48). Use sheets for scoped tasks, with medium/large detents and one at a time (49, 50, 56).
- **Video player** — keep the full-screen `AVPlayerViewController` (86, 49); tap → content, no intro (88); auto-resume from the last position (89). If loading takes longer than 2 s, show a black screen with a centered spinner and minimal branding, gone the moment playback can start (90). The current loading screen (aurora shader, wordmark, rotating marketing-style tips, staged progress bar that creeps forward) conflicts with 90, 68 and 69. On exit, return to the detail page with Resume (91); people choose when to leave (93); controls are easy to reveal (92).
- **Loading & refresh elsewhere** — skeletons rather than spinners for rows (66); `.refreshable` plus automatic refresh with an informative timestamp (70); status inline, not in alerts (83); determinate progress for anything measurable (67).
- **iPhone Duo** — system `TabView` and toolbars only (17); one-word tab labels, because the system stacks icon and label in compact widths and sets them side by side in regular ones (8); at most 5 tabs and no "More" overflow in the folded side column (5, 6); `.sidebarAdaptable` if the unfolded layout needs more navigation (18); reflowing rows into grids on unfold is fine as a response to an explicit action, but it must stay easy to follow (23); hero art extends under floating glass (19). Duo-specific guidance is in designing-for-iphone-duo.txt, which is outside this set.
- **Motion, appearance, copy** — these pages endorse motion as feedback (press states 34; insert/delete/reorder 22) and discourage it as a barrier before content (88, 71); motion.txt is outside this set. Rule 2 asks apps to adapt to appearance changes, including Dark Mode, so a dark-only app is a deliberate deviation; check dark-mode.txt (outside this set). Copy: labels start with a verb (37, 40), action-sheet titles fit one line (46), status text is specific (69), and each purpose string is one active sentence (80).

## Anti-patterns the docs warn against

- Hiding the tab bar on pushed screens; disabling or hiding tabs; an overflow "More" tab; badges for non-critical news; tabs used for actions. [Tab bars › Best practices]
- Titling a screen with the app name; "Back"/"Close" text buttons. [Toolbars › Titles; Navigation]
- Crowded bars, custom bar backgrounds and tints, outlined-circle symbols, more than one primary action. [Toolbars › Best practices; Actions]
- Custom collection layouts that "draw undue attention to itself"; changing the layout while people are viewing it. [Collections › Best practices; iOS, iPadOS]
- Same-axis nested scroll views; decorative scroll edge effects, or more than one per view. [Scroll views › Best practices; Scroll edge effects]
- More than about 10 page dots; colored indicators or more than two kinds of indicator image; scrubbing with the minimal style; animating each page while scrubbing. [Page controls]
- Info buttons used for navigation; a section index beside trailing chevrons. [Lists and tables › iOS, iPadOS, visionOS]
- More than one or two prominent buttons per view; size instead of style to signal preference; the primary role on a destructive action; custom buttons with no press state; hit regions under 44 × 44 pt. [Buttons]
- Overlong menus; deep or long submenus; indenting instead of submenus; icons on only some items in a group; icons that don't clearly represent the item. [Menus]
- Alerts used to offer choices; a menu where an action sheet is expected (and the reverse); scrolling or overused action sheets. [Action sheets]
- Stacked sheets or modals; a sheet that closes back into another sheet; Done with no Cancel or Back; Cancel + Done + Back together; app-within-an-app modals; modals with no obvious exit; two alerts at once. [Sheets; Modality]
- Blank screens while loading; vague "loading" copy; progress pacing that "can even feel deceptive"; indicators that stop moving; switching between spinner and bar. [Loading; Progress indicators]
- Launch screens with text, logos or branding: "The launch screen isn’t a branding opportunity." [Launching › Launch screens]
- Long onboarding that asks people to memorize a lot; showing a skipped tutorial again; licensing details in onboarding; nonessential setup up front; splash screens that delay people. [Onboarding]
- Permission requests at launch without need, before people show interest, or for more data than a feature needs; vague or passive purpose strings. [Privacy › Best practices; Requesting permission]
- Pre-alert screens with an "Allow"-style button, more than one button, or a close/cancel option; incentives, imitation requests, alert images or annotations. [Privacy › Pre-alert screens; Tracking requests]
- Showing search history with no way to clear it. [Searching › Best practices]
- A custom player that "diverges slightly" from the system player; letterbox or pillarbox padding baked into the video; overlays that obscure playback; audio from different sources mixing. [Playing video › Best practices]
- Splash, detail or intro screens before playback; asking whether to resume; busy loading screens. [Playing video › Integrating with the TV app; Loading content]
- Ending full screen automatically when a movie finishes; hiding essential controls with no familiar way to bring them back. [Going full screen › Best practices]
- Warnings for expected data loss; alerts for unimportant information; confirming routine successes. [Feedback › Best practices]
- Too many settings; in-app copies of system-wide settings; task options buried in Settings; asking for setup information the app can detect. [Settings]
