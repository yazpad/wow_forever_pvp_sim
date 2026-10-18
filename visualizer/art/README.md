# Talent school backgrounds

`talent_schools.png` is a 1536×1024 background atlas generated with the built-in
imagegen tool. The renderer uses six 512×512 cells without resampling the file:

| | Left | Middle | Right |
|---|---|---|---|
| Top | Affliction | Demonology | Destruction |
| Bottom | Arcane | Fire | Frost |

The original editor used colored panels; no previous background artwork was found.
`talent_backgrounds.lua` crops each cell to cover its panel and darkens it for icon
legibility. If artwork is unavailable, each school retains its colored panel.

Generation prompt:

> Use case: stylized-concept. Asset type: one game UI background texture atlas, six equal rectangular cells in an exact 3-column by 2-row edge-to-edge grid, total canvas landscape 1536x1024. Each cell is square, same size, no gutters, no text or labels or borders. Purpose: six dark fantasy talent-school backgrounds displayed behind a grid of bright ability icons. Painterly old-school fantasy RPG loading-screen illustration, rich atmospheric texture, subdued brightness, intricate environmental detail, no foreground characters. Top row left Affliction: spectral violet marsh, drifting ghostly wisps, ruined gravestones. Top row middle Demonology: emerald fel portal inside a shadowy gothic stone chamber. Top row right Destruction: charred volcanic temple, red-orange embers and fissures. Bottom row left Arcane: violet-blue wizard observatory with suspended luminous magical rings and ancient stone architecture. Bottom row middle Fire: amber inferno inside a scorched stone citadel with rising sparks. Bottom row right Frost: blue glacial cavern and distant frozen spires with swirling snow. The atmosphere should differ distinctly in every cell. Keep the entire atlas fairly dark with readable silhouettes and soft glows, avoiding white hotspots, so UI icons and rank numbers will remain readable on top. Fill every cell completely. No typography, no interface elements, no icons, no watermarks.
