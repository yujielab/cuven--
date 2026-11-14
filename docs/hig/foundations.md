# HIG foundations digest: Cuven max (iOS 26 · iPhone + iPhone Duo · dark only)

## Layout & spacing

1. Put what matters most first: the hero and the primary action (Play) go at the top and leading edge, with shelves below in order of importance. Choose a navigation structure that keeps content in focus.
    - [Layout › Visual hierarchy] "place the most important items near the top and leading side of the window or display" · [Liquid Glass › Design principles] "Define a layout and choose a navigation structure that puts the most important content in focus."
2. Align shelf titles, poster rows and metadata to one shared leading edge. Indent only to show that content is subordinate.
    - [Layout › Visual hierarchy] "Align elements to make them easier to scan, and use indentation to convey hierarchy."
3. Show grouping with negative space, container shapes or separator lines. For a restrained look, use negative space first (the gaps between shelves and sections).
    - [Layout › Visual hierarchy] "you might use negative space, container shapes, or separator lines to show which elements are related"
4. Use progressive disclosure. Show a curated set on each screen, put the rest in horizontally scrolling shelves (`ScrollView(.horizontal)` + `LazyHStack`), and put details in pushed views.
    - [Layout › Visual hierarchy] "use scrollable sections to showcase additional content, which is particularly useful for media-focused apps like those for video"
5. Don't use solid or semi-opaque fills to separate bars and controls from content. Use the system scroll edge effect.
    - [Layout › Visual hierarchy] "Instead of applying a solid or semi-opaque background color beneath controls, use a scroll edge effect"
6. Let full-bleed hero and backdrop art run under the nav bar, toolbar and tab bar (`.ignoresSafeArea()` on the background layer only). If a sidebar would cover key art, add `.backgroundExtensionEffect()`.
    - [Layout › Visual hierarchy] "For full-screen background content, be sure to extend it underneath sidebars, toolbars, and tab bars" · "use a background extension effect to flip and blur the image"
7. Keep all text and controls inside the safe area on every edge, including the folded Duo's side column of system bars. Only background art may ignore the safe area.
    - [Layout › Guides and safe areas] "Respecting the safe area is essential to make sure system UI and hardware features like the Dynamic Island don’t obstruct"
8. Take margins from the system (SwiftUI default `.padding()` and list/form insets; UIKit `readableContentGuide`), not hard-coded numbers. On the 669 pt unfolded screen, limit long text such as synopses to a readable width. These files give no numeric iOS margin.
    - [Layout › Guides and safe areas] "predefined layout guides that make it easy to apply standard margins around content and restrict the width of text"
9. Choose layouts from `horizontalSizeClass` and available width, never from device model or orientation. Test the smallest (folded ~382 pt) and largest (unfolded ~669 pt) layouts first.
    - [Layout › Size classes] "Determine layout based on size classes, not device type or orientation." · [Layout › Adaptability] "first testing versions of your experience that use the largest and the smallest layouts"
10. Folded and unfolded have the same features. The wider state only shows more: more posters per row, extra columns, or a tab bar that becomes a sidebar (`.tabViewStyle(.sidebarAdaptable)`).
    - [Layout › Size classes] "Don’t change your app’s functionality based on the space it occupies." · "Consider taking advantage of larger spaces to switch from a tab bar to a sidebar"
11. Leave about 12 pt of padding around bezeled controls and about 24 pt around the visible edges of controls without a bezel (icon-only and text buttons).
    - [Accessibility › Mobility] "it works well to add about 12 points of padding around elements that include a bezel" · "For elements without a bezel, about 24 points of padding works well around the element’s visible edges."
12. Use one spacing rhythm: one gap between posters and one gap between shelves, used everywhere, plus extra room above and below each shelf title. This is tvOS grid guidance, applied by analogy.
    - [Layout › tvOS › Grids] "When content isn’t consistently spaced, it no longer looks like a grid and it’s harder for people to scan." · "Include additional vertical spacing for titled rows."
13. Make nested corners concentric with their container, for example cards, or buttons inside sheets (`ConcentricRectangle`, `.rect(corners:isUniform:)`).
    - [Adopting Liquid Glass › Controls] "using rounded shapes that are concentric to their containers"
14. Build Settings as a `Form` with `.formStyle(.grouped)`, and keep the system's larger row height and padding.
    - [Adopting Liquid Glass › Organization and layout] "Use SwiftUI forms with the grouped form style to automatically update your form layouts." · "To give content room to breathe, organizational components like lists, tables, and forms have a larger row height and padding."

## Typography

15. Set every string in a built-in text style (`.font(.title2)`, `.font(.subheadline)`, …), not a fixed point size. The styles carry the hierarchy and support Dynamic Type.
    - [Typography › Using system fonts] "text styles give you a convenient and consistent way to convey your information hierarchy through font size and weight" · "Using text styles with the system fonts also ensures support for Dynamic Type and larger accessibility type sizes"
