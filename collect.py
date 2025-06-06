import argparse
import warnings
from cryptography.utils import CryptographyDeprecationWarning

warnings.filterwarnings(
    "ignore",
    message=".*Blowfish.*",
    category=CryptographyDeprecationWarning
)

import os, io, paramiko
import datetime
import subprocess
import shutil
from paramiko.ssh_exception import SSHException
from scp import SCPClient

LOGTYPES_DEFAULT_ARG="middleware,platform,nfs"
DEFAULT_NUMBER_OF_LOGFILES=3

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

parser = argparse.ArgumentParser(
                    prog='collect.py',
                    description='Collects logs from clusters')
parser.add_argument('-c', '--clusters', type=str, help='where clusters are names of clusters separated by comma (ex. \"irp871-c01,irp871-c02\")')
# TODO: nice format in help
parser.add_argument('-l', '--logtypes', type=str, default=LOGTYPES_DEFAULT_ARG, help=f'''\
list of logtypes which we want to download (separated by comma)" 1>&2
   possible values:
    - middleware: middleware.log
    - platform: platform.log of FMs
    - platform_blades: platform.log of blades
    - nfs: nfs.log of blades
    - system: system.log of FMs
    - system_blades: system.log of blades
    - haproxy_blades: haproxy.log of blades
    - atop_blades: atop measurements on blades
   default value: \"{LOGTYPES_DEFAULT_ARG}\"''')
# TODO: nice format in help
parser.add_argument('-d', '--dir-prefix', type=str, default='', help='''\
relative path where log pack directory shall be created.
(ex. \"path/to/downloads\", then logs will be under \"path/to/downloads/irpXXX-cXX_2024-01-30-T17-00-37)
only irpXXX-cXX... directory will be created but no parents (for safety considerations)''')
parser.add_argument('-n', '--num', type=int, default=DEFAULT_NUMBER_OF_LOGFILES, help=f'collect only the last <number> of logfiles, default value: {DEFAULT_NUMBER_OF_LOGFILES}')

args = parser.parse_args()

if not args.clusters:
    print(f'Please specify clusters with -c/--clusters')
    exit(1)
clusters_concat=args.clusters
clusters=clusters_concat.split(',')
print(f'clusters = {clusters}')
assert len(clusters) > 0, 'len(clusters) is 0'

logtypes=args.logtypes.split(',')
print(f'logtypes = {logtypes}')
assert len(logtypes) > 0, 'len(logtypes) is 0'
want_blade_logs = list(set(logtypes) & {"nfs", "platform_blades", "system_blades", "haproxy_blades"})
want_fm_logs = list(set(logtypes) & {"middleware", "platform", "system"})

dir_prefix=args.dir_prefix
print(f'dir_prefix = {dir_prefix}')

number_of_logfiles=args.num
print(f'number_of_logfiles = {number_of_logfiles}')

current_time=datetime.datetime.now()
toplevel_logdir=clusters[0] + '_' + current_time.strftime('%F-T%H-%M-%S')
if dir_prefix:
    toplevel_logdir = os.path.join(dir_prefix, toplevel_logdir)

os.makedirs(toplevel_logdir)

def download_file(scp, remote_filepath: str, local_filepath: str):
    print(f'Downloading: {remote_filepath} ...')
    scp.get(remote_path=remote_filepath, local_path=local_filepath, preserve_times=True)

print('collecting FM IPs')
cluster_fm_ips = []

