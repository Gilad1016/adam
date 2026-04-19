"""Email client — IMAP/SMTP for Gmail."""

import email
import imaplib
import os
import smtplib
from email.mime.text import MIMEText


AGENT_EMAIL = os.environ.get("ADAM_EMAIL_ADDRESS", "")
AGENT_PASSWORD = os.environ.get("ADAM_EMAIL_PASSWORD", "")
OWNER_EMAIL = os.environ.get("ADAM_OWNER_EMAIL", "")

IMAP_HOST = "imap.gmail.com"
SMTP_HOST = "smtp.gmail.com"
SMTP_PORT = 587


def check_inbox() -> list[dict]:
    if not AGENT_EMAIL or not AGENT_PASSWORD:
        return []

    try:
        mail = imaplib.IMAP4_SSL(IMAP_HOST)
        mail.login(AGENT_EMAIL, AGENT_PASSWORD)
        mail.select("inbox")

        _, data = mail.search(None, "UNSEEN")
        messages = []

        for num in data[0].split():
            _, msg_data = mail.fetch(num, "(RFC822)")
            raw = email.message_from_bytes(msg_data[0][1])

            sender = email.utils.parseaddr(raw["From"])[1]
            subject = raw["Subject"] or ""
            body = _extract_body(raw)

            messages.append({
                "from": sender,
                "subject": subject,
                "body": body,
                "is_owner": sender.lower() == OWNER_EMAIL.lower(),
            })

        mail.logout()
        return messages
    except Exception as e:
        print(f"[EMAIL CHECK FAILED: {e}]")
        return []


def send_email(subject: str, body: str, to: str | None = None) -> bool:
    if not AGENT_EMAIL or not AGENT_PASSWORD:
        print("[EMAIL SEND SKIPPED: no credentials]")
        return False

    recipient = to or OWNER_EMAIL
    msg = MIMEText(body)
    msg["Subject"] = subject
    msg["From"] = AGENT_EMAIL
    msg["To"] = recipient

    try:
        server = smtplib.SMTP(SMTP_HOST, SMTP_PORT)
        server.starttls()
        server.login(AGENT_EMAIL, AGENT_PASSWORD)
        server.sendmail(AGENT_EMAIL, recipient, msg.as_string())
        server.quit()
        return True
    except Exception as e:
        print(f"[EMAIL SEND FAILED: {e}]")
        return False


def _extract_body(msg) -> str:
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain":
                payload = part.get_payload(decode=True)
                if payload:
                    return payload.decode("utf-8", errors="replace")
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            return payload.decode("utf-8", errors="replace")
    return ""