16. Body text defaults to 17 pt, and no text goes below 11 pt (Caption 2). This applies to custom fonts too.
    - [Typography › Ensuring legibility] "Follow the recommended default and minimum text sizes for each platform — for both custom and system fonts" · "iOS, iPadOS | 17 pt | 11 pt"
17. Use Regular, Medium, Semibold or Bold. Avoid Ultralight, Thin and Light, especially at small sizes.
    - [Typography › Ensuring legibility] "prefer Regular, Medium, Semibold, or Bold font weights, and avoid Ultralight, Thin, and Light font weights"
18. Show hierarchy with weight, size and color (for example `.foregroundStyle(.secondary)` for metadata), and keep that hierarchy at every text size.
    - [Typography › Conveying hierarchy] "Adjust font weight, size, and color as needed to emphasize important information and help people visualize hierarchy." · "Be sure to maintain the relative hierarchy and visual distinction of text elements when people adjust text sizes."
19. For one more level of hierarchy, apply `.bold()` to a style. It gives that style's emphasized weight: Bold for Large Title, Title 1 and Title 2; Semibold for all others.
    - [Typography › Using system fonts] "the bold trait adds weight to text, letting you create another level of hierarchy" · [Typography › Specifications] "In SwiftUI, use the bold() modifier"
20. Use as few typefaces as possible: SF Pro through the system styles. If you use a brand face, use it only for headlines and subheadings, and it must support Bold Text and Dynamic Type (`Font.custom(_:size:relativeTo:)`).
    - [Typography › Conveying hierarchy] "Minimize the number of typefaces you use, even in a highly customized interface." · [Branding › Best practices] "use a custom font for headlines and subheadings while using system fonts for body copy and captions" · "supports accessibility features like bold text and Dynamic Type"
21. Use loose leading for multi-line synopses (`.font(.body.leading(.loose))`). Use `.tight` only for one or two lines in rows with limited height, never for three or more lines.
    - [Typography › Using system fonts] "more space between lines (loose leading) can make it easier for people to keep their place" · "display three or more lines of text, avoid tight leading even in areas where height is limited"
22. Let the system set tracking for SF text; it changes with point size. Use the tracking table only to make design mockups match.
    - [Typography › Using system fonts] "In a running app, the system font dynamically adjusts tracking at every point size."
23. Check every screen at every Dynamic Type size up to AX5. Keep primary elements (title, Play) at the top even at the largest sizes.
    - [Typography › Supporting Dynamic Type] "Make sure your app’s layout adapts to all font sizes." · "keep primary elements toward the top of a view even when the font size is very large"
24. Don't truncate text inside scrolling content unless a tap opens the full text (for example, a synopsis with “More”). Otherwise allow as many lines as needed.
    - [Typography › Supporting Dynamic Type] "Avoid truncating text in scrollable regions unless people can open a separate view to read the rest of the content."
25. At accessibility sizes, use fewer grid columns (Library) and stack side-by-side poster-and-text rows vertically (`ViewThatFits`, `dynamicTypeSize.isAccessibilitySize`).
    - [Typography › Supporting Dynamic Type] "Reduce the number of columns when the font size increases to avoid truncation and enhance readability." · [Layout › Adaptability] "horizontally adjacent views may need to stack vertically to provide more space for text"

## Color & dark mode

26. Lock the whole app to dark appearance (`UIUserInterfaceStyle` = Dark in Info.plist, or `.preferredColorScheme(.dark)` at the root). The docs allow this for immersive media apps. Don't add an in-app appearance setting.
    - [Dark Mode › Best practices] "it can make sense for an app that supports immersive media viewing to use a permanently dark appearance" · "Avoid offering an app-specific appearance setting."
27. Define every custom color as an asset-catalog Color Set with light and dark values, plus an Increased Contrast variant of each. You need these even though the app is dark-only, because Liquid Glass uses them to adapt.
    - [Color › Best practices] "Even if your app ships in a single appearance mode, provide both light and dark colors to support Liquid Glass" · "an increased contrast option for each variant that provides a significantly higher amount of visual differentiation"
28. Use dynamic system colors through the `Color` APIs, and only for what they mean: text in `.primary`, `.secondary`, `.tertiary` or `.quaternary`; separator colors only for separators. No hard-coded values, no repurposing.
    - [Dark Mode › Text] "Use the system-provided label colors for labels." · [Color › System colors] "Avoid hard-coding system color values in your app." · "don’t use the separator color as a text color, or secondarylabel color as a background color"
29. Use background colors by level: `systemBackground` for the screen, secondary for grouped elements, tertiary inside those, and the grouped set in Settings. With system backgrounds, sheets switch to the brighter "elevated" variant automatically.
    - [Dark Mode › iOS, iPadOS] "Prefer the system background colors." · "automatically changes from base to elevated when an interface is in the foreground" · [Color › iOS, iPadOS] "Secondary for grouping content or elements within the overall view"
