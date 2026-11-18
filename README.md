# Slajkon Buddy

Slajkon Buddy keeps player reviews on your character and shares them with online WoW character and Battle.net friends who also use the addon.

## Use

- Type `/sbuddy` to open the ratings window.
- Type `/review` to review your current target, or `/review Player Name` to review a named player directly.
- Characters register automatically when they load the addon. Use `/sbuddy own Character-Realm` to link a character with older reviews, or `/sbuddy unown Character-Realm` to unlink one. Reviews by linked characters can be edited from any of your characters, and edits keep the original author.
- Enter a player name to make a manual review, or use `/sbuddy Name-Realm` directly. If the name field is empty, **Review player** uses your current player target.
- Click the draggable minimap button to open or hide the addon. Reviews only open when you manually start one from the addon, `/review`, or `/sbuddy Player Name`.
- Choose thumbs up or thumbs down and optionally select tags: Skilled, Friendly, or Helpful for positive reviews; Rude, Ninja looter, or Unskilled for negative reviews. Comments are optional.
- Use **Save & next** to keep the vote, **Skip player** to move on, or **Skip voting** to close the review flow.
- Hover a player to see a green Positive or red Negative rating. Positive votes must outnumber negative votes; ties count as Negative. No rating appears until the player has a vote you have not ignored. Unit tooltip ratings are appended after EllesmereUI's tooltip lines when it is installed.
- The player list groups entries into **Positive** and **Negative** sections when they have entries. Names use their class color with their latest known level, up to three most-used tags, and a comment preview that prioritizes your own review. The tags line is hidden when no tags are provided. Click a row to inspect votes, comments, and dates, or use **Invite** and **Whisper** directly. Your review has an **Edit** button on the details page; it opens the saved review so you can change its vote, tags, or comment. Ratings can be removed or locally ignored from the details view.
- Players with only locally ignored reviews are hidden from the main list. Use the **Ignored** menu to see them, inspect a player's reviews, or restore ignored ratings locally. Players with both visible and ignored reviews remain in the main list and also appear in **Ignored**.

## Friend sync

The addon checks your in-game character friends and online Battle.net friends when you log in and when friend status changes. Battle.net friends must be playing the same WoW client to sync; offline friends catch up the next time they are online. Character friends sync by addon whisper, while Battle.net friends use WoW's direct Battle.net addon-data channel. Both routes require the friend to respond to a small addon handshake before saved reviews are exchanged. Reviews, tags, comments, and vote removals are pushed to confirmed addon friends when you make a change. Friends who come online later get the saved snapshot then. Data received from one friend can be relayed to your other online addon friends, so information can travel through the friend network. Local ignore choices are never shared. Sync does not rely on a shared server database.

## Files

- `SlajkonBuddy.toc` — addon metadata and saved-variable declaration.
- `SlajkonBuddy.lua` — UI, review storage, tooltip display, and friend sync.
