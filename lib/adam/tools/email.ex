defmodule Adam.Tools.Email do
  def send(%{"subject" => subject, "body" => body}) when is_binary(subject) and is_binary(body) do
    case Adam.EmailClient.send_email(subject, body) do
      :ok -> "email sent: #{subject}"
      {:error, reason} -> "[EMAIL ERROR: #{reason}]"
    end
  end

  def send(args) when is_map(args) do
    subject = to_string(args["subject"] || "")
    body = to_string(args["body"] || "")
    if subject == "" do
      "[ERROR: send_email requires 'subject', got #{inspect(args)}]"
    else
      send(%{"subject" => subject, "body" => body})
    end
  end

  def send(args), do: "[ERROR: send_email requires map args, got #{inspect(args)}]"
end
