#!/usr/bin/env python3
import argparse
import os
import re
import subprocess

import paramiko
import paramiko.agent
from scp import SCPClient

import paramiko_utils

# Workaround for paramiko: AgentKey skips PKey.__init__ and never sets
# public_blob; its __getattr__ raises AttributeError when inner_key is None
# (e.g. for cert agent keys like ssh-{rsa,ed25519}-cert-v01@openssh.com or
# FIDO2/SK keys), which crashes publickey auth in _get_key_type_and_bits.
paramiko.agent.AgentKey.public_blob = None

LOGTYPES_DEFAULT_ARG = "middleware,platform,nfs"

parser = argparse.ArgumentParser(
                    prog='collect-fuse.py',
                    description='Collects logs from fuse/fuse-staging',
                    formatter_class=argparse.RawTextHelpFormatter)
parser.add_argument('-c', '--cluster', type=str, required=True, help='cluster whose logs we need (ex. fern)')
parser.add_argument('-s', '--staging', action='store_true', default=False, help='use fuse-staging instead of fuse')
parser.add_argument('-l', '--logtypes', type=str, default=LOGTYPES_DEFAULT_ARG, help=f'''\
list of logtypes which we want to download (separated by comma)
   possible values:
    - middleware: middleware.log
    - middleware_db_dump
    - platform: platform.log of FMs
    - platform_blades: platform.log of blades
    - nfs: nfs.log of blades
    - system: system.log of FMs
    - system_blades: system.log of blades
    - haproxy_blades: haproxy.log of blades
    - congo: congo.log of FMs
    - congo_blades: congo.log of blades
    - http: http.log of blades
    - atop_blades: atop measurements on blades
   default value: \"{LOGTYPES_DEFAULT_ARG}\"''')
parser.add_argument('-d', '--dir-prefix', type=str, default='', help='''\
relative path where log pack directory shall be created
(ex. \"path/to/downloads\", then logs will be under \"path/to/downloads/irpXXX-cXX_2024-01-30-T17-00-37)
only irpXXX-cXX... directory will be created but no parents (for safety considerations)''')
parser.add_argument('--date', type=str, required=True, help='the date we need data for (format: YYYY-MM-DD)')
parser.add_argument('--min-hour', type=int, default=0, help='the minimum hour we need data for in 24 hour format')
parser.add_argument('--max-hour', type=int, default=23, help='the maximum hour we need data for in 24 hour format')
parser.add_argument('--cluster-dir-on-fuse', type=str, required=True, help='the dir where \'goto <cluster>\' brings on fuse (without date)')

args = parser.parse_args()

cluster = args.cluster
print(f'Used cluster: [{cluster}]')

fuse_server = 'fuse-staging' if args.staging else 'fuse'

logtypes = args.logtypes.split(',')
print(f'logtypes to download: [{logtypes}]')
print(f'date: [{args.date}]')

if args.max_hour < args.min_hour:
    print(f'Error: min-hour should be less or equal to max-hour! MIN_HOUR=[{args.min_hour}], MAX_HOUR=[{args.max_hour}]')
    exit(1)
print(f'minimum hour: [{args.min_hour}]')
print(f'maximum hour: [{args.max_hour}]')

date = args.date
dir_prefix = args.dir_prefix
cluster_dir_on_fuse = args.cluster_dir_on_fuse

logdir = f'{cluster}_{date}-T{args.min_hour}'
print(f'dir_prefix=[{dir_prefix}]')
if dir_prefix:
    logdir = os.path.join(dir_prefix, logdir)
logdir = os.path.realpath(logdir)
print(f'Directory in which we download the logs: {logdir}')

# only the leaf directory is created, no parents (for safety considerations)
os.mkdir(logdir)

# fuse uses underscore
fuse_date = date.replace('-', '_')
print(f'fuse_date=[{fuse_date}]')


def connect_via_ssh_config(host: str) -> paramiko.SSHClient:
    config = paramiko.SSHConfig()
    user_config_file = os.path.expanduser('~/.ssh/config')
    if os.path.exists(user_config_file):
        with open(user_config_file) as f:
            config.parse(f)
    cfg = config.lookup(host)
    print(f'alma: {cfg=}')

    client = paramiko.SSHClient()
    client.load_system_host_keys()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    connect_kwargs = {'hostname': cfg.get('hostname', host)}
    if 'user' in cfg:
        connect_kwargs['username'] = cfg['user']
    # if 'port' in cfg:
    #     connect_kwargs['port'] = int(cfg['port'])
    # if 'identityfile' in cfg:
    #     connect_kwargs['key_filename'] = cfg['identityfile']
    # if 'proxycommand' in cfg:
    #     connect_kwargs['sock'] = paramiko.ProxyCommand(cfg['proxycommand'])

    client.connect(**connect_kwargs)

    # forward the local ssh-agent on every session opened on this transport
    # (covers both client.exec_command and SCPClient channels)
    transport = client.get_transport()
    original_open_session = transport.open_session

    def open_session_with_agent_forwarding(*a, **kw):
        chan = original_open_session(*a, **kw)
        paramiko.agent.AgentRequestHandler(chan)
        return chan

    transport.open_session = open_session_with_agent_forwarding
    return client


