defmodule Adam.AtomicFile do
  @moduledoc """
  Atomic file writes via tmp-file + rename. POSIX guarantees rename is
  atomic on the same filesystem, so a crash mid-write either leaves the
  old file intact or has the new file fully present — never a half-written
  truncation.

  Use this for any state file that ADAM cannot afford to lose to a crash.
  """

  @doc """
  Write `content` to `path` atomically. Creates the parent directory if
  needed. The temp file is in the same directory as `path` so they share
  a filesystem.

  Raises on any IO failure — same contract as `File.write!/2`.
  """
  def write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp." <> Integer.to_string(:erlang.unique_integer([:positive]))

    try do
      File.write!(tmp, content)
      File.rename!(tmp, path)
    rescue
      e ->
        File.rm(tmp)
        reraise e, __STACKTRACE__
    end
  end
end
