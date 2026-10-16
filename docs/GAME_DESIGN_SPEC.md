# Pet Part Hunter – Game Design Specification

Oct 16, 2026 · @Leighton

## 1. Overview

Pet Part Hunter is a Roblox game where players run into rarity-tiered areas, grab pet parts while a mythic creature chases them, escape with their haul, and assemble mix-and-match pets from the parts. Speed from running pads and rebirths is what lets players survive harder areas.

**Core loop**

1. Train speed on running pads at home (and rebirth when maxed).
2. Enter an area and collect up to 3 parts (the bag).
3. Escape through a teleport-out point before the chaser catches you.
4. Sell spare parts for coins, or combine parts into a pet.
5. Use pet stats and coins to go further, then repeat in a harder area.

**Design pillars**

- Risk versus reward: parts only count once you escape with them.
- Targeted hunting: players chase specific parts, not random drops.
- Speed is power: speed gates survival in higher areas.
- Social competition: shared servers, shared part spawns, trading.

**Reference:** Keyboard Escape is the model for the speed pads, speed levels and rebirth.

**Audience:** mobile-first. Assume most players are on phones: large touch targets, simple UI, and mesh and effect budgets sized for low-end devices.

**Scope at launch:** six areas (Common, Uncommon, Rare, Super Rare, Legendary, Mythic), 6-slot pets, house building, speed pads with rebirth, trading, Robux monetisation, events and admin tools, and monitoring.

## 2. Home building

Each player owns a private plot with a basic starter house they can furnish, move items in, and delete items from.

**Requirements**

- Plot: each player gets a fixed plot, loaded only for them and visitors they allow.
- Starter house: a basic room set (walls, floor, door) that works without any furniture.
- Placement: grid-snapped with a rotate button (touch-friendly), ghost preview that turns red if invalid.
- Move and delete: tap an item to select it, then move, rotate, or delete. Deleting returns the item to the player's inventory.
- Item limit per plot (start at 150) to protect mobile performance, raised by house expansion pass.
- Surfaces: floor, wall and ceiling items are flagged so they can only go on the right surface.
- Pets live in the house and walk around as a display. A showcase area is a later feature.

**How players get items**

- Buy with coins (basic furniture).
- Buy with Robux (cosmetic sets, themes; non-tradable).
- Earn from events.

**Save data per item:** item ID, position (relative to the plot origin), rotation, and optional colour variant. Store the layout as a compact list in a DataStore, saved on leave and on a timer, with a version number for migrations.

**Server validation:** the client only requests placement. The server checks ownership, bounds, overlap and the item limit before placing anything.

## 3. Speed pads and rebirth

Speed is one growing stat, multiplied by permanent rebirth bonuses, and it decides which areas players can survive. This section follows +1 Speed Keyboard Escape (SecretVerse Studio), reviewed through third-party guides. I have since reviewed screenshots of its menus (the Halloween event build, early levels only), so figures from those are marked observed. Anything marked proposed is our own design.

**What Keyboard Escape does (from the guides)**

- Speed is the main stat: +1 per step by default, and speed milestones raise your level.
- Treadmills add speed while the player stands on them. Higher tiers, bought with Wins, raise the speed gained per step (one guide lists 25, 50, 100, 250 and 500).
- Wins are a second currency, collected from yellow pads in safe zones after each stage. They buy Trails and Auras, which are permanent speed multipliers that stack with rebirth.
- Rebirth unlocks at a level threshold, and each rebirth needs a higher level than the last. A button on the left of the screen shows what you will get.
- Rebirth resets your speed level to zero and grants a permanent speed multiplier. Multipliers climb very steeply: x3.5 at Rebirth 5 (level 75), x6 at Rebirth 8 (level 150), x10K at Rebirth 13 (level 300), x100M at Rebirth 17 (level 465).
- Flat speed bonuses (free gifts, treadmill gains) are wiped by a rebirth, which is why guides say to claim them after Rebirth 2.
- The game sells a Robux option to skip the rebirth level requirement.

**What your screenshots add (observed)**

