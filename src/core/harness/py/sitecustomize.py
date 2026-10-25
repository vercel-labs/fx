# proto-fx harness hook. proto-fx puts this folder first on PYTHONPATH only
# for the agent's own shell commands. It must stay cheap: it imports nothing
# beyond what the interpreter already loaded, and does nothing more unless
# PROTO_FX_HARNESS_TOKEN is set. -I, -E and -S skip it, as Python skips any
# sitecustomize then. Keep this file valid on old interpreters: no f-strings,
# no annotations.
import os
import sys


def _proto_fx_chain():
    # Run the sitecustomize this folder hides, such as a project's or the
    # interpreter's own, exactly once.
    here = os.path.dirname(os.path.abspath(__file__))
    finder = sys.modules.get("_frozen_importlib_external")
    if finder is None:
        return
    rest = [p for p in sys.path if os.path.abspath(p or os.curdir) != here]
    try:
        spec = finder.PathFinder.find_spec("sitecustomize", rest)
    except Exception:
        return
    if spec is None or spec.loader is None:
        return
    module = type(sys)("sitecustomize")
    module.__spec__ = spec
    module.__file__ = getattr(spec, "origin", None)
    module.__loader__ = spec.loader
    spec.loader.exec_module(module)


def _proto_fx_json(value):
    # A JSON string without importing json.
    out = ['"']
    for ch in value:
        code = ord(ch)
        if ch == '"' or ch == "\\":
            out.append("\\" + ch)
        elif code < 0x20 or 0xD800 <= code <= 0xDFFF:
            out.append("\\u%04x" % code)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _proto_fx_report(path, token):
    # Tells the host this command ran Python. One line, no reply awaited.
    import _socket

    argv = ",".join(_proto_fx_json(str(a)) for a in getattr(sys, "orig_argv", sys.argv))
    try:
        cwd = os.getcwd()
    except OSError:
        cwd = ""
    line = (
        '{"v":1,"token":%s,"id":0,"op":"process","args":{"pid":%d,"ppid":%d,'
        '"executable":%s,"argv":[%s],"cwd":%s,"version":%s}}\n'
        % (
            _proto_fx_json(token),
            os.getpid(),
            os.getppid(),
            _proto_fx_json(sys.executable or ""),
            argv,
            _proto_fx_json(cwd),
            _proto_fx_json("%d.%d.%d" % sys.version_info[:3]),
        )
    )
    sock = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
    try:
        sock.settimeout(0.25)
        sock.connect(path)
        sock.sendall(line.encode("utf-8", "surrogatepass"))
    finally:
        sock.close()


def _proto_fx_main():
    token = os.environ.get("PROTO_FX_HARNESS_TOKEN")
    path = os.environ.get("PROTO_FX_HARNESS_SOCKET")
    if not token or not path:
        return
    try:
        depth = int(os.environ.get("PROTO_FX_HARNESS_DEPTH", "0"))
    except ValueError:
        depth = 1
    # Children of this Python inherit a deeper count and stay quiet.
    os.environ["PROTO_FX_HARNESS_DEPTH"] = str(depth + 1)
    if depth > 0:
        return
    if sys.version_info < (3, 10):
        sys.stderr.write(
            "proto-fx: the proto_fx harness needs Python 3.10 or newer; %s is %d.%d, so this run has no harness.\n"
            % (sys.executable or "python", sys.version_info[0], sys.version_info[1])
        )
        return
    try:
        _proto_fx_report(path, token)
    except Exception:
        pass


try:
    _proto_fx_chain()
finally:
    try:
        _proto_fx_main()
    except Exception:
        pass
    del _proto_fx_chain, _proto_fx_json, _proto_fx_report, _proto_fx_main