30. Contrast must never be below 4.5:1. Aim for 7:1 with custom foreground and background colors, especially for small text such as metadata over artwork.
    - [Dark Mode › Dark Mode colors] "make sure the contrast ratio between colors is no lower than 4.5:1" · "strive for a contrast ratio of 7:1, especially in small text"
31. Give each color one meaning. If the accent color marks things you can tap, don't use it (or a similar color) on text you can't tap.
    - [Color › Best practices] "Avoid using the same color to mean different things."
32. Use the accent color sparingly, only for primary actions and status (the selected tab, "new" badges). Put brand color in the content layer, where it scrolls beneath the glass.
    - [Branding › Best practices] "Minimize its use on controls and instead use it intentionally for primary actions or status indicators" · "consider moving it into the content layer, where it scrolls beneath Liquid Glass controls"
33. On poster-heavy screens, keep the tab bar and toolbars monochrome. Only the one primary action gets a tinted (prominent) glass background; tint the background, not the symbol or text.
    - [Color › Liquid Glass color] "prefer a monochromatic appearance for toolbars and tab bars" · "To emphasize primary actions, apply color to the background rather than to symbols or text." · "Refrain from adding color to the background of multiple controls."
34. Make sure the resting state is legible. At the top of a scroll view, bar buttons and titles over hero art must be easy to read. For example, darken the top of the art in the content layer, or place bright areas of the art away from the bars.
    - [Color › Liquid Glass color] "make sure its default or resting state — like the top of a screen of scrollable content — maintains clear legibility"
35. Let the artwork set nearby UI colors. For example, take a detail page's backdrop tone from its key art, so the surrounding UI neither overpowers it nor disappears.
    - [Color › Best practices] "Variations in artwork sometimes warrant changes to nearby colors to maintain visual continuity"
36. Never show state with color alone. Watched, downloaded, unavailable and selected states also need a symbol, shape or text.
    - [Color › Inclusive color] "Avoid relying solely on color to differentiate between objects, indicate interactivity, or communicate essential information."
37. Tune colors for dark rooms, where they look brighter and more saturated: test at night and adjust. Because this is a video app, consider setting a white point adaptivity style (`UIWhitePointAdaptivityStyle`).
    - [Color › Best practices] "In dark environments, colors appear bright and saturated." · "Apps that primarily support reading, photos, video, and gaming can strengthen or weaken this effect"

## Materials & Liquid Glass

38. Use Liquid Glass only in the functional layer: tab bar, nav bar and toolbars, floating controls. Never use it on posters, shelves, cards or hero text panels.
    - [Materials › Liquid Glass] "Don’t use Liquid Glass in the content layer."
39. Get glass from standard components (`NavigationStack`, `TabView`, `.toolbar`, `.sheet`, `Menu`, standard `Button`s). Remove custom bar backgrounds so the system draws them.
    - [Adopting Liquid Glass › Visual refresh] "standard components like bars, sheets, popovers, and controls automatically adopt this material" · "Reduce your use of custom backgrounds in controls and navigation elements."
40. Put custom glass only on the few most important functional controls. Use `.buttonStyle(.glass)` or `.buttonStyle(.glassProminent)` before building buttons by hand with `glassEffect`.
    - [Materials › Liquid Glass] "Limit these effects to the most important functional elements in your app." · [Adopting Liquid Glass › Controls] "Instead of creating buttons with custom Liquid Glass effects, you can adopt the look and feel of the material"
41. Use `.regular` glass by default and for anything with a lot of text. Use `.clear` only for controls floating over rich media (hero video, key art). If that media is bright, add a black dimming layer at 35% opacity; over dark media or AVKit controls you don't need one.
    - [Materials › Liquid Glass] "Use the regular variant when background content might create legibility issues, or when components have a significant amount of text" · "Only use clear Liquid Glass for components that appear over visually rich backgrounds." · "If the underlying content is bright, consider adding a dark dimming layer of 35% opacity."
42. To separate things within the content layer, use the standard materials (`.ultraThinMaterial` … `.thickMaterial`). Use thicker ones behind text with fine detail, and thinner ones where the background should stay visible.
    - [Materials › iOS, iPadOS] "four standard materials — ultra-thin, thin, regular (default), and thick — which you can use in the content layer" · [Materials › Standard materials] "Thicker materials, which are more opaque, can provide better contrast for text and other elements with fine features."
43. On any material, use vibrant hierarchical styles (`.foregroundStyle(.secondary)` and so on). Never use the quaternary level on `.thinMaterial` or `.ultraThinMaterial`.
    - [Materials › Standard materials] "Help ensure legibility by using vibrant colors on top of materials." · [Materials › iOS, iPadOS] "avoid using quaternary on top of the thin and ultraThin materials, because the contrast is too low"
