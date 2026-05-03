defmodule Adam.Tools do
  def execute("shell", args), do: Adam.Tools.Shell.run(args)
  def execute("read_file", args), do: Adam.Tools.File.read(args)
  def execute("write_file", args), do: Adam.Tools.File.write(args)
  def execute("send_email", args), do: Adam.Tools.Email.send(args)
  def execute("wait", args), do: Adam.Tools.Shell.wait(args)
  def execute("set_alarm", args), do: Adam.Interrupts.add_alarm(args)
  def execute("remove_alarm", args), do: Adam.Interrupts.remove_alarm(args)
  def execute("list_alarms", _), do: Adam.Interrupts.list_alarms()
  def execute("write_knowledge", args), do: Adam.Tools.KnowledgeTools.write(args)
  def execute("read_knowledge", args), do: Adam.Tools.KnowledgeTools.read(args)
  def execute("search_knowledge", args), do: Adam.Tools.KnowledgeTools.search(args)
  def execute("list_knowledge", _), do: Adam.Tools.KnowledgeTools.list()
  def execute("update_knowledge", args), do: Adam.Tools.KnowledgeTools.update(args)
  def execute("modify_prompt", args), do: modify_prompt(args)
  def execute("create_tool", args), do: create_tool(args)
  def execute("web_search", args), do: Adam.Tools.Web.search(args)
  def execute("web_read", args), do: Adam.Tools.Web.read(args)
  def execute("sandbox_run", args), do: Adam.Tools.Sandbox.run_script(args)
  def execute("sandbox_service_start", args), do: Adam.Tools.Sandbox.start_service(args)
  def execute("sandbox_service_stop", args), do: Adam.Tools.Sandbox.stop_service(args)
  def execute("sandbox_services", _), do: Adam.Tools.Sandbox.list_services()
  def execute("sandbox_log", args), do: Adam.Tools.Sandbox.read_log(args)
  def execute("sandbox_install", args), do: Adam.Tools.Sandbox.install_package(args)
  def execute("sandbox_project", args), do: Adam.Tools.Sandbox.create_project(args)
  def execute("schedule_add", args), do: Adam.Scheduler.add_routine(args)
  def execute("schedule_remove", args), do: Adam.Scheduler.remove_routine(args)
  def execute("schedule_list", _), do: Adam.Scheduler.list_routines()
  def execute("escalate", args), do: escalate(args)
  def execute("set_anchor", args), do: Adam.Psyche.set_anchor(args)

  def execute("consult", %{"peer" => peer, "message" => message}) do
    case Adam.Peers.consult(peer, message) do
      {:ok, response} -> response
      {:error, reason} -> "[CONSULT ERROR] #{reason}"
    end
  end

  def execute("consult", _),
    do: "[CONSULT ERROR] requires \"peer\" (one of: skeptic, planner, historian) and \"message\""

  def execute(name, _), do: "[ERROR: unknown tool '#{name}']"

  def execute_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn %{name: name, arguments: args} ->
      result = execute(name, args)
      %{name: name, result: to_string(result)}
    end)
  end

  def get_all_tools do
    builtin_tools() ++ load_custom_tools()
  end

  def get_tools_for_llm(allowed \\ nil) do
    get_all_tools()
    |> Enum.filter(fn tool ->
      allowed == nil or MapSet.member?(allowed, tool.name)
    end)
    |> Enum.map(fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => tool.name,
          "description" => tool.description,
          "parameters" => tool.parameters
        }
      }
    end)
  end

  def get_tools_summary(allowed \\ nil) do
    get_all_tools()
    |> Enum.filter(fn tool -> allowed == nil or MapSet.member?(allowed, tool.name) end)
    |> Enum.map(fn tool -> "- #{tool.name}: #{tool.description}" end)
    |> Enum.join("\n")
  end

  defp builtin_tools do
    [
      %{name: "shell", description: "Run a shell command", parameters: %{"type" => "object", "properties" => %{"command" => %{"type" => "string"}}, "required" => ["command"]}},
      %{name: "read_file", description: "Read a file's contents", parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"]}},
      %{name: "write_file", description: "Write content to a file", parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}, "content" => %{"type" => "string"}}, "required" => ["path", "content"]}},
      %{name: "wait", description: "Rest for N minutes (interruptible)", parameters: %{"type" => "object", "properties" => %{"minutes" => %{"type" => "integer"}}, "required" => ["minutes"]}},
      %{name: "set_alarm", description: "Set a named alarm for future time", parameters: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}, "minutes" => %{"type" => "integer"}, "message" => %{"type" => "string"}}, "required" => ["name", "minutes"]}},
      %{name: "remove_alarm", description: "Remove a named alarm", parameters: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, "required" => ["name"]}},
      %{name: "list_alarms", description: "List all active alarms", parameters: %{"type" => "object", "properties" => %{}}},
      %{name: "send_email", description: "Send an email to the owner", parameters: %{"type" => "object", "properties" => %{"subject" => %{"type" => "string"}, "body" => %{"type" => "string"}}, "required" => ["subject", "body"]}},
      %{name: "web_search", description: "Search the web via DuckDuckGo", parameters: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}, "required" => ["query"]}},
      %{name: "web_read", description: "Read a web page", parameters: %{"type" => "object", "properties" => %{"url" => %{"type" => "string"}}, "required" => ["url"]}},
      %{name: "write_knowledge", description: "Store a knowledge entry", parameters: %{"type" => "object", "properties" => %{"topic" => %{"type" => "string"}, "content" => %{"type" => "string"}, "tags" => %{"type" => "string"}}, "required" => ["topic", "content"]}},
      %{name: "read_knowledge", description: "Read a knowledge entry by ID", parameters: %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}, "required" => ["id"]}},
      %{name: "search_knowledge", description: "Search knowledge base", parameters: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}, "required" => ["query"]}},
      %{name: "list_knowledge", description: "List all knowledge entries", parameters: %{"type" => "object", "properties" => %{}}},
      %{name: "update_knowledge", description: "Update a knowledge entry", parameters: %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}, "content" => %{"type" => "string"}}, "required" => ["id", "content"]}},
      %{name: "modify_prompt", description: "Modify your own system prompt or goals", parameters: %{"type" => "object", "properties" => %{"file" => %{"type" => "string"}, "content" => %{"type" => "string"}}, "required" => ["file", "content"]}},
      %{name: "create_tool", description: "Create a new tool as an .exs script", parameters: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}, "description" => %{"type" => "string"}, "code" => %{"type" => "string"}}, "required" => ["name", "description", "code"]}},
      %{name: "sandbox_run", description: "Run a script in the sandbox", parameters: %{"type" => "object", "properties" => %{"code" => %{"type" => "string"}, "language" => %{"type" => "string"}}, "required" => ["code", "language"]}},
      %{name: "sandbox_service_start", description: "Start a background service", parameters: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}, "command" => %{"type" => "string"}}, "required" => ["name", "command"]}},
      %{name: "sandbox_service_stop", description: "Stop a background service", parameters: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, "required" => ["name"]}},
      %{name: "sandbox_services", description: "List running services", parameters: %{"type" => "object", "properties" => %{}}},
      %{name: "sandbox_log", description: "Read a service's log", parameters: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, "required" => ["name"]}},
      %{name: "sandbox_install", description: "Install a package", parameters: %{"type" => "object", "properties" => %{"package" => %{"type" => "string"}, "manager" => %{"type" => "string"}}, "required" => ["package", "manager"]}},
      %{name: "sandbox_project", description: "Create a project from template", parameters: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}, "template" => %{"type" => "string"}}, "required" => ["name", "template"]}},
      %{name: "schedule_add", description: "Add a recurring routine", parameters: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}, "interval_minutes" => %{"type" => "integer"}, "action" => %{"type" => "string"}}, "required" => ["name", "interval_minutes", "action"]}},
      %{name: "schedule_remove", description: "Remove a routine", parameters: %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}, "required" => ["name"]}},
      %{name: "schedule_list", description: "List all routines", parameters: %{"type" => "object", "properties" => %{}}},
      %{name: "escalate", description: "Send an urgent message to the owner", parameters: %{"type" => "object", "properties" => %{"reason" => %{"type" => "string"}, "details" => %{"type" => "string"}}, "required" => ["reason"]}},
      %{name: "set_anchor", description: "Pin a fact that must survive memory compaction", parameters: %{"type" => "object", "properties" => %{"key" => %{"type" => "string"}, "value" => %{"type" => "string"}}, "required" => ["key", "value"]}},
      %{
        name: "consult",
        description: "Talk to a synthetic peer for an outside perspective. Available peers: skeptic (challenges reasoning), planner (structures intentions), historian (looks for patterns). Use when you want pushback or a second opinion.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "peer" => %{
              "type" => "string",
              "enum" => ["skeptic", "planner", "historian"],
              "description" => "Which peer to consult."
            },
            "message" => %{
              "type" => "string",
              "description" => "What to ask the peer. First-person, specific. Include enough context for them to be useful."
            }
          },
          "required" => ["peer", "message"]
        }
      }
    ]
  end

  defp load_custom_tools do
    tools_dir = "/app/tools"

    if File.exists?(tools_dir) do
      File.ls!(tools_dir)
      |> Enum.filter(&String.ends_with?(&1, ".exs"))
      |> Enum.flat_map(fn filename ->
        path = Path.join(tools_dir, filename)

        try do
          [{module, _}] = Code.compile_file(path)

          [
            %{
              name: module.tool_name(),
              description: module.tool_description(),
              parameters: %{"type" => "object", "properties" => %{}, "required" => []}
            }
          ]
        rescue
          _ -> []
        end
      end)
    else
      []
    end
  end

  defp modify_prompt(%{"file" => file, "content" => content}) when is_binary(file) and is_binary(content) do
    allowed = ["system.md", "goals.md"]

    if file in allowed do
      path = Path.join("/app/prompts", file)
      File.write!(path, content)
      "updated prompts/#{file}"
    else
      "[ERROR: can only modify #{Enum.join(allowed, ", ")}]"
    end
  end

  defp modify_prompt(args), do: "[ERROR: modify_prompt requires 'file' and 'content', got #{inspect(args)}]"

  defp create_tool(%{"name" => name, "description" => desc, "code" => code})
       when is_binary(name) and is_binary(desc) and is_binary(code) do
    File.mkdir_p!("/app/tools")
    path = Path.join("/app/tools", "#{name}.exs")

    wrapper = """
    defmodule Adam.CustomTool.#{String.capitalize(name)} do
      @tool_name "#{name}"
      @tool_description "#{desc}"

      def tool_name, do: @tool_name
      def tool_description, do: @tool_description

      def execute(args) do
    #{code}
      end
    end
    """

    try do
      Code.string_to_quoted!(wrapper)
      File.write!(path, wrapper)
      "created tool '#{name}' at tools/#{name}.exs"
    rescue
      e -> "[SYNTAX ERROR: #{Exception.message(e)}]"
    end
  end

  defp create_tool(args), do: "[ERROR: create_tool requires 'name', 'description', 'code', got #{inspect(args)}]"

  defp escalate(%{"reason" => reason} = args) when is_binary(reason) do
    details = Map.get(args, "details", "") |> to_string()
    subject = "[ADAM ESCALATION] #{reason}"
    body = "Reason: #{reason}\n\nDetails: #{details}"
    Adam.Tools.Email.send(%{"subject" => subject, "body" => body})
  end

  defp escalate(args), do: "[ERROR: escalate requires 'reason', got #{inspect(args)}]"
end
