import sys
from pathlib import Path

# The scripts are standalone programs, not a package; make them importable.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