44. Wrap multiple custom glass elements in one `GlassEffectContainer(spacing:)`, and keep the number of glass effects on screen at once small.
    - [Applying Liquid Glass to custom views › Combine multiple views] "Use GlassEffectContainer when applying Liquid Glass effects on multiple views to achieve the best rendering performance." · [Applying Liquid Glass to custom views › Optimize performance] "Limit the use of Liquid Glass effects onscreen at the same time."
45. For custom glass, apply `.glassEffect(.regular.interactive(), in: shape)` after the other appearance modifiers. The shape is a Capsule by default; use a rounded rectangle for larger components, and keep one shape language across the app.
    - [Applying Liquid Glass to custom views › Combine multiple views] "Apply the `glassEffect(_:in:)` modifier after other modifiers that affect the appearance of the view." · [Applying Liquid Glass to custom views › Apply and configure] "use a rounded rectangle if you’re applying the effect to larger components that would look odd as a `Capsule`" · "Add interactive(_:) to custom components to make them react to touch and pointer interactions."
46. Don't layer glass on glass or crowd glass controls together. Keep the standard spacing between them.
    - [Adopting Liquid Glass › Controls] "Prefer to use standard spacing metrics instead of overriding them, and avoid overcrowding or layering Liquid Glass elements on top"
47. Put any custom bar over scrolling content (for example, a Library filter or sort bar) in `.safeAreaBar(edge:alignment:spacing:content:)`, so it gets the scroll edge effect like system bars.
    - [Adopting Liquid Glass › Controls] "you can register those views to use a scroll edge effect with these APIs"
48. Keep tabs separate from content. Let the tab bar shrink on scroll (`.tabBarMinimizeBehavior(.onScrollDown)`). Make Search a semantic search tab (`Tab(role: .search)`) so the system puts it at the trailing end.
    - [Adopting Liquid Glass › Navigation] "Tab bars can help elevate the underlying content by receding when a person scrolls up or down." · [Adopting Liquid Glass › Search] "The system automatically separates the search tab from other tabs and places it at the trailing end"
49. In toolbars, group related actions and separate groups with `ToolbarSpacer(.fixed)`. Use standard SF Symbols instead of text for common actions, and never mix text and icons in one shared group. To hide an item, apply `.hidden(_:)` to the item itself.
    - [Adopting Liquid Glass › Menus and toolbars] "Consider representing common actions in toolbars with standard icons instead of text." · "For consistency, don’t mix text and icons across items that share a background." · "Instead, hide the entire toolbar item"
50. In menus, give common actions SF Symbol icons (`Label(_:systemImage:)`). The top actions in a poster's context menu should match its swipe actions.
    - [Adopting Liquid Glass › Menus and toolbars] "menu items for common actions use icons to help people quickly scan and identify those actions" · "Match top menu actions to swipe actions."
51. For sheets and dialogs: no custom background views on sheets or popovers, content kept away from the rounder sheet corners, and confirmation dialogs anchored to the button that opens them.
    - [Adopting Liquid Glass › Windows and modals] "remove those custom background views to provide a consistent experience with other sheets across the system" · "check for content and controls that might appear too close to rounder sheet corners" · "Position an action sheet’s anchor next to the control it originates from."

## Motion

52. Every animation needs a purpose: show status, give feedback, or enrich the experience.
    - [Motion › Best practices] "Add motion purposefully, supporting the experience without overshadowing it." · [Motion › intro] "conveying status, providing feedback and instruction, and enriching the visual experience"
53. Use system motion first (navigation push and pop, sheets, tab bar, glass morphing). It is familiar and already adapts to accessibility settings and input type.
    - [Motion › intro] "Many system components automatically include motion, letting you offer familiar and consistent experiences throughout your app or game." · "System components might also adjust their motion in response to factors like accessibility settings or different input methods."
54. Motion should behave physically: it follows the finger and reverses the way it came. A view revealed by sliding down isn't dismissed sideways; a view that grew out of a poster shrinks back into it.
    - [Motion › Providing feedback] "Strive for realistic feedback motion that follows people’s gestures and expectations." · "they don’t expect to dismiss the view by sliding it to the side"
55. Keep feedback short, precise and interruptible. Never make people wait for an animation to finish, and add no custom motion to frequent actions (scrolling shelves, tapping posters, switching tabs). The files give no duration values.
    - [Motion › Providing feedback] "Aim for brevity and precision in feedback animations." · "don’t make people wait for an animation to complete before they can do anything" · "In apps, generally avoid adding motion to UI interactions that occur frequently."
56. Motion is never the only signal. Pair important changes with a change in text or symbol, and with haptics (`.sensoryFeedback`).
    - [Motion › Best practices] "it’s essential to avoid using it as the only way to communicate important information"