for cluster in clusters:
    ip1 = ''
    ip2 = ''
    master_fm = 0
    with agentNestedConnectWithPassword(None, cluster, username="ir", password="welcome", look_for_keys=False) as client:
        ip1 = run(client, f"purenetwork list --csv | grep 'fm1.admin0,' | cut -d',' -f5")
        ip2 = run(client, f"purenetwork list --csv | grep 'fm2.admin0,' | cut -d',' -f5")
        master_fm = int(run(client, "puremastership list | grep master | cut -d'M' -f2 | cut -c1-1"))
    assert master_fm in (1, 2), f'master_fm should be 1 or 2, but is {master_fm}'
    assert ip1, 'ip1 is empty'
    assert ip2, 'ip2 is empty'

    if want_fm_logs:
        for ip in (ip1, ip2):
            fm_num = 1 if ip is ip1 else 2
            fm_dir = os.path.join(toplevel_logdir, f'{cluster}_sup{fm_num}_{ip}')
            print(f'fm_num={fm_num}, ip={ip}, fm_dir={fm_dir}')

            os.makedirs(fm_dir)
            with agentNestedConnectWithPassword(None, ip, username="ir", password="welcome", look_for_keys=False) as client_fm:
                logfiles = []
                if 'middleware' in logtypes:
                    logfiles_str = run(client_fm, f'cd /logs; ls middleware.log* -tr | tail --lines {number_of_logfiles}')
                    logfiles += logfiles_str.split('\n')
                if 'platform' in logtypes:
                    logfiles_str = run(client_fm, f'cd /logs; ls platform.log* -tr | tail --lines {number_of_logfiles}')
                    logfiles += logfiles_str.split('\n')
                if 'system' in logtypes:
                    logfiles_str = run(client_fm, f'cd /logs; ls system.log* -tr | tail --lines {number_of_logfiles}')
                    logfiles += logfiles_str.split('\n')
                print(f'logfiles = {logfiles}')
                for logfile in logfiles:
                    scp = SCPClient(client_fm.get_transport())
                    download_file(scp, '/logs/'+logfile, fm_dir)

    if want_blade_logs:
        # using standby_fm because it's less loaded
        # standby_fm is indexed from 0!
        standby_fm = 0 if master_fm == 2 else 1
        standby_ip = (ip1, ip2)[standby_fm]
        with agentNestedConnectWithPassword(None, standby_ip, username="ir", password="welcome", look_for_keys=False) as client_fm:
            bladelist_str = run(client_fm, "pureblade list --notitle | grep -v unused | cut -d' ' -f1 | cut -c7-")
            bladelist = bladelist_str.split('\n')
            assert len(bladelist) > 0, f'bladelist is empty, bladelist_str={bladelist_str}'
            for bladenum in bladelist:
                print(f'cluster={cluster}, blade=ir{bladenum}')
                with nestedConnectWithKeyFromClient(client_fm, f'ir{bladenum}', username="ir", key=getKeyFromClient(client_fm, "/home/ir/.ssh/id_rsa")) as client_blade:
                    scp = SCPClient(client_blade.get_transport())
                    logfiles = []
                    if 'nfs' in logtypes:
                        logfiles_str = run(client_blade, f'cd /logs; ls nfs.log nfs.log.* -tr | tail --lines {number_of_logfiles}')
                        logfiles += logfiles_str.split('\n')
                    if 'platform_blade' in logtypes:
                        logfiles_str = run(client_blade, f'cd /logs; ls platform.log* -tr | tail --lines {number_of_logfiles}')
                        logfiles += logfiles_str.split('\n')
                    if 'system_blade' in logtypes:
                        logfiles_str = run(client_blade, f'cd /logs; ls system.log* -tr | tail --lines {number_of_logfiles}')
                        logfiles += logfiles_str.split('\n')
                    if 'haproxy_blade' in logtypes:
                        logfiles_str = run(client_blade, f'cd /logs; ls haproxy.log* -tr | tail --lines {number_of_logfiles}')
                        logfiles += logfiles_str.split('\n')
                    print(f'logfiles = {logfiles}')
                    local_blade_dir = os.path.join(toplevel_logdir, cluster, f'ir{bladenum}')
                    os.makedirs(local_blade_dir)
                    for logfile in logfiles:
                        scp = SCPClient(client_blade.get_transport())
                        download_file(scp, '/logs/'+logfile, local_blade_dir)

print(f"decompressing every .zst file we downloaded in toplevel_logdir=[{toplevel_logdir}] ...")
subprocess.run(["find", toplevel_logdir, "-name", "*.zst", "-exec", "sh", "-c",  'zstd -d "{}"; rm -f "{}"', ";"])

current_time = datetime.datetime.now().timestamp()
ir_test_log_time = os.path.getmtime('ir_test.log')
if os.path.exists('ir_test.log') and ir_test_log_time < current_time:
    ir_test_log_age = current_time - ir_test_log_time
    print(f"ir_test.log age: {int(ir_test_log_age)} sec")
    if ir_test_log_age < 12*60*60:
        print(f"copying ir_test.log")
        shutil.copyfile('ir_test.log', os.path.join(toplevel_logdir, 'ir_test.log'))
    else:
        print(f"NOT copying ir_test.log, because it is too old")

print(f'\nlogdir = {toplevel_logdir}')