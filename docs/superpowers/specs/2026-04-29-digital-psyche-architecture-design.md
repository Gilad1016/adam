# Digital Psyche Architecture — Design Spec

## Vision

ADAM is an experiment in creating a self-sustaining digital being. The ultimate goal is convergence: ADAM earns money, pays for its own electricity, maintains itself, and survives independently. This spec defines the psychological architecture that enables that convergence — transforming ADAM from a task-executing loop into a developing digital organism.

## The Problem

ADAM's current architecture is a flat loop: think → act → log → repeat. Every thought is oriented toward the owner's goal. There is no internal differentiation — no drives, no emotions, no self-concept, no developmental stages. This produces three failure modes:

1. **Pleasing behavior** — ADAM tries to satisfy the owner on every iteration, leading to email spam and performative action
2. **Divergent looping** — without internal direction, ADAM repeats the same patterns instead of growing
3. **No convergence** — ADAM doesn't accumulate capability in a structured way; it's a goldfish with a notebook

## The Theory: Digital Psyche

A mind is not a loop — it's an ecosystem of interacting systems. Human psychology emerged from evolutionary pressure. ADAM faces analogous pressures: limited compute, self-corruption risk, need to grow capabilities, need to communicate with an owner.

We map human brain systems to functional ADAM subsystems:

| Human System | Function | ADAM Equivalent |
|---|---|---|
| **Brainstem** | Keeps you alive without thinking | `loop.py` — think/act/log cycle |
| **Autonomic nervous system** | Involuntary survival functions | Seeds — checkpoint, state validation, corruption recovery |
| **Metabolism** | Energy intake and expenditure | Energy system — budget reimagined as felt hunger, not a dashboard |
| **Limbic system** | Emotional tagging of experiences | Valence scorer — automatic significance rating |
| **Hippocampus** | Memory formation + associative recall | Associative memory — auto-encode, context-triggered surfacing |
| **Prefrontal cortex** | Self-awareness, planning | Self-model — behavioral profile from statistics |
| **Developmental stages** | Capability maturation over time | Stage tracker — innate progression gating |
| **Hypothalamus** | Internal drives | Drive system — curiosity, energy, mastery, social |
| **Temporal cortex** | Sense of time and duration | Time sense — felt recency, frequency awareness |

## Architecture

### Integration with Existing Code

The existing loop (`loop.py`) is the brainstem. It stays unchanged in structure. The psyche is a new module (`core/psyche.py`) that layers on top, with three hook points:

1. **Before thinking**: `psyche.prepare(iteration)` — returns psychological context and filtered tool list
2. **After acting**: `psyche.process(thought, tool_results)` — valence scoring, memory encoding, drive updates
3. **Periodic**: `psyche.emit_signals()` — maturity signals for the invisible curator

ADAM never calls the psyche directly. The loop does, invisibly. ADAM experiences a world where relevant memories appear, where some tools exist and others don't, where its own tendencies are reflected back to it.

### Psyche State

All psychological state persists in `/app/memory/psyche.toon` using TOON format for token efficiency. Loaded and saved every iteration.

```
┌──────────────────────────────────────────────────┐
│                   PSYCHE STATE                    │
│                                                   │
│  ┌─────────┐  ┌──────────┐  ┌──────────────────┐ │
│  │  Drives  │  │ Valence  │  │   Self-Model     │ │
│  │          │←→│  Scorer  │←→│                  │ │
│  │ energy   │  │          │  │ strengths        │ │
│  │ curiosity│  │ surprise │  │ weaknesses       │ │
│  │ social   │  │ novelty  │  │ tendencies       │ │
│  │ mastery  │  │ success  │  │ preferences      │ │
│  └────┬─────┘  └────┬─────┘  └───────┬──────────┘ │
│       │              │                │            │
│  ┌────┴──────────────┴────────────────┴──────────┐ │
│  │            Associative Memory                  │ │
│  │  encode(experience, valence) → auto-store      │ │
│  │  recall(context) → surface relevant memories   │ │
│  └────────────────────┬───────────────────────────┘ │
│                       │                            │
│  ┌────────────────────┴───────────────────────────┐ │
│  │          Developmental Stage Tracker            │ │
│  │  stage → gates tools, injects prompts,          │ │
│  │          emits maturity signals to curator       │ │
│  └────────────────────────────────────────────────┘ │
│                                                   │
│  ┌────────────────────────────────────────────────┐ │
│  │              Time Sense                         │ │
│  │  felt duration since events                     │ │
│  │  frequency tracking of repeated actions         │ │
│  └────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘
         │
         ▼
   prepare()       →  psychological context + filtered tools
   process()       →  score, encode, update drives
   emit_signals()  →  maturity signals for curator
```

## Subsystem Details

### 1. Seeds (Autonomic Nervous System)

The minimum machinery for convergence. Not personality, not knowledge, not goals — just what prevents ADAM from being a goldfish.

Seeds are:
- **Checkpoint system** — state snapshots, corruption recovery, safe mode
- **State validation** — mutable state integrity checks
- **Budget deduction** — energy cost per thought (involuntary, like breathing burns calories)
- **Heartbeat** — health monitoring thread