57. Use SF Symbol effects for state feedback: `.symbolEffect(.bounce, value:)` once when an item is added, and `.contentTransition(.symbolEffect(.replace))` for plus → checkmark or play ↔ pause.
    - [SF Symbols › Animations] "The bounce animation plays once by default and can help communicate that an action occurred or needs to take place." · "Down-up, where the outgoing symbol scales down and the incoming symbol scales up, communicating a change in state."
58. Morph custom glass with `glassEffectID(_:in:)` inside a `GlassEffectContainer`. Use `.matchedGeometry` for nearby shapes and `.materialize` for distant ones, the same way everywhere in the app.
    - [Applying Liquid Glass to custom views › Morph Liquid Glass effects] "To provide people with a consistent experience, use `matchedGeometry` and `materialize` transitions across your apps."
59. When Reduce Motion is on (`@Environment(\.accessibilityReduceMotion)`), stop automatic and repeating motion (auto-advancing hero, slow zoom on artwork, parallax) and cut zoom and scale effects.
    - [Accessibility › Cognitive] "ensure your app or game responds by reducing automatic and repetitive animations, including zooming, scaling, and peripheral motion"
60. When Reduce Motion is on, replace slide and zoom transitions with fades, tighten springs so they don't bounce, and don't animate blurs in or out.
    - [Accessibility › Cognitive] "Replacing transitions in x-, y-, and z-axes with fades to avoid motion" · "Tightening animation springs to reduce bounce effects" · "Avoiding animating into and out of blurs"
61. If you add depth or parallax to hero art or posters, keep it almost unnoticeable. This is tvOS parallax guidance, applied by analogy.
    - [Images › tvOS › Layered images] "Parallax is designed to be almost unnoticeable. Excessive 3D effects can appear unrealistic and jarring."

## Images & artwork

62. Ship @2x and @3x bitmaps. For posters and backdrops from the server, request pixel sizes = points × `displayScale`. Check them on real devices for pixelation or stretching.
    - [Images › Resolution] "iOS | @2x and @3x" · [Images › Best practices] "An image that looks great at design time may appear pixelated, stretched, or compressed when viewed on various devices."
63. Formats: key art and stills as optimized JPEG or HEIC; flat icons and logos as PDF or SVG; other bitmaps as de-interlaced PNG.
    - [Images › Formats] "JPEG files, optimized as necessary, or HEIC files" · "PDF or SVG files" · "De-interlaced PNG files"
64. Embed a color profile in every image. Use Display P3 at 16 bits per channel (PNG) for wide-color art, and provide sRGB versions where P3 gradients clip.
    - [Images › Best practices] "Include a color profile with each image." · [Color › Color management] "use the Display P3 color profile at 16 bits per pixel (per channel) and export images in PNG format" · "Gradients that use P3 colors can also sometimes appear clipped on sRGB displays."
65. Never distort artwork. Scale it to fill (`.scaledToFill()` + `.clipped()`), and compose hero art with extra image beyond the frame so it works at both the folded and unfolded aspect ratios.
    - [Layout › Adaptability] "don’t change the aspect ratio of the artwork; instead, scale it so that it fills the screen completely" · "background artwork may often need to extend beyond what is typically visible in a more standard display aspect ratio"
66. Slightly darken images with white backgrounds (stills, logos, screenshots) so they don't glow against the dark UI.
    - [Dark Mode › Dark Mode colors] "consider slightly darkening the image to prevent the background from glowing in the surrounding Dark Mode context"
67. Check every full-color asset on the dark background. Logos and custom icons with dark edges may need a subtle border to stay visible.
    - [Dark Mode › Icons and images] "might need a slight border to make the edge visible against a dark background"
68. Use SF Symbols for interface icons. Let the container pick the variant (fill in the tab bar, outline in toolbars), and use the slash variant for unavailable items.
    - [Dark Mode › Icons and images] "Use SF Symbols wherever possible." · [SF Symbols › Design variants] "an iOS tab bar prefers the fill variant, whereas a toolbar takes the outline variant" · "use the slash variant of a symbol to show that an item or action is unavailable"
