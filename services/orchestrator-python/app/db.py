from collections.abc import Iterator

import psycopg
from psycopg.rows import dict_row

from app.config import settings


def connection() -> Iterator[psycopg.Connection]:
    with psycopg.connect(settings.postgres_dsn, row_factory=dict_row) as conn:
        yield conn
