# Tom & Jerry: Supervisor/Worker Agent Design 

## 1. Summary

Two models, three logs, one job record, one persistent memory for Tom.

- **Tom** is the supervisor. He talks to the user and to Jerry, and to nothing else. His tools are job operations plus a memory store. He is woken on every event and fully manages Jerry, including sending work back without consulting the user.
- **Jerry** is the worker. He talks to Tom and proposes real tool calls. Every proposed call is gated by user approval before it runs (this gate already exists; the design just records its events). Jerry never sees the user and has no memory beyond the current session.
- **The harness** owns all state: logs, job records, status, Tom's memory. Exactly one Tom instance and exactly one Jerry instance exist; both process their work serially from queues.

The user sees everything and writes only to Tom.

## 2. Core principles

1. **State lives in the harness.** Models hold no state the harness does not also hold. Status is written by the harness, never claimed by a model.
2. **One of each.** A single Tom loop and a single Jerry loop. Concurrency exists only at the level of job records; execution is serialized.
3. **Tom is always awake for events.** Every harness event (status change, tool proposed/approved/rejected/result, question from Jerry) queues a Tom turn. Tom may respond with nothing.
4. **Jerry is session-scoped.** Jerry's context is the current user↔Tom session only. Prior sessions do not exist for him. Durable knowledge lives in Tom's memory, not Jerry's history.
5. **Tom learns; Jerry does not.** Tom has a persistent, user-visible notes store he reads at the start of every turn and writes after jobs complete.

## 3. Data model

### 3.1 Three event logs

| Log | Participants | Written by | Contents |
|---|---|---|---|
| `L1` | user ↔ Tom | user, Tom | plain messages |
| `L2` | Tom ↔ Jerry | Tom, Jerry, harness | messages, job specs, status events, questions |
| `L3` | Jerry ↔ tools | harness only | `tool_proposed`, `tool_approved` / `tool_rejected`, `tool_result` |

Append-only, timestamped, tagged with `session_id` and (where relevant) `job_id`.

### 3.2 Job record

```yaml
job:
  id: j17
  session_id: s4
  spec:
    goal: "..."
    constraints: ["..."]
    done_criteria: "..."
    return: "..."
  status: queued | running | awaiting_approval | blocked | done | failed
  blocked_on: null | "question text"
  events: []               # harness-written
  result:
    summary: "..."         # written for Tom to relay verbatim
    details: "..."         # for the user to expand
    artifacts: []
  revisions: 0             # incremented each time Tom sends it back
```

### 3.3 Tom's memory

```yaml
memory:
  user_prefs:   ["Uses Spotify, not Apple Music", "Max volume 40 after 22:00", ...]
  jerry_playbook: ["Jerry won't adjust volume unless it's a named step in done_criteria", ...]
  failures:     ["j12: spec said 'queue' and Jerry interpreted as 'play now'", ...]
```

Plain text, bounded (e.g. ≤ 60 lines), shown to the user in the UI, editable by the user, read into Tom's prompt every turn. Tom writes to it via tools (§4.1).

### 3.4 Views

| Reader | Prompt built from | Scope |
|---|---|---|
| Tom | `memory` + `L1` + `L2`, interleaved by time + list of open jobs | current session |
| Jerry | `L2` (his jobs) + `L3` + full job record | current session; rolling window within the session if it gets long, job record always pinned |
| UI | `L1` + `L2` + `L3` + `memory` | everything, three lanes plus a memory panel |

Tom never sees `L3` (he sees the *events* "tool proposed/approved/rejected", not raw results). Jerry never sees `L1` or `memory`.

## 4. Tool surfaces

### 4.1 Tom

| Tool | Effect |
|---|---|
| `delegate(spec)` | creates job, status `queued`, enqueues for Jerry; returns `job_id` |
| `get_status(job_id)` | status, `blocked_on`, recent events, `result` if done |
| `message_jerry(job_id, text)` | appends to `L2`. On a `blocked` job: unblocks. On a `done` job: reopens it (status `queued`, `revisions += 1`) |
| `cancel(job_id)` | status `failed`, removed from queue |
| `remember(section, note)` | appends a line to memory |
| `forget(section, note)` | removes a line |

Tom has no other tools. A Tom turn may end with: a message to the user, a message to Jerry, memory edits, any combination, or nothing.

### 4.2 Jerry

Any real tool, plus:

| Tool | Effect |
|---|---|
| `ask_tom(question)` | status `blocked`; Jerry loop moves to the next queued job |
| `finish(result)` | writes `result`, status `done`; Jerry loop moves to the next queued job |

A real tool call does not execute immediately. The harness records `tool_proposed`, sets status `awaiting_approval`, and waits for the user. On approval it runs the tool and records `tool_result`. On rejection it records `tool_rejected` and returns a rejection as the tool result, so Jerry can adapt (ask Tom, try another approach, or finish with a partial result).

