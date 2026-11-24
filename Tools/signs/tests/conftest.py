import sys
from pathlib import Path

# Lets the tests import the `signs` package and the shared synthetic-data helpers wherever pytest is run from.
SIGNS_TOOL_FOLDER = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIGNS_TOOL_FOLDER))
sys.path.insert(0, str(Path(__file__).resolve().parent))


def pytest_configure(config):
    # Known and harmless here: newer torch marks jit.trace as deprecated (Core ML conversion still takes a trace),
    # and Linux warns about forking loader workers from a process with threads (macOS spawns them instead).
    config.addinivalue_line("filterwarnings", "ignore:`torch.jit.trace` is deprecated:FutureWarning")
    config.addinivalue_line("filterwarnings", "ignore:`torch.jit.trace_method` is deprecated:FutureWarning")
    config.addinivalue_line("filterwarnings", "ignore:This process .* is multi-threaded:DeprecationWarning")
