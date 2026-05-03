"""ADAM external fine-tuning trainer.

Watches the bind-mounted memory directory for a `finetune_requested` marker
written by `Adam.Sleep.request_finetune/0`, runs a short QLoRA pass with
Unsloth on the exported JSONL, converts the adapter to GGUF, and registers
a new Ollama model tag via `ollama create`.

Run manually (or under systemd / cron) on the same host that runs the ADAM
docker stack. See trainer/README.md for setup.

Design notes:
  * Model-agnostic: the marker JSON includes the Ollama tag of ADAM's thinker
    model. We map that tag → a HuggingFace base model id with a small lookup
    table (overridable via env). Unsloth auto-detects LoRA target modules per
    architecture (Qwen3, Gemma, Llama, ...).
  * GPU coordination: training and Ollama share one GPU on adam-pc (6 GB
    RTX 3000). `--pause-ollama` stops the container while training to free
    VRAM, then restarts it when the new tag is registered. Without that
    flag, training will OOM on small cards.
  * Honest failure mode: if `llama.cpp`'s convert_lora_to_gguf.py is not
    found, we save the adapter but skip Ollama registration and leave a
    failure marker. ADAM keeps running on the previous model — sleep just
    didn't update weights this cycle.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

LOG = logging.getLogger("adam.trainer")

# Default mapping from Ollama tag → HuggingFace base model id. Keys are the
# tag exactly as ADAM passes it (`qwen3:8b`, `gemma3:4b-it`, etc.). The
# 4-bit Unsloth pre-quants are preferred where they exist — they download
# faster and avoid an on-the-fly bnb quantization pass.
DEFAULT_MODEL_MAP = {
    "qwen3:4b": "unsloth/Qwen3-4B-unsloth-bnb-4bit",
    "qwen3:8b": "unsloth/Qwen3-8B-unsloth-bnb-4bit",
    "qwen3:14b": "unsloth/Qwen3-14B-unsloth-bnb-4bit",
    "gemma3:4b-it": "unsloth/gemma-3-4b-it-unsloth-bnb-4bit",
    "gemma3:12b-it": "unsloth/gemma-3-12b-it-unsloth-bnb-4bit",
    # Placeholders for the gemma4 line — update once Unsloth ships them.
    "gemma4:e2b": "unsloth/gemma-4-e2b-it",
    "gemma4:e4b": "unsloth/gemma-4-e4b-it",
}


@dataclass
class TrainerConfig:
    memory_dir: Path
    adapters_dir: Path
    models_dir: Path
    llama_cpp_dir: Optional[Path]
    base_model_override: Optional[str]
    max_steps: int
    lora_rank: int
    lora_alpha: int
    learning_rate: float
    batch_size: int
    grad_accum: int
    epochs: int
    pause_ollama: bool
    ollama_container: str

    @property
    def trigger_file(self) -> Path:
        return self.memory_dir / "finetune_requested"

    @property
    def training_data(self) -> Path:
        return self.memory_dir / "sleep_training_data.jsonl"

    @property
    def active_marker(self) -> Path:
        return self.memory_dir / "active_finetune.txt"


# ---------------------------------------------------------------------------
# Marker handling
# ---------------------------------------------------------------------------


def read_marker(path: Path) -> dict:
    """Parse the finetune_requested marker.

    Adam.Sleep writes JSON with `thinker_model`, `actor_model`, `training_data`,
    `requested_at`. Old/manual markers may just contain a bare model tag —
    fall back to treating the whole file as the tag string.
    """
    raw = path.read_text().strip()
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            return data
    except json.JSONDecodeError:
        pass
    return {"thinker_model": raw}


def fail_marker(trigger: Path, reason: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    failed = trigger.with_name(f"finetune_failed.{ts}")
    body = f"{reason}\n"
    if trigger.exists():
        body = trigger.read_text() + "\n---\n" + body
        trigger.unlink()
    failed.write_text(body)
    LOG.error("training failed (%s) — wrote %s", reason, failed)


# ---------------------------------------------------------------------------
# Model resolution
# ---------------------------------------------------------------------------


def resolve_base_model(ollama_tag: str, override: Optional[str]) -> str:
    if override:
        return override
    env_override = os.environ.get("ADAM_BASE_MODEL_HF")
    if env_override:
        return env_override
    if ollama_tag in DEFAULT_MODEL_MAP:
        return DEFAULT_MODEL_MAP[ollama_tag]
    # Last-resort fallback: try the HF path that matches the tag with a dash.
    # Prints a warning — the user will likely need to set ADAM_BASE_MODEL_HF.
    LOG.warning(
        "no HF mapping for Ollama tag %r — falling back to a guess. Set "
        "ADAM_BASE_MODEL_HF=<hf/repo> to override.",
        ollama_tag,
    )
    family, _, size = ollama_tag.partition(":")
    return f"unsloth/{family}-{size}"


# ---------------------------------------------------------------------------
# Training
# ---------------------------------------------------------------------------


def run_training(cfg: TrainerConfig, base_model: str, run_dir: Path) -> Path:
    """Runs Unsloth QLoRA on the exported JSONL. Returns the adapter dir."""
    # Imports are deferred so `--help` / dry-run paths don't pay the cost of
    # loading torch + transformers.
    from datasets import load_dataset
    from trl import SFTTrainer, SFTConfig
    from unsloth import FastLanguageModel
    from unsloth.chat_templates import train_on_responses_only

    LOG.info("loading base model %s", base_model)
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=base_model,
        max_seq_length=2048,
        load_in_4bit=True,
        # Unsloth picks target modules per architecture automatically when we
        # call get_peft_model below.
    )

    model = FastLanguageModel.get_peft_model(
        model,
        r=cfg.lora_rank,
        lora_alpha=cfg.lora_alpha,
        lora_dropout=0.0,
        bias="none",
        use_gradient_checkpointing="unsloth",
        random_state=42,
    )

    LOG.info("loading dataset %s", cfg.training_data)
    ds = load_dataset("json", data_files=str(cfg.training_data), split="train")

    def to_text(example):
        msgs = example["messages"]
        text = tokenizer.apply_chat_template(
            msgs, tokenize=False, add_generation_prompt=False
        )
        return {"text": text}

    ds = ds.map(to_text, remove_columns=list(ds.column_names))
    LOG.info("dataset has %d examples", len(ds))

    if len(ds) == 0:
        raise RuntimeError("training data is empty")

    sft_cfg = SFTConfig(
        output_dir=str(run_dir / "checkpoints"),
        per_device_train_batch_size=cfg.batch_size,
        gradient_accumulation_steps=cfg.grad_accum,
        warmup_steps=5,
        num_train_epochs=cfg.epochs,
        max_steps=cfg.max_steps,
        learning_rate=cfg.learning_rate,
        logging_steps=1,
        optim="adamw_8bit",
        weight_decay=0.01,
        lr_scheduler_type="linear",
        seed=42,
        report_to="none",
        dataset_text_field="text",
        max_seq_length=2048,
        packing=False,
    )

    # TRL >= 0.12 renamed `tokenizer` → `processing_class`. Try both so a
    # minor TRL bump doesn't break the trainer.
    try:
        trainer = SFTTrainer(
            model=model,
            processing_class=tokenizer,
            train_dataset=ds,
            args=sft_cfg,
        )
    except TypeError:
        trainer = SFTTrainer(
            model=model,
            tokenizer=tokenizer,
            train_dataset=ds,
            args=sft_cfg,
        )

    # Best-effort: only train on assistant turns. Falls back silently for
    # templates that the helper doesn't recognise.
    try:
        trainer = train_on_responses_only(trainer)
    except Exception as e:  # noqa: BLE001
        LOG.warning("train_on_responses_only skipped: %s", e)

    LOG.info("training: max_steps=%d epochs=%d", cfg.max_steps, cfg.epochs)
    trainer.train()

    adapter_dir = run_dir / "adapter"
    adapter_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(str(adapter_dir))
    tokenizer.save_pretrained(str(adapter_dir))
    LOG.info("adapter saved to %s", adapter_dir)
    return adapter_dir


# ---------------------------------------------------------------------------
# GGUF conversion + Ollama registration
# ---------------------------------------------------------------------------


def find_convert_script(llama_cpp_dir: Optional[Path]) -> Optional[Path]:
    candidates = []
    if llama_cpp_dir:
        candidates.append(llama_cpp_dir / "convert_lora_to_gguf.py")
    home_cpp = Path.home() / "llama.cpp"
    candidates.append(home_cpp / "convert_lora_to_gguf.py")
    for c in candidates:
        if c.exists():
            return c
    return None


def convert_adapter_to_gguf(adapter_dir: Path, llama_cpp_dir: Optional[Path]) -> Path:
    script = find_convert_script(llama_cpp_dir)
    if not script:
        raise RuntimeError(
            "convert_lora_to_gguf.py not found. Set --llama-cpp-dir or clone "
            "ggerganov/llama.cpp into ~/llama.cpp."
        )
    out = adapter_dir / "adapter.gguf"
    LOG.info("converting adapter → GGUF via %s", script)
    subprocess.run(
        [sys.executable, str(script), str(adapter_dir), "--outfile", str(out)],
        check=True,
    )
    return out


def register_ollama_model(base_tag: str, gguf_path: Path, new_tag: str) -> None:
    modelfile = gguf_path.parent / "Modelfile"
    modelfile.write_text(f"FROM {base_tag}\nADAPTER {gguf_path.name}\n")
    LOG.info("ollama create %s -f %s", new_tag, modelfile)
    subprocess.run(
        ["ollama", "create", new_tag, "-f", str(modelfile)],
        check=True,
        cwd=str(gguf_path.parent),
    )


# ---------------------------------------------------------------------------
# Ollama container coordination
# ---------------------------------------------------------------------------


def docker_compose_action(action: str, service: str) -> None:
    """Stop or start a docker compose service. Best-effort — if neither
    `docker compose` nor `docker-compose` is on PATH, skip with a warning."""
    for prefix in (["docker", "compose"], ["docker-compose"]):
        if shutil.which(prefix[0]):
            try:
                subprocess.run([*prefix, action, service], check=True)
                return
            except subprocess.CalledProcessError as e:
                LOG.warning("%s %s failed: %s", " ".join(prefix), action, e)
                return
    LOG.warning("docker not found; cannot %s %s", action, service)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


def process_request(cfg: TrainerConfig) -> None:
    trigger = cfg.trigger_file
    if not trigger.exists():
        return
    LOG.info("found marker: %s", trigger)

    if not cfg.training_data.exists():
        fail_marker(trigger, f"training data missing: {cfg.training_data}")
        return

    marker = read_marker(trigger)
    ollama_tag = (
        cfg.base_model_override
        or marker.get("thinker_model")
        or os.environ.get("ADAM_BASE_MODEL")
        or "qwen3:8b"
    )
    base_model_hf = resolve_base_model(ollama_tag, cfg.base_model_override)
    LOG.info("ollama_tag=%s hf=%s", ollama_tag, base_model_hf)

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = cfg.adapters_dir / ts
    run_dir.mkdir(parents=True, exist_ok=True)

    paused = False
    try:
        if cfg.pause_ollama:
            LOG.info("stopping %s to free VRAM", cfg.ollama_container)
            docker_compose_action("stop", cfg.ollama_container)
            paused = True

        adapter_dir = run_training(cfg, base_model_hf, run_dir)
        gguf = convert_adapter_to_gguf(adapter_dir, cfg.llama_cpp_dir)

        if paused:
            LOG.info("restarting %s before ollama create", cfg.ollama_container)
            docker_compose_action("start", cfg.ollama_container)
            paused = False
            # Give Ollama a moment to bind 11434 before we shell out to it.
            time.sleep(5)

        new_tag = f"adam-finetuned-{ts}"
        register_ollama_model(ollama_tag, gguf, new_tag)

        cfg.active_marker.write_text(new_tag + "\n")
        trigger.unlink()
        LOG.info("done. new tag = %s (recorded in %s)", new_tag, cfg.active_marker)

    except Exception as e:  # noqa: BLE001
        fail_marker(trigger, f"{type(e).__name__}: {e}")
        raise
    finally:
        if paused:
            docker_compose_action("start", cfg.ollama_container)


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="ADAM external fine-tuning trainer")
    p.add_argument(
        "--memory-dir",
        type=Path,
        default=Path(os.environ.get("ADAM_MEMORY_DIR", "./memory")),
        help="path to ADAM memory dir (host bind mount of /app/memory)",
    )
    p.add_argument("--adapters-dir", type=Path, default=Path("./adapters"))
    p.add_argument("--models-dir", type=Path, default=Path("./models"))
    p.add_argument(
        "--llama-cpp-dir",
        type=Path,
        default=Path(os.environ.get("LLAMA_CPP_DIR", str(Path.home() / "llama.cpp"))),
    )
    p.add_argument(
        "--base-model",
        default=None,
        help="override Ollama tag detection (e.g. qwen3:8b)",
    )
    p.add_argument("--max-steps", type=int, default=60)
    p.add_argument("--lora-rank", type=int, default=16)
    p.add_argument("--lora-alpha", type=int, default=32)
    p.add_argument("--lr", type=float, default=2e-4)
    p.add_argument("--batch-size", type=int, default=2)
    p.add_argument("--grad-accum", type=int, default=4)
    p.add_argument("--epochs", type=int, default=1)
    p.add_argument(
        "--pause-ollama",
        action="store_true",
        help="stop the ollama compose service during training (recommended on <12GB cards)",
    )
    p.add_argument("--ollama-container", default="ollama")
    p.add_argument(
        "--once",
        action="store_true",
        help="process one request (or zero) and exit, instead of looping",
    )
    p.add_argument("--poll-seconds", type=int, default=15)
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )
    args = parse_args(argv)
    cfg = TrainerConfig(
        memory_dir=args.memory_dir.resolve(),
        adapters_dir=args.adapters_dir.resolve(),
        models_dir=args.models_dir.resolve(),
        llama_cpp_dir=args.llama_cpp_dir.resolve() if args.llama_cpp_dir else None,
        base_model_override=args.base_model,
        max_steps=args.max_steps,
        lora_rank=args.lora_rank,
        lora_alpha=args.lora_alpha,
        learning_rate=args.lr,
        batch_size=args.batch_size,
        grad_accum=args.grad_accum,
        epochs=args.epochs,
        pause_ollama=args.pause_ollama,
        ollama_container=args.ollama_container,
    )

    cfg.adapters_dir.mkdir(parents=True, exist_ok=True)
    cfg.models_dir.mkdir(parents=True, exist_ok=True)

    if not cfg.memory_dir.exists():
        LOG.error("memory dir does not exist: %s", cfg.memory_dir)
        return 2

    LOG.info("watching %s (poll=%ds)", cfg.trigger_file, args.poll_seconds)
    if args.once:
        process_request(cfg)
        return 0

    while True:
        try:
            process_request(cfg)
        except KeyboardInterrupt:
            LOG.info("interrupted")
            return 0
        except Exception as e:  # noqa: BLE001
            LOG.exception("unhandled error: %s", e)
        time.sleep(args.poll_seconds)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
