#!/usr/bin/env python3
"""
oh-my-opencode-sync

Cross-platform backup/restore for opencode + oh-my-opencode plugin state.

Design goals:
- Read-only path detection (NO opencode doctor; no mutation)
- XDG first (macOS/Linux), macOS Library fallback, Windows AppData fallback
- Env override supported
- Prevent "meta-only" archives (refuse if nothing exists)
- Safe tar extraction (path traversal protection)
- GUI optional (customtkinter if available, else tkinter; CLI always available)
- Safe restore mode: backs up existing targets before overwrite
- Progress + elapsed time for backup/restore (file-based)
"""
from __future__ import annotations

import io
import json
import os
import platform
import shutil
import subprocess
import tarfile
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


APP_NAME = "oh-my-opencode-sync"
ARCHIVE_PREFIX = "omoc-snapshot"


# ----------------------------
# Utilities
# ----------------------------
def now_ts() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def run_cmd(cmd: List[str]) -> Tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, check=False)
        out = (p.stdout or "") + ("\n" + p.stderr if p.stderr else "")
        return p.returncode, out.strip()
    except Exception:
        return 1, ""


def get_opencode_version() -> Optional[str]:
    rc, out = run_cmd(["opencode", "--version"])
    if rc == 0 and out:
        return out.splitlines()[0].strip()
    return None


def fmt_elapsed(seconds: float) -> str:
    s = int(seconds)
    m, r = divmod(s, 60)
    return f"{m}m{r:02d}s"


def safe_extract_member(tar: tarfile.TarFile, member: tarfile.TarInfo, dest: Path) -> None:
    """Extract a single member safely (prevents path traversal)."""
    dest_resolved = dest.resolve()
    target = (dest / member.name).resolve()
    if not str(target).startswith(str(dest_resolved)):
        raise RuntimeError(f"Unsafe path in tar: {member.name}")

    if member.isdir():
        target.mkdir(parents=True, exist_ok=True)
        return

    # ensure parent
    target.parent.mkdir(parents=True, exist_ok=True)

    src = tar.extractfile(member)
    if src is None:
        return

    with src, open(target, "wb") as f:
        shutil.copyfileobj(src, f)

    # basic perms/timestamps best-effort
    try:
        os.chmod(target, member.mode)
    except Exception:
        pass
    try:
        os.utime(target, (member.mtime, member.mtime))
    except Exception:
        pass


@dataclass(frozen=True)
class Paths:
    config: Path
    data: Path
    cache: Path

    def as_dict(self) -> Dict[str, str]:
        return {"config": str(self.config), "data": str(self.data), "cache": str(self.cache)}

    def exists_dict(self) -> Dict[str, bool]:
        return {"config": self.config.exists(), "data": self.data.exists(), "cache": self.cache.exists()}


# ----------------------------
# Path detection (NO opencode doctor)
# ----------------------------
def _xdg_base_dirs(home: Path) -> Tuple[Path, Path, Path]:
    xdg_cfg = Path(os.environ.get("XDG_CONFIG_HOME", str(home / ".config")))
    xdg_data = Path(os.environ.get("XDG_DATA_HOME", str(home / ".local" / "share")))
    xdg_cache = Path(os.environ.get("XDG_CACHE_HOME", str(home / ".cache")))
    return xdg_cfg, xdg_data, xdg_cache


