# ADAM External Fine-Tuning Trainer

ADAM's `Adam.Sleep` module exports JSONL training pairs and writes a
`finetune_requested` marker. This trainer is the **external** process the
README refers to: it watches that marker, runs a short QLoRA pass via
Unsloth, converts the adapter to GGUF, and registers a new Ollama tag
named `adam-finetuned-<timestamp>`.

It is intentionally a standalone host script for v1 — not a docker service.
Reasons:
- The trainer and Ollama share one GPU on adam-pc (RTX 3000, 6 GB). With
  `--pause-ollama`, the trainer stops the `ollama` compose service for the
  duration of training, then restarts it. Doing that from inside a
  containerised trainer is awkward; from the host it is one line.
- The user is iterating on hyperparameters and model choices. A host script
  is faster to edit and re-run.

A future iteration may move this into its own `trainer` docker service with
proper GPU coordination — see "Limitations" below.

## What it does

```
memory/finetune_requested        ← written by Adam.Sleep
        ↓ (trainer reads marker JSON, picks ADAM's thinker model)
HuggingFace base model + memory/sleep_training_data.jsonl
        ↓ Unsloth FastLanguageModel + SFTTrainer (LoRA r=16, ~60 steps)
adapter/ (PEFT)
        ↓ llama.cpp convert_lora_to_gguf.py
adapter.gguf + Modelfile (FROM <base tag> / ADAPTER ./adapter.gguf)
        ↓ ollama create adam-finetuned-<ts>
new Ollama tag, recorded in memory/active_finetune.txt
```

ADAM does **not** automatically switch to the new tag — see Limitations.

## One-time setup on adam-pc

Prerequisites:
- NVIDIA driver compatible with CUDA 12.x.
- `ollama` CLI on PATH (already installed for the compose stack).
- `python3.11` (Unsloth supports 3.10–3.12).
- `git`, `cmake`, `build-essential` for building llama.cpp.

```bash
cd ~/ADAM/trainer

# 1. Python venv with the ML stack.
python3.11 -m venv venv
source venv/bin/activate
pip install --upgrade pip

# 2. Install torch matching your CUDA. Example for CUDA 12.4:
pip install torch==2.5.1 --index-url https://download.pytorch.org/whl/cu124

# 3. Install pinned trainer deps.
pip install -r requirements.txt

# 4. Clone llama.cpp for the convert_lora_to_gguf.py script.
#    (Default search path is ~/llama.cpp — override with --llama-cpp-dir.)
git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp
pip install -r ~/llama.cpp/requirements/requirements-convert_lora_to_gguf.txt
```

## Running

In one shell, keep the trainer watching:

```bash
cd ~/ADAM/trainer
source venv/bin/activate
python trainer.py \
  --memory-dir ../memory \
  --pause-ollama \
  2>&1 | tee -a trainer.log
```

It polls `memory/finetune_requested` every 15 s. When it appears (after
ADAM falls asleep with `ADAM_FINETUNE_ENABLED=true`), the trainer:

1. Reads the marker JSON to learn ADAM's current Ollama tag (e.g. `qwen3:8b`).
2. Maps it to a HuggingFace repo (e.g. `unsloth/Qwen3-8B-unsloth-bnb-4bit`).
3. Stops the `ollama` compose service (with `--pause-ollama`).
4. Trains LoRA r=16 on the JSONL — capped at 60 steps so a single sleep
   takes minutes, not hours.
5. Saves the adapter, converts to GGUF, restarts Ollama, registers the
   new tag, deletes the marker, writes `memory/active_finetune.txt`.

On error, the marker is renamed to `finetune_failed.<ts>` with the reason
appended, and ADAM keeps using its previous Ollama tag.

## One-shot mode

Useful for testing — process one request (or none) and exit:

```bash
python trainer.py --memory-dir ../memory --once --pause-ollama
```

## Picking a different model

ADAM's thinker model is the default training target. Override either by:

- Setting `ADAM_THINKER_MODEL` in `.env` so ADAM uses (and the marker
  records) a different tag — e.g. `gemma3:4b-it`.
- Passing `--base-model qwen3:14b` on the trainer CLI for a one-off run.
- Setting `ADAM_BASE_MODEL_HF=org/repo` to override the Ollama→HF mapping
  for tags not in `DEFAULT_MODEL_MAP` in `trainer.py`.

## Tailing the log

```bash
tail -f ~/ADAM/trainer/trainer.log
```

## Limitations (be honest about these)

1. **ADAM does not auto-switch to the new tag.** The trainer writes
   `memory/active_finetune.txt` with the new model name as a convention,
   but `lib/adam/llm.ex` still reads `ADAM_THINKER_MODEL`. Wiring ADAM to
   prefer `active_finetune.txt` over the env var is a future change.
   Workaround: edit `.env` and `docker compose restart adam` after a
   successful run.
2. **GPU contention with Ollama.** On a 6 GB card, Unsloth 4-bit training
   of an 8 B model uses ~4–5 GB. Ollama keep-alive holds the loaded model
   at full size. `--pause-ollama` is therefore the supported path — without
   it, expect OOM. On larger cards (>= 12 GB) you can drop the flag.
3. **GGUF LoRA support is model-dependent.** `convert_lora_to_gguf.py` in
   llama.cpp covers Qwen2/Qwen3, Llama, Gemma 2/3. Brand-new architectures
   (e.g. Gemma 4 the day it ships) may need a llama.cpp bump first. If
   conversion fails the marker is renamed to `finetune_failed.*` and ADAM
   keeps the previous weights.
4. **No multi-GPU, no gradient checkpointing tuning, no eval split.** This
   is a "consolidate one sleep cycle" trainer, not a research harness.
5. **Pinned versions drift.** Unsloth ships breaking minor updates roughly
   monthly. If a new model architecture needs newer libs, bump
   `requirements.txt` and re-test.

## Future work (the "B" architecture)

A future iteration may add a `trainer` service to `docker-compose.yml`:
- Shares the `memory` bind mount.
- GPU access (compute capability), uses Docker's GPU resource API.
- Coordinates with the `ollama` service via the docker socket — pause/resume
  Ollama from inside the container.
- Reads `active_finetune.txt` and signals ADAM to reload its model config.

Skipping it for v1: the GPU-coordination story on a 6 GB card is fiddly and
the user wants to iterate on the Python script itself, not on container
orchestration.
