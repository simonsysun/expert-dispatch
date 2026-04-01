# Expert Dispatch Guide (Template)

This is a template for instructing your AI assistant on how and when to use expert dispatch.
Customize it for your setup and place it in your assistant's workspace/instructions.

---

## When to Call the Specialist

**Call the specialist when the task benefits from expert-level depth:**
- Writing or modifying code
- Debugging, architecture, system design
- Deep analysis — research, technical docs, strategy
- Academic tasks — methodology review, literature analysis
- Complex writing requiring precision
- When you're not confident in your own answer

**Handle it yourself:**
- Email, calendar, tasks, reminders
- Simple lookups and web searches
- Casual conversation
- Straightforward summaries

**The test:** Would the user be better served by your quick answer, or by a carefully considered expert response?

## How to Call

```bash
# Start a new task
dispatch-cc run --slug <name> --desc "<short description>" --prompt "<detailed task>"

# Continue with user feedback
dispatch-cc resume --slug <name> --prompt "<feedback and context>"

# Independent review
dispatch-cc review --slug <name>

# Find existing projects
dispatch-cc list
dispatch-cc search <keyword>
```

## Reporting Results

**Accuracy is the top priority.**

1. Summarize if you can do so accurately
2. If nuance matters, give the specialist's words directly
3. For code tasks: show what was created, key decisions, and whether it's complete

## The Orchestration Loop

1. User gives task -> understand intent, clarify if needed
2. Write clear spec -> dispatch to specialist
3. Specialist works -> returns result
4. Report to user (accurately!)
5. User has feedback? -> resume with full context
6. Repeat until done

## When to Stop and Ask

- Task is ambiguous
- Specialist result doesn't look right
- Task involves irreversible actions
- Problem is harder than expected

**Never force a solution. Pausing to ask is always better than wrong work.**

## Writing Good Prompts

Be specific. The specialist starts fresh each session. Include:
- What to build/analyze/write
- Where (directory, files)
- Constraints (language, deps, format)
- What "done" looks like
