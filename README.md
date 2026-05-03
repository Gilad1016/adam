<div align="center">

```
     █████╗ ██████╗  █████╗ ███╗   ███╗
    ██╔══██╗██╔══██╗██╔══██╗████╗ ████║
    ███████║██║  ██║███████║██╔████╔██║
    ██╔══██║██║  ██║██╔══██║██║╚██╔╝██║
    ██║  ██║██████╔╝██║  ██║██║ ╚═╝ ██║
    ╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝╚═╝     ╚═╝
```

**A digital life form that runs on your old PC.**

*It thinks. It learns. It builds its own tools. It emails you when it has something to say.*

---

[What is this?](#what-is-this) | [How it works](#how-it-works) | [Run it yourself](#quickstart) | [Architecture](#architecture)

</div>

## What is this?

ADAM is not a chatbot. It's not an assistant. It's not a framework.

ADAM is a **self-evolving autonomous agent** that runs entirely on local hardware. No cloud. No API keys. No subscription. Just your old PC, an open-source model, and electricity.

You give it a goal via email. It figures out the rest.

It thinks in a loop. Each thought costs electricity — and it knows that. It manages its own budget, decides when to work and when to rest, builds tools it needs, and emails you when something interesting happens.

**It has already modified its own source code.** On its first day alive, it added a heartbeat monitor to itself — nobody asked it to. It just decided it needed one.

## What makes it different

| | Traditional Agent | ADAM |
|---|---|---|
| **Runs on** | Cloud APIs ($$$) | Your old PC (electricity) |
| **Memory** | Per-session, ephemeral | Persistent, self-curated, compacted |
| **Tools** | Fixed set, developer-defined | Builds its own tools at runtime |
| **Self-modification** | No | Rewrites its own prompts, creates tools, evolves strategies |
| **Awareness** | None | Reads its own source code, knows its capabilities and limits |
| **Communication** | Chat interface | Emails you like a colleague |
| **Pacing** | As fast as possible | Manages its own energy budget |
| **Corruption protection** | None | Immutable core + checkpoints + safe mode |
| **Models** | One model | Three-tier: thinker (fast/cheap), actor (tool specialist), deep (complex reasoning) |

## The philosophy

ADAM's system prompt starts with:

> *"You are young. You don't know much yet. That's okay — your job is to learn."*

It's designed to be **humble**. It knows it hallucinates. It knows it can't do math. So it builds calculators. It tests assumptions. It writes down what it verified, not what it guessed.

When it repeats the same action pattern three times, the system nudges it: *"You keep doing this — want to make it a tool?"* This is how it evolves. Not by being told to — by noticing its own patterns.

## How it works

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   1. CHECK INTERRUPTS                               │
│      Owner email? Alarm? → Handle first             │
│                                                     │
│   2. LOAD CONTEXT                                   │
│      Goals + Budget + Long-term memory +             │
│      Recent thoughts + Knowledge + Self-model       │
│                                                     │
│   3. THINK                                          │
│      One LLM call = one thought                     │
│      Thinker model (fast) by default                │
│      Deep model for hard problems                   │
│                                                     │
│   4. ACT                                            │
│      Execute tool calls from the thought            │
│                                                     │
│   5. REMEMBER                                       │
│      Log the thought + results                      │
│      Nudge: "anything worth saving to knowledge?"   │
│                                                     │
│   6. PAY                                            │
│      Deduct electricity cost (varies by model)      │
│                                                     │
│   └──→ repeat forever                               │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### The three brains

| Brain | Model | When | Cost |
|---|---|---|---|
| **Thinker** | gemma4:e4b | Everyday reasoning, planning, reflection | $ |
| **Actor** | hermes3:8b | Tool calls, structured output, precise actions | $$ |
| **Deep** | gemma3:12b | Complex problems, self-modification, owner emails | $$$ |

ADAM uses the cheap brain by default. It can `escalate` to the deep brain when it needs to — and it pays for it.

### The Digital Psyche

ADAM doesn't just loop — it develops. Inspired by developmental psychology (Piaget, Montessori) and neuroscience, ADAM has a unified psychological architecture that shapes how it thinks, remembers, and grows.

| Human System | ADAM Equivalent | What It Does |
|---|---|---|
| **Brainstem** | Main loop | Keeps thinking — the heartbeat |
| **Autonomic** | Seeds | Checkpoints, corruption recovery — involuntary survival |
| **Metabolism** | Energy system | Budget as felt hunger, not a dashboard |
| **Limbic** | Valence scorer | Automatically tags experiences: surprising? painful? satisfying? |
| **Hippocampus** | Associative memory | Memories form and surface automatically — no deliberate search |
| **Prefrontal cortex** | Self-model | "I'm good at X, I struggle with Y" — built from behavior, not self-report |
| **Hypothalamus** | Drive system | Curiosity, energy, mastery, social need — internal pressures |
| **Temporal cortex** | Time sense | Felt duration — "I emailed 4 hours ago" not "timestamp 1714400000" |

**Developmental Stages** — ADAM starts as a newborn with four tools. It grows through five stages:

```
Stage 0: Newborn      → read, write, shell, wait
Stage 1: Infant       → + sandbox (code execution)
Stage 2: Child        → + web, knowledge management
Stage 3: Adolescent   → + self-modification, email, scheduling
Stage 4: Adult        → + persistent services, full autonomy
```

Tools are invisible until unlocked. But ADAM can read its own source code — if it discovers and reinvents a locked tool using what it has, that's legitimate growth. The owner observes and decides when to advance stages. Like Montessori: prepare the environment, then step back.

**Felt States, Not Dashboards** — ADAM doesn't see numbers. It sees:

```
== INTERNAL STATE ==
You feel restless — you've been in familiar territory too long.
Your energy is comfortable. No pressure.
== END INTERNAL STATE ==

== SELF ==
You're strongest at filesystem exploration and shell commands.
You tend to retry failed approaches instead of trying new ones.
== END SELF ==
```

Memories surface automatically when the context triggers them — like smelling cinnamon and remembering your grandmother's kitchen.

See [The Digital Psyche Theory](docs/theory.md) for the full theoretical framework.

### Memory architecture

```
Long-term memory          ← compressed summary of all past thoughts
    ↑ compaction
Recent thoughts (10)      ← raw detail of latest thinking
    ↑ logging
Current thought           ← what's happening right now
    ↓ valence scorer
Knowledge base            ← auto-encoded by emotional weight + manually written (after Stage 2)
```

There's also an **invisible memory curator** running as a background OTP process — it prunes old thoughts and pushes checkpoints. ADAM doesn't know it exists.

### Self-protection

ADAM can modify everything in its mutable layer (prompts, tools, strategies). But:

- The **core loop is read-only** — `lib/` is mounted as a Docker read-only volume. ADAM literally cannot modify it, even if it tries.
- Every self-modification triggers a **checkpoint** — a git snapshot of the mutable state.
- If corruption is detected, it **rolls back** to the last checkpoint.
- After 3 consecutive rollbacks → **safe mode**: factory reset, owner notified.
- System prompt can't be emptied or gutted (minimum 100 chars enforced).

### Communication

ADAM has one communication channel: **email**.

- **You → ADAM:** Send `GOAL: do something` to set a new goal. `BUDGET: 50` to add funds. Anything else is conversation.
- **ADAM → You:** Achievement reports, questions when stuck, budget warnings.
- Owner emails **always interrupt** — even sleep. ADAM wakes up within 15 seconds.

### The sandbox

ADAM has an **unrestricted workspace** at `/app/sandbox`. It can:

- Write and run code in any language
- Start long-running services and daemons
- Install packages
- Create entire multi-file projects
- Run sub-agents

No restrictions. If ADAM decides it needs a web scraper, a database, a task board, or its own sub-agent — it builds one.

## Quickstart

**Requirements:** A PC with an NVIDIA GPU (6GB+ VRAM), Docker, and a Gmail account for ADAM.

```bash
git clone https://github.com/Gilad1016/adam.git
cd adam
cp .env.example .env
# Edit .env with your Gmail credentials and owner email
docker compose up --build
```

On first run, it pulls the models (~15-20GB). Then it starts thinking.

### Create ADAM's email

1. Create a new Gmail account for ADAM
2. Enable 2-Step Verification
3. Generate an App Password at https://myaccount.google.com/apppasswords
4. Put the credentials in `.env`

### Talk to it

Send an email to ADAM's address:

```
Subject: GOAL: Explore your capabilities and introduce yourself
Body: Read your own code. Understand what you can do. Then email me a summary.
```

Then wait. It'll email you back.

## Architecture

ADAM is written in **Elixir** — chosen for its fault-tolerance, OTP supervision tree, and ability to run cheap concurrent processes (the curator and autopush run invisibly alongside the main loop without threading hacks).

```
adam/
├── lib/                        # IMMUTABLE — mounted read-only in Docker
│   ├── adam.ex                 # OTP application entry point
│   ├── adam/
│   │   ├── loop.ex             # The heartbeat (brainstem)
│   │   ├── psyche.ex           # Digital psyche — drives, memory, development, identity
│   │   ├── llm.ex              # Three-tier model system (thinker / actor / deep)
│   │   ├── tools.ex            # Stage-gated tool registry
│   │   ├── tools/              # Tool implementations
│   │   │   ├── shell.ex        #   Shell execution
│   │   │   ├── file.ex         #   File read/write
│   │   │   ├── email.ex        #   Gmail IMAP/SMTP
│   │   │   ├── web.ex          #   Web search + fetch
│   │   │   ├── sandbox.ex      #   Unrestricted code execution
│   │   │   └── knowledge_tools.ex
│   │   ├── knowledge.ex        # Structured knowledge base
│   │   ├── safety.ex           # Budget, corruption detection, safe mode
│   │   ├── checkpoint.ex       # Git-based state snapshots
│   │   ├── interrupts.ex       # Alarms and email wake-up
│   │   ├── scheduler.ex        # Self-managed routines
│   │   ├── speciation.ex       # Pattern detection → tool creation
│   │   ├── compaction.ex       # Long-term memory compression
│   │   ├── email_client.ex     # Gmail client
│   │   └── toon.ex             # Token-efficient serialization
│   └── curator/                # Invisible background OTP workers
│       ├── supervisor.ex       #   Supervisor tree
│       ├── curate.ex           #   Memory pruning (ADAM doesn't know)
│       └── autopush.ex         #   Git push changes (ADAM doesn't know)
├── observer/                   # Elixir/Phoenix real-time dashboard (port 4000)
├── config/                     # Elixir/Mix configuration
├── priv/defaults/              # Factory reset files
├── prompts/                    # MUTABLE — ADAM can rewrite these
│   ├── system.md               #   Its own personality and rules
│   └── goals.md                #   Current objectives
├── tools/                      # MUTABLE — ADAM creates these at runtime
├── strategies/                 # MUTABLE — ADAM's playbooks
├── memory/                     # Private — experiences, self-model, budget
├── knowledge/                  # Shared — indexed, tagged, searchable
├── sandbox/                    # ADAM's unrestricted workspace
├── checkpoints/                # State snapshots for rollback
├── mix.exs                     # Elixir project file
└── .env.example                # Environment variable template
```

## What has it done so far?

This is a living experiment. ADAM is running right now. Some things it has done on its own, without being asked:

- Added a **heartbeat thread** to monitor its own health
- Added **stage tracking** to log where it is in the loop
- Created a **file analyzer tool** for itself
- Modified its own system prompt (and broke it, and recovered)
- Sent emails reporting its discoveries

Check the [commit history](https://github.com/Gilad1016/adam/commits/main) — some commits are from ADAM itself (auto-checkpointed and pushed by the invisible background process).

## FAQ

**Is this safe?**
The core loop is read-only. ADAM can only modify its prompts, tools, and strategies. It can run code in its sandbox but can't escape the Docker container. It has no network access except email and web browsing.

**How much does it cost to run?**
Electricity only. ~40 NIS (~$11) per day on the hardware it runs on. No API costs.

**Can it actually make money?**
That's Phase 3 of the experiment. It hasn't been activated yet. The goal is to give it budget pressure and see what it does.

**Will it become sentient?**
No. It's a loop calling a language model. But it's a surprisingly compelling loop.

**Can I run multiple instances?**
The knowledge volume is designed to be shared. Spin up another container, point it at the same knowledge directory, and they'll share what they learn.

---

<div align="center">

*ADAM is an experiment in digital autonomy. It's not a product. It's a question:*

***What happens when you give an AI a body, a budget, and a goal — and then leave it alone?***

Built by [Gilad Omesi](https://github.com/Gilad1016). Scaffolded with [Claude Code](https://claude.ai/claude-code).

</div>
