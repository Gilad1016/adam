defmodule Adam.Tools.File do
  def read(%{"path" => path}) do
    case File.read(path) do
      {:ok, content} -> String.slice(content, 0, 4000)
      {:error, reason} -> "[ERROR: #{reason}]"
    end
  end

  def write(%{"path" => path, "content" => content}) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
    "wrote #{byte_size(content)} bytes to #{path}"
  rescue
    e -> "[ERROR: #{Exception.message(e)}]"
  end
end
