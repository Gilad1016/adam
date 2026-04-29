defmodule Adam.Tools.Email do
  def send(%{"subject" => subject, "body" => body}) do
    case Adam.EmailClient.send_email(subject, body) do
      :ok -> "email sent: #{subject}"
      {:error, reason} -> "[EMAIL ERROR: #{reason}]"
    end
  end
end
