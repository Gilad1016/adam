import Config

config :adam, speciation_interval: 50
config :adam, compaction_interval: 25
config :adam, recent_window: 10
config :adam, self_model_rebuild_interval: 50

import_config "#{config_env()}.exs"
