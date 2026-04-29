defmodule Adam.Tools.Sandbox do
  @sandbox_dir "/app/sandbox"

  def run_script(%{"code" => code, "language" => lang}) when is_binary(code) and is_binary(lang) do
    File.mkdir_p!(@sandbox_dir)
    {ext, cmd} = runner_for(lang)
    script_path = Path.join(@sandbox_dir, "script#{ext}")
    File.write!(script_path, code)

    try do
      case System.cmd(cmd, [script_path], cd: @sandbox_dir, stderr_to_stdout: true) do
        {output, 0} -> String.slice(output, 0, 2000)
        {output, code} -> "[EXIT #{code}] #{String.slice(output, 0, 2000)}"
      end
    rescue
      _ -> "[TIMEOUT]"
    after
      File.rm(script_path)
    end
  end

  def run_script(args), do: "[ERROR: sandbox_run requires 'code' and 'language' strings, got #{inspect(args)}]"

  def start_service(%{"name" => name, "command" => command}) when is_binary(name) and is_binary(command) do
    File.mkdir_p!(@sandbox_dir)
    log_path = Path.join(@sandbox_dir, "#{name}.log")
    pid_path = Path.join(@sandbox_dir, "#{name}.pid")

    System.cmd("sh", ["-c", "nohup #{command} > #{log_path} 2>&1 & echo $!"],
      cd: @sandbox_dir,
      stderr_to_stdout: true
    )
    |> case do
      {pid_str, 0} ->
        File.write!(pid_path, String.trim(pid_str))
        "started service '#{name}' (pid: #{String.trim(pid_str)})"

      {output, _} ->
        "[ERROR starting #{name}]: #{output}"
    end
  end

  def start_service(args), do: "[ERROR: sandbox_service_start requires 'name' and 'command', got #{inspect(args)}]"

  def stop_service(%{"name" => name}) when is_binary(name) do
    pid_path = Path.join(@sandbox_dir, "#{name}.pid")

    if File.exists?(pid_path) do
      pid = File.read!(pid_path) |> String.trim()
      System.cmd("kill", [pid], stderr_to_stdout: true)
      File.rm(pid_path)
      "stopped service '#{name}'"
    else
      "[ERROR: service '#{name}' not found]"
    end
  end

  def stop_service(args), do: "[ERROR: sandbox_service_stop requires 'name', got #{inspect(args)}]"

  def list_services do
    File.mkdir_p!(@sandbox_dir)

    Path.wildcard(Path.join(@sandbox_dir, "*.pid"))
    |> Enum.flat_map(fn path ->
      name = Path.basename(path, ".pid")
      case File.read(path) do
        {:ok, raw} -> ["#{name} (pid: #{String.trim(raw)})"]
        _ -> []
      end
    end)
    |> case do
      [] -> "no running services"
      services -> Enum.join(services, "\n")
    end
  end

  def read_log(%{"name" => name}) when is_binary(name) do
    log_path = Path.join(@sandbox_dir, "#{name}.log")

    if File.exists?(log_path) do
      File.read!(log_path) |> String.slice(-2000, 2000)
    else
      "[ERROR: no log for '#{name}']"
    end
  end

  def read_log(args), do: "[ERROR: sandbox_log requires 'name', got #{inspect(args)}]"

  def install_package(%{"package" => package, "manager" => manager}) when is_binary(package) and is_binary(manager) do
    cmd =
      case manager do
        "pip" -> "pip install #{package}"
        "npm" -> "npm install -g #{package}"
        "apt" -> "apt-get install -y #{package}"
        _ -> "echo 'unknown package manager: #{manager}'"
      end

    case System.cmd("sh", ["-c", cmd], cd: @sandbox_dir, stderr_to_stdout: true) do
      {output, 0} -> "installed #{package}\n#{String.slice(output, 0, 500)}"
      {output, _} -> "[INSTALL ERROR] #{String.slice(output, 0, 1000)}"
    end
  end

  def install_package(args), do: "[ERROR: sandbox_install requires 'package' and 'manager', got #{inspect(args)}]"

  def create_project(%{"name" => name, "template" => template}) when is_binary(name) and is_binary(template) do
    project_dir = Path.join(@sandbox_dir, name)
    File.mkdir_p!(project_dir)

    case template do
      "python" ->
        File.write!(Path.join(project_dir, "main.py"), "#!/usr/bin/env python3\n\n")
        File.write!(Path.join(project_dir, "requirements.txt"), "")

      "node" ->
        System.cmd("npm", ["init", "-y"], cd: project_dir, stderr_to_stdout: true)

      "elixir" ->
        System.cmd("mix", ["new", name, "--sup"], cd: @sandbox_dir, stderr_to_stdout: true)

      _ ->
        File.write!(Path.join(project_dir, "README.md"), "# #{name}\n")
    end

    "created project '#{name}' (#{template}) at sandbox/#{name}"
  end

  def create_project(args), do: "[ERROR: sandbox_project requires 'name' and 'template', got #{inspect(args)}]"

  defp runner_for("python"), do: {".py", "python3"}
  defp runner_for("node"), do: {".js", "node"}
  defp runner_for("bash"), do: {".sh", "bash"}
  defp runner_for("elixir"), do: {".exs", "elixir"}
  defp runner_for(_), do: {".sh", "bash"}
end
