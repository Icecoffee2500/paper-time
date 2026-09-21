/**
 * The app's icons, drawn here.
 *
 * SF Symbols are Apple's, licensed for use in apps on Apple's platforms and
 * nowhere else, so a Windows or Linux build cannot carry them. These are drawn
 * to the same rules the Mac's set follows — a 16-point grid, a 1.4 stroke,
 * round caps and joins, optical rather than geometric centres — so the toolbar
 * reads as the same toolbar rather than as a different app wearing its layout.
 *
 * Each entry is the inside of an `<svg>`; `icon()` wraps it.
 */

const SHAPES: Record<string, string> = {
  // -------------------------------------------------------------- the panes
  // A window with a panel down one side: the divider, and two short rules
  // standing for the list inside it.
  'sidebar.left': `
    <rect x="1.6" y="2.8" width="12.8" height="10.4" rx="2.4"/>
    <path d="M6.1 2.8v10.4"/>
    <path d="M3.5 6.2h1.4M3.5 8.4h1.4"/>`,
  'sidebar.right': `
    <rect x="1.6" y="2.8" width="12.8" height="10.4" rx="2.4"/>
    <path d="M9.9 2.8v10.4"/>
    <path d="M11.1 6.2h1.4M11.1 8.4h1.4"/>`,
  // A portrait card with a list on it — the stack of papers.
  'list.bullet.rectangle.portrait': `
    <rect x="3.2" y="1.7" width="9.6" height="12.6" rx="2.2"/>
    <circle cx="5.9" cy="5.4" r="0.72" fill="currentColor" stroke="none"/>
    <circle cx="5.9" cy="8" r="0.72" fill="currentColor" stroke="none"/>
    <circle cx="5.9" cy="10.6" r="0.72" fill="currentColor" stroke="none"/>
    <path d="M7.9 5.4h2.6M7.9 8h2.6M7.9 10.6h2.6"/>`,
  // A page with writing on it — the paper you are reading.
  'text.page': `
    <path d="M3.4 1.9h5.2l4 4v8.2a1.4 1.4 0 0 1-1.4 1.4H3.4A1.4 1.4 0 0 1 2 14.1V3.3a1.4 1.4 0 0 1 1.4-1.4Z"/>
    <path d="M8.5 1.9v3a1.1 1.1 0 0 0 1.1 1.1h3"/>
    <path d="M4.6 8.6h6.3M4.6 11h4.4"/>`,

  // ------------------------------------------------------------- navigation
  'chevron.left': `<path d="M10 3.4 5.4 8l4.6 4.6"/>`,
  'chevron.right': `<path d="M6 3.4 10.6 8 6 12.6"/>`,
  'chevron.down': `<path d="M3.6 6.2 8 10.6l4.4-4.4"/>`,
  'chevron.up': `<path d="M3.6 10 8 5.6l4.4 4.4"/>`,
  magnifyingglass: `
    <circle cx="7.2" cy="7.2" r="4.4"/>
    <path d="M10.5 10.5 14 14"/>`,
  plus: `<path d="M8 3.2v9.6M3.2 8h9.6"/>`,
  ellipsis: `
    <circle cx="3.4" cy="8" r="1.05" fill="currentColor" stroke="none"/>
    <circle cx="8" cy="8" r="1.05" fill="currentColor" stroke="none"/>
    <circle cx="12.6" cy="8" r="1.05" fill="currentColor" stroke="none"/>`,

  // ---------------------------------------------------------- library rows
  // A tray: where every paper lands.
  'tray.full': `
    <path d="M2 9.6h2.8l1 1.7h4.4l1-1.7H14"/>
    <path d="M2 9.6V12a1.6 1.6 0 0 0 1.6 1.6h8.8A1.6 1.6 0 0 0 14 12V9.6"/>
    <path d="M4.3 6.6h7.4M5.4 3.8h5.2"/>`,
  circle: `<circle cx="8" cy="8" r="5.2"/>`,
  'circle.lefthalf.filled': `
    <circle cx="8" cy="8" r="5.2"/>
    <path d="M8 2.8a5.2 5.2 0 0 0 0 10.4Z" fill="currentColor" stroke="none"/>`,
  'checkmark.circle': `
    <circle cx="8" cy="8" r="5.2"/>
    <path d="M5.6 8.2 7.3 9.9l3.2-3.6"/>`,
  star: `<path d="m8 2.4 1.72 3.49 3.85.56-2.79 2.72.66 3.83L8 11.2l-3.44 1.8.66-3.83-2.79-2.72 3.85-.56Z"/>`,
  'star.fill': `<path d="m8 2.4 1.72 3.49 3.85.56-2.79 2.72.66 3.83L8 11.2l-3.44 1.8.66-3.83-2.79-2.72 3.85-.56Z" fill="currentColor"/>`,
  'exclamationmark.triangle': `
    <path d="M6.85 2.9 1.9 11.4a1.3 1.3 0 0 0 1.13 1.96h9.94a1.3 1.3 0 0 0 1.13-1.96L9.15 2.9a1.3 1.3 0 0 0-2.3 0Z"/>
    <path d="M8 6.2v2.7"/>
    <circle cx="8" cy="11" r="0.72" fill="currentColor" stroke="none"/>`,
  // A slip of paper with a folded corner: the slip-box.
  note: `
    <path d="M2.6 3.4a1.4 1.4 0 0 1 1.4-1.4h8a1.4 1.4 0 0 1 1.4 1.4v6.1l-3.9 3.9H4a1.4 1.4 0 0 1-1.4-1.4Z"/>
    <path d="M13.4 9.5H10.9a1.4 1.4 0 0 0-1.4 1.4v2.5"/>
    <path d="M5.2 5.6h5.6M5.2 8h3.6"/>`,
  folder: `
    <path d="M1.9 4.4a1.5 1.5 0 0 1 1.5-1.5h2.3l1.4 1.7h5.5a1.5 1.5 0 0 1 1.5 1.5v5.5a1.5 1.5 0 0 1-1.5 1.5H3.4a1.5 1.5 0 0 1-1.5-1.5Z"/>`,
  'plus.circle': `
    <circle cx="8" cy="8" r="5.6"/>
    <path d="M8 5.4v5.2M5.4 8h5.2"/>`,
  person: `
    <circle cx="8" cy="5.5" r="2.6"/>
    <path d="M3 13.4a5 5 0 0 1 10 0"/>`,
  tag: `
    <path d="M7.4 2.2H12a1.8 1.8 0 0 1 1.8 1.8v4.6a1.3 1.3 0 0 1-.38.92l-4.9 4.9a1.3 1.3 0 0 1-1.84 0L2.36 9.32a1.3 1.3 0 0 1 0-1.84l4.9-4.9a1.3 1.3 0 0 1 .14-.12Z"/>
    <circle cx="10.4" cy="5.6" r="1.1"/>`,
  // Three papers and the lines between them: the citation graph.
  graph: `
    <circle cx="3.6" cy="11.8" r="1.9"/>
    <circle cx="12.4" cy="10.4" r="1.9"/>
    <circle cx="7.6" cy="3.6" r="1.9"/>
    <path d="M5.1 10.5 6.6 5.4M9.2 4.7l2.4 4M5.5 11.9h5"/>`,

  // ------------------------------------------------------------ the toolbar
  'arrow.clockwise': `
    <path d="M13.2 8a5.2 5.2 0 1 1-1.6-3.75"/>
    <path d="M13.4 2.4v3.1h-3.1"/>`,
  'square.and.arrow.up': `
    <path d="M8 2.4v7.2"/>
    <path d="M5.3 5 8 2.3 10.7 5"/>
    <path d="M3.6 7.8v4.4a1.4 1.4 0 0 0 1.4 1.4h6a1.4 1.4 0 0 0 1.4-1.4V7.8"/>`,
  'arrow.up.arrow.down': `
    <path d="M4.6 2.6v10.8M2.4 4.8 4.6 2.6l2.2 2.2"/>
    <path d="M11.4 13.4V2.6M13.6 11.2l-2.2 2.2-2.2-2.2"/>`,
  'textformat.size': `
    <path d="M2.2 12.4 5.4 4l3.2 8.4"/>
    <path d="M3.2 9.8h4.4"/>
    <path d="M10.2 12.4 12.3 7l2.1 5.4"/>
    <path d="M10.9 10.7h2.8"/>`,
  trash: `
    <path d="M2.8 4.2h10.4"/>
    <path d="M6.2 4.2V3a1 1 0 0 1 1-1h1.6a1 1 0 0 1 1 1v1.2"/>
    <path d="M4.1 4.2 4.7 13a1.2 1.2 0 0 0 1.2 1.1h4.2a1.2 1.2 0 0 0 1.2-1.1l.6-8.8"/>
    <path d="M6.7 6.8v4.6M9.3 6.8v4.6"/>`,
  info: `
    <circle cx="8" cy="8" r="5.6"/>
    <path d="M8 7.2v3.6"/>
    <circle cx="8" cy="5.2" r="0.72" fill="currentColor" stroke="none"/>`,
  checkmark: `<path d="M3 8.4 6.4 11.8 13 5.2"/>`,
  'doc.on.doc': `
    <rect x="5.4" y="1.9" width="8.2" height="9.4" rx="1.6"/>
    <path d="M10.6 11.3v1.6a1.6 1.6 0 0 1-1.6 1.6H4a1.6 1.6 0 0 1-1.6-1.6V5.9A1.6 1.6 0 0 1 4 4.3h1.4"/>`,
  'folder.badge.gearshape': `
    <path d="M1.9 4.4a1.5 1.5 0 0 1 1.5-1.5h2.3l1.4 1.7h5.5a1.5 1.5 0 0 1 1.5 1.5v2.1"/>
    <path d="M1.9 4.4v7.2a1.5 1.5 0 0 0 1.5 1.5h4.2"/>
    <circle cx="11.6" cy="11.6" r="1.5"/>
    <path d="M11.6 8.9v.8M11.6 13.5v.8M13.9 10.2l-.7.4M10 12.6l-.7.4M13.9 13l-.7-.4M10 10.6l-.7-.4"/>`,

  // ------------------------------------------------------- the window's own
  'window.minimize': `<path d="M3 8h10"/>`,
  'window.maximize': `<rect x="3.2" y="3.2" width="9.6" height="9.6" rx="1.2"/>`,
  'window.restore': `
    <rect x="3" y="5.2" width="7.8" height="7.8" rx="1.2"/>
    <path d="M5.6 5.2V4.3A1.3 1.3 0 0 1 6.9 3h5.2a1.3 1.3 0 0 1 1.3 1.3v5.2a1.3 1.3 0 0 1-1.3 1.3h-.9"/>`,
  'window.close': `<path d="M3.6 3.6 12.4 12.4M12.4 3.6 3.6 12.4"/>`,

  // ------------------------------------------------------ the drawing tools
  // An arrow pointer, the way every canvas draws "select".
  cursorarrow: `
    <path d="M3.4 2.2 12 8.1l-3.7.8-1.9 3.4Z"/>`,
  // A nib, not a pencil: this writes, it does not sketch.
  pen: `
    <path d="M11.7 2.3a1.9 1.9 0 0 1 2.7 2.7l-7.4 7.4-3.5.8.8-3.5Z"/>
    <path d="M10.3 3.7l2.7 2.7"/>`,
  highlighter: `
    <path d="M9.6 2.6 13.4 6.4l-5.5 5.5H4.1L2.9 10.7Z"/>
    <path d="M2.6 13.9h5.6"/>`,
  eraser: `
    <path d="M6.4 13.4H3.3a1.3 1.3 0 0 1-.92-2.22l6.5-6.5a1.3 1.3 0 0 1 1.84 0l2.9 2.9a1.3 1.3 0 0 1 0 1.84l-4 4"/>
    <path d="M6.2 7.2 11 12"/>
    <path d="M6.4 13.4h7.2"/>`,
  rectangle: `<rect x="2.3" y="3.6" width="11.4" height="8.8" rx="1.8"/>`,
  ellipse: `<ellipse cx="8" cy="8" rx="5.7" ry="4.6"/>`,
  arrow: `
    <path d="M2.6 13.4 13.4 2.6"/>
    <path d="M7.9 2.6h5.5v5.5"/>`,
  line: `<path d="M2.6 13.4 13.4 2.6"/>`,
  textbox: `
    <path d="M3 5.1V3.4h10v1.7"/>
    <path d="M8 3.4v9.2"/>
    <path d="M6.1 12.6h3.8"/>`,
  // A frame drawn round what is already there.
  border: `
    <rect x="2.4" y="2.4" width="11.2" height="11.2" rx="1.8" stroke-dasharray="2.4 2"/>
    <path d="M6 8h4" stroke-dasharray="0"/>`,

  // ------------------------------------------------------ the style choices
  'line.solid': `<path d="M2 8h12"/>`,
  'line.dashed': `<path d="M2 8h3M6.5 8h3M11 8h3"/>`,
  'line.dotted': `<path d="M2.4 8h.1M5 8h.1M7.6 8h.1M10.2 8h.1M12.8 8h.1" stroke-width="2"/>`,
  'corner.sharp': `<path d="M3 13V5a2 2 0 0 1 2-2h8"/>`,
  'corner.round': `<path d="M3 13V8a5 5 0 0 1 5-5h5"/>`,
  'head.none': `<path d="M2.5 8h11"/>`,
  'head.arrow': `<path d="M2.5 8h11M9.6 4.6 13.5 8l-3.9 3.4"/>`,
  'head.triangle': `<path d="M2.5 8h7.6"/><path d="M9.8 4.9 14 8l-4.2 3.1Z" fill="currentColor"/>`,
  'head.bar': `<path d="M2.5 8h11M13 4.6v6.8"/>`,
  'head.dot': `<path d="M2.5 8h8.4"/><circle cx="12.4" cy="8" r="1.9" fill="currentColor" stroke="none"/>`,
  'text.small': `<path d="M4.4 11.6 7 5.4l2.6 6.2M5.2 9.9h3.6"/>`,
  'text.medium': `<path d="M3.4 12.4 7 3.8l3.6 8.6M4.6 10.1h4.8"/>`,
  'text.large': `<path d="M2.4 13.2 7 2.6l4.6 10.6M4 10.3h6"/>`,
  'front': `
    <rect x="2.4" y="2.4" width="7.6" height="7.6" rx="1.4" stroke-dasharray="2 1.8"/>
    <rect x="6" y="6" width="7.6" height="7.6" rx="1.4" fill="currentColor" fill-opacity="0.18"/>`,
  'back': `
    <rect x="6" y="6" width="7.6" height="7.6" rx="1.4" stroke-dasharray="2 1.8"/>
    <rect x="2.4" y="2.4" width="7.6" height="7.6" rx="1.4" fill="currentColor" fill-opacity="0.18"/>`,

  // ------------------------------------------------------ the rack's ends
  'arrow.uturn.backward': `
    <path d="M5.2 6.4h5.6a3.2 3.2 0 0 1 0 6.4H7.6"/>
    <path d="M7.6 3.8 5 6.4l2.6 2.6"/>`,
  'arrow.uturn.forward': `
    <path d="M10.8 6.4H5.2a3.2 3.2 0 0 0 0 6.4h3.2"/>
    <path d="M8.4 3.8 11 6.4 8.4 9"/>`,
  minus: `<path d="M3.6 8h8.8"/>`,
  'slash.circle': `
    <circle cx="8" cy="8" r="5.2"/>
    <path d="M4.4 11.6 11.6 4.4"/>`,
  'chevron.up.chevron.down': `<path d="M5.4 6.2 8 3.6l2.6 2.6M5.4 9.8 8 12.4l2.6-2.6"/>`,

  // ------------------------------------------- the inspector's alignments
  // A rule and two bars laid against it: which edge the selection lines up on.
  'align.horizontal.left': `
    <path d="M3 2.6v10.8"/>
    <rect x="5" y="4.4" width="8" height="2.6" rx="0.8" fill="currentColor" stroke="none"/>
    <rect x="5" y="9" width="5" height="2.6" rx="0.8" fill="currentColor" stroke="none"/>`,
  'align.horizontal.center': `
    <path d="M8 2.6v10.8"/>
    <rect x="3.5" y="4.4" width="9" height="2.6" rx="0.8" fill="currentColor" stroke="none"/>
    <rect x="5.5" y="9" width="5" height="2.6" rx="0.8" fill="currentColor" stroke="none"/>`,
  'align.horizontal.right': `
    <path d="M13 2.6v10.8"/>
    <rect x="3" y="4.4" width="8" height="2.6" rx="0.8" fill="currentColor" stroke="none"/>
    <rect x="6" y="9" width="5" height="2.6" rx="0.8" fill="currentColor" stroke="none"/>`,
  'align.vertical.top': `
    <path d="M2.6 3h10.8"/>
    <rect x="4.4" y="5" width="2.6" height="8" rx="0.8" fill="currentColor" stroke="none"/>
    <rect x="9" y="5" width="2.6" height="5" rx="0.8" fill="currentColor" stroke="none"/>`,
  'align.vertical.center': `
    <path d="M2.6 8h10.8"/>
    <rect x="4.4" y="3.5" width="2.6" height="9" rx="0.8" fill="currentColor" stroke="none"/>
    <rect x="9" y="5.5" width="2.6" height="5" rx="0.8" fill="currentColor" stroke="none"/>`,
  'align.vertical.bottom': `
    <path d="M2.6 13h10.8"/>
    <rect x="4.4" y="3" width="2.6" height="8" rx="0.8" fill="currentColor" stroke="none"/>
    <rect x="9" y="6" width="2.6" height="5" rx="0.8" fill="currentColor" stroke="none"/>`,

  // ------------------------------------------------ the inspector's layout
  'square.dashed': `<rect x="2.8" y="2.8" width="10.4" height="10.4" rx="1.8" stroke-dasharray="2.2 2"/>`,
  'arrow.down': `<path d="M8 2.8v10.4M3.8 9 8 13.2 12.2 9"/>`,
  'arrow.right': `<path d="M2.8 8h10.4M9 3.8 13.2 8 9 12.2"/>`,
  'text.alignleft': `<path d="M2.6 4h10.8M2.6 7h7M2.6 10h10.8M2.6 13h7"/>`,
  'text.aligncenter': `<path d="M2.6 4h10.8M4.5 7h7M2.6 10h10.8M4.5 13h7"/>`,
  'text.alignright': `<path d="M2.6 4h10.8M6.4 7h7M2.6 10h10.8M6.4 13h7"/>`,
  // As wide as its words, or as tall as they need.
  'arrow.left.and.right.text.vertical': `
    <path d="M2.4 8h11.2M4.6 5.8 2.4 8l2.2 2.2M11.4 5.8 13.6 8l-2.2 2.2"/>
    <path d="M6 3h4M6 13h4"/>`,
  'arrow.up.and.down.text.horizontal': `
    <path d="M8 2.4v11.2M5.8 4.6 8 2.4l2.2 2.2M5.8 11.4 8 13.6l2.2-2.2"/>
    <path d="M3 6v4M13 6v4"/>`,

  // ------------------------------------------------ the inspector's actions
  'rectangle.3.group': `
    <rect x="2" y="2.4" width="5.2" height="5.2" rx="1.2"/>
    <rect x="8.8" y="2.4" width="5.2" height="5.2" rx="1.2"/>
    <rect x="2" y="9.2" width="12" height="4.4" rx="1.2"/>`,
  'rectangle.3.group.bubble': `
    <rect x="2" y="2.4" width="5.2" height="5.2" rx="1.2" stroke-dasharray="1.8 1.6"/>
    <rect x="8.8" y="2.4" width="5.2" height="5.2" rx="1.2" stroke-dasharray="1.8 1.6"/>
    <rect x="2" y="9.2" width="12" height="4.4" rx="1.2" stroke-dasharray="1.8 1.6"/>`,
  'number.square': `
    <rect x="2.2" y="2.2" width="11.6" height="11.6" rx="2.2"/>
    <path d="M6.4 5v6M9.6 5v6M5 6.6h6M5 9.4h6"/>`,
  'rectangle.split.3x1': `
    <rect x="2" y="3.4" width="12" height="9.2" rx="1.8"/>
    <path d="M6 3.4v9.2M10 3.4v9.2"/>`,
  'plus.square.on.square': `
    <rect x="5.4" y="1.9" width="8.2" height="8.2" rx="1.6"/>
    <path d="M9.5 4.2v3.6M7.7 6h3.6"/>
    <path d="M10.6 10.1v1.4a1.6 1.6 0 0 1-1.6 1.6H4a1.6 1.6 0 0 1-1.6-1.6V6.1A1.6 1.6 0 0 1 4 4.5h1.4"/>`,
  'square.3.layers.3d.top.filled': `
    <path d="m8 2.6 5.4 2.7L8 8 2.6 5.3Z" fill="currentColor"/>
    <path d="M2.6 8 8 10.7 13.4 8M2.6 10.7 8 13.4l5.4-2.7"/>`,
  'square.3.layers.3d.bottom.filled': `
    <path d="M2.6 5.3 8 2.6l5.4 2.7L8 8M2.6 8 8 10.7 13.4 8"/>
    <path d="m8 10.7 5.4-2.7v2.7L8 13.4l-5.4-2.7V8Z" fill="currentColor"/>`,
}

