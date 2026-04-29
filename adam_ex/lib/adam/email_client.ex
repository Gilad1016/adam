defmodule Adam.EmailClient do
  def send_email(subject, body) do
    from = Application.get_env(:adam, :email_address)
    to = Application.get_env(:adam, :owner_email)
    password = Application.get_env(:adam, :email_password)

    unless from && to && password do
      {:error, "email not configured"}
    else
      email = build_email(from, to, subject, body)

      case :gen_smtp_client.send_blocking(
             {from, [to], email},
             relay: ~c"smtp.gmail.com",
             port: 587,
             username: String.to_charlist(from),
             password: String.to_charlist(password),
             tls: :always,
             auth: :always,
             ssl_options: [versions: [:"tlsv1.2", :"tlsv1.3"]]
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  def check_inbox do
    addr = Application.get_env(:adam, :email_address)
    password = Application.get_env(:adam, :email_password)
    owner = Application.get_env(:adam, :owner_email)

    unless addr && password && owner do
      []
    else
      try do
        {:ok, socket} = :ssl.connect(~c"imap.gmail.com", 993, [:binary, active: false])
        {:ok, _greeting} = :ssl.recv(socket, 0, 10_000)

        imap_command(socket, "LOGIN #{addr} #{password}")
        imap_command(socket, "SELECT INBOX")
        {_, search_resp} = imap_command(socket, "SEARCH UNSEEN")

        uids = parse_search_uids(search_resp)

        messages =
          Enum.flat_map(uids, fn uid ->
            {_, fetch_resp} = imap_command(socket, "FETCH #{uid} (BODY[HEADER.FIELDS (FROM SUBJECT)] BODY[TEXT])")
            parse_email(fetch_resp, owner)
          end)

        imap_command(socket, "LOGOUT")
        :ssl.close(socket)
        messages
      rescue
        e ->
          IO.puts("[IMAP ERROR] #{Exception.message(e)}")
          []
      catch
        _, reason ->
          IO.puts("[IMAP ERROR] #{inspect(reason)}")
          []
      end
    end
  end

  defp imap_command(socket, command) do
    tag = "A#{:rand.uniform(9999)}"
    :ssl.send(socket, "#{tag} #{command}\r\n")
    recv_until_tag(socket, tag, "")
  end

  defp recv_until_tag(socket, tag, acc) do
    case :ssl.recv(socket, 0, 15_000) do
      {:ok, data} ->
        acc = acc <> data

        if String.contains?(acc, "#{tag} OK") or String.contains?(acc, "#{tag} NO") or
             String.contains?(acc, "#{tag} BAD") do
          {:ok, acc}
        else
          recv_until_tag(socket, tag, acc)
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp parse_search_uids(response) do
    case Regex.run(~r/\* SEARCH (.+)/i, response) do
      [_, uids_str] ->
        uids_str |> String.trim() |> String.split() |> Enum.take(10)

      _ ->
        []
    end
  end

  defp parse_email(response, owner_email) do
    from =
      case Regex.run(~r/From:\s*(.+)/i, response) do
        [_, f] -> String.trim(f)
        _ -> ""
      end

    from_addr =
      case Regex.run(~r/<([^>]+)>/, from) do
        [_, addr] -> String.downcase(addr)
        _ -> String.downcase(from)
      end

    if from_addr == String.downcase(owner_email) do
      subject =
        case Regex.run(~r/Subject:\s*(.+)/i, response) do
          [_, s] -> String.trim(s)
          _ -> ""
        end

      body =
        case Regex.split(~r/\r?\n\r?\n/, response, parts: 3) do
          [_, _, text | _] -> text |> String.trim() |> String.slice(0, 2000)
          _ -> ""
        end

      [%{"subject" => subject, "body" => body, "from" => from_addr}]
    else
      []
    end
  end

  defp build_email(from, to, subject, body) do
    "From: #{from}\r\nTo: #{to}\r\nSubject: #{subject}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n#{body}"
  end
end
