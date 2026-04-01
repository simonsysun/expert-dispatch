# expert-dispatch

Delegate complex tasks from your AI assistant to specialist backends like Claude Code, keeping your main agent cheap and your specialist work high-quality.

## The Pattern

Most AI assistants use one model for everything. That's wasteful: routine tasks don't need a top-tier model, but complex tasks do.

**expert-dispatch** implements the **Specialist Dispatch Pattern**: your main assistant handles daily work with a cheap model. When it encounters something that needs depth — coding, analysis, research — it dispatches to a specialist that runs locally.

```
User (chat interface)
  -> Main Assistant (cheap model — daily tasks, email, calendar)
       -> Complex task detected
            -> dispatch-cc run --slug my-api --prompt "build X"
            -> Claude Code works autonomously in project directory
            -> Returns structured JSON result
       <- Assistant summarizes and reports back
  <- User gets expert-quality output
```

Your assistant is the **secretary**. The specialist is the **expert consultant**. The secretary manages; the expert does the deep work.

## Prerequisites

- **bash** 3.2+ (macOS default works; Linux default works)
- **python3** (for JSON parsing)
- **Claude Code CLI** installed and authenticated ([install guide](https://claude.ai/claude-code))
- **timeout** or **gtimeout** — included on Linux; on macOS: `brew install coreutils`
- `~/.local/bin` in your `$PATH` (or install wherever you prefer)

## Quick Start

### 1. Install

```bash
cp adapters/claude-code.sh ~/.local/bin/dispatch-cc
chmod +x ~/.local/bin/dispatch-cc

dispatch-cc --version
```

### 2. Run a task

```bash
dispatch-cc run --slug my-api \
  --desc "Flask REST API for tasks" \
  --prompt "Create a Python Flask REST API with CRUD endpoints for tasks. Use SQLite."
```

### 3. See the result

```bash
dispatch-cc status --slug my-api
```

Output:
```
Project: my-api
Path: /home/user/dispatch-projects/my-api
Last session: a1b2c3d4-...
Last run: 20260331-143022-12345-result.json
  Status: success
  Duration: 45.2s
  Turns: 8
  Stop reason: end_turn

Last result:
  Created a Flask REST API with full CRUD for tasks...
```

The raw JSON output from Claude Code contains:
```json
{
  "result": "Created a Flask REST API with full CRUD...",
  "is_error": false,
  "num_turns": 8,
  "stop_reason": "end_turn",
  "session_id": "a1b2c3d4-..."
}
```

### 4. Iterate with feedback

```bash
dispatch-cc resume --slug my-api \
  --prompt "Add pagination to GET /tasks. Default 20 per page."
```

### 5. Independent review

```bash
dispatch-cc review --slug my-api
```

## Commands

| Command | Description |
|---------|-------------|
| `run` | Create a project and execute a task |
| `resume` | Continue a previous session with new input |
| `review` | Independent quality review of a project |
| `status` | Show project details and last run info |
| `list` | List all projects with descriptions |
| `search` | Find projects by keyword |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DISPATCH_PROJECTS_DIR` | `~/dispatch-projects` | Where project directories are created |
| `DISPATCH_CC_BIN` | auto-detect | Path to `claude` CLI |
| `DISPATCH_TIMEOUT` | `600` | Default timeout in seconds |
| `DISPATCH_PERMISSION` | `acceptEdits` | Permission mode (see Permissions below) |

## Permissions and Security

Claude Code in headless mode (`-p`) needs a permission policy that doesn't require interactive approval. The adapter defaults to `acceptEdits`, which auto-approves file reads and writes but still logs all actions.

**Permission modes:**

| Mode | What it auto-approves | Best for |
|------|----------------------|----------|
| `acceptEdits` (default) | File reads/writes | Most use cases — CC can create/edit files |
| `plan` | Nothing — read-only analysis | Review, auditing, research tasks |
| `dangerously-skip-permissions` | Everything including shell commands | Trusted/sandboxed environments only |

To change:
```bash
export DISPATCH_PERMISSION="dangerously-skip-permissions"  # fully autonomous
export DISPATCH_PERMISSION="plan"                          # read-only
```

> **Warning:** `dangerously-skip-permissions` skips ALL permission checks including shell execution. Only use in environments where you trust the input. See [Claude Code permission docs](https://code.claude.com/docs/en/permissions).

**What happens when permissions block an action:** The adapter detects `permission_denials` in CC's output and reports the run as BLOCKED (visible in `dispatch-cc status`), so you know the task didn't fully complete.

**Data flow:** Prompts and code are sent to Anthropic's API for processing. The adapter itself does not handle provider credentials, but Claude Code can read files in the project working directory. Review [Claude Code's data usage policy](https://docs.anthropic.com/en/docs/claude-code/data-usage) for details.

## How It Works

Each project gets its own directory:

```
my-api/
  CLAUDE.md              # Project context (auto-created, CC loads this)
  src/                   # Your code (created by CC)
  .dispatch-logs/
    project.json         # Metadata (slug, description, timestamps)
    last-session-id      # For resume continuity
    last-result.txt      # Last output text
    *-result.json        # Full JSON output (audit trail)
```

Key behaviors:
- **Session persistence** — session IDs saved for `resume`
- **Project context** — `CLAUDE.md` is auto-loaded by CC; add conventions and constraints there
- **Per-project locking** — concurrent runs on different projects are allowed
- **Audit trail** — every run logged with full output

## Integrating with Your Assistant

The adapter is designed to be called by another AI system. See [`examples/dispatch-guide.md`](examples/dispatch-guide.md) for a template that teaches your assistant when and how to dispatch.

The orchestration loop:
1. User gives task → assistant clarifies intent
2. Assistant writes spec → `dispatch-cc run`
3. CC works → returns JSON result
4. Assistant reports to user
5. User has feedback? → `dispatch-cc resume` with context
6. Repeat until done

## Extending

The adapter interface is straightforward: any CLI that accepts a prompt and returns structured output can be wrapped in the same `run / resume / review / status / list / search` pattern. The concept is not tied to Claude Code.

## Cleanup

Projects are stored in `$DISPATCH_PROJECTS_DIR` (default `~/dispatch-projects`). To remove:

```bash
rm -rf ~/dispatch-projects/<slug>    # remove one project
rm -rf ~/dispatch-projects            # remove everything
rm ~/.local/bin/dispatch-cc           # uninstall
```

## Important Notes

- **Provider terms**: Users are responsible for ensuring their use complies with the terms of service of their chosen specialist backend.
- **Privacy**: Prompts and code are sent to the specialist provider's API for processing. Review their data handling policies.
- **Credentials**: The adapter does not directly handle provider credentials. It invokes the specialist CLI, which manages its own authentication.

## License

MIT
