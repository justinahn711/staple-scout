# iPhone design

The user approved the web flow and clarified iPhone as the shipping platform. Preserve its restrained grocery workspace: warm neutral surfaces, deep green accents and direct price evidence. Use native SwiftUI navigation, tab bars, lists, forms, sheets, toggles and date pickers. System type and SF Symbols are the visual system; no custom display face or webview.

Tabs: Staples for the user's list and individual product review; Compare for explicit Shelf/Pickup and planned-store filters; This week for grouped recommendations, coverage gaps and saved reports; Stores for immutable location preferences and honest source capabilities. Adding/editing a staple or recording an observation uses a native sheet with Cancel/Save. Deletion requires a destructive confirmation. Editing requirements explains reapproval.

Color tokens: accent green light #176447/dark #76C99E; semantic primary/secondary text and system grouped backgrounds. Brand green supplies the accent; platform semantics supply contrast in both appearances. Currency and quantities use aligned numerals. Unit price and exact package outlay are separately labeled. No invented prices/staples on first launch; empty states explain the next action.

Each row is a real object, not a generic dashboard card. Lists group related facts and use disclosures for evidence details. Product conditions/exclusions are text as well as color. Date/time context is visible. Network work has loading, partial-failure and retry-next-day explanations without automatic refresh loops. SwiftData save failures keep an explicit recovery state and never silently overwrite a library.

Bounded verification: build the native app and core tests, inspect the running iPhone surface when simulator UI access is available, repair one batch, then confirm. No claim of visual verification when access is unavailable.
