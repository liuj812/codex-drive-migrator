"""Codex Drive Migrator: local-only Windows migration UI and bundled helper."""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading

VERSION = '0.1.0'
LABELS = {'data':'聊天与配置', 'agents':'个人技能', 'runtimes':'运行环境', 'engine':'程序组件', 'local':'本地缓存', 'roaming':'界面缓存'}
ROOT = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parent))
STAGES = {
    'waiting_for_codex_exit': '等待完全退出 Codex（包括托盘）',
    'preparing_permissions': '正在准备目录权限',
    'final_copy': '正在同步文件',
    'verifying': '正在进行 SHA-256 校验',
    'waiting_for_files_to_settle': '等待文件稳定后重试',
    'removing_verified_c_copy': '正在清理已校验的旧备份',
    'moving_windows_application': '正在整理应用迁移结果',
    'complete': '迁移完成',
    'complete_backup_retained': '迁移完成，原始备份已保留',
    'data_complete_attention_needed': '数据迁移完成，应用安装位置需另外处理',
    'cancelled': '已取消，尚未开始迁移',
    'failed': '迁移已停止，请查看下方原因',
    'waiting_timeout': '等待退出超时，可重新开始',
}
FINAL = {'complete', 'complete_backup_retained', 'data_complete_attention_needed', 'cancelled', 'failed', 'waiting_timeout'}