/**
 * The drawing tools, as Figma draws them: a 20-point box, a 1.6 stroke,
 * round joins, no fill — the outline of a pointer, a hash for a frame, a
 * square, a nib, a serif T. The same paths as the Mac's `FigmaIcon`, point
 * for point, so the five buttons read as one set on every desktop.
 */
const FIGMA: Record<string, string> = {
  // The pointer, outlined.
  select: `<path d="M4.5 2.5 16.5 10.5 11 11.8 14 17.4 11.6 18.5 8.7 12.9 4.5 16.5Z"/>`,
  frame: `<path d="M7 3v14M13 3v14M3 7h14M3 13h14"/>`,
  rectangle: `<rect x="3.5" y="4.5" width="13" height="11" rx="1.5"/>`,
  ellipse: `<circle cx="10" cy="10" r="6.5"/>`,
  line: `<path d="M4 16 16 4"/>`,
  arrow: `<path d="M4 16 16 4M9 4h7v7"/>`,
  // The nib: a pointed body, a hole, and the tail it sits on.
  pen: `
    <path d="M10 2.5 15.5 10.5 13 15.5H7L4.5 10.5Z"/>
    <path d="M10 15.5v3"/>
    <circle cx="10" cy="10.5" r="1.5" stroke-width="1.3"/>`,
  // A marker: a slanted body and a flat tip.
  highlighter: `
    <path d="M12.5 3 17 7.5 9 15.5 4.5 11Z"/>
    <path d="M4.5 11 3 15.5 7.5 17 9 15.5"/>
    <path d="M3 18.5h14"/>`,
  eraser: `
    <path d="M11.5 3.5 17 9l-7.5 7.5H5l-2-2V12Z"/>
    <path d="M7.5 7.5 13 13"/>
    <path d="M9 18.5h8"/>`,
  // A serif T.
  text: `<path d="M4 5.5v-2h12v2M10 3.5v13M7 16.5h6"/>`,
}

/** One of the rack's tool icons; `name` is the tool's own name. */
export function figmaIcon(name: string): string {
  const shape = FIGMA[name]
  if (!shape) return ''
  return `<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6"
    stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${shape}</svg>`
}

export type IconName = keyof typeof SHAPES | string

/** One icon as SVG markup, sized by CSS rather than by an attribute. */
export function icon(name: IconName, extra = ''): string {
  const shape = SHAPES[name]
  if (!shape) return ''
  return `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"
    stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" ${extra}>${shape}</svg>`
}

export function hasIcon(name: string): boolean {
  return name in SHAPES
}