def resolve_paths() -> Paths:
    """
    Priority:
      1) Env override: OPENCODE_CONFIG_DIR / OPENCODE_DATA_DIR / OPENCODE_CACHE_DIR
      2) XDG: ~/.config/opencode, ~/.local/share/opencode, ~/.cache/opencode (or XDG_*_HOME)
      3) macOS Library fallback
      4) Windows AppData fallback
    """
    home = Path.home()
    system = platform.system()

    cfg_env = os.environ.get("OPENCODE_CONFIG_DIR")
    data_env = os.environ.get("OPENCODE_DATA_DIR")
    cache_env = os.environ.get("OPENCODE_CACHE_DIR")

    xdg_cfg_base, xdg_data_base, xdg_cache_base = _xdg_base_dirs(home)

    config = Path(cfg_env).expanduser() if cfg_env else (xdg_cfg_base / "opencode")
    data = Path(data_env).expanduser() if data_env else (xdg_data_base / "opencode")
    cache = Path(cache_env).expanduser() if cache_env else (xdg_cache_base / "opencode")

    if system == "Darwin":
        mac_base = home / "Library" / "Application Support"
        mac_cbase = home / "Library" / "Caches"
        if not config.exists():
            for name in ("opencode", "OpenCode", "oh-my-opencode"):
                p = mac_base / name
                if p.exists():
                    config = p
                    break
        if not data.exists():
            for name in ("opencode", "OpenCode", "oh-my-opencode"):
                p = mac_base / name
                if p.exists():
                    data = p
                    break
        if not cache.exists():
            for name in ("opencode", "OpenCode", "oh-my-opencode"):
                p = mac_cbase / name
                if p.exists():
                    cache = p
                    break

    if system == "Windows":
        appdata = Path(os.environ.get("APPDATA", str(home)))
        localapp = Path(os.environ.get("LOCALAPPDATA", str(home)))
        if not config.exists():
            for name in ("opencode", "OpenCode", "oh-my-opencode"):
                p = appdata / name
                if p.exists():
                    config = p
                    break
        if not data.exists():
            for name in ("opencode", "OpenCode", "oh-my-opencode"):
                p = appdata / name
                if p.exists():
                    data = p
                    break
        if not cache.exists():
            candidates = [
                localapp / "opencode" / "Cache",
                localapp / "OpenCode" / "Cache",
                localapp / "oh-my-opencode" / "Cache",
                localapp / "opencode",
                localapp / "OpenCode",
                localapp / "oh-my-opencode",
            ]
            for p in candidates:
                if p.exists():
                    cache = p
                    break

    return Paths(config=config, data=data, cache=cache)


def resolve_workspace_dir() -> Optional[Path]:
    p = Path.cwd() / ".opencode"
    return p if p.is_dir() else None


# ----------------------------
# Progress helpers (file-based)
# ----------------------------
def iter_files(root: Path) -> Iterable[Path]:
    for p in root.rglob("*"):
        if p.is_file():
            yield p


def compute_total_files_bytes(mappings: List[Tuple[Path, str]]) -> Tuple[int, int]:
    total_files = 0
    total_bytes = 0
    for src, _ in mappings:
        if src.is_file():
            total_files += 1
            total_bytes += src.stat().st_size
        elif src.is_dir():
            for f in iter_files(src):
                try:
                    st = f.stat()
                except FileNotFoundError:
                    continue
                total_files += 1
                total_bytes += st.st_size
    return total_files, total_bytes


def print_progress(prefix: str, done_files: int, total_files: int, done_bytes: int, total_bytes: int) -> None:
    pct = (done_bytes / total_bytes * 100.0) if total_bytes > 0 else 0.0
    line = f"\r{prefix} {done_files}/{total_files} files, {pct:6.2f}%"
    print(line, end="", flush=True)


# ----------------------------
# Backup / restore core
# ----------------------------
def build_meta(paths: Paths, include_workspace: bool) -> Dict:
    ws = resolve_workspace_dir() if include_workspace else None
    home = Path.home()
    xdg_cfg, xdg_data, xdg_cache = _xdg_base_dirs(home)
    return {
        "tool": APP_NAME,
        "created_at": datetime.now().isoformat(),
        "os": platform.system(),
        "os_release": platform.release(),
        "machine": platform.machine(),
        "hostname": platform.node(),
        "python": platform.python_version(),
        "opencode_version": get_opencode_version(),
        "xdg": {
            "config_home": str(xdg_cfg),
            "data_home": str(xdg_data),
            "cache_home": str(xdg_cache),
        },
        "detected_paths": paths.as_dict(),
        "exists": paths.exists_dict(),
        "workspace_opencode_dir": str(ws) if ws else None,
        "cwd": str(Path.cwd()),
    }


