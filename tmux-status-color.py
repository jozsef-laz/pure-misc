import subprocess
colorMap = {
    "first": "colour81", # blue
    "second": "colour10", # green
    "third": "colour183", # purple
    "triage": "colour208", # orange
    "perf": "colour226", # yellow
    "devcontainers": "colour248", # gray
    "swagger": "colour217", # pink
    "lamella": "colour223", # peach
}

res = subprocess.run(["tmux", "list-sessions", "-F", "#{session_name}"], capture_output=True)
sessions = [session for session in res.stdout.decode("utf-8").split('\n') if session]

for session in sessions:
    if session not in colorMap:
        print(f'skipping session {session}...')
        continue
    print(f"{session} gets color {colorMap[session]}")
    subprocess.run(['tmux', 'set', '-t', session, 'status-bg', f'{colorMap[session]}'])
    res = subprocess.run(["tmux", "list-windows", "-t", session], capture_output=True)
    windows = [win for win in res.stdout.decode("utf-8").split('\n') if win]
    for win in windows:
        subprocess.run(['tmux', 'set', '-t', session, 'window-status-current-style', f'bg=black,fg={colorMap[session]}'])
        subprocess.run(['tmux', 'next-window', '-t', session])

