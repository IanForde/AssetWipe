#!/usr/bin/env python3
"""
AssetWipe Daemon
Runs as root via launchd. Listens on a Unix socket and executes
privileged macvdmtool / cfgutil commands on behalf of the skill,
so no sudo prompt is ever needed at wipe time.
"""

import os
import sys
import json
import socket
import subprocess
import threading
import signal
import logging

SOCKET_PATH = '/var/run/assetwipe.sock'
LOG_PATH    = '/var/log/assetwipe-daemon.log'

logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format='%(asctime)s  %(levelname)-8s  %(message)s',
)

# Allowlist — only these commands can be triggered over the socket
COMMANDS = {
    'status':  None,                          # built-in, no subprocess
    'dfu':     ['macvdmtool', 'dfu'],
    'list':    ['cfgutil', 'list'],
    'restore': ['cfgutil', 'restore'],
}


def run(args, timeout=300):
    """Run a subprocess and return (success, combined_output)."""
    try:
        result = subprocess.run(
            args, capture_output=True, text=True, timeout=timeout
        )
        output = (result.stdout or '') + (result.stderr or '')
        return result.returncode == 0, output.strip()
    except FileNotFoundError:
        return False, f'Command not found: {args[0]}'
    except subprocess.TimeoutExpired:
        return False, f'Command timed out after {timeout}s'
    except Exception as e:
        return False, str(e)


def handle_client(conn):
    try:
        data = b''
        while b'\n' not in data:
            chunk = conn.recv(1024)
            if not chunk:
                break
            data += chunk

        request = json.loads(data.decode().strip())
        cmd = request.get('command', '').strip()
        logging.info('Command received: %s', cmd)

        if cmd not in COMMANDS:
            response = {'success': False, 'output': f'Unknown command: {cmd}'}
        elif cmd == 'status':
            response = {'success': True, 'output': 'AssetWipe daemon is running.'}
        else:
            success, output = run(COMMANDS[cmd])
            logging.info('Command %s %s', cmd, 'succeeded' if success else 'FAILED')
            if not success:
                logging.warning('Output: %s', output)
            response = {'success': success, 'output': output}

        conn.sendall(json.dumps(response).encode() + b'\n')

    except Exception as e:
        logging.error('Client handler error: %s', e)
        try:
            conn.sendall(json.dumps({'success': False, 'output': str(e)}).encode() + b'\n')
        except Exception:
            pass
    finally:
        conn.close()


def cleanup(signum=None, frame=None):
    logging.info('Daemon shutting down (signal %s)', signum)
    try:
        os.unlink(SOCKET_PATH)
    except OSError:
        pass
    sys.exit(0)


def main():
    logging.info('AssetWipe daemon starting (pid %d)', os.getpid())

    # Remove stale socket from a previous run
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT,  cleanup)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    # Allow any local user to send commands — restrict further if needed
    os.chmod(SOCKET_PATH, 0o666)
    server.listen(5)

    logging.info('Listening on %s', SOCKET_PATH)

    while True:
        conn, _ = server.accept()
        t = threading.Thread(target=handle_client, args=(conn,), daemon=True)
        t.start()


if __name__ == '__main__':
    main()