def make_archive(selected: List[str], include_workspace: bool) -> Path:
    start = time.time()

    paths = resolve_paths()
    ws_dir = resolve_workspace_dir() if include_workspace else None

    ts = now_ts()
    archive = Path.cwd() / f"{ARCHIVE_PREFIX}-{ts}.tar.gz"

    mappings: List[Tuple[Path, str]] = []
    for key in selected:
        p = getattr(paths, key, None)
        if isinstance(p, Path) and p.exists():
            mappings.append((p, key))

    if ws_dir and ws_dir.exists():
        mappings.append((ws_dir, "workspace/.opencode"))

    if not mappings:
        raise RuntimeError(
            "No backup targets found (refusing to create a meta-only archive).\n"
            f"Selected: {selected}, include_workspace={include_workspace}\n"
            f"Detected paths: {json.dumps(paths.as_dict(), ensure_ascii=False, indent=2)}\n"
            "Fix: ensure opencode has created its storage directories, set OPENCODE_*_DIR env vars, "
            "or run inside a project that contains .opencode."
        )

    meta = build_meta(paths, include_workspace=include_workspace)
    meta_bytes = json.dumps(meta, ensure_ascii=False, indent=2).encode("utf-8")

    total_files, total_bytes = compute_total_files_bytes(mappings)
    done_files = 0
    done_bytes = 0

    print(f"Creating archive: {archive}")
    with tarfile.open(archive, "w:gz") as tar:
        # add files with progress
        for src, arc_root in mappings:
            if src.is_file():
                tar.add(src, arcname=arc_root)
                done_files += 1
                done_bytes += src.stat().st_size
                print_progress("Backup:", done_files, total_files, done_bytes, total_bytes)
            else:
                for f in iter_files(src):
                    try:
                        st = f.stat()
                    except FileNotFoundError:
                        continue
                    rel = f.relative_to(src)
                    arcname = str(Path(arc_root) / rel)
                    tar.add(f, arcname=arcname)
                    done_files += 1
                    done_bytes += st.st_size
                    if done_files % 50 == 0 or done_files == total_files:
                        print_progress("Backup:", done_files, total_files, done_bytes, total_bytes)

        # meta.json
        info = tarfile.TarInfo(name="meta.json")
        info.size = len(meta_bytes)
        info.mtime = int(datetime.now().timestamp())
        tar.addfile(info, fileobj=io.BytesIO(meta_bytes))

    print()  # newline
    print(f"✅ Backup created (elapsed: {fmt_elapsed(time.time() - start)}): {archive}")
    return archive


def safe_backup_target(dst: Path, safe_dir: Path, label: str) -> None:
    """Move existing dst to safe_dir (fast rollback point)."""
    if dst.exists():
        safe_dir.mkdir(parents=True, exist_ok=True)
        backup_path = safe_dir / f"{label}-{dst.name}"
        # Ensure unique
        if backup_path.exists():
            backup_path = safe_dir / f"{label}-{dst.name}-{now_ts()}"
        shutil.move(str(dst), str(backup_path))


