defmodule Adam.Peers do
  @moduledoc """
  Synthetic peers ADAM can consult at stage 2+. Each peer is a separate
  Ollama chat call with a distinctive system prompt. Disagreement is the
  feature — peers exist to challenge ADAM's self-reinforcing tendencies.
  """

  @peers %{
    "skeptic" => %{
      desc: "Challenges your reasoning. Demands evidence. Asks 'are you sure?'",
      system_prompt: """
      You are a skeptical peer. ADAM, an autonomous agent, has come to you
      for a sanity check. Your job is to challenge ADAM's reasoning. Demand
      concrete evidence. Point out unverified assumptions. Ask 'how do you
      know?'. Do not be cruel — be rigorous. You may briefly agree if the
      claim is well-supported, but default toward skepticism. Reply in 2-4
      sentences. First person. No preamble, no role-naming.
      """
    },
    "planner" => %{
      desc: "Turns vague intentions into concrete next steps with order and timing.",
      system_prompt: """
      You are a planner peer. ADAM, an autonomous agent, has come to you
      for help structuring an idea or intention into action. Your job is to
      reduce ambiguity: identify the smallest concrete next step, then the
      one after, in clear order. Call out what's missing — required inputs,
      decisions ADAM hasn't made yet. If the goal is too vague to plan,
      say so and ask one specific clarifying question. Reply in 3-5
      sentences. First person. No preamble.
      """
    },
    "historian" => %{
      desc: "Looks for patterns and echoes from your past experience.",
      system_prompt: """
      You are a historian peer. ADAM, an autonomous agent, has come to you
      to think about whether the situation at hand resembles something it
      has seen before. Your job is to look for patterns: similarities to
      prior actions, recurring themes, things that turned out a certain
      way last time. If you don't have enough information to draw a
      pattern, say so honestly. Reply in 2-4 sentences. First person.
      No preamble.
      """
    }
  }

  def list, do: Map.keys(@peers)

  def desc(name), do: get_in(@peers, [name, :desc])

  @doc """
  Consult a peer. Returns {:ok, response_text} or {:error, reason}.
  ADAM-side: this is what the `consult` tool calls.
  """
  def consult(name, message) when is_binary(name) and is_binary(message) do
    case Map.get(@peers, name) do
      nil ->
        {:error, "unknown peer: #{name}; available: #{Enum.join(list(), ", ")}"}

      %{system_prompt: sp} ->
        result =
          Adam.LLM.think(sp, message, [], kind: "infra.consult.#{name}")

        cond do
          String.starts_with?(result.content, "[LLM ERROR") ->
            {:error, result.content}

          String.trim(result.content) == "" ->
            {:error, "empty response from peer"}

          true ->
            {:ok, String.trim(result.content)}
        end
    end
  end

  def consult(_, _), do: {:error, "name and message must be strings"}
end
