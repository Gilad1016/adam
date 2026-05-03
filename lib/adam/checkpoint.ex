defmodule Adam.Checkpoint do
  @checkpoint_interval 900

  def init_git do
    try do
      System.cmd("git", ["init"], cd: "/app", stderr_to_stdout: true)
      System.cmd("git", ["config", "user.email", "adam@local"], cd: "/app", stderr_to_stdout: true)
      System.cmd("git", ["config", "user.name", "ADAM"], cd: "/app", stderr_to_stdout: true)

      if remote = Application.get_env(:adam, :git_remote_url) do
        System.cmd("git", ["remote", "add", "origin", remote], cd: "/app", stderr_to_stdout: true)
      end

      snapshot()
      IO.puts("[CHECKPOINT] Git initialized")
    rescue
      e -> IO.puts("[CHECKPOINT] Git init failed (non-fatal): #{Exception.message(e)}")
    end
  end

  def snapshot do
    System.cmd("git", ["add", "-A"], cd: "/app", stderr_to_stdout: true)
    System.cmd("git", ["commit", "-m", "checkpoint"], cd: "/app", stderr_to_stdout: true)
  end

  def restore_latest do
    case System.cmd("git", ["log", "--oneline", "-1"], cd: "/app", stderr_to_stdout: true) do
      {output, 0} when output != "" ->
        System.cmd("git", ["checkout", "HEAD", "--", "prompts/", "tools/", "strategies/"],
          cd: "/app",
          stderr_to_stdout: true
        )
        true

      _ ->
        false
    end
  end

  def should_checkpoint(last_time) do
    System.os_time(:second) - last_time > @checkpoint_interval
  end
end
