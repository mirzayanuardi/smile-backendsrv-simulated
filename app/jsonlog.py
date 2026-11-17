"""Log satu baris JSON (dipakai access log dan dispatcher)."""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone

log = logging.getLogger("smile")


def log_json(**fields) -> None:
    fields = {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"), **fields}
    log.info(json.dumps(fields, default=str))
