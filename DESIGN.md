---
version: alpha
name: "Darckware Remoto"
description: "A focused Windows deployment wizard for secure Darckware remote-access setup."
colors:
  canvas: "#0B0D10"
  surface: "#12151A"
  primary: "#5CF2C4"
  secondary: "#3DAEFF"
  text: "#F2F4F7"
  muted: "#7C8794"
  error: "#FF6B7A"
  warning: "#F2C94C"
typography:
  sans:
    fontFamily: "Segoe UI, sans-serif"
  mono:
    fontFamily: "Cascadia Mono, Consolas, monospace"
rounded:
  DEFAULT: "0.5rem"
  sm: "0.25rem"
  md: "0.5rem"
  lg: "0.75rem"
spacing:
  control-gap: "0.75rem"
  section-gap: "1.5rem"
  page-padding: "2rem"
components:
  wizard: { }
  button: { }
  input: { }
  status: { }
---

# Darckware Remoto Design System

## Overview

### Creative North Star

The interface should feel like a careful field technician's deployment console: dark, calm, explicit about every network change, and unmistakably Darckware without resembling a gaming launcher or neon dashboard.

### Product context and register

- **Audience and primary job:** Portuguese-speaking IT operators installing secure remote access on Windows 11.
- **Target market and evidence:** the repository brief and existing Darckware brand guide; no geography-specific business behavior is inferred.
- **Locale and language policy:** Brazilian Portuguese UI; vendor names and technical identifiers remain unchanged.
- **Usage scene:** elevated desktop setup, infrequent but security-sensitive, with keyboard and mouse.
- **Register:** product-first with a restrained brand header.
- **Memorable signature:** a left-side installation path whose active stage shifts from muted gray to the Darckware mint/blue accent.
- **Restraint:** native controls, validation, confirmation, progress, and failures remain familiar Windows UI.
- **Anti-references:** no glassmorphism, decorative terminal noise, excessive glow, or hidden advanced behavior.
- **Token ownership/runtime mapping:** this file mirrors the approved brand palette; `Installer.UI.psm1` is the WinForms runtime owner and defines each matching `System.Drawing.Color` once.

## Colors

`canvas` is the window background and `surface` separates the navigation rail and field groups. Mint is the primary safe action; blue is focus/information. Text uses the approved light and muted values. Error and warning colors always appear with explanatory text, never alone.

## Typography

Segoe UI is the Windows-native body and control family. Cascadia Mono or Consolas is reserved for IDs, IP addresses, and paths. Headings use weight and size rather than all caps; action labels use sentence case.

## Layout

The fixed desktop dialog uses a narrow progress rail and a wider single-task panel. Content pages keep stable title, description, error, and action regions. A 12px control rhythm and 24px section rhythm prevent dense security fields from becoming visually ambiguous.

## Elevation & Depth

Hierarchy comes from tonal surfaces and one-pixel borders. Static sections have no drop shadows. Modal depth remains owned by Windows.

## Shapes

Compact radii apply to buttons and field groups; the approved icon retains its larger rounded badge. Network/status rows use straight dividers to read as operational data.

## Components

### Foundational visual states

Controls provide default, hover, keyboard focus, pressed, disabled, busy, success, warning, and error states. Error copy occupies a reserved line so validation does not move navigation controls.

### Buttons and actions

Each page has one mint primary action. Back and Cancel are neutral. Installation remains disabled until the review page is valid; busy state disables duplicate activation without changing button geometry.

### Navigation and data display

The progress rail shows named stages and current/completed status with text plus color. RustDesk IDs and log paths use monospace text and remain selectable.

### Forms and overlays

Every input has a visible label. Auth keys and passwords are masked by default and are never echoed on review or result pages. Validation appears inline and moves focus to the first invalid field.

### Iconography

Only approved Darckware assets and Windows system glyphs are used. Icons never replace required action labels.

### Motion

Page changes are immediate; progress changes may use color only. The installer avoids decorative animation and layout shifts.

### Content and data visualization

Copy uses direct Portuguese verbs: “Voltar”, “Continuar”, “Instalar” and “Fechar”. Errors explain what must be corrected without exposing raw secrets.

## Do's and Don'ts

- **Do:** preserve native keyboard order and visible focus.
- **Do:** show route replacement and component choices explicitly before installation.
- **Don't:** display, log, or persist secret values.
- **Don't:** use glow or accent colors on every surface; reserve them for brand and active state.
