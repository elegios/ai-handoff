import ctypes, os, struct, sys, time

libc = ctypes.CDLL("libc.so.6", use_errno=True)

IN_CREATE = 0x00000100
IN_MOVED_TO = 0x00000080
IN_CLOSE_WRITE = 0x00000008
MASK = IN_CREATE | IN_MOVED_TO | IN_CLOSE_WRITE

directory = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
handoff_path = os.path.join(directory, "handoff")
ack_path = os.path.join(directory, "handoff.ack")

EVENT_HDR = 16


def stat_key(path):
    try:
        st = os.stat(path)
        return f"{st.st_mtime_ns}:{st.st_ino}"
    except FileNotFoundError:
        return ""


def atomic_write(path, content):
    import tempfile

    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".handoff.tmp.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def process_command():
    with open(handoff_path, "r") as f:
        content = f.read()

    atomic_write(ack_path, "ACK")

    if not content.startswith("CMD: "):
        print(f"MALFORMED_COMMAND raw={content!r}", flush=True)
        return

    path = content[len("CMD: "):]
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] COMMAND path={path!r}", flush=True)


def main():
    fd = libc.inotify_init()
    if fd < 0:
        raise OSError(ctypes.get_errno(), "inotify_init failed")

    wd = libc.inotify_add_watch(fd, directory.encode(), MASK)
    if wd < 0:
        raise OSError(ctypes.get_errno(), "inotify_add_watch failed")

    prev_key = stat_key(handoff_path)
    print(f"handoff monitor watching {directory} (wd={wd})", flush=True)

    while True:
        data = os.read(fd, 4096)
        offset = 0
        while offset < len(data):
            wd_, mask, cookie, length = struct.unpack_from("iIII", data, offset)
            raw_name = data[offset + EVENT_HDR: offset + EVENT_HDR + length]
            name = raw_name.split(b"\0", 1)[0].decode(errors="replace")
            offset += EVENT_HDR + length

            if name != "handoff":
                continue

            key = stat_key(handoff_path)
            if key == "" or key == prev_key:
                continue
            prev_key = key
            process_command()


if __name__ == "__main__":
    main()
