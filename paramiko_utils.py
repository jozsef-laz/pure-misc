import io
import paramiko
import warnings

from cryptography.utils import CryptographyDeprecationWarning

warnings.filterwarnings(
    "ignore",
    message=".*Blowfish.*",
    category=CryptographyDeprecationWarning
)

def run(client: paramiko.SSHClient, command: str):
    stdin, stdout, stderr = client.exec_command(command)
    exit_status = stdout.channel.recv_exit_status()
    output = stdout.read().decode('utf-8').strip()
    error = stderr.read().decode('utf-8').strip()
    # print(f'run output of command: {command}\n' + output)
    return output

def rootConnect(hostname, username, password):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(hostname, username=username, password=password, allow_agent=True, look_for_keys=True)
    return client

def agentNestedConnectWithPassword(client, hostname, username, password, look_for_keys=True):
    if client == None:
        socket = None
    else:
        transport = client.get_transport()
        socket = transport.open_channel("direct-tcpip", (hostname, 22), ("127.0.0.1", 0))

    client2 = paramiko.SSHClient()
    client2.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    print(f"hostname={hostname}, username={username}, pass={password}, look_for_keys={look_for_keys}")
    client2.connect(hostname, username=username, password=password, sock=socket, allow_agent=False, look_for_keys=look_for_keys)
    return client2

def getKeyFromClient(client: paramiko.SSHClient, key_filepath: str):
    if client == None:
        with open(key_filepath, "r") as local_key_file:
            key_string = local_key_file.read()
    else:
        with client.open_sftp() as sftp, sftp.open(key_filepath, "r") as remote_key_file:
            key_string = remote_key_file.read().decode('utf-8')

    key_stream = io.StringIO(key_string)
    for cls in (paramiko.RSAKey, paramiko.DSSKey, paramiko.ECDSAKey, paramiko.Ed25519Key):
        try:
            key_stream.seek(0)
            key = cls.from_private_key(key_stream)
            return key  # e.g. "RSAKey", "Ed25519Key", etc.
        except paramiko.ssh_exception.SSHException:
            pass
    return None

def nestedConnectWithKeyFromClient(client: paramiko.SSHClient, hostname: str, username: str, key):
    if client == None:
        socket = None
    else:
        transport = client.get_transport()
        socket = transport.open_channel("direct-tcpip", (hostname, 22), ("127.0.0.1", 0))

    client2 = paramiko.SSHClient()
    client2.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client2.connect(hostname, username=username, sock=socket, pkey=key, allow_agent=True, look_for_keys=False)
    return client2
