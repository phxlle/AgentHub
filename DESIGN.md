---
name: AgentHub
description: A quiet operations desk for local AI coding workflows on macOS.
colors:
  signal-slate: "#A0AEC0"
  graphite-channel: "#2D3748"
  cool-paper: "#CBD5E0"
  ink-canvas: "#0D0D0D"
  terminal-well: "#080808"
  mist-text: "#E2E8F0"
  warm-workspace: "#FAF9F5"
typography:
  headline:
    fontFamily: "Geist, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "13px"
    fontWeight: 700
    lineHeight: 1.25
  title:
    fontFamily: "Geist, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "14px"
    fontWeight: 600
    lineHeight: 1.3
  body:
    fontFamily: "Geist, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: "Geist, -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: "11px"
    fontWeight: 500
    lineHeight: 1.3
  code:
    fontFamily: "JetBrains Mono, ui-monospace, SFMono-Regular, monospace"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.4
rounded:
  sm: "6px"
  md: "10px"
  lg: "14px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
components:
  button-primary:
    backgroundColor: "{colors.signal-slate}"
    textColor: "{colors.ink-canvas}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "4px 8px"
  button-secondary:
    backgroundColor: "{colors.graphite-channel}"
    textColor: "{colors.mist-text}"
    typography: "{typography.label}"
    rounded: "{rounded.sm}"
    padding: "4px 8px"
  terminal-panel:
    backgroundColor: "{colors.terminal-well}"
    textColor: "{colors.mist-text}"
    typography: "{typography.code}"
    rounded: "{rounded.md}"
    padding: "12px"
---

# Design System: AgentHub

## 1. Overview

**Creative North Star: "The Operations Desk"**

AgentHub is a quiet, precise workspace where operational truth is always closer than decoration.
The interface should feel like a well-arranged macOS desk for long sessions: compact enough to scan,
stable enough to trust, and direct enough that an experienced developer never has to decode the UI.

Structure comes from alignment, typography, tonal surfaces, and predictable native controls. Terminals,
diffs, tests, review state, and approval boundaries are first-class work surfaces. AgentHub explicitly
rejects the neon AI control room, chat-first assistant, interchangeable card wall, and generic SaaS
dashboard.

**Key Characteristics:**

- Native macOS behavior with dense, deliberate information hierarchy.
- One clear ownership path from ticket to branch to implementer and reviewer.
- Terminal-first work surfaces with concise operational labels.
- Keyboard fluency, VoiceOver semantics, and color-independent state communication.
- Progressive detail instead of decorative metrics or persistent visual noise.

## 2. Colors

The palette is cool, neutral, and low-chroma so source code, state, and human decisions remain the focus.

### Primary