def restore_archive(
    archive_path: Path,
    selected: List[str],
    include_workspace: bool,
    overwrite: bool = True,
    safe_mode: bool = True,
) -> None:
    start = time.time()
    paths = resolve_paths()

    extract_dir = Path.cwd() / f".{APP_NAME}-extract-{now_ts()}"
    extract_dir.mkdir(parents=True, exist_ok=True)

    safe_dir = Path.cwd() / f".omoc-safe-restore-{now_ts()}" if safe_mode else None

    print(f"Restoring from: {archive_path}")
    with tarfile.open(archive_path, "r:gz") as tar:
        members = tar.getmembers()
        total = len([m for m in members if m.isfile()]) or 1
        done = 0

        for m in members:
            safe_extract_member(tar, m, extract_dir)
            if m.isfile():
                done += 1
                if done % 50 == 0 or done == total:
                    print(f"\rExtract: {done}/{total} files", end="", flush=True)

    print()

    # restore selected components from extracted dir
    for key in selected:
        src = extract_dir / key
        dst = getattr(paths, key, None)
        if not isinstance(dst, Path):
            continue
        if not src.exists():
            continue

        dst.parent.mkdir(parents=True, exist_ok=True)

        if overwrite:
            if safe_mode and safe_dir is not None:
                safe_backup_target(dst, safe_dir, key)
            else:
                if dst.exists():
                    shutil.rmtree(dst)

        shutil.move(str(src), str(dst))
        print(f"Restore: {key} -> {dst}")

    if include_workspace:
        src_ws = extract_dir / "workspace" / ".opencode"
        if src_ws.exists():
            dst_ws = Path.cwd() / ".opencode"
            if overwrite:
                if safe_mode and safe_dir is not None:
                    safe_backup_target(dst_ws, safe_dir, "workspace")
                else:
                    if dst_ws.exists():
                        shutil.rmtree(dst_ws)
            shutil.move(str(src_ws), str(dst_ws))
            print("Restore: workspace .opencode -> ./.opencode")

    shutil.rmtree(extract_dir, ignore_errors=True)

    print(f"✅ Restore completed (elapsed: {fmt_elapsed(time.time() - start)})")
    if safe_mode and safe_dir is not None:
        print(f"🛡️  Safe restore backup saved at: {safe_dir}")


# ----------------------------
# CLI
# ----------------------------
def cli_menu() -> None:
    print(f"\n=== {APP_NAME} (CLI) ===\n")
    paths = resolve_paths()
    ws = resolve_workspace_dir()

    print("Detected:")
    for k, p in paths.as_dict().items():
        exists = Path(p).exists()
        print(f" - {k:6}: {p} {'(exists)' if exists else '(missing)'}")
    print(f" - workspace .opencode: {ws} {'(exists)' if ws else '(missing)'}\n")

    def ask_components() -> Tuple[List[str], bool]:
        print("Select components (multi):")
        print("  1) config")
        print("  2) data")
        print("  3) cache")
        print("  4) workspace .opencode")
        raw = input("Enter numbers (e.g. 1 2 4): ").strip()
        nums = raw.split()

        comps: List[str] = []
        include_ws = False
        for n in nums:
            if n == "1":
                comps.append("config")
            elif n == "2":
                comps.append("data")
            elif n == "3":
                comps.append("cache")
            elif n == "4":
                include_ws = True

        if not comps:
            comps = ["config", "data"]
        return sorted(set(comps)), include_ws

    def ask_safe_mode() -> bool:
        raw = input("Safe restore mode? (backs up existing targets) [Y/n]: ").strip()
        return False if raw.lower() == "n" else True

    while True:
        print("\n1) Full Backup")
        print("2) Full Restore [SAFE MODE]")
        print("3) Selective Backup")
        print("4) Selective Restore [SAFE MODE]")
        print("0) Exit")
        ch = input("Choose: ").strip()

        try:
            if ch == "1":
                archive = make_archive(["config", "data", "cache"], include_workspace=True)
                print(f"Archive: {archive}")
            elif ch == "2":
                f = Path(input("Backup tar.gz path: ").strip()).expanduser()
                restore_archive(f, ["config", "data", "cache"], include_workspace=True, safe_mode=ask_safe_mode())
            elif ch == "3":
                comps, wsinc = ask_components()
                archive = make_archive(comps, include_workspace=wsinc)
                print(f"Archive: {archive}")
            elif ch == "4":
                f = Path(input("Backup tar.gz path: ").strip()).expanduser()
                comps, wsinc = ask_components()
                restore_archive(f, comps, include_workspace=wsinc, safe_mode=ask_safe_mode())
            elif ch == "0":
                return
        except Exception as e:
            print(f"\n❌ Error:\n{e}\n")


