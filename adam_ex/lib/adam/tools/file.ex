defmodule Adam.Tools.File do
  def read(%{"path" => path}) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> String.slice(content, 0, 4000)
      {:error, reason} -> "[ERROR: #{reason}]"
    end
  end

  def read(args), do: "[ERROR: read_file requires 'path' string, got #{inspect(args)}]"

  def write(%{"path" => path, "content" => content}) when is_binary(path) do
    content = to_string(content)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
    "wrote #{byte_size(content)} bytes to #{path}"
  rescue
    e -> "[ERROR: #{Exception.message(e)}]"
  end

  def write(args), do: "[ERROR: write_file requires 'path' and 'content', got #{inspect(args)}]"
end