def get_desired_log_patterns(logfilename: str) -> list[str]:
    return [f'{logfilename}.{date}.{hour:02d}-*' for hour in range(args.min_hour, args.max_hour + 1)]


def download_file(scp: SCPClient, remote_filepath: str, local_filepath: str):
    print(f'Downloading: {remote_filepath} ...')
    scp.get(remote_path=remote_filepath, local_path=local_filepath, preserve_times=True)


def download_desired_logs(client: paramiko.SSHClient, scp: SCPClient, remote_dir: str, logfilename: str, local_dir: str):
    desired_patterns = get_desired_log_patterns(logfilename)
    remote_basedir = f'{cluster_dir_on_fuse}/{fuse_date}/{remote_dir}'
    print(f'remote_dir={remote_dir}, desired_patterns={desired_patterns}, local_dir={local_dir}')
    ls_command = f'cd {remote_basedir}; ls ' + ' '.join(desired_patterns)
    output = paramiko_utils.run(client, ls_command)
    logfiles = [l for l in output.split() if l]
    print(f'logfiles=[{logfiles}]')
    for logfile in logfiles:
        download_file(scp, f'{remote_basedir}/{logfile}', local_dir)


fm_logtype_to_filename = [
    ('middleware', 'middleware.log'),
    ('middleware_db_dump', 'middleware_db_dump'),
    ('platform', 'platform.log'),
    ('system', 'system.log'),
    ('congo', 'congo.log'),
]

blade_logtype_to_filename = [
    ('nfs', 'nfs.log'),
    ('platform_blades', 'platform.log'),
    ('system_blades', 'system.log'),
    ('haproxy_blades', 'haproxy.log'),
    ('http', 'http.log'),
    ('congo_blades', 'congo.log'),
    ('atop_blades', 'atop_raw.log'),
]

print(f'\n-------- Collecting logs from CLUSTER=[{cluster}] --------\n')

def download_fm_logs(scp, logdirs):
    want_fm_logs = any(lt in logtypes for lt, _ in fm_logtype_to_filename)
    if not want_fm_logs:
        return

    fm_dirs = [d for d in logdirs if re.search(r'fm[12]$', d)]
    print(f'fm_dirs=[{fm_dirs}]')
    for fm in fm_dirs:
        local_fm_dir = os.path.join(logdir, fm)
        os.mkdir(local_fm_dir)
        print(f'collecting from FM: {fm}')
        for logtype, filename in fm_logtype_to_filename:
            if logtype in logtypes:
                download_desired_logs(client, scp, fm, filename, local_fm_dir)

def download_blade_logs(scp, logdirs):
    want_blade_logs = any(lt in logtypes for lt, _ in blade_logtype_to_filename)
    if not want_blade_logs:
        return

    blade_dirs = [d for d in logdirs if re.search(r'fb[0-9]+$', d)]
    print(f'blade_dirs=[{blade_dirs}]')
    for blade in blade_dirs:
        local_blade_dir = os.path.join(logdir, blade)
        os.mkdir(local_blade_dir)
        print(f'collecting from BLADE: {blade}')
        for logtype, filename in blade_logtype_to_filename:
            if logtype in logtypes:
                download_desired_logs(client, scp, blade, filename, local_blade_dir)

with connect_via_ssh_config(fuse_server) as client:
    scp = SCPClient(client.get_transport())
    logdirs_str = paramiko_utils.run(client, f'cd {cluster_dir_on_fuse}/{fuse_date}; ls')
    logdirs = logdirs_str.split()
    print(f'logdirs=[{logdirs}]')

    download_fm_logs(scp, logdirs)
    download_blade_logs(scp, logdirs)

print(f'decompressing every .zst file we downloaded in logdir=[{logdir}] ...')
subprocess.run(["find", logdir, "-name", "*.zst", "-exec", "sh", "-c", 'zstd -d "{}"; rm -f "{}"', ";"])

print(f'logdir=[{logdir}]')
subprocess.run(['cluster-info.sh'], cwd=logdir)

print(f'Directory in which the logs are downloaded: {logdir}')