def powershell() -> str:
    return str(Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe')


def engine_args(destination: str, *, inspect=False, cleanup=False, clean=False, move=False):
    arguments = [powershell(), '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                 '-File', str(ROOT / 'assets' / ('inspect.ps1' if inspect else 'migrate.ps1')),
                 '-DestinationRoot', destination, '-HelperExecutable', sys.executable]
    if not getattr(sys, 'frozen', False):
        arguments += ['-HelperScript', str(Path(__file__).resolve())]
    if cleanup:
        arguments += ['-CleanupOnly']
    if clean:
        arguments += ['-CleanBackups']
    if move:
        arguments += ['-MoveApplication']
    return arguments


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--tree-io':
        from tree_io import handle_request
        return handle_request(sys.argv[2])
    if '--self-test' in sys.argv:
        from self_test import run
        index = sys.argv.index('--self-test')
        output = Path(sys.argv[index + 1]) if len(sys.argv) > index + 1 else Path.cwd() / 'self-test-result.json'
        return run(output)
    if sys.platform != 'win32':
        raise SystemExit('This application requires Windows 10/11.')
    import tkinter as tk
    from tkinter import ttk, filedialog, messagebox

    class Application:
        def __init__(self):
            self.window = tk.Tk()
            self.window.title(f'Codex Drive Migrator · {VERSION}')
            self.window.geometry('1060x740')
            self.window.minsize(940, 650)
            self.window.configure(bg='#f3f6fb')
            style = ttk.Style(self.window)
            style.theme_use('clam')
            style.configure('.', font=('Microsoft YaHei UI', 10), background='#f3f6fb')
            style.configure('TButton', padding=(14, 8))
            style.configure('Accent.TButton', background='#1c6ae4', foreground='white')
            style.map('Accent.TButton', background=[('active', '#1354ba'), ('disabled', '#a9b8cf')])
            style.configure('Treeview', background='white', fieldbackground='white', rowheight=32)
            style.configure('Treeview.Heading', font=('Microsoft YaHei UI', 10, 'bold'), padding=8)
            self.destination = tk.StringVar(value=r'D:\Codex')
            self.clean = tk.BooleanVar(value=False)
            self.move = tk.BooleanVar(value=False)
            self.status = tk.StringVar(value='先扫描目录，确认迁移计划')
            self.events = queue.Queue()
            self.worker = None
            self.worker_log = None
            self.plans = None
            self.scanned_destination = None
            self.last_stage = ''
            self.work_root = None
            self.close_after_cancel = False
            self.scan_active = False

            header = tk.Frame(self.window, bg='#14283f', padx=26, pady=20)
            header.pack(fill='x')
            tk.Label(header, text='CODEX  /  DRIVE MIGRATOR', font=('Segoe UI', 12, 'bold'), bg='#14283f', fg='#82b7ff').pack(anchor='w')
            tk.Label(header, text='给系统盘腾出空间', font=('Microsoft YaHei UI', 23, 'bold'), bg='#14283f', fg='white').pack(anchor='w', pady=(8, 2))
            tk.Label(header, text='迁移数据与运行组件 · 保留兼容路径 · 全程本地处理', bg='#14283f', fg='#c3d2e5', font=('Microsoft YaHei UI', 10)).pack(anchor='w')
            body = ttk.Frame(self.window, padding=24)
            body.pack(fill='both', expand=True)
            target_row = ttk.Frame(body)
            target_row.pack(fill='x')
            ttk.Label(target_row, text='目标文件夹').pack(side='left', padx=(0, 14))
            self.target_entry = ttk.Entry(target_row, textvariable=self.destination)
            self.target_entry.pack(side='left', fill='x', expand=True)
            self.browse_button = ttk.Button(target_row, text='选择位置', command=self.browse)
            self.browse_button.pack(side='left', padx=(10, 0))
            self.scan_button = ttk.Button(target_row, text='扫描目录', command=self.scan)
            self.scan_button.pack(side='left', padx=(10, 0))
            ttk.Label(body, text='支持本地非 C 盘目录，例如 D:\\Codex。扫描不会修改你的文件。', foreground='#65758b').pack(anchor='w', pady=(8, 14))
            self.table = ttk.Treeview(body, columns=('name', 'state', 'source', 'target'), show='headings', height=6)
            for name, title, width in [('name','目录',110),('state','状态',100),('source','当前位置',300),('target','迁移位置',260)]:
                self.table.heading(name, text=title)
                self.table.column(name, width=width, minwidth=80)
            self.table.pack(fill='x')
            bar = ttk.Scrollbar(body, orient='horizontal', command=self.table.xview)
            self.table.configure(xscrollcommand=bar.set)
            bar.pack(fill='x')
            options = ttk.Frame(body)
            options.pack(fill='x', pady=(14, 3))
            self.clean_check = ttk.Checkbutton(options, text='校验完成后清理旧备份（默认保留）', variable=self.clean)
            self.clean_check.pack(side='left')
            self.move_check = ttk.Checkbutton(options, text='尝试通过 Windows 移动主程序', variable=self.move)
            self.move_check.pack(side='right')
            ttk.Label(body, text='Windows 框架包由系统管理，会单独列出；不会尝试强制搬移。', foreground='#65758b').pack(anchor='w', pady=(2, 12))
            actions = ttk.Frame(body)
            actions.pack(fill='x')
            self.start_button = ttk.Button(actions, text='开始迁移', style='Accent.TButton', command=self.start, state='disabled')
            self.start_button.pack(side='left')
            self.cleanup_button = ttk.Button(actions, text='清理已验证备份', command=lambda: self.start(cleanup=True), state='disabled')
            self.cleanup_button.pack(side='left', padx=8)
            self.cancel_button = ttk.Button(actions, text='取消等待', command=self.cancel, state='disabled')
            self.cancel_button.pack(side='left')
            ttk.Button(actions, text='打开记录目录', command=self.open_records).pack(side='right')
            ttk.Label(body, textvariable=self.status, font=('Microsoft YaHei UI', 11, 'bold')).pack(anchor='w', pady=(14, 6))
            self.progress = ttk.Progressbar(body, mode='indeterminate')
            self.progress.pack(fill='x', pady=(0, 10))
            self.log_box = tk.Text(body, height=7, wrap='word', bg='white', fg='#314156', relief='flat', font=('Microsoft YaHei UI', 9), padx=12, pady=10, state='disabled')
            self.log_box.pack(fill='both', expand=True)
            self.log('准备就绪。默认保留原始备份；清理时会再次校验内容。')
            self.window.protocol('WM_DELETE_WINDOW', self.on_close)
            self.window.after(500, self.poll)

        def log(self, text):
            self.log_box.configure(state='normal')
            self.log_box.insert('end', text + '\n')
            self.log_box.see('end')
            self.log_box.configure(state='disabled')

        def browse(self):
            value = filedialog.askdirectory(title='选择迁移目标目录')
            if value:
                self.destination.set(value)
                self.plans = None
                self.start_button.configure(state='disabled')
                self.cleanup_button.configure(state='disabled')

        def scan(self):
            if self.scan_active or self.running():
                return
            destination = os.path.abspath(self.destination.get().strip())
            self.scan_active = True
            self.set_busy(True)
            self.status.set('正在扫描目录与应用进程…')
            self.progress.start(14)
            def inspect():
                try:
                    result = subprocess.run(engine_args(destination, inspect=True), capture_output=True, encoding='utf-8-sig', errors='replace', creationflags=subprocess.CREATE_NO_WINDOW)
                    if result.returncode:
                        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
                    self.events.put(('scan', (destination, json.loads(result.stdout))))
                except Exception as error:
                    self.events.put(('error', str(error)))
            threading.Thread(target=inspect, daemon=True).start()

        def running(self):
            return self.worker is not None and self.worker.poll() is None

        def set_busy(self, value):
            state = 'disabled' if value else 'normal'
            for widget in (self.target_entry, self.browse_button, self.scan_button, self.clean_check, self.move_check):
                widget.configure(state=state)
            self.start_button.configure(state='disabled' if value or not self.plans else 'normal')
            self.cleanup_button.configure(state='disabled' if value or not self.plans else 'normal')

        def start(self, cleanup=False):
            if self.running():
                return
            destination = os.path.abspath(self.destination.get().strip())
            if not self.plans or destination != self.scanned_destination:
                self.scan()
                return
            detail = '再次校验并清理记录中的旧备份。' if cleanup else ('校验后清理旧备份。' if self.clean.get() else '保留原始备份，迁移后可单独清理。')
            if not messagebox.askokcancel('确认迁移计划', f'目标：{destination}\n\n{detail}\n\n请保持本工具打开，并完全退出 Codex（包括托盘）。'):
                return
            try:
                self.work_root = Path(destination) / '.migration'
                self.work_root.mkdir(parents=True, exist_ok=True)
                self.worker_log = open(self.work_root / 'worker-console.log', 'ab')
                self.worker = subprocess.Popen(engine_args(destination, cleanup=cleanup, clean=self.clean.get(), move=self.move.get()), stdout=self.worker_log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
                self.last_stage = ''
                self.set_busy(True)
                self.progress.start(14)
                self.status.set('启动迁移任务…')
                self.log('任务已启动。可以退出 Codex，请保持本工具打开。')
            except Exception as error:
                self.finish_error(str(error))

        def cancel(self):
            if self.running() and self.last_stage == 'waiting_for_codex_exit':
                (self.work_root / 'cancel.request').write_text('cancel', encoding='utf-8')
                self.status.set('正在取消等待…')
                self.cancel_button.configure(state='disabled')

        def open_records(self):
            path = Path(os.path.abspath(self.destination.get().strip())) / '.migration'
            if path.is_dir():
                os.startfile(path)
            else:
                messagebox.showinfo('记录目录', '开始迁移后，会在目标文件夹创建 .migration 记录目录。')

        def finish_error(self, error):
            self.scan_active = False
            self.progress.stop()
            self.set_busy(False)
            self.status.set('操作未完成，请查看原因')
            self.log(error)

        def poll(self):
            try:
                while True:
                    event, payload = self.events.get_nowait()
                    if event == 'error':
                        self.finish_error(payload)
                    elif event == 'scan':
                        self.scan_active = False
                        self.scanned_destination, snapshot = payload
                        self.plans = snapshot['plans']
                        self.table.delete(*self.table.get_children())
                        for entry in self.plans:
                            source, target = entry['Source'], entry['Destination']
                            state = '已在目标位置' if os.path.exists(source) and os.path.normcase(os.path.realpath(source)) == os.path.normcase(os.path.realpath(target)) else ('待迁移' if os.path.exists(source) else '不存在，跳过')
                            self.table.insert('', 'end', values=(LABELS.get(entry['Name'],entry['Name']), state, source, target))
                        self.progress.stop()
                        self.set_busy(False)
                        self.status.set('扫描完成，请确认上方目录')
                        self.log(f'识别到 {len(self.plans)} 个目录；Codex 相关活动进程 {len(snapshot["busyProcesses"])} 个。')
            except queue.Empty:
                pass
            if self.worker is not None:
                snapshot = None
                try:
                    snapshot = json.loads((self.work_root / 'status.json').read_text(encoding='utf-8-sig'))
                except (OSError, ValueError):
                    pass
                if snapshot and snapshot.get('pid') == self.worker.pid:
                    stage = snapshot['stage']
                    details = snapshot.get('details', {})
                    label = STAGES.get(stage, stage)
                    if isinstance(details, dict):
                        label += '  ' + LABELS.get(details.get('name', ''), str(details.get('name', '')))
                        if 'files' in details:
                            label += f' · 已校验 {details["files"]} 个文件'
                    self.status.set(label)
                    self.cancel_button.configure(state='normal' if stage == 'waiting_for_codex_exit' else 'disabled')
                    if stage != self.last_stage:
                        self.log(label)
                    self.last_stage = stage
                if self.worker.poll() is not None:
                    code = self.worker.returncode
                    if self.worker_log:
                        self.worker_log.close()
                    self.worker = None
                    self.progress.stop()
                    self.cancel_button.configure(state='disabled')
                    self.set_busy(False)
                    if snapshot and snapshot.get('stage') in FINAL:
                        details = snapshot.get('details', {})
                        if isinstance(details, dict):
                            if details.get('message') and snapshot['stage'] == 'failed':
                                self.log(details['message'])
                            for package in details.get('application', {}).get('packages', []):
                                self.log(f'{package["name"]}: {package["state"]}')
                            for item in details.get('retainedBackups', []):
                                self.log('已保留备份：' + item['backup'])
                    else:
                        self.log(f'任务已退出（代码 {code}），请查看记录目录中的 worker-console.log。')
                    if self.close_after_cancel:
                        self.window.destroy()
                        return
            self.window.after(600, self.poll)

        def on_close(self):
            if self.running():
                if self.last_stage == 'waiting_for_codex_exit':
                    if messagebox.askyesno('取消等待', '取消本次等待并关闭工具？'):
                        self.close_after_cancel = True
                        self.cancel()
                else:
                    messagebox.showinfo('任务进行中', '文件处理期间请保持此窗口打开，完成后再关闭。')
                return
            self.window.destroy()

    app = Application()
    if '--ui-smoke-test' in sys.argv:
        app.window.withdraw()
        app.window.update_idletasks()
        app.window.destroy()
        return 0
    app.window.mainloop()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
