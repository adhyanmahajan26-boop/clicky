# Air tests for Theo build 202611051711

For a separate Claude session working on the MacBook Air. Do these in order and report each row at the end as ✅, ⚠️ or ❌, with the evidence file. A ⚠️ is fine, a fake ✅ is not.

The Air travels and isn't on the Studio's network. Nothing here needs the Studio.

## Rules

- Everything runs in a test profile (`--profile test-air`), never in Addy's real chats. If anything lands in a real chat, clean it up and say so.
- Models: bots and coding runs on `claude-haiku-5-5` at low effort. **No Codex at all**: Addy's monthly limit is at 21%. Cursor only on its Auto model, except the one check in row 8. T3 Code tests use a Claude Haiku thread.
- Test agents keep Addy's real home, so `~` in their shell is the real one. Everything that runs a harness works in a folder under the profile's own area, `~/Library/Application Support/Theo-Test-air/home/Projects`, and test prompts say "the current folder". Never `~/Projects` or Addy's other real folders. Your tools and evidence go in your scratchpad.
- Secrets: no raw dumps of databases, config files or meta rows, in your session or any subagent's. Select named, non-secret columns only, and pass this rule to every subagent. Never print, log or paste API keys.
- Stock T3 Code on the Air must stay stock. Theo may only use the `t3` CLI. Nothing of Theo's goes into `~/.t3` or T3 Code's settings.
- Don't touch Addy's real Link pairing or Devices settings. Reading them is fine.
- Don't sign in to anything, on any harness. A CLI that isn't installed or signed in gets its row marked and you move on.
- Never record the screen. Screenshots of Theo's own window only. Don't move Addy's mouse, take focus or press real keys. Don't kill processes you didn't start.
- Keep tests tiny: one run per row.

## 0. Before touching anything

Read only. Keep the output, it's the baseline for row 5.

```bash
plutil -extract CFBundleVersion raw /Applications/Theo.app/Contents/Info.plist
~/.t3/bin/t3 --version
ls -a ~/.t3
ls ~/.t3/bots 2>/dev/null
find ~/.t3 -type f -not -path '*/logs/*' -exec stat -f '%N %m' {} + | sort > "$SCRATCH/t3-before.txt"
defaults read com.personal.clicky v3.devices.bots 2>/dev/null
defaults read com.personal.clicky v3.devices.routines 2>/dev/null
```

`$SCRATCH` is your scratchpad. Stock T3 should be v0.1.7 at `~/.t3/bin/t3`; say if it isn't. Don't print the contents of any file under `~/.t3`.

## 1. Update real Theo, only when it's idle

Idle means: nothing playing, and no agent running under Theo.

```bash
pmset -g assertions | /usr/bin/grep -a -E "HTMLMediaElement|coremedia"
MAIN='^/Applications/Theo.app/Contents/MacOS/Clicky( --background)?$'
pgrep -P "$(pgrep -f "$MAIN")" -fl | cut -c1-60
```

Both should print nothing that's Addy's work. Theo's `--mcp` children belong to Claude sessions and aren't work in progress. If Addy is busy, wait and check again later.

Then use the app's own update path, the same one as Settings › Updates › Update now. These go through real Theo's control inbox: write `{"cmd":"updateCheck"}` and then `{"cmd":"updateInstall"}` as `~/.clicky/control-inbox/<any id>.json`, and read the reply from `~/.clicky/control-outbox/<same id>.json`. Theo quits and comes back by itself. Afterwards check the build is 202611051711.

If your permission system refuses this, don't route around it. Tell the coordinator, and Addy can press Update now. The tests below don't wait for it: run them from the release zip instead, with nothing changed in `/Applications`:

```bash
mkdir -p "$SCRATCH/theo"
gh release download build-202611051711 --repo adhyanmahajan26-boop/claudia-releases --pattern 'Theo-*.zip' --dir "$SCRATCH/theo"
shasum -a 256 "$SCRATCH/theo/Theo-202611051711.zip"
ditto -x -k "$SCRATCH/theo/Theo-202611051711.zip" "$SCRATCH/theo"
export THEOUI_BINARY="$SCRATCH/theo/Theo.app/Contents/MacOS/Clicky"
```

The sha256 must be `38279044e3d50ebd56bc18bd7cdcf5427601370c33bc20ea02e629e2cf802dd9`. Say in your report which of the two you tested.

## 2. Start a test profile

Get the driver from the branch into your scratchpad:

```bash
gh api -H "Accept: application/vnd.github.raw" "repos/adhyanmahajan26-boop/clicky/contents/Tools/theoui.py?ref=theo-bot-harness" > "$SCRATCH/theoui.py"
```

Write this as `$SCRATCH/lib.py`:

