defmodule Adam.Toon do
  @moduledoc "Token-efficient serialization format."

  def encode(data), do: Jason.encode!(data)

  def decode(text) do
    text = String.trim(text)

    cond do
      text == "" -> nil
      String.starts_with?(text, "{") or String.starts_with?(text, "[") -> Jason.decode!(text)
      true ->
        lines = String.split(text, "\n")
        if length(lines) >= 2 and String.contains?(hd(lines), ",") do
          decode_table(lines)
        else
          decode_dict(lines)
        end
    end
  end

  defp decode_table(lines) do
    keys = hd(lines) |> String.split(",") |> Enum.map(&String.trim/1)

    tl(lines)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(fn line ->
      vals = String.split(line, ",") |> Enum.map(&String.trim/1)

      Enum.zip(keys, vals)
      |> Enum.map(fn {k, v} -> {k, deserialize_val(v)} end)
      |> Map.new()
    end)
  end

  defp decode_dict(lines) do
    lines
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      cond do
        String.contains?(line, ": ") ->
          [k | rest] = String.split(line, ": ", parts: 2)
          Map.put(acc, String.trim(k), deserialize_val(Enum.join(rest, ": ") |> String.trim()))

        String.ends_with?(String.trim(line), ":") ->
          k = line |> String.trim() |> String.trim_trailing(":")
          Map.put(acc, k, %{})

        true ->
          acc
      end
    end)
  end

  defp deserialize_val("null"), do: nil
  defp deserialize_val("true"), do: true
  defp deserialize_val("false"), do: false

  defp deserialize_val("[" <> _ = v) do
    case Jason.decode(v) do
      {:ok, decoded} -> decoded
      _              -> v
    end
  end

  defp deserialize_val("{" <> _ = v) do
    case Jason.decode(v) do
      {:ok, decoded} -> decoded
      _              -> v
    end
  end

  defp deserialize_val(v) do
    case Integer.parse(v) do
      {int, ""} -> int
      _ ->
        case Float.parse(v) do
          {float, ""} -> float
          _ -> v
        end
    end
  end
end