| Level | Speed needed for that level | Walk speed shown |
| --- | --- | --- |
| 1 | 100 | 12 |
| 2 | 115 | 14 |
| 3 | 132 | 16 |
| 4 | 152 | 18 |
| 5 | 175 | 20 |

- The big Speed number is a running total. For example, 62 into level 2 shows 162 Speed, and 20 into level 5 shows 519.
- Each level costs about 15% more Speed than the one before. At that rate, Level 15 needs roughly 4,000 total Speed (my calculation).
- Walk speed rises by 2 per level (10 + 2 × level) at these levels. A Custom Speed box lets players set their own speed up to that maximum. Five levels cannot show whether walk speed is capped later.
- Six multiplier labels flank the Speed number: Ascend, Items and Speed Boost on the left, Trail & Aura, Rebirth and Boombox on the right. All read x1 at the start. I read them as multipliers on Speed gained per step.
- The course has lanes marked x1, x3 and x9, so the lane you run on sets Speed per step. Every step shows a floating +1.
- Per-step upgrades are gated by Wins (for example +50 per step needs 500 Wins, and another tier needs 2.5K Wins).
- The Rebirth panel needs Level 15 and moves Speed gain from x1 to x1.5. Together with the guides' Rebirth 5 (level 75, x3.5), early rebirths look like +15 levels and +0.5x each.
- The same panel has an Ascend! button and a Skip Rebirth! Robux button. I cannot tell from the screenshots how Ascend differs from Rebirth.
- A hub sign says World 2 requires Level 120, so worlds unlock by level, not by rebirth.

**What we take from it (proposed)**

1. Keep two layers: a Speed score that can grow huge, and a capped WalkSpeed that the chase actually uses. Keyboard Escape does this through levels: Speed is the running total, and walk speed follows the level, which costs more Speed each time. Here WalkSpeed is the balance lever against the chaser, so I would also give it a ceiling.
2. Make rebirth multiplicative and steeply growing, with a higher level threshold each time, and gentle early steps (Rebirth 5 at about x3.5 is the reference point).
3. Add Trails and Auras as equippable effects around the player with small permanent speed multipliers, bought with coins (some with Robux), and stacking with rebirth.
4. Optional: steps taken inside the areas also add a little Speed, so hunting trains you as well as the pads.

**Running pads at home (proposed)**

| Pad tier | Speed per second | Unlock |
| --- | --- | --- |
| 1 | 1 | Free starter pad |
| 2 | 25 | Coins |
| 3 | 50 | Coins |
| 4 | 100 | Coins |
| 5 | 250 | Coins and Rebirth 1 |
| 6 | 500 | Coins and Rebirth 2 |

Standing on a pad grants Speed every second from a server-side timer. A 2x speed pass doubles Speed gained, and does not raise the WalkSpeed cap.

**From Speed to WalkSpeed (proposed)**

```latex
\text{LevelCost}(n) = 100 \times 1.15^{\,n-1}
```

```latex
\text{WalkSpeed} = \min\big(\text{BaseWalk} + \text{WalkPerLevel} \times \text{Level},\ \text{WalkCap}\big)
```

This copies what the screenshots show (BaseWalk 10, WalkPerLevel 2, level cost growing 15% per level) and adds a WalkCap, which is the open question in the comment above. Because each level costs more Speed, WalkSpeed grows slowly against the Speed total. Rebirth, Trail and Aura multipliers then speed up levelling without letting WalkSpeed run away. Keep the cap below the server's anti-cheat ceiling and tune the chaser tiers against it.

**Rebirth rules (proposed)**

- Available when the player reaches the level threshold for their next rebirth.
- Resets: speed level, Speed, and flat Speed bonuses.
- Keeps: coins, pets, parts, house, Trails and Auras, passes, trades.
- Gives: a permanent multiplier, a higher level cap, and access to higher pad tiers.
- Rebirth count shows on the name tag and leaderboard.
- No Robux rebirth skip at launch. Guides call it poor value, and it would undercut the progression the chase depends on.