# ----------------------------
# GUI (optional)
# ----------------------------
def _has_tkinter() -> bool:
    try:
        import tkinter  # noqa: F401
        return True
    except Exception:
        return False


def run_gui_customtk() -> None:
    import customtkinter as ctk  # type: ignore
    from tkinter import filedialog, messagebox

    ctk.set_appearance_mode("dark")

    class App(ctk.CTk):
        def __init__(self) -> None:
            super().__init__()
            self.title(APP_NAME)
            self.geometry("600x580")

            self.paths = resolve_paths()
            self.ws_dir = resolve_workspace_dir()

            self.vars = {
                "config": ctk.BooleanVar(value=True),
                "data": ctk.BooleanVar(value=True),
                "cache": ctk.BooleanVar(value=False),
                "workspace": ctk.BooleanVar(value=True if self.ws_dir else False),
                "safe": ctk.BooleanVar(value=True),
            }

            header = ctk.CTkLabel(self, text=APP_NAME, font=ctk.CTkFont(size=18, weight="bold"))
            header.pack(pady=10)

            info = ctk.CTkTextbox(self, height=180)
            info.pack(fill="x", padx=16)
            info.insert("end", "Detected paths:\n")
            for k, p in self.paths.as_dict().items():
                info.insert("end", f" - {k:6}: {p} {'(exists)' if Path(p).exists() else '(missing)'}\n")
            info.insert("end", f" - workspace .opencode: {self.ws_dir} {'(exists)' if self.ws_dir else '(missing)'}\n")
            info.configure(state="disabled")

            frame = ctk.CTkFrame(self)
            frame.pack(fill="x", padx=16, pady=12)

            ctk.CTkLabel(frame, text="Backup / Restore Components", font=ctk.CTkFont(size=14, weight="bold")).pack(pady=8)

            for k in ["config", "data", "cache"]:
                ctk.CTkCheckBox(frame, text=k, variable=self.vars[k]).pack(anchor="w", padx=12, pady=4)
            ctk.CTkCheckBox(frame, text="workspace .opencode (current folder)", variable=self.vars["workspace"]).pack(
                anchor="w", padx=12, pady=4
            )
            ctk.CTkCheckBox(frame, text="Safe restore mode (backup existing targets)", variable=self.vars["safe"]).pack(
                anchor="w", padx=12, pady=4
            )

            btns = ctk.CTkFrame(self)
            btns.pack(fill="x", padx=16, pady=12)

            ctk.CTkButton(btns, text="Backup (.tar.gz)", command=self.do_backup).pack(
                side="left", expand=True, fill="x", padx=6
            )
            ctk.CTkButton(btns, text="Restore (.tar.gz)", command=self.do_restore).pack(
                side="left", expand=True, fill="x", padx=6
            )

            self.status = ctk.CTkLabel(self, text="Ready", justify="left")
            self.status.pack(fill="x", padx=16, pady=8)

        def selected(self) -> Tuple[List[str], bool]:
            comps = [k for k in ["config", "data", "cache"] if self.vars[k].get()]
            include_ws = bool(self.vars["workspace"].get())
            if not comps:
                comps = ["config", "data"]
            return comps, include_ws

        def do_backup(self) -> None:
            comps, inc_ws = self.selected()
            try:
                self.status.configure(text="Backing up...")
                archive = make_archive(comps, include_workspace=inc_ws)
                messagebox.showinfo("Backup", f"Archive created:\n{archive}")
                self.status.configure(text="Ready")
            except Exception as e:
                self.status.configure(text="Error")
                messagebox.showerror("Backup failed", str(e))

        def do_restore(self) -> None:
            f = filedialog.askopenfilename(filetypes=[("tar.gz", "*.tar.gz")])
            if not f:
                return
            comps, inc_ws = self.selected()
            try:
                self.status.configure(text="Restoring...")
                restore_archive(
                    Path(f),
                    comps,
                    include_workspace=inc_ws,
                    safe_mode=bool(self.vars["safe"].get()),
                )
                messagebox.showinfo("Restore", "Restore completed.")
                self.status.configure(text="Ready")
            except Exception as e:
                self.status.configure(text="Error")
                messagebox.showerror("Restore failed", str(e))

    App().mainloop()


