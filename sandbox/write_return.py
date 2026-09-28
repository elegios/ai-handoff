import json, os, sys, tempfile


def main():
    data = sys.stdin.read()
    json.loads(data)  # fail fast on malformed JSON before touching the protocol file

    directory = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    target = os.path.join(directory, "handoff.return")

    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".handoff.tmp.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


if __name__ == "__main__":
    main()