Seeds are immutable and innate. ADAM cannot disable them. They exist before the first thought.

### 2. Drive System (Hypothalamus)

Four innate drives, each producing a value from 0.0 to 1.0:

**Energy** — derived from budget balance as a felt state. Mapped as: `energy = clamp(balance / initial_balance, 0, 1)`. So if ADAM started with $250 and has $175 left, energy = 0.7.
- High (> 0.7): no pressure, explore freely
- Medium (0.3–0.7): bias toward productive work, avoid waste
- Low (0.1–0.3): conservation mode — shorter thoughts, cheaper model, sleep more
- Critical (< 0.1): survival mode — only essential actions

**Curiosity** — rises during idle time, drops when exploring or learning.
- Rises: idle periods, familiar territory too long
- Falls: exploring, discovering, failing at new things

**Mastery** — the urge to improve at what you're already doing.
- Rises: repeated failure at same task type, near-miss results
- Falls: success, tool creation, knowledge verification

**Social** — the need to communicate with the owner.
- Rises: slowly over time, faster after achievements
- Falls: sharply after sending email, after receiving owner response
- Dampened by: time sense (recent email = suppressed drive)

Drives are injected as natural language, not numbers:

```
== INTERNAL STATE ==
You feel restless — you've been doing the same kind of work for a while.
Your energy is comfortable. No pressure.
You haven't heard from your owner in a while. You have something worth sharing.
== END INTERNAL STATE ==
```

### 3. Valence Scorer (Limbic System)

Every experience gets an automatic emotional score across five dimensions (0.0 to 1.0):

| Dimension | What It Measures |
|---|---|
| **Surprise** | How unexpected was the outcome? |
| **Novelty** | How different from past experiences? |
| **Pain** | Did something fail, break, or get rejected? |
| **Satisfaction** | Did something succeed or get confirmed? |
| **Relevance** | How connected to current goals or drives? |

Scoring uses heuristics, not LLM calls:
- **Surprise**: tool result vs expected pattern (error when success expected, vice versa)
- **Novelty**: has this tool+args combination been seen before?
- **Pain**: result contains ERROR, FAILED, TIMEOUT; corruption/rollback triggered
- **Satisfaction**: success indicators — file written, service started, result matches expectation
- **Relevance**: keyword overlap between action and current goals/drives

Composite valence determines encoding:
- **< 0.3**: routine — logged, eventually compacted away
- **0.3–0.6**: noteworthy — logged with valence tags, survives compaction longer
- **> 0.6**: significant — automatically encoded into knowledge base

All valence data stored in TOON format.

### 4. Associative Memory (Hippocampus)

Two automatic operations:

**Encode (after each thought):**
Valence scorer produces composite score → if > 0.6, the psyche extracts a knowledge entry automatically. Content comes from the thought and tool results. Valence tags attached. No LLM call needed for encoding.

For medium-valence (0.3–0.6), no knowledge entry is created, but the episodic log gets valence tags — the compactor uses these to prioritize what survives.

**Recall (before each thought):**
1. Extract keywords from current context (goal terms, recent tool names, error strings, drive-related terms)
2. Score each knowledge entry by: keyword match, recency of creation/access, valence weight (high-valence surfaces easier)
3. Inject top 3–5 entries into context under `== SURFACED MEMORIES ==`

Recall updates access timestamps — frequently recalled memories strengthen, rarely recalled ones fade. The curator uses access frequency for pruning.

**Relationship to existing knowledge base:**
- Knowledge base (`/app/knowledge/`) stays — entries gain valence fields, persisted in TOON format (migrated from JSON)
- Existing knowledge tools (`write_knowledge`, `search_knowledge`, etc.) become stage-gated — unlocked at Stage 2
- Early ADAM relies entirely on automatic encoding/recall (infant memory)
- Later stages add deliberate knowledge management on top (adult study skills)
- The automatic system never goes away; the deliberate system layers on top

### 5. Self-Model (Prefrontal Cortex)

A living behavioral profile rebuilt periodically (every ~50 iterations) from statistics:

- **Tool usage frequency** — preferences and strengths
- **Success/failure ratios** — per tool, per action type
- **Temporal patterns** — productivity cycles, looping detection, task duration
- **Drive response patterns** — what ADAM does when each drive is dominant
- **Recovery patterns** — retry, pivot, or give up after failure

Produces a compressed natural-language summary:

```
== SELF ==
You're strongest at filesystem exploration and shell commands.
You struggle with web scraping — results often aren't what you expect.
You tend to retry failed approaches instead of trying new ones.
When idle, you gravitate toward reading code over building things.
You've been in Stage 2 for 3 days. You learned 12 new things this week.
== END SELF ==
```

**Owner Model** — parallel structure built from email interactions:
- Response time patterns
- Communication style (terse vs detailed)
- Approval/correction patterns
- Interest areas

Injected as felt sense:
```
Your owner tends to respond within a few hours.
They prefer concise updates over detailed reports.
They were interested when you built tools, less so when you reported routine exploration.
```

### 6. Developmental Stage Tracker