def run_gui_tkinter() -> None:
    import tkinter as tk
    from tkinter import filedialog, messagebox

    root = tk.Tk()
    root.title(APP_NAME)
    root.geometry("580x540")

    paths = resolve_paths()
    ws = resolve_workspace_dir()

    txt = tk.Text(root, height=12)
    txt.pack(fill="x", padx=10, pady=10)
    txt.insert("end", "Detected paths:\n")
    for k, p in paths.as_dict().items():
        txt.insert("end", f" - {k:6}: {p} {'(exists)' if Path(p).exists() else '(missing)'}\n")
    txt.insert("end", f" - workspace .opencode: {ws} {'(exists)' if ws else '(missing)'}\n")
    txt.configure(state="disabled")

    vars_ = {
        "config": tk.BooleanVar(value=True),
        "data": tk.BooleanVar(value=True),
        "cache": tk.BooleanVar(value=False),
        "workspace": tk.BooleanVar(value=True if ws else False),
        "safe": tk.BooleanVar(value=True),
    }

    frm = tk.Frame(root)
    frm.pack(fill="x", padx=10, pady=10)

    tk.Label(frm, text="Backup / Restore Components", font=("Arial", 12, "bold")).pack(anchor="w")

    for k in ["config", "data", "cache"]:
        tk.Checkbutton(frm, text=k, variable=vars_[k]).pack(anchor="w")
    tk.Checkbutton(frm, text="workspace .opencode (current folder)", variable=vars_["workspace"]).pack(anchor="w")
    tk.Checkbutton(frm, text="Safe restore mode (backup existing targets)", variable=vars_["safe"]).pack(anchor="w")

    def selected() -> Tuple[List[str], bool]:
        comps = [k for k in ["config", "data", "cache"] if vars_[k].get()]
        inc_ws = bool(vars_["workspace"].get())
        if not comps:
            comps = ["config", "data"]
        return comps, inc_ws

    def do_backup_btn() -> None:
        comps, inc_ws = selected()
        try:
            archive = make_archive(comps, include_workspace=inc_ws)
            messagebox.showinfo("Backup", f"Archive created:\n{archive}")
        except Exception as e:
            messagebox.showerror("Backup failed", str(e))

    def do_restore_btn() -> None:
        f = filedialog.askopenfilename(filetypes=[("tar.gz", "*.tar.gz")])
        if not f:
            return
        comps, inc_ws = selected()
        try:
            restore_archive(Path(f), comps, include_workspace=inc_ws, safe_mode=bool(vars_["safe"].get()))
            messagebox.showinfo("Restore", "Restore completed.")
        except Exception as e:
            messagebox.showerror("Restore failed", str(e))

    btns = tk.Frame(root)
    btns.pack(fill="x", padx=10, pady=10)
    tk.Button(btns, text="Backup (.tar.gz)", command=do_backup_btn).pack(side="left", expand=True, fill="x", padx=5)
    tk.Button(btns, text="Restore (.tar.gz)", command=do_restore_btn).pack(side="left", expand=True, fill="x", padx=5)

    root.mainloop()


def main() -> None:
    if not _has_tkinter():
        print("[WARN] tkinter unavailable. Falling back to CLI mode.\n")
        cli_menu()
        return

    try:
        import customtkinter  # noqa: F401
        run_gui_customtk()
    except Exception:
        try:
            run_gui_tkinter()
        except Exception as e:
            print(f"[WARN] GUI unavailable ({e}). Falling back to CLI mode.\n")
            cli_menu()


if __name__ == "__main__":
    main()
