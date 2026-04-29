defmodule Adam.Toon do
  @moduledoc "Token-efficient serialization format."

  def encode(data) when is_list(data) and length(data) > 0 do
    if Enum.all?(data, &is_map/1), do: encode_table(data), else: Jason.encode!(data)
  end

  def encode(data) when is_map(data), do: encode_dict(data)
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

  defp encode_table(items) do
    keys = Map.keys(hd(items))
    header = Enum.join(keys, ", ")

    rows =
      Enum.map(items, fn item ->
        Enum.map(keys, fn k -> serialize_val(Map.get(item, k, "")) end) |> Enum.join(", ")
      end)

    header <> "\n" <> Enum.join(rows, "\n")
  end

  defp encode_dict(map, indent \\ 0) do
    prefix = String.duplicate("  ", indent)

    Enum.map(map, fn {k, v} ->
      cond do
        is_map(v) ->
          "#{prefix}#{k}:\n#{encode_dict(v, indent + 1)}"

        is_list(v) and length(v) > 0 and Enum.all?(v, &is_map/1) ->
          table = encode_table(v)
          indented = table |> String.split("\n") |> Enum.map(&"#{prefix}  #{&1}") |> Enum.join("\n")
          "#{prefix}#{k}:\n#{indented}"

        true ->
          "#{prefix}#{k}: #{serialize_val(v)}"
      end
    end)
    |> Enum.join("\n")
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

  defp serialize_val(nil), do: "null"
  defp serialize_val(true), do: "true"
  defp serialize_val(false), do: "false"
  defp serialize_val(v) when is_number(v), do: to_string(v)
  defp serialize_val(v) when is_list(v), do: Jason.encode!(v)
  defp serialize_val(v) when is_binary(v), do: v
  defp serialize_val(v) when is_atom(v), do: Atom.to_string(v)
  defp serialize_val(v), do: Jason.encode!(v)

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