```python
import json, os, pathlib, time, uuid
def client(profile="air"):
    home = pathlib.Path.home() / ("Library/Application Support/Theo-Test-" + profile) / "home"
    inbox, outbox = home/".clicky/control-inbox", home/".clicky/control-outbox"
    def send(obj, timeout=30):
        inbox.mkdir(parents=True, exist_ok=True); outbox.mkdir(parents=True, exist_ok=True)
        ident = uuid.uuid4().hex
        tmp = inbox/f"{ident}.tmp"; tmp.write_text(json.dumps(obj)); tmp.rename(inbox/f"{ident}.json")
        reply = outbox/f"{ident}.json"
        deadline = time.time()+timeout
        while time.time() < deadline:
            if reply.exists():
                text = reply.read_text(); reply.unlink(); return json.loads(text)
            time.sleep(0.05)
        return {"ok": False, "error": "timeout"}
    return send
def chat(send, cid, limit=60):
    return send({"cmd":"botChat","id":cid,"limit":limit}).get("result",[])
def wait_idle(send, seconds=240, quiet=4):
    start=time.time(); calm=0
    while time.time()-start<seconds:
        s=send({"cmd":"botsState"}).get("result",{})
        calm = 0 if (s.get("replying") or s.get("exchanges")) else calm+1
        if calm>=quiet: return True
        time.sleep(1)
    return False
PROJECTS = pathlib.Path.home()/"Library/Application Support/Theo-Test-air/home/Projects"
```

Start it:

```bash
defaults write com.personal.clicky.test-air v2.setup.completed -bool true
defaults write com.personal.clicky.test-air v3.bots.freshStart -bool true
export THEOUI_PROFILE=air THEOUI_OUT="$SCRATCH/shots"
python3 "$SCRATCH/theoui.py" start --tab bots
```

`theoui.py start` refuses if `v2.screen.claudia` isn't set on the Air. It reads those keys from the real profile and never changes them. If it refuses, start the profile behind whatever Addy is doing instead, and stop it at the end with `pkill -f -- '--profile test-air'`:

```bash
env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open -g -n /Applications/Theo.app --args --profile test-air
```

Use `$THEOUI_BINARY`'s app instead of `/Applications/Theo.app` if you're testing from the zip. A window of the test profile may show on the Air's screen. It doesn't take focus.

Then set the cheap models, once:

```python
from lib import *
send = client()
print(send({"cmd":"botUpdate","id":"theo","model":"claude-haiku-5-5"}))
print(send({"cmd":"harnessSet","codingTarget":"claude","codingModel":"claude-haiku-5-5","codingEffort":"low"}))
```

To see or click the window: `python3 "$SCRATCH/theoui.py" shot NAME` takes a screenshot of Theo's window only. `{"cmd":"uiWindows"}` lists its windows, popovers included, and `shot NAME <number>` takes one of them. `{"cmd":"uiClick","window":<number>,"x":..,"y":..}` clicks inside the app without moving the pointer, in window points, which are screenshot pixels divided by 2. `{"cmd":"uiType","text":".."}` types into the focused field of that window. `clicktext` needs an OCR tool that isn't on the Air, so read the screenshot yourself.

## 3. The rows

### Row 1: the "where you are" block

```python
r = send({"cmd":"uiBotPrompt","bot":"theo"})["result"]
print(r["awareness"])
```

✅ when it says "you're running on … MacBook Air" and folders and coding runs are on the MacBook Air, and it lists the Air's engines. It must not name the Mac Studio as where things run. It should also say who the bot is and what its job is.

### Row 2: a bot turn on the Air

```python
send({"cmd":"botSay","bot":"theo","text":"Which Mac are you on, and where would code go if I asked you to build something? One short sentence."})
wait_idle(send, 120)
print(chat(send, "theo", 1)[0]["text"])
```

✅ when it says the MacBook Air, with no offer to connect to the Mac Studio.

### Row 3: a coding run on the Air, and its device chip

```python
folder = PROJECTS/"air-run"; folder.mkdir(parents=True, exist_ok=True)
send({"cmd":"uiRunStart","prompt":"Create a file named hello.txt in the current folder containing the word one. Only that.","title":"Air run","folder":str(folder),"harness":"claude","model":"claude-haiku-5-5","effort":"low","room":"theo"})
```

Poll `{"cmd":"botsState"}` until the run with that title has `phase` done or failed. ✅ when the phase is done, `hello.txt` is in that folder and nowhere else, `origin` names the MacBook Air, and a screenshot of the chat shows the Air on the run's card. Also confirm `~/Projects/air-run` doesn't exist.

### Row 4: the folder menu with New folder

```python
send({"cmd":"botSay","bot":"theo","text":"Draft a coding prompt for one index.html that says hello. Only draft it: I'll choose the folder on the card and press Start myself."})
wait_idle(send, 120)
```