## 5. Execution model

### 5.1 The two loops

**Tom loop** — one instance, serial.
```
loop:
  item = tom_queue.pop()         # user message | harness event
  build prompt (memory + L1 + L2 + open jobs)
  run Tom
  apply tool calls; append outputs to L1 / L2
```

**Jerry loop** — one instance, serial.
```
loop:
  job = job_queue.pop_oldest(status == queued)   # FIFO, includes reopened and unblocked jobs
  job.status = running
  run Jerry agent loop on job until finish / ask_tom / cancel
  (tool calls inside the loop block on user approval)
```

A job that is `blocked` or `done` leaves the Jerry loop; the next queued job starts. A job that Tom unblocks or reopens re-enters the queue at the back. While Jerry is `awaiting_approval`, he does not switch jobs: the user is the one holding him, and switching would interleave approval prompts from different jobs confusingly.

### 5.2 Which events wake Tom

All of them. In practice:

| Event | Tom's typical response |
|---|---|
| `tool_proposed` / `tool_approved` / `tool_result` | usually nothing; occasionally a corrective `message_jerry` if the plan looks wrong |
| `tool_rejected` | often nothing (user has spoken); sometimes a `message_jerry` with a hint, or a note to the user |
| `blocked` (Jerry asked a question) | answer from context/memory, or relay to the user |
| `done` | check result against spec; either relay to the user, or `message_jerry` to send it back; then `remember` anything learned |
| `failed` | tell the user |

"Nothing" is a legitimate and common Tom output. Since tens of tool calls per job are rare, the cost of waking Tom for each is acceptable.

### 5.3 Session boundaries