- **Signal Slate** (#A0AEC0): restrained emphasis for the current selection, primary actions, and terminal cursor.

### Secondary

- **Graphite Channel** (#2D3748): selected rows, secondary actions, and structural surfaces in dark mode.

### Tertiary

- **Cool Paper** (#CBD5E0): quiet dividers, inactive emphasis, and secondary content where stronger contrast is unnecessary.

### Neutral

- **Ink Canvas** (#0D0D0D): canonical dark workspace background.
- **Terminal Well** (#080808): recessed terminal and code surfaces.
- **Mist Text** (#E2E8F0): primary terminal text and high-contrast content on dark surfaces.
- **Warm Workspace** (#FAF9F5): canonical light workspace background.

### Named Rules

**The Signal Is Rare Rule.** Signal Slate marks selection or action, not decoration. A screen should have
one dominant current action and one unmistakable current selection.

**The State Has Words Rule.** Never communicate implementing, reviewing, blocked, or approved through
color alone. Pair every state color with text and, when helpful, a system icon.

## 3. Typography

**Display Font:** Geist with the macOS system sans-serif fallback
**Body Font:** Geist with the macOS system sans-serif fallback
**Label/Mono Font:** JetBrains Mono with the macOS monospace fallback

**Character:** Geist keeps interface language compact and neutral. JetBrains Mono gives branches, paths,
session identifiers, commands, and diffs a visibly technical register without turning the whole app into
a terminal.

### Hierarchy

- **Headline** (700, 13px, 1.25): panel and section headings only.
- **Title** (600, 14px, 1.3): ticket keys, branch names, and the primary title of the current work surface.
- **Body** (400, 12px, 1.45): summaries, explanations, errors, and supporting operational detail.
- **Label** (500, 11px, 1.3): controls, roles, metadata labels, and compact status text.
- **Code** (400, 11px, 1.4): paths, branches, commands, hashes, session identifiers, and terminal-adjacent data.

### Named Rules

**The Mono Means Machine Rule.** Use JetBrains Mono only for values produced by or addressed to tools.
Human-facing descriptions and decisions stay in Geist.

## 4. Elevation

AgentHub is flat by default. Depth comes from tonal layering, 1px separators, and the recessed Terminal
Well surface. Shadows are reserved for transient macOS overlays such as menus, sheets, and command
palettes, where they clarify stacking rather than decorate content.

### Named Rules

**The Surface Before Shadow Rule.** First use background contrast and a separator. Add a shadow only when
one surface temporarily floats above another.

## 5. Components

Components feel refined and restrained. Their state should be legible before their styling becomes noticeable.

### Buttons

- **Shape:** compact rounded rectangle using the small 6px radius.
- **Primary:** Signal Slate on Ink Canvas with 4px vertical and 8px horizontal padding.
- **Hover / Focus:** a 150ms tonal shift; keyboard focus uses the native macOS focus treatment and remains visible at high contrast.
- **Secondary / Ghost:** Graphite Channel or transparent; use a 1px neutral separator when a boundary is needed.

### Chips

- **Style:** compact role or state label with a 6px radius, subtle tonal background, text, and optional system icon.
- **State:** selection changes both surface and label emphasis; never use a dot without a textual state.

### Cards / Containers

- **Corner Style:** 10px for panels and 6px for nested rows.
- **Background:** Ink Canvas, Terminal Well, or native system surfaces according to context.
- **Shadow Strategy:** no shadow at rest.
- **Border:** 1px neutral separator only when adjacent tonal surfaces are insufficient.
- **Internal Padding:** 12px for rows and cards, 16px for major panels.

### Inputs / Fields

- **Style:** native macOS field behavior, 6px radius, compact vertical rhythm, and a quiet surface boundary.
- **Focus:** native focus ring with sufficient contrast in both appearances.
- **Error / Disabled:** pair visual treatment with concise text; keep disabled content readable.

### Navigation

Use a stable split-view hierarchy: tickets on the left, branch workflow in the center, and the active
terminal or artifact on the right. Selected rows use Signal Slate or Graphite Channel tonally, not a
thick colored stripe. Keyboard selection and VoiceOver reading order follow the visible hierarchy.

### Branch Workflow Row

Each branch has one continuous row showing repository, branch, base branch, implementer, reviewer,
tests, review cycle, and pending human action. Expand the row for terminals and artifacts instead of
adding a separate card for every agent.

## 6. Do's and Don'ts

### Do:

- **Do** use the 4, 8, 12, 16, and 20px spacing scale consistently.
- **Do** keep ticket, branch, provider, role, test state, and approval state visible in scan order.
- **Do** use native macOS controls, keyboard shortcuts, tooltips, and VoiceOver labels.
- **Do** keep terminals first-class and use Terminal Well (#080808) as their recessed surface.
- **Do** pair every status color with a textual label and meaningful system icon.
- **Do** show read-only roles and human approval boundaries before an action can run.

### Don't:

- **Don't** make AgentHub resemble a neon AI control room.
- **Don't** use a chat-first assistant as the primary navigation model.
- **Don't** build a wall of interchangeable cards or a generic SaaS dashboard.
- **Don't** use decorative gradients, glassmorphism, or animated agent avatars.
- **Don't** add oversized metrics or vague status language.
- **Don't** use novelty interactions that obscure standard macOS affordances.
- **Don't** use a colored side stripe thicker than 1px to indicate selection.
- **Don't** nest cards when a row, divider, or tonal surface communicates the same hierarchy.