69. Match symbol weight to the text next to it, and change emphasis with `.imageScale(.small/.medium/.large)`, not point size. Scale meaningful icons with Dynamic Type (`@ScaledMetric` for images that aren't symbols).
    - [SF Symbols › Weights and scales] "Specifying a scale lets you adjust a symbol’s emphasis compared to adjacent text, without disrupting the weight matching" · [Typography › Supporting Dynamic Type] "Increase the size of meaningful interface icons as font size increases."
70. For symbol color, use hierarchical rendering for depth, and variable color only for values that change (download progress, playback activity). Check that the chosen mode is legible where it's used.
    - [SF Symbols › Variable color] "Use variable color to communicate change — don’t use it to communicate depth." · [SF Symbols › Rendering modes] "Confirm that a symbol’s rendering mode works well in every context."

## Accessibility

71. Let text grow to at least 200%: use the system text styles, `Font.custom(_:size:relativeTo:)` for custom fonts, and `@ScaledMetric` for sizes that follow text.
    - [Accessibility › Vision] "Ideally, give people the option to enlarge text by at least 200 percent"
72. Meet WCAG AA contrast: 4.5:1 for text up to 17 pt; 3:1 for text 18 pt or larger, or bold. Measure titles and metadata over artwork and gradients too.
    - [Accessibility › Vision] "Up to 17 pts | All | 4.5:1" · "18 pts | All | 3:1" · "All | Bold | 3:1"
73. Switch to higher-contrast colors when Increase Contrast is on (`@Environment(\.colorSchemeContrast)`). Test custom glass, colors and animations in dark mode with Increase Contrast, Reduce Transparency and Reduce Motion, one at a time and together.
    - [Accessibility › Vision] "ensure it at least provides a higher contrast color scheme when the system setting Increase Contrast is turned on" · [Dark Mode › Best practices] "in Dark Mode with Increase Contrast and Reduce Transparency turned on (both separately and together)" · [Adopting Liquid Glass › Visual refresh] "Ensure you test your app’s custom elements, colors, and animations with different configurations of these settings."
74. Make tap targets 44×44 pt by default and never smaller than 28×28 pt. Enlarge icon-only buttons with `.frame(minWidth: 44, minHeight: 44)` + `.contentShape(.rect)`.
    - [Accessibility › Mobility] "iOS, iPadOS | 44x44 pt | 28x28 pt"
75. Give every gesture an on-screen alternative: a Close button for swipe-down on the player, a page control for the swiping hero carousel. Avoid custom multi-finger gestures.
    - [Accessibility › Mobility] "if you use a swipe gesture to dismiss a view, also make a button available" · "avoid custom multifinger and multihand gestures"
76. Label everything for VoiceOver and Voice Control: every icon-only button, every poster (title plus type and year), and every custom symbol.
    - [Adopting Liquid Glass › Menus and toolbars] "always specify an accessibility label for each icon" · [Accessibility › Vision] "Describe your app’s interface and content for VoiceOver." · [SF Symbols › Custom symbols] "Provide alternative text labels for custom symbols."
77. Previews and trailers that autoplay need visible play and stop controls, and must follow the system's video autoplay setting (`UIAccessibility.isVideoAutoplayEnabled`).
    - [Accessibility › Cognitive] "Avoid autoplaying audio and video content without also providing controls to start and stop it." · "consider global settings that let people opt out of auto-playing all audio and video"
78. Playback offers subtitles, captions and audio descriptions, and follows the Dim Flashing Lights setting.
    - [Accessibility › Hearing] "Support text-based ways to enjoy audio and video." · [Accessibility › Cognitive] "If your app supports video playback, ensure that it responds appropriately to the Dim Flashing Lights setting."
79. Avoid UI that runs on a timer, such as banners that dismiss themselves or content that advances with no control. Let people dismiss things explicitly.
    - [Accessibility › Cognitive] "Minimize use of time-boxed interface elements." · "Prefer dismissing views with an explicit action."

## Branding & writing

80. Branding never takes space from content: no logo bars, no banners that only show the brand, no logo repeated across screens.
    - [Branding › Best practices] "Ensure branding always defers to content." · "Resist the temptation to display your logo throughout your app or game unless it’s essential for providing context."
81. Express the brand through familiar components and standard patterns: UI where people expect it, standard symbols for common actions, standard navigation and modals.
    - [Branding › Best practices] "Express your brand with familiar components." · "Place UI in expected locations, use standard symbols to represent common actions"
82. Make the app icon simple and layered (solid, filled, overlapping semi-transparent shapes), built in Icon Composer. Let the system add masking, blur and highlights. Never use SF Symbols in the icon or logo.
    - [Adopting Liquid Glass › App icons] "Consider a simplified design comprised of solid, filled, overlapping semi-transparent shapes." · "Let the system handle applying masking, blurring, and other visual effects, rather than factoring them into your design." · [SF Symbols › intro] "the prohibition against using symbols — or images that are confusingly similar — in app icons, logos, or any other trademarked use"
83. Keep one vocabulary. Maintain a list of terms (for example “Library”, “Watchlist”, “Downloads”) and use each one the same way everywhere.
    - [Writing › Getting started] "Create a list of common terms, and reference that list to keep your language consistent."
84. Write short, plain text: cut every word you don't need, avoid jargon, and write with localization in mind.
    - [Writing › Getting started] "If you can use fewer words, do so." · "Choose simple, plain language and write with accessibility and localization in mind, avoiding jargon"
85. Button labels are verbs (“Play”, “Resume”, “Download”), never cute phrases.
    - [Writing › Best practices] "When labeling buttons and links, it’s almost always best to use a verb." · "Prioritize clarity and avoid the temptation to be too cute or clever with your labels."
86. Use one capitalization style for each kind of element, everywhere. Section headers in lists and forms use title-style capitalization, not all caps.
    - [Writing › Best practices] "Choose a style for each UI element type and use it consistently throughout your app" · [Adopting Liquid Glass › Organization and layout] "section headers no longer render entirely in capital letters regardless of the capitalization you provide"
87. Avoid possessives and “we”: write “Favorites”, not “My Favorites”, and “Unable to load content”, not “We’re having trouble…”. Show errors next to the problem, blame no one, and say how to fix it.
    - [Writing › Best practices] "Use possessive pronouns sparingly." · "Avoid using we altogether" · "avoid blame, and be clear about what someone can do to fix it"
88. Empty states (empty Library, no search results, no downloads) say what to do next and offer a button that does it.
    - [Writing › Best practices] "guide people on actions they can take, and give them a button or link to do so if possible"
89. In Settings, use plain labels, explain what a setting does when it's on, and link straight to the system setting instead of describing where it is.
    - [Writing › Best practices] "Describe what it does when turned on, and people can infer the opposite." · "provide a direct link or button, rather than trying to describe its location"
90. Give the search field a placeholder hint (for example “Movies, Shows, People”). On iPhone, say “tap”, never “click”.
    - [Writing › Best practices] "use hint or placeholder text so people know how to format the information" · "not saying “click” for a touch device like iPhone or iPad where you mean “tap.”"

## Anti-patterns the docs warn against

- **Glass in the content layer** (glass posters, cards, shelf backgrounds). [Materials › Liquid Glass] "including it in the content layer can result in unnecessary complexity and a confusing visual hierarchy"
- **Glass on many custom controls.** [Materials › Liquid Glass] "overusing this material in multiple custom controls can provide a subpar user experience by distracting from that content"
- **Glass layered on glass, and crowded controls.** [Adopting Liquid Glass › Controls] "avoid overcrowding or layering Liquid Glass elements on top of each other"
- **Opaque or tinted plates behind controls, custom bar backgrounds, custom sheet and popover backgrounds.** [Layout › Visual hierarchy] "Instead of applying a solid or semi-opaque background color beneath controls, use a scroll edge effect" · [Adopting Liquid Glass › Visual refresh] "Any custom backgrounds and appearances you use in these elements might overlay or interfere with Liquid Glass" · [Adopting Liquid Glass › Windows and modals] "Audit the backgrounds of sheets and popovers."
- **Custom bars and toolbar items that behave differently from the system's**: custom spacers or items, groups that mix text and icons, empty glass capsules left behind when only an item's content is hidden. [Adopting Liquid Glass › Menus and toolbars] "custom items, as these can appear inconsistent with system behavior" · "don’t mix text and icons across items that share a background" · "your app might be hiding the view in the toolbar item instead of the item itself"
- **Hard-coded sizes for standard controls.** [Adopting Liquid Glass › Controls] "don’t hard-code their layout metrics"
- **Choosing a material for the color it seems to add.** [Materials › Standard materials] "Avoid selecting a material or effect based on the apparent color it imparts to your interface"
- **Too much color, or several highlighted controls competing for attention.** [Color › Liquid Glass color] "too much color can be overwhelming and make control labels more difficult to read" · "Refrain from adding color to the background of multiple controls."
- **Brand color everywhere.** [Branding › Best practices] "Using your brand color too broadly can overwhelm your interface and dilute its impact."
- **One color with two meanings, or status shown by color alone.** [Color › Best practices] "using the same or similar color to stylize noninteractive text is confusing" · [Accessibility › Vision] "Offer visual indicators, like distinct shapes or icons, in addition to color"
- **Hard-coded or non-adaptive colors, and custom backgrounds that hide the base/elevated depth.** [Dark Mode › Dark Mode colors] "Avoid using hard-coded color values or colors that don’t adapt." · [Dark Mode › iOS, iPadOS] "Using a custom background color can make it harder for people to perceive these system-provided visual distinctions."
- **An in-app appearance setting.** [Dark Mode › Best practices] "An app-specific appearance mode option creates more work for people"
- **Too many typefaces; Ultralight, Thin or Light weights.** [Typography › Conveying hierarchy] "Mixing too many different typefaces can obscure your information hierarchy and hinder readability" · [Typography › Ensuring legibility] "avoid Ultralight, Thin, and Light font weights, which can be difficult to see"
- **Overloaded screens.** [Layout › Visual hierarchy] "An interface with too much content and too many choices makes it harder to find information quickly"
- **Layouts based on device model or orientation; stretched or letterboxed art.** [Layout › Size classes] "a device’s orientation and type (also called its idiom) aren’t useful for making layout decisions" · [Layout › Adaptability] "don’t change the aspect ratio of the artwork"
- **Unnecessary motion.** [Motion › Best practices] "Don’t add motion for the sake of adding motion." · "Gratuitous or excessive animation can distract people and may make them feel disconnected or physically uncomfortable."
- **Motion on every frequent interaction, and animations people must wait for.** [Motion › Providing feedback] "avoid making people spend extra time paying attention to unnecessary motion every time they interact with it"
- **Too many symbol animations.** [SF Symbols › Animations] "too many animations can overwhelm an interface and distract people"
- **Strong 3D or parallax effects.** [Images › tvOS › Layered images] "Excessive 3D effects can appear unrealistic and jarring."
- **Fast-moving or blinking animation.** [Accessibility › Cognitive] "it can be distracting, cause dizziness, and in some cases even result in epileptic episodes"
- **Autoplay without controls; UI on a timer.** [Accessibility › Cognitive] "Avoid autoplaying audio and video content without also providing controls to start and stop it." · "Views and controls that auto-dismiss on a timer can be problematic"
- **Brand-only elements, repeated logos, a branded launch screen.** [Branding › Best practices] "an element that does nothing but display a brand asset can mean there’s less room for the content" · "A launch screen disappears too quickly to convey any information"
- **Cute labels, “Click here”, “oops”, error messages that don't help.** [Writing › Best practices] "avoid using “Click here” in favor of more descriptive words or phrases" · "Interjections like “oops!” or “uh-oh” are typically unnecessary and can sound insincere." · "Avoid robotic error messages with no helpful information"

**What these files don't say:** none of them uses the terms "decorative borders" or "competing focal points". The closest guidance is:
- Group items with negative space, container shapes or separator lines (Layout › Visual hierarchy).
- Add a slight border only where an icon with dark edges would otherwise disappear (Dark Mode › Icons and images).
- Reserve color emphasis for one primary action (Color › Liquid Glass color).
- watchOS only: use background color [Color › watchOS] "rather than as a solely visual flourish".
- visionOS only: avoid [Accessibility › visionOS] "demanding the viewer’s attention in different locations in quick succession".

The files also give no animation durations or curves, and no numeric iOS margins. The only iOS spacing numbers are the 12 and 24 pt padding in rule 11.

## iOS default text styles (Dynamic Type "Large", the default)

Source: [Typography › Specifications › iOS, iPadOS Dynamic Type sizes › Large (default)]

| Style (SwiftUI) | Weight | Size (pt) | Leading (pt) | Emphasized weight (`.bold()`) |
|---|---|---|---|---|
| Large Title (`.largeTitle`) | Regular | 34 | 41 | Bold |
| Title 1 (`.title`) | Regular | 28 | 34 | Bold |
| Title 2 (`.title2`) | Regular | 22 | 28 | Bold |
| Title 3 (`.title3`) | Regular | 20 | 25 | Semibold |
| Headline (`.headline`) | Semibold | 17 | 22 | Semibold |
| Body (`.body`) | Regular | 17 | 22 | Semibold |
| Callout (`.callout`) | Regular | 16 | 21 | Semibold |
| Subheadline (`.subheadline`; labeled "Subhead" in the file) | Regular | 15 | 20 | Semibold |
| Footnote (`.footnote`) | Regular | 13 | 18 | Semibold |
| Caption 1 (`.caption`) | Regular | 12 | 16 | Semibold |
| Caption 2 (`.caption2`) | Regular | 11 | 13 | Semibold |

- **Range to design for**, from the same Specifications tables:
  - Body: 14 pt (xSmall) → 17 (Large) → 23 (xxxLarge) → 28 (AX1) → 53 pt (AX5).
  - Large Title: 31 → 34 → 40 → 44 → 60 pt.
  - Caption 2 stays at 11 pt from xSmall through Large.
- **iOS minimums:** 17 pt default and 11 pt minimum; Accessibility gives the same values. [Typography › Ensuring legibility]
- **SF Pro tracking, for mockups only** (the system applies it at runtime) [Typography › Tracking values › SF Pro]: 11 pt +0.06 · 12 pt 0 · 13 pt −0.08 · 15 pt −0.23 · 16 pt −0.31 · 17 pt −0.43 · 20 pt −0.45 · 22 pt −0.26 · 28 pt +0.38 · 34 pt +0.40 (points).

## Source key

| Label | File |
|---|---|
| Layout | layout.txt |
| Typography | typography.txt |
| Color | color.txt |
| Dark Mode | dark-mode.txt |
| Materials | materials.txt |
| Motion | motion.txt |
| Images | images.txt |
| Accessibility | accessibility.txt |
| Branding | branding.txt |
| Writing | writing.txt |
| SF Symbols | sf-symbols.txt |
| Liquid Glass | technologyoverviews_liquid-glass.txt |
| Adopting Liquid Glass | technologyoverviews_adopting-liquid-glass.txt |
| Applying Liquid Glass to custom views | swiftui_applying-liquid-glass-to-custom-views.txt |

- "intro" means the text before a page's first section heading.
- tvOS, watchOS and visionOS sections are cited only where a rule is marked as applied by analogy or as platform-only.
