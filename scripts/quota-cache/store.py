"""Private, restart-durable state for the quota-cache service.

Backed by a single SQLite file so `success` and backoff state (never the raw
auth-files listing, never a token) survive a service restart — a fresh restart
with no memory of the last failure would otherwise immediately re-hammer an
upstream that was already backing off. Every access goes through one process
lock: this service is intentionally single-process, so a simple mutex is
sufficient and keeps the on-disk format easy to reason about.
"""

from __future__ import annotations

import os
import sqlite3
import threading
from dataclasses import dataclass
from typing import Optional


@dataclass
class CacheRow:
    pool: str
    resource: str
    auth_index: str
    identity: str
    status_code: Optional[int]
    header_json: Optional[str]
    body: Optional[str]
    fetched_at: Optional[float]
    last_attempt: Optional[float]
    next_retry_at: Optional[float]
    consecutive_failures: int
    generation: int

    @property
    def has_success(self) -> bool:
        return self.status_code is not None and self.fetched_at is not None


_SCHEMA = """
CREATE TABLE IF NOT EXISTS cache_rows (
    pool TEXT NOT NULL,
    resource TEXT NOT NULL,
    auth_index TEXT NOT NULL,
    identity TEXT NOT NULL,
    status_code INTEGER,
    header_json TEXT,
    body TEXT,
    fetched_at REAL,
    last_attempt REAL,
    next_retry_at REAL,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    generation INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (pool, resource, auth_index)
);
"""


class CacheStore:
    def __init__(self, path: str) -> None:
        directory = os.path.dirname(os.path.abspath(path))
        if directory:
            os.makedirs(directory, exist_ok=True, mode=0o700)
            os.chmod(directory, 0o700)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.execute(_SCHEMA)
        self._conn.commit()
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

    def get(self, pool: str, resource: str, auth_index: str) -> Optional[CacheRow]:
        with self._lock:
            cur = self._conn.execute(
                "SELECT pool, resource, auth_index, identity, status_code, header_json, body, "
                "fetched_at, last_attempt, next_retry_at, consecutive_failures, generation "
                "FROM cache_rows WHERE pool = ? AND resource = ? AND auth_index = ?",
                (pool, resource, auth_index),
            )
            row = cur.fetchone()
        if row is None:
            return None
        return CacheRow(*row)

    def delete(self, pool: str, resource: str, auth_index: str) -> None:
        with self._lock:
            self._conn.execute(
                "DELETE FROM cache_rows WHERE pool = ? AND resource = ? AND auth_index = ?",
                (pool, resource, auth_index),
            )
            self._conn.commit()

    def record_success(
        self,
        pool: str,
        resource: str,
        auth_index: str,
        identity: str,
        status_code: int,
        header_json: str,
        body: str,
        fetched_at: float,
        expected_generation: Optional[int],
    ) -> bool:
        """Writes a successful attempt, unless another writer already advanced
        `generation` past what this caller observed before it started its own
        upstream call — in that case the write is discarded rather than
        clobbering newer state (see `service.py`'s account-identity-changed
        guard, which is the actual condition that bumps generation mid-flight).
        Returns whether the write happened.
        """
        return self._write(
            pool, resource, auth_index, identity,
            status_code=status_code, header_json=header_json, body=body, fetched_at=fetched_at,
            last_attempt=fetched_at, next_retry_at=None, consecutive_failures=0,
            expected_generation=expected_generation,
        )

    def record_failure(
        self,
        pool: str,
        resource: str,
        auth_index: str,
        identity: str,
        attempted_at: float,
        next_retry_at: Optional[float],
        consecutive_failures: int,
        expected_generation: Optional[int],
    ) -> bool:
        existing = self.get(pool, resource, auth_index)
        keep_status = existing.status_code if existing and existing.identity == identity else None
        keep_header = existing.header_json if existing and existing.identity == identity else None
        keep_body = existing.body if existing and existing.identity == identity else None
        keep_fetched_at = existing.fetched_at if existing and existing.identity == identity else None
        return self._write(
            pool, resource, auth_index, identity,
            status_code=keep_status, header_json=keep_header, body=keep_body, fetched_at=keep_fetched_at,
            last_attempt=attempted_at, next_retry_at=next_retry_at, consecutive_failures=consecutive_failures,
            expected_generation=expected_generation,
        )

    def _write(
        self,
        pool: str,
        resource: str,
        auth_index: str,
        identity: str,
        *,
        status_code: Optional[int],
        header_json: Optional[str],
        body: Optional[str],
        fetched_at: Optional[float],
        last_attempt: float,
        next_retry_at: Optional[float],
        consecutive_failures: int,
        expected_generation: Optional[int],
    ) -> bool:
        with self._lock:
            cur = self._conn.execute(
                "SELECT generation FROM cache_rows WHERE pool = ? AND resource = ? AND auth_index = ?",
                (pool, resource, auth_index),
            )
            row = cur.fetchone()
            current_generation = row[0] if row else 0
            if expected_generation is not None and row is not None and current_generation != expected_generation:
                return False
            next_generation = current_generation + 1
            self._conn.execute(
                "INSERT INTO cache_rows (pool, resource, auth_index, identity, status_code, header_json, "
                "body, fetched_at, last_attempt, next_retry_at, consecutive_failures, generation) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(pool, resource, auth_index) DO UPDATE SET "
                "identity=excluded.identity, status_code=excluded.status_code, header_json=excluded.header_json, "
                "body=excluded.body, fetched_at=excluded.fetched_at, last_attempt=excluded.last_attempt, "
                "next_retry_at=excluded.next_retry_at, consecutive_failures=excluded.consecutive_failures, "
                "generation=excluded.generation",
                (
                    pool, resource, auth_index, identity, status_code, header_json, body, fetched_at,
                    last_attempt, next_retry_at, consecutive_failures, next_generation,
                ),
            )
            self._conn.commit()
            return True

    def close(self) -> None:
        with self._lock:
            self._conn.close()
