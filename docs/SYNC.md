# Sync between phone and PC

Chesster can keep your Dojo data in step between devices (for example the
Pixel and the Windows PC) through a **private GitHub repository that you own**.
There is no Chesster server: the app talks directly to `api.github.com` with a
token that can only touch that one repository.

## Set it up (once)

1. **Create a private repository** at [github.com/new](https://github.com/new),
   for example `chesster-data`. Choose *Private*. It can be empty; Chesster
   adds a README on the first sync.
2. **Create a fine-grained personal access token** at
   [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new):
   - *Repository access*: **Only select repositories** → your data repository
   - *Repository permissions*: **Contents → Read and write**
     (*Metadata → Read-only* is added automatically)
   - nothing else; pick any expiry you like (you'll paste a new token when it expires)
3. In Chesster open **Settings (⚙) → Sync with GitHub**, leave *Owner* empty
   (it is filled in from the token), check the repository name, paste the
   token and tap **Save & test**. The first sync starts right away.
4. Do the same on the other device with the same repository (the same token
   works, or make one per device).

If your token is allowed to create repositories (for example a classic token
with the `repo` scope), the sync screen offers **Create private repository**
when the repository does not exist yet. A token limited to one repository
cannot do that, which is why step 1 comes first.

## What syncs

| Remote file | Content |
|---|---|
| `games/<id>.json` | Each Dojo game: move tree, move checks, chats, Stockfish report, AI review, PGN |
| `progress_chat.json` | The progress-coach conversation |
| `settings.json` | Dojo preferences: guidance, Claude model and effort, last opponent and side, analysis strength, voice auto-send |

**Never synced:** the Anthropic API key, the GitHub token (both stay in the
device's secure storage) and the Windows Stockfish path (device-specific).
Classic Maia data is not synced.

## When it syncs

- shortly after the app starts,
- a few seconds after a finished game is saved (game end, report, AI review),
- when the app goes to the background or the window is minimised,
- when you tap **Sync now**.

Moves of a game in progress are synced the next time the app goes to the
background. Sync never blocks the app; failures show up as the status line on
the sync screen and in the diagnostics log.

## How conflicts and deletions work

Each sync lists the repository in one request and compares git blob hashes
with the hashes recorded at the last sync (`sync_manifest.json` in the Dojo
folder, never uploaded), so unchanged files are not transferred either way.
All uploads and deletions of one sync are a single commit.

- Changed on one device only: that version is copied to the other.
- Changed on both: the copy with the newer `updated` time wins. The other copy
  is kept on the device that ran the sync, under `conflicts/` next to the
  `games` folder (it is not shown in the game list).
- Deleted in the app: the game is deleted from the repository and then from
  the other device, unless the other device changed it in the meantime (then
  it comes back).
- A game file that disappears without being deleted in the app (for example
  removed by hand) is restored from the repository rather than deleted there.

The repository keeps the full git history, so older versions of every game can
be recovered on GitHub.

## Privacy

- Your games go only to your own private repository; the app refuses to sync
  with a public one.
- The token is stored in Android Keystore / Windows encrypted storage and is
  sent only to `api.github.com`. Revoke it any time on GitHub; **Disconnect**
  removes it from the device and leaves your data in place.
- GitHub's [privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement)
  applies to the repository.
