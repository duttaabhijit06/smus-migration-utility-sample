"""Seed RDS one-shot seeder Lambda handler.

This handler is packaged into the `<prefix>-rds-seeder` Lambda by
`seed/rds/create.sh` step 6 and invoked exactly once (by the create.sh
script itself, synchronously) to load the schema fixture from
`seed/rds/fixtures/seed.sql` into the seed Postgres database.

The Lambda is then deleted in the same create.sh step (the seeder is a
disposable one-shot, NOT a persistent seed resource — its ARN is
recorded transiently and nulled out once the seed succeeds).

Dependency note: the deployment package vendors `pg8000` (a pure-Python
Postgres client). pg8000 is preferred over psycopg2 because pg8000 is
pure Python with zero compiled deps and packages cleanly into a Lambda
ZIP from a non-Linux build host (e.g. macOS). psycopg2-binary, by
contrast, ships compiled wheels that are platform-specific and break
when packaged from macOS for the Lambda x86_64 runtime.

Event shape (passed by `aws lambda invoke`):
    {
        "host": "<rds-endpoint>",
        "port": 5432,
        "dbname": "seeddb",
        "user": "seedadmin",
        "password": "<master-password>",
        "sql": "<full SQL fixture text>"
    }

Returns:
    {"statusCode": 200, "executed_statements": <count>}

Failures raise the underlying exception so the caller's
`aws lambda invoke` returns a FunctionError and the create.sh script
can surface a clear seeding-failed STATUS line.
"""

from __future__ import annotations

import json

import pg8000.dbapi  # vendored


def _split_statements(sql_text: str) -> list[str]:
    """Split a SQL script on `;` boundaries that are NOT inside string literals.

    A naive `sql_text.split(";")` would also split inside ``VALUES (..., 'a;b')``
    payloads, so we walk the text once and only treat `;` as a boundary
    when it is outside a single-quoted string literal. Multi-line
    statements are handled implicitly because newlines are preserved.

    Lines beginning with `--` (SQL comments) within a statement are kept
    so pg8000's parser sees them, and trailing whitespace-only chunks
    are filtered out at the end.
    """
    statements: list[str] = []
    current: list[str] = []
    in_string = False
    i = 0
    while i < len(sql_text):
        ch = sql_text[i]
        if ch == "'":
            # Postgres uses doubled `''` to escape a single quote inside
            # a string literal. Detect that case by peeking at the next
            # char; otherwise toggle the string flag.
            if in_string and i + 1 < len(sql_text) and sql_text[i + 1] == "'":
                current.append("''")
                i += 2
                continue
            in_string = not in_string
            current.append(ch)
        elif ch == ";" and not in_string:
            stmt = "".join(current).strip()
            if stmt:
                statements.append(stmt)
            current = []
        else:
            current.append(ch)
        i += 1
    tail = "".join(current).strip()
    if tail:
        statements.append(tail)
    return statements


def lambda_handler(event, context):  # noqa: ARG001
    host = event["host"]
    port = int(event.get("port", 5432))
    dbname = event["dbname"]
    user = event["user"]
    password = event["password"]
    sql_text = event["sql"]

    # connect() with ssl_context=True triggers pg8000 to negotiate TLS on
    # the wire — RDS accepts unencrypted by default but the seed prefers
    # TLS so the password isn't sent in the clear.
    conn = pg8000.dbapi.connect(
        host=host,
        port=port,
        database=dbname,
        user=user,
        password=password,
        ssl_context=True,
    )
    conn.autocommit = False
    executed = 0
    try:
        cur = conn.cursor()
        for stmt in _split_statements(sql_text):
            cur.execute(stmt)
            executed += 1
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    return {
        "statusCode": 200,
        "executed_statements": executed,
    }