**Second prestige layer (proposed)**

There are two layers. Rebirth is layer 1. Layer 2 is called Apex (decided; it fits the hunter theme and avoids a clash with Keyboard Escape's Ascend button).

- Unlocks at the final rebirth of the current ladder (Rebirth 10, decided). World 2 opens at Rebirth 8, so Apex arrives after players have started exploring World 2.
- Resets: rebirth count, level, Speed, and flat Speed bonuses.
- Keeps: coins, pets, parts, Part Index, house, Trails and Auras, passes, and world unlocks.
- Gives: a larger permanent multiplier on Speed gained, a fresh rebirth ladder with a higher level cap, and progress towards later world gates.
- The Apex count shows as a badge on the name tag.
- No Robux skip for either layer at launch.
- Build it after launch tuning, but before players can reach the rebirth cap.

**Look and feel (from your screenshots)**

- **HUD layout:** a left grid of six big icon buttons (Rebirth, Free gift, Sound, Teleport, Inventory, Treadmills), a right stack (Shop, 2x Speed pass, Trading, Custom Speed and a jump button), and a top row of small square icons (time rewards, settings, event quests, item index, dances, music).
- **Bottom centre:** the Speed total in huge outlined text, three multiplier labels on each side, a wide level bar, and three Speed-pack buttons (+150K, +1M, +10M) underneath.
- **Style:** thick dark outlines on all text, candy gradients, a studded-brick texture on panels, 3D-rendered icons, titles written like ~~this~~, red X close buttons, tab icons that grow when selected, and a blurred world behind open panels.
- **Feedback:** a +1 pop-up and floating red sneaker icons on every step, lane signs in the world, a starburst on the start pad, and keycap click sounds with their own volume slider.
- **Selling buttons are animated:** the 2x Speed button cycles colour and glints, Free gift pulses, and new features carry a New! banner.
- **Event layer:** Halloween decoration, a Candy Corn counter, and a quest panel with a countdown.
- **For us (proposed):** keep the chunky style and the big step feedback, but show fewer always-visible buttons on phones and put the rest behind one menu.

**Tuning note:** chaser speeds in section 4 are set against the expected WalkSpeed of a player in that area, so any change to the curve above needs the chaser table rechecked.

## 4. Areas and the chaser

Six maze-like areas, one per rarity. Each holds parts of that rarity, and each has a mythic chaser that gets faster as the area gets better.

| Area | Access | Chaser speed (vs. expected player speed) | Part rarity focus |
| --- | --- | --- | --- |
| Common | Free | 0.85x | Common parts |
| Uncommon | Free | 0.95x | Uncommon, some Common |
| Rare | Free | 1.05x | Rare, some Uncommon |
| Super Rare | Gamepass, or Rebirth 2 | 1.15x | Super Rare |
| Legendary | Gamepass, or Rebirth 4 | 1.25x | Legendary |
| Mythic | Gamepass, or Rebirth 6 | 1.35x | Mythic, plus rare specials |

**Free route to the paid areas (decided):** every paid area can also be unlocked by playing. The pass is early access, and a rebirth count is the free route (Rebirth 2, 4 and 6, proposed). Top Roblox games do the same: a Robux shortcut sits beside a free gate, so non-payers stay and payers buy time. Rebirth also raises speed, so a player who unlocks an area by rebirth is already fast enough to survive it. Area unlocks are permanent and not tradable.

Chaser multipliers are starting values to tune. The goal is that players at the expected speed for an area can escape with good routing, while players who are under-levelled get caught.

**Entering and the bag**

- Players enter through a portal from the home hub.
- Bag holds 3 parts at the start. Bag upgrades (coins and Robux) raise this.
- Parts are only owned once the player escapes. Parts in the bag are lost if caught.
- Anything already in the player's inventory stays safe.

**Part spawns**

- Each area has a pool of spawn points. Parts spawn at random points from that pool, weighted by rarity.
- When a part is taken, it respawns at a different spawn point after a timer. Parts are visible to everyone on the server, so players compete for them.
- First player to touch a part takes it (server decides, to avoid duplication).
- Special-slot parts (wings, hats, auras) can spawn in any area at low rates.
- Launch content: 8 species per area, 48 species across the six areas. At 5 to 6 parts per species that is about 240 to 290 parts, each animated, so art volume is the biggest cost in the plan. If the schedule is tight, build the first 3 areas fully and ship the top 3 as a second wave.

**The chaser**

- Each player has their own chaser instance, so nobody else's chaser blocks or griefs them. Part spawns stay shared.
- Chaser targets one player, paths through the maze, and speeds up with the area tier.
- Pathfinding runs on the server, with a throttled update rate to limit cost.
- Optional later: the chaser gets slightly faster as the bag fills, to raise the stakes.

**If caught**

- The player drops all parts in their bag (they are lost, not left on the ground).
- The player is teleported back to the area entrance, so the route is rebuilt from scratch.
- A short protected window after respawn stops instant re-catching at the entrance.

**Escaping**

- Teleport-out points are placed around each area. Spacing is the main difficulty lever: fewer and further apart in higher areas.
- Standing in a teleport point for 2 seconds triggers the escape, and the chaser can interrupt it.
- On escape the bag moves to the player's inventory.

**Maze layout:** each area is a maze with loops (not only dead ends), so players can reroute away from the chaser. Teleport points should sit near loops, not at dead ends.

**Worlds (proposed)**

- World 1 is the six rarity areas above, with real-world and fantasy-lite animals.
- World 2 (decided) is a mythical-creature world: dragons, phoenixes, griffins, unicorns and similar species, with better part stats than World 1. It keeps the same six rarity tiers, so the maze, bag, chase and escape systems are reused and only content and tuning change. The game is scoped to these two worlds. Further worlds are out of scope for now, and the world config record keeps the door open.
- World 2 part stats sit above World 1's caps. Stat caps are per world, so a World 2 part is a real upgrade, but World 1 parts stay useful in mixed pets and as trade stock.
- World 2 chasers are new, faster creatures themed to the world, and their speeds are set against the higher expected WalkSpeed of players who have reached it.
- World 2 opens with a rebirth count plus one escape from the World 1 Mythic area (8 rebirths proposed, after the Mythic free route at Rebirth 6).
- Unlocks are permanent and stored in the player profile, so rebirths and Apex never lock a world again.
- Gates are not tradable and have no Robux skip, so they stay a progression milestone.
- Each world is a config record: its areas, species pool, chaser tuning and unlock rule. A new world then needs content, not new systems.
- Parts carry a world tag, and parts from different worlds can be mixed on one pet.
- The WalkSpeed ceiling and chaser tiers need headroom above World 1's top tier.
- Scope is World 1 and World 2 only. Launch with World 1 and ship World 2 as the first big update.

**Player combat (club)**

- Active from Rare areas upwards. Common and Uncommon have no combat, so new players learn the loop without being farmed.
- A hit makes the victim drop 1 random item from their bag onto the floor. If the bag is empty, nothing drops.
- Dropped items can be picked up by anyone, including the victim. They despawn after a timer (30 seconds proposed) and return to that area's spawn pool.
- If a player's own chaser catches them, their bag simply disappears, as described above. Nothing drops for others.
- There is no damage and nobody is removed from the area by a hit.
- **Guardrails:** no-hit zones around the area entrance and teleport-out points, about 2 seconds of protection after being hit, a swing cooldown and a brief slowdown for the attacker, and a cap on hits per victim per minute (to tune).
- The server checks every hit (range, cooldown, line of sight) and logs it. Mobile gets an attack button with light aim assist.
- Clubs and skins are sold in the shop (section 7).

## 5. Pets and parts

A pet has 6 slots. Any part can be mixed with any other part, as long as the slot needs it, so a chicken head on a tiger body is valid.

| Slot | Count | Role |
| --- | --- | --- |
| Head | 1 | Main stat contribution, defines face |
| Body | 1 | Largest stat contribution |
| Legs | 1 | Mostly speed-related stats |
| Tail | 1 | Small stat contribution |
| Special | 2 | Wings, hats, auras, back items. Mostly cosmetic with a small stat bonus |

**Part data (per part)**

- ID, species, slot type, rarity, area of origin.
- Stats (3-4 per pet, summed across all 6 parts): speed bonus, bag capacity bonus, coin bonus, luck bonus.
- Mesh asset ID, animation set ID, attachment point name (see section 6).

**Stat rules**

- Pet stat = sum of its parts' stats, then capped per stat to protect balance.
- Higher rarity parts have higher stat ranges. Each part rolls a stat value within its rarity range when it drops, so two of the same part can differ slightly.
- Special parts carry smaller stats than core parts so cosmetic collecting does not become mandatory.
- Optional: a small set bonus when all parts come from the same species.

**Building a pet**

- Done at a crafting station in the home hub.
- The player picks one part for each slot from their inventory. Slots can be left empty (a pet with no tail is valid, with lower stats).
- Building consumes the chosen parts. Duplicates are expected and are the player's trade and sell stock.
- Pets cannot be taken apart again, to keep part hunting meaningful.
- A player can equip a limited number of pets: 2 at the start, with more slots bought up to a cap of 6 (proposed; early slots cost coins, later ones Robux or the pet slot pass). Equipped pets give their stats.

**Trading**

- Players can trade parts and finished pets with each other. Robux-bought items are not tradable.
- Server-side trade window: both players lock in, then confirm, then the server swaps items atomically.
- Gate trading behind a minimum level or account age, add a trade cooldown, and log every trade.
- Trade value warnings: flag trades that are wildly lopsided to help prevent scams.

**Selling:** unwanted parts can be sold to a shop NPC for coins, priced by rarity.

**Part Index**

- A collection book listing every part in the game, filled in as players find them. Each entry records the first time you found the part and the best quality tier you have owned.
- Entries stay filled when a part is sold, traded, merged or used in a pet.
- Completing every part of a species gives a small permanent bonus and a badge. Completing an area's parts gives a larger one. Bonus sizes are to be tuned.
- Tabs: All, by world, by area, and Events.

**Merge**

- 5 copies of the same part at the same quality tier merge into 1 part of the next tier. Starting target: 3 tiers (Standard, Polished, Brilliant, as working names), each raising that part's stats by a set percentage.
- Merging happens at the crafting station and runs on the server: it takes all 5 parts and returns the new one in a single step, so a failed call can never lose parts.
- Higher-tier parts show a coloured frame and a stronger effect. They can still be traded, sold at a higher price, and used in pets.
- Merging uses up duplicates, but it does not replace hunting, because you still need the part to appear in the area.

## 6. Art and animation

Every part is a mesh built for Roblox Studio and every part is animated. Because any part can be combined with any other, parts must follow one shared standard so a mixed pet still looks and moves correctly.

**Rules**

- Every part is built inside Roblox Studio with its own mesh creation tools (no Blender or other external modelling) and ends up as a MeshPart or a small group of MeshParts. No flat decals or sprite-style parts.
- Every part ships with its own animation set: idle, walk and run at minimum. Specials (wings, auras) also loop their own motion, such as wing flap or aura pulse.
- No part may depend on another specific part to look right.

**Shared pet skeleton**

The pet model is a fixed rig with six sockets. Each part attaches to one socket through a Motor6D, and each part animates only its own joint.

| Slot | Socket (on pet rig) | Part joint name | Typical animation |
| --- | --- | --- | --- |
| Body | Root | BodyJoint | Breathing, bounce |
| Head | HeadSocket | HeadJoint | Look around, bob |
| Legs | LegSocket | LegJoint | Walk and run cycle |
| Tail | TailSocket | TailJoint | Wag, sway |
| Special 1 | Special1Socket | Special1Joint | Flap, pulse, float |
| Special 2 | Special2Socket | Special2Joint | Flap, pulse, float |

Because each animation keyframes only its own joint, six animations from six different species can play together on one Animator without clashing. Movement speed drives the playback speed of leg animations, and all parts share one clock so they stay in sync.

**Authoring standard (for every mesh)**

- Pivot placed exactly at the socket attach point, facing forward (-Z), upright (+Y).
- Fit to a fixed bounding box per slot, so any head fits any body, and any legs fit any body (the body defines hip width, and a leg part is one mesh that contains all of its legs).
- Consistent naming: `<Species>_<Slot>` for meshes, `<Species>_<Slot>_<Idle|Walk|Run>` for animations.
- Rarity shows through material, colour, and light effects, and not through bigger meshes.

**Mobile budgets (starting targets, tune after device testing)**

| Item | Budget |
| --- | --- |
| Triangles per part | 1,500 or fewer (specials 2,000) |
| Triangles per full pet | 8,000 or fewer |
| Texture per part | One 512x512 map |
| Particle emitters per pet | 2 or fewer, rare parts only |
| Collision on pet parts | Off (CanCollide, CanTouch and CanQuery all false) |

**Performance rules**

- Animate on the client only. The server stores which parts a pet has, and clients build and animate the model.
- Only animate pets within a set distance of the camera. Freeze animation beyond that.
- In the house, cap how many pets animate at once.

**Pipeline:** build the part in Studio, set its pivot and socket, animate it with the Studio animation editor, then register the part in the part data table with its mesh ID and animation IDs. Run a validation check on each new part (pivot, bounding box, triangle count, all required animations present) before it can spawn in game.

## 7. Economy and monetisation

**Currencies**

- **Coins (soft currency):** earned by selling parts and from events. Spent on bag upgrades, house items, pet building fees, and pad-related upgrades.
- **Robux (premium):** pays for gamepasses, developer products and cosmetics.
- **Rebirths:** not a currency. A permanent speed multiplier only.

**Coin sources and sinks**

| Sources | Sinks |
| --- | --- |
| Selling spare parts (priced by rarity) | Bag upgrades |
| Event rewards | House items and expansions |
| Pet coin bonus stat (small multiplier) | Pet building fee |
|  | Cosmetics, Trails and Auras |

Sinks must grow in cost as players progress, so coins do not pile up unused. Track coins earned and spent per hour (section 9) to catch inflation early.

**Gamepasses (permanent)**

| Pass | Notes |
| --- | --- |
| Super Rare, Legendary, Mythic area access | Sold singly and as a discounted bundle |
| 2x speed gain | Doubles pad XP, not the walk speed cap |
| 2x coins | Applies to selling and event coins |
| Extra bag slots | Tiered (for example +2, +4) |
| Extra pet slots | Lets players equip more pets |
| House expansion | Raises the item limit |

**Developer products (repeatable)**

- Coin packs.
- Timed luck boost (for example 30 minutes).
- Limited-use insurance: keep the bag if caught, one use per purchase.

**Cosmetics:** furniture sets, house themes, pet skins, plus Trails and Auras that show around the player and carry small permanent speed multipliers (bought with coins, some with Robux).

**Weapons (clubs)**

- 5 coin clubs, differing by reach and swing cooldown. There is no damage stat, because every hit drops exactly 1 item. Starting values (proposed, tune with hit-rate data):

| Club | Reach (studs) | Swing cooldown | Notes |
| --- | --- | --- | --- |
| 1 | 6 | 0.8 s | Starter, cheap |
| 2 | 7 | 0.9 s | |
| 3 | 8 | 1.0 s | |
| 4 | 9 | 1.1 s | |
| 5 | 10 | 1.2 s | Best coin club |

Longer reach comes with a slower swing, so a better club is a choice and not a pure upgrade. A missed swing costs the attacker a brief slowdown, which matters when a chaser is behind them. Prices climb steeply, so clubs act as a coin sink.
- 2 paid clubs sold for Robux. Each has the stats of club 5 with 5% longer reach (10.5 studs, same cooldown), plus a unique skin, swing effect and hit sound.
- The reach edge is deliberately small so free players can still compete. Hit rates are tracked per club type, and the edge can be cut if paying players dominate.
- Paid clubs are not tradable.
- Clubs only work from Rare areas upwards.
- Coin clubs are another coin sink.

**Rules to protect the game**

- Never sell parts directly, because hunting is the core loop.
- Robux-bought items are not tradable, to prevent real-money trading.
- Insurance is limited use and does not work on events with special rules.
- Players who do not pay still have a route to the paid areas: the plan is to open a path through rebirths later, and this is a decision to confirm (see open questions).

**What Keyboard Escape sells and gives away (observed)**

- Always-visible Speed packs: +150K, +1M and +10M.
- A low-priced 2x Speed gamepass (shown at 4 Robux), timed 2x boosts (10 minutes for 8 Robux or by watching a video, 30 minutes for 25, one hour for 44), and a 15-minute server-wide boost (119 Robux).
- Skips: Skip Rebirth, Skip All on time rewards, skip on quests, and stage teleports priced in Wins or Robux (Stage 2 is 2 Wins or 3 Robux, Stage 6 is 100 Wins or 20 Robux).
- Trails, Auras and items priced in Wins and Robux side by side, each with a gift button. Examples: Green Trail x1.5 for 500 Wins or 25 Robux, Blue Trail x2 for 1.5K or 35, Purple Trail x3 for 5K or 75, Glow Aura x1.2 for 1M or 90, Wind Aura x1.5 for 5M or 189.
- Cosmetics: a Gold Treadmill skin (gamepass), dances and a dance wheel (one dance shown at 399 Robux).
- Free hooks: a 12-tile time-rewards grid (Wins, Speed, boosts, plus a rare and an "OP" reward) with a reset timer, a like-and-join gift worth 15,000 Speed, a Medal clip quest for a free x2 Aura, and a restocking items shop.

**What we take (proposed)**

- Price non-part items in coins or Robux side by side, with a gift button.
- Offer timed boosts and a server boost.
- Add a time-rewards grid and a like-and-join gift.
- Keep parts, chaser skips and escape skips out of the shop, so the hunt stays earned.
- A "watch a video" boost depends on what Roblox currently supports for rewarded ads, so check that before planning around it.

## 8. Events and admin tools

**Events**

Events are defined as config data, so a new event never needs a code update. Each event record holds a start and end time, a list of modifiers, a spawn table override, an optional exclusive area, and reward definitions.

| Event type | Example |
| --- | --- |
| Limited-time area | A Halloween area with exclusive parts and a themed chaser |
| Boost weekend | 2x luck, 2x coins, or a slower chaser |
| Chaser variant | An enraged chaser that is faster but drops better parts |
| Community goal | The whole server collects a set number of parts for a shared reward |
| Chaos event | Short admin-run fun events, as Keyboard Escape does: players briefly transformed or thrown into a boss encounter |

- Event parts are added to the part data table with an event tag and can be made non-tradable or time-limited.
- Events are loaded at server start and refreshed on a timer, plus pushed live through MessagingService for immediate starts and stops.
- A Halloween event is the natural first test, as it is about two weeks away at the time of writing.

**Keyboard Escape's Halloween event (observed)**

- A second counter for the event currency (Candy Corn) beside the main one, with its own buy button.
- Event quests, each with a progress bar, a refresh countdown and a Robux skip (for example collect 25 Candy Corn, run 60 minutes on a treadmill, find one secret key).
- Seasonal decoration across the world, an Events tab in the item index, and an in-world board promoting the admin boost event.
- A TikTok Live integration lets viewers trigger effects on a player: turn into a chicken, slow down, banana slip, jail, explode, shrink, turn invisible, disco and blur. This is optional for us and only useful if you plan to stream.

**Admin tools**

- Access is limited to listed user IDs or group ranks, and every action is checked on the server. Admin commands are never trusted from the client.
- **Player tools:** view inventory, grant or remove coins and parts, kick, ban, and roll back to a saved data snapshot.
- **Live tuning:** change chaser speed, spawn rates, trade on and off, and per-area settings without a restart.
- **Event control:** start, stop and schedule events, and send server announcements.
- **Audit log:** every admin action is recorded with who, what, target and time.
- Use an in-game admin panel for quick actions and the external dashboard (section 9) for review.

## 9. Monitoring and anti-exploit

Monitoring is built in from the first milestone, because the economy, trading and paid areas are where problems appear first.

| Area | What to track | Why |
| --- | --- | --- |
| Economy | Coins earned and spent per hour, part drops vs. collections, trade prices | Spot inflation and broken sinks |
| Progression | Players per area, rebirth rate, drop-off points | Find where players quit |
| Difficulty | Catch rate and escape rate per area | Tune chaser speed |
| Monetisation | Pass conversion, product sales, revenue per player | See what sells |
| Exploits | Speed beyond cap, teleporting, bag over capacity, duplicate parts, unusual trade volume | Catch cheating early |
| Server health | DataStore errors, request budget, server count, player count | Keep the game stable |

**How**

1. **Roblox analytics:** use AnalyticsService for economy events, progression funnels and custom events. It feeds the Creator Dashboard at no cost, so start here.
2. **Exploit log:** a server-side log of suspicious events (impossible speed, oversized hauls, trade spikes) with player ID, server and time.
3. **External dashboard (when the game has players):** send key events from the server to your own backend through HttpService or Open Cloud, and chart them in a tool such as Grafana for real-time views.
4. **Alerts:** a webhook to a relay for serious events, such as a player gaining a huge number of parts in one run. Discord often blocks Roblox requests, so route through a small relay.

**Server-side validation (non-negotiable)**

- Speed: the server sets and checks WalkSpeed against the player's level and cap.
- Parts: only the server awards parts and only when the player completes an escape. A part can be claimed once.
- Bag: capacity enforced server-side.
- Trades: atomic swap, with every trade logged.
- Purchases: grant on the server after a verified receipt, with receipt handling that is safe to repeat.
- Remote events: rate limit each one and validate every argument.

* Combat: validate range, cooldown and line of sight for every club hit, log hits per player and per club type, and flag unusual hit rates. This also shows whether the paid clubs' reach edge is making paying players dominate.

## 10. Technical architecture and build order

The server owns all game state; clients send requests and render the result.

&#91;embedded content: architecture · client, server, Roblox services\]

Clients send requests that the server validates; the server alone writes to DataStores, checks purchases and logs events.

**Data saved per player:** coins, speed level, rebirth count, part inventory (part ID, rolled stats, count), pets (six slot part IDs and rolled stats), equipped pets, house layout, owned passes, and a schema version. Use a session-locking DataStore wrapper (such as ProfileStore) so two servers can never write the same profile.

**Build order**

1. Chase prototype: one area, one chaser, a 3-part bag, teleport-out points and five placeholder parts. Gate: the chase is fun before any progression exists.
2. Data layer and validation: player profile, session locking, rate-limited remotes, and analytics events logged from here on.
3. Speed pads, levels and rebirth (Apex follows after launch tuning).
4. Part pipeline: part data table, shared pet rig, three species built and animated end to end, the crafting station, the Part Index and merge.
5. All six areas with chaser scaling and gamepass gating.
6. Home building.
7. Economy: selling parts, coins, bag upgrades and Robux products.
8. Trading.
9. Admin panel, events system and external dashboard.
10. Closed test on phones, tune chaser speeds and prices from the monitoring data, then launch.

**Decisions made**

- World 2: a mythical-creature world with better stats, same six rarity tiers.
- Free route to paid areas: Rebirth 2, 4 and 6 (to tune).
- Species: 8 per area, 48 at launch.
- Meshes: built inside Studio, no external modelling.
- Pets equipped: 2 at the start, buyable up to 6.
- World 2 gate: 8 rebirths plus a World 1 Mythic escape.
- Second prestige layer: Apex, unlocking at Rebirth 10.
- Coin clubs: reach 6 to 10 studs, cooldown 0.8 to 1.2 s; paid clubs 10.5 studs.

**Open questions**

- None at the moment. Worlds beyond World 2 are out of scope.
