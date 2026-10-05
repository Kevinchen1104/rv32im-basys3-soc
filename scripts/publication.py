"""Replace a validated generated snapshot, retaining the old one on failure."""
from pathlib import Path
import shutil


def publish_directory(stage, destination, root, validate):
    root = Path(root).resolve()
    stage, destination = Path(stage).absolute(), Path(destination).absolute()
    backup = stage.with_name(stage.name + "-previous")
    for path in (stage, destination, backup):
        if not path.resolve().is_relative_to(root) or path.resolve() == root:
            raise ValueError(f"publication path escapes the repository: {path}")
        for parent in (path, *path.parents):
            if parent == root:
                break
            if parent.is_symlink() or (hasattr(parent, "is_junction") and parent.is_junction()):
                raise ValueError(f"publication refuses linked paths: {parent}")
    if (stage == destination or stage.is_relative_to(destination)
            or destination.is_relative_to(stage) or backup.exists()):
        raise ValueError("publication requires separate staging and an unused backup path")
    validate(stage)
    previous = destination.exists()
    if previous:
        validate(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if previous:
        destination.rename(backup)
    try:
        stage.rename(destination)
    except OSError:
        if previous:
            backup.rename(destination)
        raise
    if previous:
        # The exact backup was resolved under root above and contains the
        # validated prior snapshot. It is no longer needed after replacement.
        shutil.rmtree(backup)