A session is one user↔Tom conversation. At session start: Jerry's view is empty; Tom's memory is loaded; any jobs still open from a previous session are listed to Tom as open jobs (the job records persist, Jerry's chat history does not).

## 6. Sequence diagram

```mermaid
sequenceDiagram
    actor U as User
    participant T as Tom (1 instance)
    participant H as Harness
    participant J as Jerry (1 instance)
    participant X as Tools

    Note over T: every turn starts by reading memory
    U->>T: request (L1)
    T->>H: delegate(spec j17)
    T->>U: "delegated as j17" (L1)

    H->>J: pop j17, status=running
    J->>J: intent (L2)
    J->>H: propose tool call
    H->>H: status=awaiting_approval, log tool_proposed (L3)
    H-->>T: wake: tool_proposed
    T-->>H: (no output)
    U->>H: approve
    H->>X: execute
    X-->>H: raw result
    H-->>J: tool_result (L3)
    H-->>T: wake: tool_result
    T-->>H: (no output)

    U->>T: second request (L1)
    T->>H: delegate(spec j18)  — queued behind j17
    T->>U: "queued as j18" (L1)

    J->>H: finish(result)
    H->>H: j17 status=done
    H-->>T: wake: done
    T->>T: compare result vs spec
    T->>H: message_jerry(j17, "redo: ...")  — reopened, queued
    H->>J: pop j18 (oldest queued)
    Note over J: j18 runs; j17 revision waits its turn
    J->>H: finish(j18)
    H-->>T: wake: done
    T->>U: relays j18 summary (L1)
    H->>J: pop j17 (revision 1)
    J->>H: propose tool call
    U->>H: reject
    H-->>J: tool_rejected
    J->>J: adapt
    J->>H: finish(result)
    H-->>T: wake: done
    T->>U: relays j17 summary (L1)
    T->>H: remember(jerry_playbook, "...")
```

## 7. Minimal illustrative exchange

One session. Exercises: memory read, delegation with a visible spec, approval gate (approve and reject), Tom waking on events and staying silent, a second job queued behind the first, Tom sending a job back without asking the user, Jerry adapting to a rejection, summary/details separation, and Tom writing a memory note.

```
[mem] user_prefs:     Uses Spotify. Keep volume ≤ 40 after 22:00.
[mem] jerry_playbook: (empty)

[L1] User → Tom:   put on something for focus

[L2] Tom → Jerry:  delegate(j17)
                   goal:          Start focus-friendly music on Spotify.
                   constraints:   Spotify only. It's 22:30 — volume ≤ 40.
                   done_criteria: Music is playing and volume is ≤ 40.
                   return:        summary (what's playing, volume), details.
[L1] Tom → User:   On it — j17.
[L2] harness:      j17 running

[L2] Jerry:        I'll search for a focus playlist.
[L3] proposed:     spotify.search(q="focus", type="playlist")
[L2] harness:      j17 awaiting_approval
     (Tom woken — no output)
[L3] approved by user
[L3] result:       [{id:"pl-3", name:"Deep Focus"}, {id:"pl-9", name:"Lo-Fi Beats"}]
     (Tom woken — no output)
[L2] Jerry:        "Deep Focus" fits. Playing it.
[L3] proposed:     spotify.play(playlist="pl-3")
[L3] approved by user
[L3] result:       {playing: true, volume: 65}
     (Tom woken — no output)
[L2] Jerry:        finish({ summary: "Playing 'Deep Focus' on Spotify.",
                            details: "Searched 'focus', chose pl-3, started playback." })
[L2] harness:      j17 done

[L1] User → Tom:   also set a 25 min timer

[L2] Tom → Jerry:  delegate(j18)
                   goal: Start a 25-minute timer.  done_criteria: timer running.
[L1] Tom → User:   Queued as j18, right after the music finishes setting up.

     (Tom woken: j17 done)
[L2] Tom → Jerry:  message_jerry(j17, "Result shows volume 65; spec requires
                   ≤ 40. Set volume to 40 and finish again.")
[L2] harness:      j17 reopened (revision 1), queued behind j18

[L2] harness:      j18 running
[L2] Jerry:        Starting the timer.
[L3] proposed:     clock.set_timer(minutes=25)
[L3] approved by user
[L3] result:       {timer_id:"t-4", ends_at:"22:57"}
[L2] Jerry:        finish({ summary: "25-minute timer set, ends 22:57." })
[L2] harness:      j18 done
     (Tom woken: j18 done)
[L1] Tom → User:   Timer's set, ends at 22:57.

[L2] harness:      j17 running (revision 1)
[L2] Jerry:        Lowering volume to 40 as requested.
[L3] proposed:     spotify.set_volume(40)
[L3] approved by user
[L3] result:       {volume: 40}
[L2] Jerry:        Volume is 40. I'll also save this playlist for next time.
[L3] proposed:     spotify.save_playlist("pl-3")
[L3] rejected by user
[L2] Jerry:        Understood, skipping the save. Finishing.
[L2] Jerry:        finish({ summary: "Playing 'Deep Focus' on Spotify at volume 40.",
                            details: "...search, play, volume set; save rejected..." })
[L2] harness:      j17 done
     (Tom woken: j17 done)
[L1] Tom → User:   'Deep Focus' is playing at volume 40.   [▸ details] [▸ tool log]
[L2] Tom:          remember(jerry_playbook, "Jerry ignores volume constraints
                   unless set_volume is an explicit step in done_criteria.")
[L2] Tom:          remember(user_prefs, "Declines having playlists saved to library.")
```

Tom never saw the search results or the raw play response. He saw the *events*, the spec, and the result, which was enough to catch the volume miss and fix it before the user noticed.

## 8. Does learning fix the spec-quality bottleneck?

Partly, and the other part is fixed by something else in this design.

The bottleneck has two components:

1. **Recurring knowledge gaps** — which service the user uses, what Jerry tends to misread, what phrasing works. Memory addresses this directly. Each miss becomes a playbook line, and that line changes the next spec. For the "play a song" class of task, this is most of the problem: the task structure is simple and the errors are almost all preference or convention errors, which are exactly what a notes store captures.

2. **Novel, first-time tasks** — Jerry can't see the user, so a new kind of request still depends on Tom's first-shot spec. Memory can't help here because there is nothing to remember yet.

The second component is handled by **Tom being woken on every event and allowed to send work back.** A bad spec no longer produces a bad outcome; it produces a `done` event Tom inspects against the spec and reopens. The user approval gate adds a second safety net: a misguided tool call is visible and rejectable before it runs. Together these turn spec quality from a one-shot requirement into an iterative one. The cost is latency and extra revisions, which you've accepted.

What remains: first attempts at novel tasks will be sloppier than later ones, and Tom's inspection of results is only as good as the `return` shape he asked for. The mitigation is to have Tom always request enough in `return` to verify `done_criteria` (as he did with volume above). That is itself a good playbook note.

## 9. Design justifications

**Why one Tom and one Jerry.**
Multiple instances would need locking on job records and memory, would interleave approval prompts from different jobs, and would let two Toms give the user contradictory updates. Serial loops over queues give the same concurrency at the job level (many open jobs) with none of the coordination cost. The user is in the loop on every tool call anyway, so parallel Jerries would mostly be waiting on the same person.

**Why three logs.**
Keeps tool traffic out of Tom's context, lets the harness record ground truth instead of relying on Jerry's narration, and makes isolation a query over logs rather than a prompt rule.

**Why status is harness-written.**
Tom's check-ins are only trustworthy if the thing he reads is not authored by Jerry. Every transition is a side effect of a tool call, an approval, `finish`, or `ask_tom`, all performed by the harness.

**Why Tom wakes on every event.**
It lets Tom catch problems mid-flight (a wrong tool proposed, a rejection Jerry mishandles) rather than only at `done`. "No output" is cheap and is the usual answer. This is what makes "Tom fully manages Jerry" true rather than aspirational.

**Why Jerry is session-scoped with no memory.**
Jerry's history is mostly tool noise; carrying it across sessions would bloat his context with stale detail and give him a second, uncontrolled place to "learn" wrong things. Durable knowledge belongs in one place, under Tom, where the user can see and edit it.

**Why memory is plain text, bounded, and user-visible.**
Learning systems drift. A readable, editable, capped notes store means a wrong lesson can be spotted and deleted by the user, and Tom can be asked to justify a spec by pointing at the note he used. Bounded size forces Tom to prune rather than accumulate.

**Why `message_jerry` on a done job reopens it rather than creating a new job.**
Keeps the revision history under one `job_id`, so the UI shows "j17, revision 1" and the user can see why it was sent back. A new job would lose the link between spec, result, and correction.

**Why Jerry doesn't switch jobs while awaiting approval.**
The user is the blocker. Switching would present approval prompts from two jobs interleaved, which is confusing, and would gain nothing since the same user approves both.

**Why rejection is a tool result, not an error.**
Jerry needs to continue sensibly after a rejection. Returning it as a structured result ("rejected by user") lets him adapt in his normal loop rather than crashing the job.

## 10. Keeping small models on track (as built)

The prompts and the harness assume the models are small and drift:

- Each role's prompt is a numbered list of what to do, with a worked example in its own tools (Tom: a `delegate` call, a `(nothing)` on an event, a relay and a send-back; Jerry: narrate + tool, then `finish`). The tool manual's example is the role's own tool, since models copy the shape they're shown.
- Each of these is caught and the model is asked once, with a note from the Mac, for the right thing: Tom addressing Jerry in words (Jerry hears only tool calls); Tom claiming he can't; Jerry answering in words with no `finish`/`ask_tom`/tool; a tool call that didn't parse (cut off, single quotes); Jerry still calling tools past a job's round limit (asked to finish with what he has); two turn-ending calls in one answer (only the first is made); the same goal delegated while a job with it is open (not created). One nudge per turn each, so a model that doesn't take it can't be sent round in circles.
- `message_jerry` on the job Jerry is working reaches him mid-job (an interjection before his next model call), not at the next pickup.
- Jerry's chat is fresh for each job; the job record (spec, Tom's messages, Jane's advice, tools used, the last result) is pinned in the briefing. Every request asks for a 16k context so a page read doesn't push the system prompt and spec out.

## 11. Tom as router, Jane as the brain (as built)

Small models answer what they half know instead of handing it off, say "I'll have Jerry check" and then don't, and answer "how's it going?" about themselves. So Tom's role is narrowed until it's nearly mechanical:

- **Tom is the face.** He understands the user, routes every request, follows the jobs and answers only from them. He never answers a request himself: anything to do or look up is `delegate` (Jerry, the engine); anything to know, explain, decide, plan or write is `ask_jane` (Jane, the brain). Only greetings, thanks and status are his own words.
- **Jane answers questions** as jobs of her own (`spec.worker = "Jane"`): her own queue, one at a time, beside Jerry's; no tools; her answer is the result, read out in her voice; Tom is woken on `done` like any job. She also still reviews a job Tom sends back. When something goes wrong Tom can't sort out, he asks her.
- **Status first.** Every user message reaches Tom prefixed with the board's standing in one line ("Where the jobs stand now (from the Mac): j3 (Jerry): running: …; The user says: …"). His rule 3 says to read it first and lead with it while a job is open.
- **Router nudge.** A user request (anything but greetings, thanks, yes/no or a status question) that Tom answers in words with no job, or any answer that promises work ("I'll have Jerry…", "let me look", "one moment") without the call, gets one note: nothing is being done; call `delegate` or `ask_jane`. A question back ("Which city?") or an answer after a memory or status tool stands.
- **One engine.** Jerry's skills are the library and Tool Mac Tool Run, whose scripts reach the browser, files, the clipboard and the Mac. The scripts and flows are fetched as AI Listen starts and put in Jerry's prompt by name (and summarized in Tom's), so specs and calls name what exists. Runs wait for the card's click and the run (no `async`), so Jerry reads the output in the same turn.

## 12. Open choices

- **Tom chattiness.** With a wake on every event, Tom needs a clear rule in his prompt: speak to the user only on `done`, `failed`, `blocked`-needs-user, or when correcting course; otherwise stay silent.
- **Approval timeouts.** Decide what happens if the user never approves: leave the job `awaiting_approval` indefinitely (simplest, and Jerry is idle anyway) or expire to `tool_rejected` after N minutes.
- **Memory pruning.** When the cap is hit, Tom must `forget` before `remember`. Consider a periodic "review memory" wake.
- **Queue ordering.** FIFO is proposed. If a reopened revision should jump the queue (it usually should, since the user is waiting on it), give revisions priority over fresh jobs.
