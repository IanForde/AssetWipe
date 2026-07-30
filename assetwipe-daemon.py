#!/usr/bin/env python3
"""
AssetWipe Daemon
Runs as root via launchd. Accepts commands via two channels:

  1. Unix socket  /var/run/assetwipe.sock  — for direct terminal use
  2. Trigger file <watch_dir>/.assetwipe-trigger — for Claude sandbox use

The watch directory is read from /Library/Application Support/AssetWipe/config.json
and is set to the user's mounted Cowork project folder by the installer.
"""

import os
import sys
import json
import socket
import subprocess
import threading
import signal
import logging
import time

SOCKET_PATH = '/var/run/assetwipe.sock'
LOG_PATH    = '/var/log/assetwipe-daemon.log'
CONFIG_PATH = '/Library/Application Support/AssetWipe/config.json'

logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format='%(asctime)s  %(levelname)-8s  %(message)s',
)

# Allowlist — only these commands can be triggered
COMMANDS = {
    'status':  None,
    'dfu':     ['macvdmtool', 'dfu'],
    'list':    ['cfgutil', 'list'],
    'restore': ['cfgutil', 'restore'],
}


def run(args, timeout=1800):
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


def execute(cmd):
    """Execute a command string and return (success, output)."""
    if cmd not in COMMANDS:
        return False, f'Unknown command: {cmd}'
    if cmd == 'status':
        return True, 'AssetWipe daemon is running.'
    return run(COMMANDS[cmd])


# ── Channel 1: Unix socket ────────────────────────────────────────────────────

def handle_socket_client(conn):
    try:
        data = b''
        while b'\n' not in data:
            chunk = conn.recv(1024)
            if not chunk:
                break
            data += chunk

        request = json.loads(data.decode().strip())
        cmd = request.get('command', '').strip()
        logging.info('Socket command: %s', cmd)

        success, output = execute(cmd)
        logging.info('Socket %s %s', cmd, 'OK' if success else 'FAILED')
        conn.sendall(json.dumps({'success': success, 'output': output}).encode() + b'\n')

    except Exception as e:
        logging.error('Socket handler error: %s', e)
        try:
            conn.sendall(json.dumps({'success': False, 'output': str(e)}).encode() + b'\n')
        except Exception:
            pass
    finally:
        conn.close()


def socket_server():
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o666)
    server.listen(5)
    logging.info('Socket listening on %s', SOCKET_PATH)

    while True:
        conn, _ = server.accept()
        t = threading.Thread(target=handle_socket_client, args=(conn,), daemon=True)
        t.start()


# ── Channel 2: File trigger ───────────────────────────────────────────────────

def file_watcher(watch_dir):
    trigger = os.path.join(watch_dir, '.assetwipe-trigger')
    result  = os.path.join(watch_dir, '.assetwipe-result')

    logging.info('File watcher active: %s', watch_dir)

    while True:
        try:
            if os.path.exists(trigger):
                with open(trigger) as f:
                    request = json.load(f)
                os.unlink(trigger)

                cmd = request.get('command', '').strip()
                logging.info('File trigger command: %s', cmd)

                success, output = execute(cmd)
                logging.info('File trigger %s %s', cmd, 'OK' if success else 'FAILED')

                with open(result, 'w') as f:
                    json.dump({'success': success, 'output': output}, f)
                os.chmod(result, 0o666)

        except Exception as e:
            logging.error('File watcher error: %s', e)

        time.sleep(0.5)


# ── Startup ───────────────────────────────────────────────────────────────────

def load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def cleanup(signum=None, frame=None):
    logging.info('Daemon shutting down (signal %s)', signum)
    try:
        os.unlink(SOCKET_PATH)
    except OSError:
        pass
    sys.exit(0)


def main():
    logging.info('AssetWipe daemon starting (pid %d)', os.getpid())

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT,  cleanup)

    config = load_config()
    watch_dir = config.get('watch_dir', '')

    # Start file watcher if a watch directory is configured
    if watch_dir and os.path.isdir(watch_dir):
        t = threading.Thread(target=file_watcher, args=(watch_dir,), daemon=True)
        t.start()
    else:
        logging.warning('No valid watch_dir in config — file trigger disabled. Re-run installer to fix.')

    # Start socket server (blocking)
    socket_server()


if __name__ == '__main__':
    main()
