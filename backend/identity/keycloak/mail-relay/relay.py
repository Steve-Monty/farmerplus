"""Private SMTP relay for the FarmerPlus Keycloak test-recipient phase.

Only the Keycloak container may submit. Account email addresses stay unchanged;
the SMTP envelope and visible To header route to the operator test inbox.
"""
import asyncio
import json
import os
import smtplib
import socket
import ssl
import threading
from email.parser import BytesParser
from email.policy import SMTP
from pathlib import Path

from aiosmtpd.controller import Controller

CONFIG_PATH = Path('/run/secrets/farmerplus-mail-relay.json')


def relay_message(config, original_content, original_recipients):
    message = BytesParser(policy=SMTP).parsebytes(original_content)
    for header in ('To', 'Cc', 'Bcc'):
        if header in message:
            del message[header]
    message['To'] = config['test_recipient']
    message['X-FarmerPlus-Original-Recipient'] = ', '.join(original_recipients)
    content = message.as_bytes(policy=SMTP)
    context = ssl.create_default_context()
    with smtplib.SMTP(config['host'], int(config['port']), timeout=20) as smtp:
        smtp.ehlo()
        smtp.starttls(context=context)
        smtp.ehlo()
        smtp.login(config['user'], config['password'])
        smtp.sendmail(config['from'], [config['test_recipient']], content)


class Handler:
    def __init__(self, config):
        self.config = config

    async def handle_RCPT(self, server, session, envelope, address, rcpt_options):
        if len(envelope.rcpt_tos) >= 1:
            return '452 One recipient per message'
        envelope.rcpt_tos.append(address)
        return '250 OK'

    async def handle_DATA(self, server, session, envelope):
        if not session.peer or session.peer[0] != socket.gethostbyname('identity'):
            return '554 Sender not permitted'
        if not envelope.rcpt_tos or len(envelope.original_content) > 1024 * 1024:
            return '552 Invalid message size or recipient'
        try:
            await asyncio.to_thread(relay_message, self.config,
                                    envelope.original_content, envelope.rcpt_tos)
        except (OSError, smtplib.SMTPException):
            return '451 Delivery temporarily unavailable'
        return '250 Accepted'


if __name__ == '__main__':
    config = json.loads(CONFIG_PATH.read_text())
    assert config['test_recipient'] == 'steve@informationcapital.co.za'
    assert config['host'] and config['user'] and config['password'] and config['from']
    Controller(Handler(config), hostname='0.0.0.0', port=1025,
               data_size_limit=1024 * 1024).start()
    threading.Event().wait()