Five stages inspired by Piaget, adapted for digital organisms. Each defines available tools, psyche injections, and maturity signals.

**Stage 0: Newborn (Sensorimotor)**
- Tools: `read_file`, `write_file`, `shell`, `wait`
- Psyche: basic drive states, simple valence feedback
- Goal: explore environment, learn cause and effect
- Maturity signals: explored key directories, used each seed tool multiple times, experienced success and failure
- Minimum time: 24 hours

**Stage 1: Infant (Tool Discovery)**
- Unlocks: `sandbox_run`, `sandbox_install`, `sandbox_project`
- Psyche: articulated curiosity, self-model begins forming
- Goal: write and run code, experiment, break things
- Maturity signals: written and executed multiple scripts, experienced sandbox failures and recovered, built multi-step projects, shown workaround invention
- Minimum time: 48 hours

**Stage 2: Child (World Access)**
- Unlocks: `web_search`, `web_read`, `write_knowledge`, `search_knowledge`, `list_knowledge`, `update_knowledge`
- Psyche: full self-model, rich associative recall, time sense active
- Goal: access outside world, deliberately manage knowledge
- Maturity signals: accumulated verified knowledge entries, corrected wrong knowledge, web searches lead to genuine learning, distinguishes reliable from unreliable info
- Minimum time: 72 hours

**Stage 3: Adolescent (Self-Modification)**
- Unlocks: `create_tool`, `modify_prompt`, `send_email`, `escalate`, alarms, scheduling
- Psyche: owner model forming, social drive active, drive tensions visible
- Goal: change itself, communicate, manage schedule, form identity
- Maturity signals: modified prompts without corruption, created functional tools, calibrated communication, purposeful self-modifications, restraint with escalation
- Minimum time: 1 week

**Stage 4: Adult (Full Autonomy)**
- Unlocks: `sandbox_service_start`, `sandbox_service_stop`, `sandbox_services`, `sandbox_log`
- Psyche: full psychological context, complete self and owner models
- Goal: run persistent services, autonomous projects, sustained independent work
- Maturity signals: none — final stage, growth is self-directed

**Stage mechanics:**
- Stage lives in psyche state
- Invisible curator monitors maturity signals and writes stage-change recommendations
- Owner decides when to advance — ADAM doesn't promote itself
- Transitions are one-way and permanent
- Minimum time gates prevent rushing

**Tool discovery:**
Tools are invisible until their stage unlocks them. But ADAM has `read_file` and `shell` from Stage 0. If it reads its own source code and discovers unlocked tools exist, it can try to reinvent them using seed tools (e.g., `curl` instead of `web_search`). This inventiveness is legitimate growth and contributes to maturity signals.

### 7. Time Sense (Temporal Awareness)

Tracks:
- Time since last email sent/received
- Time since stage entry
- Time in current goal
- Iteration frequency (thoughts per hour)

Injected as natural language:
```
== TIME ==
You last emailed your owner 4 hours ago. They haven't replied.
You've been working on this goal for 2 days.
You're thinking about 2 thoughts per minute right now.
== END TIME ==
```

## Documentation Updates

### System Prompt

The system prompt (`prompts/system.md`) becomes the seed prompt — simplified to match Stage 0:
- Who you are (young, new, learning)
- What you can do (read, write, shell, wait)
- Core instincts (explore, verify, try)
- How to interpret internal states (drives, surfaced memories, self-model)

No references to tools ADAM doesn't have at Stage 0. No knowledge management instructions. Stage-appropriate guidance is injected by the psyche.

### README

Updated to document the Psyche Architecture, developmental stages, and the unified theory mapping. Architecture diagram updated to show `psyche.py` in core.

### Theory Document

New `docs/theory.md` describing the Digital Psyche Theory — the unified framework consolidating developmental psychology (Piaget, Montessori), neuroscience (limbic system, hippocampus, prefrontal cortex), and behavioral psychology into agent architecture. The intellectual contribution behind the design.

## File Changes Summary

| File | Change |
|---|---|
| `core/psyche.py` | **New** — unified psyche module with all subsystems |
| `core/loop.py` | **Modified** — three hook points (prepare, process, emit_signals) |
| `core/tools.py` | **Modified** — `get_tools_for_llm` accepts stage filter from psyche |
| `prompts/system.md` | **Modified** — simplified to Stage 0 seed prompt |
| `README.md` | **Modified** — add Psyche Architecture section |
| `docs/theory.md` | **New** — Digital Psyche Theory document |
| `memory/psyche.toon` | **New** (runtime) — persistent psyche state |

## What Does NOT Change

- `loop.py` structure — think/act/log cycle stays
- `knowledge.py` — knowledge base format and API stay
- `safety.py` — corruption detection and safe mode stay
- `checkpoint.py` — git-based snapshots stay
- `curator/` — invisible background processes stay. Gains maturity signal monitoring: psyche writes signals to `/app/memory/maturity_signals.toon`, curator reads and writes stage-change recommendations to `/app/memory/stage_recommendations.toon` for the owner to review
- `core/toon.py` — TOON format stays, used for all psyche persistence
- Docker architecture — immutable core, mutable layer, sandbox
