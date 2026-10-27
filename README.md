# Sokoban TD

A Godot 4.7 roguelite that mixes Sokoban and tower defense. Your towers are crates: push them around to reshape the enemy path, then survive the wave.

## Rules
- You start the run with one Bolt Tower. You can push blocks only during the build phase. Once enemies are on the field, blocks stay where they are.
- Enemies always take the shortest route from a gate (red) to your core (cyan). A push that would seal every route is refused.
- **Corners are forever.** A block pushed into a wall corner can never come back out (it shows a gold padlock). Faint corner brackets mark these cells. Gold **power tiles** (+50% damage, +0.5 range) usually sit in such spots.
- **Combos:** blocks that touch each other (left, right, above or below) give bonuses, shown as a diamond between them. Hover a block to see its stats and active combos.
- After every wave you choose one reward: a new block or an upgrade. Your blocks carry over to the next level.
- Clear all 3 levels to win (The Crossing, Switchback, Twin Gates).

| Tower | Role |
|---|---|
| Bolt | fast single-target shots |
| Cannon | slow shells that do splash damage |
| Frost | pulse that damages and slows everything in range |
| Tesla | lightning that chains between 3 enemies |
| Stone | pure blocker; towers touching it get +0.5 range |

Enemies: Grunt, Runner (fast), Brute (armored), Splitter (splits into 2 Splitlings when it dies), plus a boss Brute at the end of each level.

## Level editor
Press **E** on the title screen (or after a run ends) to open the editor.
- Paint with the left mouse button and erase to floor with the right. Pick tiles with 1-7: wall, floor, enemy gate, core, player start, block dock, power tile. Ctrl+Z undoes.
- A path preview, corner brackets and a list of problems update as you paint. The editor checks for a core, a player start and at least one gate, and that every gate and the player can reach the core.
- Set the name, the number of waves and the difficulty (how many waves into the campaign's difficulty curve the level starts).
- **Playtest** (P) starts a run on just this level; Esc goes back to the editor with your map intact.
- **Save** writes `user://levels/<name>.json`. **Load** opens a saved level or one of the built-in levels as a starting point.
- **Copy as code** copies the level as a GDScript dictionary you can paste into `LEVELS` in `scripts/data.gd` to add it to the campaign.

## Controls
WASD or arrows: move and push · Z: undo (build phase) · Space: start the wave · F: game speed · Shift: show all tower ranges · 1-3 or click: pick a reward

## Tests
```
godot --headless --path . -s tests/logic.gd            # rule checks
godot --headless --path . -s tests/editor.gd           # level editor checks
godot --headless --path . -s tests/sim.gd [-- --strong] # plays a full run with no pushing
xvfb-run godot --path . -s tests/shots.gd -- <dir>      # screenshots
```
