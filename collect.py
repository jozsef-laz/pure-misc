import argparse
import datetime
import os
import subprocess
import shutil
from scp import SCPClient

import paramiko_utils

LOGTYPES_DEFAULT_ARG="middleware,platform,nfs"
DEFAULT_NUMBER_OF_LOGFILES=3

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
    with paramiko_utils.agentNestedConnectWithPassword(None, cluster, username="ir", password="welcome", look_for_keys=False) as client:
        ip1 = paramiko_utils.run(client, f"purenetwork list --csv | grep 'fm1.admin0,' | cut -d',' -f5")
        ip2 = paramiko_utils.run(client, f"purenetwork list --csv | grep 'fm2.admin0,' | cut -d',' -f5")
        master_fm = int(paramiko_utils.run(client, "puremastership list | grep master | cut -d'M' -f2 | cut -c1-1"))
    assert master_fm in (1, 2), f'master_fm should be 1 or 2, but is {master_fm}'
    assert ip1, 'ip1 is empty'
    assert ip2, 'ip2 is empty'

    if want_fm_logs:
        for ip in (ip1, ip2):
            fm_num = 1 if ip is ip1 else 2
            fm_dir = os.path.join(toplevel_logdir, f'{cluster}_sup{fm_num}_{ip}')
            print(f'fm_num={fm_num}, ip={ip}, fm_dir={fm_dir}')

            os.makedirs(fm_dir)
            with paramiko_utils.agentNestedConnectWithPassword(None, ip, username="ir", password="welcome", look_for_keys=False) as client_fm:
                logfiles = []
                if 'middleware' in logtypes:
                    logfiles_str = paramiko_utils.run(client_fm, f'cd /logs; ls middleware.log* -tr | tail --lines {number_of_logfiles}')
                    logfiles += logfiles_str.split('\n')
                if 'platform' in logtypes:
                    logfiles_str = paramiko_utils.run(client_fm, f'cd /logs; ls platform.log* -tr | tail --lines {number_of_logfiles}')
                    logfiles += logfiles_str.split('\n')
                if 'system' in logtypes:
                    logfiles_str = paramiko_utils.run(client_fm, f'cd /logs; ls system.log* -tr | tail --lines {number_of_logfiles}')
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
        with paramiko_utils.agentNestedConnectWithPassword(None, standby_ip, username="ir", password="welcome", look_for_keys=False) as client_fm:
            bladelist_str = paramiko_utils.run(client_fm, "pureblade list --notitle | grep -v unused | cut -d' ' -f1 | cut -c7-")
            bladelist = bladelist_str.split('\n')
            assert len(bladelist) > 0, f'bladelist is empty, bladelist_str={bladelist_str}'
            for bladenum in bladelist:
                print(f'cluster={cluster}, blade=ir{bladenum}')
                with paramiko_utils.nestedConnectWithKeyFromClient(client_fm, f'ir{bladenum}', username="ir", key=paramiko_utils.getKeyFromClient(client_fm, "/home/ir/.ssh/id_rsa")) as client_blade:
                    scp = SCPClient(client_blade.get_transport())
                    logfiles = []
                    if 'nfs' in logtypes:
                        logfiles_str = paramiko_utils.run(client_blade, f'cd /logs; ls nfs.log nfs.log.* -tr | tail --lines {number_of_logfiles}')
                        logfiles += logfiles_str.split('\n')
                    if 'platform_blade' in logtypes:
                        logfiles_str = paramiko_utils.run(client_blade, f'cd /logs; ls platform.log* -tr | tail --lines {number_of_logfiles}')
                        logfiles += logfiles_str.split('\n')
                    if 'system_blade' in logtypes:
                        logfiles_str = paramiko_utils.run(client_blade, f'cd /logs; ls system.log* -tr | tail --lines {number_of_logfiles}')
                        logfiles += logfiles_str.split('\n')
                    if 'haproxy_blade' in logtypes:
                        logfiles_str = paramiko_utils.run(client_blade, f'cd /logs; ls haproxy.log* -tr | tail --lines {number_of_logfiles}')
                        logfiles += logfiles_str.split('\n')
                    print(f'logfiles = {logfiles}')
                    local_blade_dir = os.path.join(toplevel_logdir, cluster, f'ir{bladenum}')
                    os.makedirs(local_blade_dir)
                    for logfile in logfiles:
                        scp = SCPClient(client_blade.get_transport())
                        download_file(scp, '/logs/'+logfile, local_blade_dir)

print(f"decompressing every .zst file we downloaded in toplevel_logdir=[{toplevel_logdir}] ...")
subprocess.run(["find", toplevel_logdir, "-name", "*.zst", "-exec", "sh", "-c",  'zstd -d "{}"; rm -f "{}"', ";"])

def copy_ir_test_log():
    if not os.path.exists('ir_test.log'):
        print('no ir_test.log was found')
        return

    current_time = datetime.datetime.now().timestamp()
    ir_test_log_time = os.path.getmtime('ir_test.log')
    if ir_test_log_time > current_time:
        print('ir_test.log was modified in the future, skipping...')
        return

    ir_test_log_age = current_time - ir_test_log_time
    print(f"ir_test.log age: {int(ir_test_log_age)} sec")
    if ir_test_log_age > 12*60*60:
        print(f"NOT copying ir_test.log, because it is too old")
        return

    print(f"copying ir_test.log")
    shutil.copyfile('ir_test.log', os.path.join(toplevel_logdir, 'ir_test.log'))

copy_ir_test_log()

print(f'\nlogdir = {toplevel_logdir}')