import Config

config :adam,
  email_address: System.get_env("ADAM_EMAIL"),
  email_password: System.get_env("ADAM_EMAIL_PASSWORD"),
  owner_email: System.get_env("ADAM_OWNER_EMAIL"),
  ollama_url: System.get_env("OLLAMA_URL") || "http://ollama:11434",
  thinker_model: System.get_env("ADAM_THINKER_MODEL") || "gemma4:e4b",
  actor_model: System.get_env("ADAM_ACTOR_MODEL") || "hermes3:8b",
  deep_model: System.get_env("ADAM_DEEP_MODEL") || "gemma3:12b",
  thinker_cost: String.to_float(System.get_env("ADAM_THINKER_COST") || "0.004"),
  actor_cost: String.to_float(System.get_env("ADAM_ACTOR_COST") || "0.008"),
  deep_cost: String.to_float(System.get_env("ADAM_DEEP_COST") || "0.012"),
  budget_total: String.to_float(System.get_env("ADAM_BUDGET_TOTAL") || "250"),
  budget_visible: (System.get_env("ADAM_BUDGET_VISIBLE") || "true") == "true",
  git_remote_url: System.get_env("GIT_REMOTE_URL"),
  git_token: System.get_env("GIT_TOKEN")
