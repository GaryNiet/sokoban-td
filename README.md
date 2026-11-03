# Sokoban TD

A Godot 4.7 roguelite that mixes Sokoban and tower defense, shown in an isometric view. Your towers are crates: push them around to reshape the enemy path, then survive the wave.

## Rules
- You start the run with one Bolt Tower. You can push blocks only during the build phase. Once enemies are on the field, blocks stay where they are.
- Enemies always take the shortest route from a spawn (red) to the core (cyan). A push that would seal every route is refused.
- **Tower spawns.** New blocks from rewards drop on the tower spawns (`T`), taking turns between them, so you always know where the next one lands: it glows on the board and on the reward screen. Every choice on a reward screen lands on the same spot. A spawn with a block left on it is skipped. If every spawn is covered, the only reward is a repair until you push a block off one.
- **Holes** can't be crossed by you or the enemies. Push a block into one and it falls in for good, filling the hole so it becomes floor. Undo brings both back.
- **Corners are forever.** A block pushed into a wall corner can never come back out (it shows a gold padlock). Faint corner brackets mark these cells.
- **Upgrade blocks** (Amplifier, Overclock, Lens) don't shoot. Push one next to your towers and it boosts every tower it touches, of any kind, up to four at once.
- **Combos:** blocks that touch each other (left, right, above or below) give bonuses, shown as a diamond between them. Hover a block to see its stats and active combos.
- After every wave you choose one reward: a tower, an upgrade block, or (when you're hurt) a repair for +5 lives. Press **H** (or the button) to hide the reward screen and look at the field.
- **Pick a level** on the start screen (arrows + Enter, number keys, or click). Each level is its own run of 20 waves with fresh lives and blocks; beat the last wave and you're back at the level select. Levels: The Corridor, Split Wall, The Comb, The Pits.

## Map format
Levels live in `LEVELS` in `scripts/data.gd`. Each row is a string, and all rows must be the same length:

| Char | Meaning |
|---|---|
| `.` | floor |
| `-` | wall |
| `S` | enemy spawn |
| `A` | core (the point to protect) |
| `T` | tower spawn |
| `P` | player start (optional; defaults to next to the first tower spawn) |
| `*` | power tile (+50% damage, +0.5 range) |
| `O` | hole: nobody can walk over it; push a block in to fill it (the block is lost) |

| Tower | Role |
|---|---|
| Bolt | fast single-target shots |
| Cannon | slow shells that do splash damage |
| Frost | pulse that damages and slows everything in range |
| Tesla | lightning that chains between 3 enemies |
| Stone | pure blocker; towers touching it get +0.5 range |
| Amplifier | upgrade: every tower touching it deals +30% damage |
| Overclock | upgrade: every tower touching it fires 25% faster |
| Lens | upgrade: every tower touching it gets +0.75 range |

Enemies: Grunt, Runner (fast), Brute (armored), Splitter (splits into 2 Splitlings when it dies), plus a boss Brute at the end of each level.

## Level editor
Press **E** on the level select (or after a run ends) to open the editor.
- Paint with the left mouse button and erase to floor with the right. Pick tiles with 1-8: wall, floor, enemy spawn, core, tower spawn, player start, power tile, hole. Ctrl+Z undoes.
- A path preview, corner brackets and a list of problems update as you paint. The editor checks for a core and at least one enemy spawn, and that every spawn, tower spawn and the player start can reach the core.
- Set the name, the number of waves, the difficulty (how many waves into the difficulty curve the level starts; the built-in levels use 0, 2 and 4) and the map size (5-30 wide, 3-16 tall).
- **Playtest** (P) starts a run on just this level; Esc goes back to the editor with your map intact.
- **Save** writes `user://levels/<name>.json`. **Load** opens a saved level or one of the built-in levels as a starting point.
- **Copy as code** copies the level as a GDScript dictionary you can paste into `LEVELS` in `scripts/data.gd` to add it to the campaign.

## Controls
WASD or arrows: move and push (taps queue up; hold to keep walking, and you stop as soon as you let go) · Z: undo (build phase) · Esc: back to the level select · Space: start the wave · F: game speed · Shift: show all tower ranges · 1-3 or click: pick a reward · H: hide/show the reward screen

## Tests
```
godot --headless --path . -s tests/logic.gd            # rule checks
godot --headless --path . -s tests/editor.gd           # level editor checks
godot --headless --path . -s tests/sim.gd [-- --strong] # plays a full run with no pushing
xvfb-run godot --path . -s tests/shots.gd -- <dir>      # screenshots
```