A card shows under the reply, with chips for the Mac, the folder and the chat. If Theo wrote no card, ask once more for a ```prompt block. On the card: click the folder chip, and take a screenshot of the popover through `uiWindows`. ✅ when it lists the projects in this profile's folder, plus "New folder…" and "Choose a folder…". Click "New folder…", type `air-new` with `uiType`, click Create. ✅ when `PROJECTS/air-new` exists with git and one empty commit, the chip now says `air-new`, and `~/Projects/air-new` doesn't exist. Don't press Start. Don't open "Choose a folder…", because that panel takes focus; mark that part ⚠️ not opened.

Also read the Chat chip. It should say "New chat", with no chats listed for a new folder.

### Row 5: continuing a thread in stock T3 Code

Theo opens T3 Code's server hidden if it isn't up. It only lists threads once the server is up, because stock T3's CLI can write into `~/.t3` without one.

```python
folder = PROJECTS/"air-t3"; folder.mkdir(parents=True, exist_ok=True)
send({"cmd":"uiRunStart","prompt":"Create a file named t3.txt in the current folder containing the word one. Only that.","title":"Air T3 first","folder":str(folder),"harness":"t3","model":"claude-haiku-5-5","room":"theo"})
# Wait for phase done, then:
chats = send({"cmd":"uiChatsList","harness":"t3","folder":str(folder)}, timeout=40)["result"]
print(chats)
send({"cmd":"uiRunStart","prompt":"What word is in t3.txt? Add a second line that says two. Only that.","title":"Air T3 second","folder":str(folder),"harness":"t3","model":"claude-haiku-5-5","room":"theo","chat":chats[0]["id"]})
```

✅ when the chat is listed, the second run's `chat` names it, `t3.txt` reads `one` then `two`, the agent's answer knows the word from before, and `~/.t3/bin/t3 thread list --project "<folder>" --json` shows **one** thread. Only run that CLI line with T3's server up: check the `pid` in `~/.t3/userdata/server-runtime.json` is alive, reading only that field.

Then check stock stayed stock:

```bash
~/.t3/bin/t3 --version
find ~/.t3 -type f -not -path '*/logs/*' -exec stat -f '%N %m' {} + | sort > "$SCRATCH/t3-after.txt"
diff "$SCRATCH/t3-before.txt" "$SCRATCH/t3-after.txt" | cut -d' ' -f2- | cut -c1-120
/usr/bin/grep -l -E '"(theo|claudia|clicky)|mcpServers' ~/.t3/userdata/*.json
```

✅ when the version is unchanged, the only changes are T3's own files from these two runs (its database, worktrees, and its settings files if opening its app touched them), nothing named bots, theo or claudia is new, and the `grep` lists no file. It prints file names only. Report file names only.

Press Stop on a T3 run only if one is still going. Stock has no `thread stop`, so Theo should say in the chat that it couldn't stop it, not claim it did.

### Row 6: Devices settings

In the test profile open Settings › Devices with `{"cmd":"uiGo","pane":"settings:devices"}`, and take a screenshot. ✅ when the MacBook Air shows "This Mac", "Bots & coding" says "The Mac you're using", and Routines has its own row.

From step 0, report what `v3.devices.bots` and `v3.devices.routines` hold on the real Air. Not set means it's on the new default. If `v3.devices.bots` is set to `macStudio`, someone picked that by hand, so it was kept: tell the coordinator, because the Air's bots would then want the Studio. Don't change it.

### Row 7: Gemini

Check whether Gemini is installed and signed in with `{"cmd":"harnessState"}`: read only `installed` and `loggedIn` from its entry in `harnesses`. If it is, use a folder under `PROJECTS`: one tiny run on its cheapest model, then `uiChatsList`, then a second run with `"chat":<its id>`, as in row 5. ✅ when it continues the same chat and the file has both lines. If it isn't signed in, mark it untested and **don't sign in**. Never call `gemini --list-sessions`, it writes.

### Row 8: Cursor's plan limit shows the real reason

If `cursor-agent` isn't installed or signed in on the Air, mark it untested. Otherwise, one run on the model the account refused on the Studio:

```python
folder = PROJECTS/"air-cursor"; folder.mkdir(parents=True, exist_ok=True)
send({"cmd":"uiRunStart","prompt":"Create a file named lim.txt in the current folder with the word one. Only that.","title":"Air limit","folder":str(folder),"harness":"cursor","model":"gpt-5.3-codex-low","room":"theo"})
```

This is the only Cursor run in this job that isn't on Auto. On the Studio the account refused it before any work, with "Additional usage is off". If the run starts working here, stop it from its card and mark the row untested.

`{"cmd":"uiRunPane","run":"<run id>"}` shows its screen. ✅ when the run ends as failed and the chat says "Cursor Agent can't run this on your plan: You've turned off usage beyond what's included…". ❌ if it says "hasn't started" or "done". Never call `cursor-agent ls`, it rewrites chats.

## 4. Clean up

```bash
python3 "$SCRATCH/theoui.py" stop
```

Or the `pkill` line from step 2. The `air-t3` project stays in T3 Code's list: on the Studio, T3's `project remove` refused a project that still had a thread, and its CLI can't delete threads. Report it, so Addy can remove it in T3 Code. Leave everything under `Theo-Test-air`. Don't delete anything else.

## 5. Report to the coordinator

- Build tested, and whether real Theo was updated or you ran from the zip.
- The eight rows with ✅, ⚠️ or ❌ and evidence paths.
- `v3.devices.bots` and `v3.devices.routines` on the real Air.
- Whether stock T3 is still stock, with the file names that changed.
- Everything your tests created or changed outside the test profile and your scratchpad.
